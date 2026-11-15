// DubStemMix.cpp - DubStemMix for MPC, feasibility mock-up (PRD § 16).
//
// SPDX-License-Identifier: MIT
//
// What this mock-up answers on a real MPC One+:
//   - do the MIDImix's CCs and notes reach the plugin through the track's MIDI input?
//   - can the MPC stream up to 6 stems from the SD card / USB drive while playing?
//   - can the plugin tell PLAY (resume) from PLAY START (position back to the start)?
//   - how much CPU does it take?
//
// Signal flow:
//   Content/Songs/<song>/*.wav (up to 6, sorted by name -> strips 1..6)
//     -> disk thread -> one ring buffer per stem
//     -> process(): gain = fader^2.5 (same law as the Mac app), mute, smoothed
//     -> sum -> master volume -> stereo out
//
// MIDImix (factory mapping, any channel): faders CC 19, 23, 27, 31, 49, 53 for strips 1..6,
// MUTE notes 1, 4, 7, 10, 13, 16 toggle the strip's mute.
//
// MPC transport: STOP pauses, PLAY resumes where it stopped, PLAY START jumps to the next song,
// whether pressed while stopped or while playing (the position then jumps back to the start).
// At the end of a song the next one starts on its own.
//
// Not in the mock-up: effects, LED-like meters, gapless chaining (a short silence while the
// next song's stems are opened), stem names on screen.

#include "mpc_plugin.h"

#include <algorithm>
#include <cctype>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include <dirent.h>
#include <time.h>

namespace {

constexpr int kStrips = 6;
constexpr int kFaderCC[kStrips] = {19, 23, 27, 31, 49, 53};
constexpr int kMuteNote[kStrips] = {1, 4, 7, 10, 13, 16};

// ~1.5 s of stereo audio per stem at 44.1 kHz. Power of two so the ring index is a mask.
constexpr size_t kRingFrames = 65536;
// The disk thread reads this many frames at a time.
constexpr size_t kChunkFrames = 4096;

bool hasWavExtension(const std::string& name)
{
    if (name.size() < 4) return false;
    std::string ext = name.substr(name.size() - 4);
    for (char& c : ext) c = (char)std::tolower((unsigned char)c);
    return ext == ".wav";
}

std::vector<std::string> listDir(const std::string& path, bool wantDirs)
{
    std::vector<std::string> out;
    DIR* dir = opendir(path.c_str());
    if (dir == nullptr) return out;
    while (dirent* e = readdir(dir))
    {
        std::string name = e->d_name;
        if (name.empty() || name[0] == '.') continue;
        bool isDir = e->d_type == DT_DIR;
        if (e->d_type == DT_UNKNOWN || e->d_type == DT_LNK)
        {
            DIR* probe = opendir((path + "/" + name).c_str());
            isDir = probe != nullptr;
            if (probe) closedir(probe);
        }
        if (wantDirs ? isDir : (!isDir && hasWavExtension(name))) out.push_back(name);
    }
    closedir(dir);
    std::sort(out.begin(), out.end());
    return out;
}

double nowSeconds()
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// A WAV file read in chunks, converted to stereo float. Used only by the disk thread.
class WavReader
{
public:
    ~WavReader() { close(); }

    bool open(const std::string& path)
    {
        close();
        file_ = std::fopen(path.c_str(), "rb");
        if (file_ == nullptr) return false;
        uint8_t head[12];
        if (std::fread(head, 1, 12, file_) != 12 || std::memcmp(head, "RIFF", 4) != 0 || std::memcmp(head + 8, "WAVE", 4) != 0)
            return fail();
        uint32_t format = 0;
        for (;;)
        {
            uint8_t ch[8];
            if (std::fread(ch, 1, 8, file_) != 8) return fail();
            const uint32_t len = u32(ch + 4);
            if (std::memcmp(ch, "fmt ", 4) == 0 && len >= 16)
            {
                std::vector<uint8_t> fmt(len);
                if (std::fread(fmt.data(), 1, len, file_) != len) return fail();
                format = u16(&fmt[0]);
                channels_ = (int)u16(&fmt[2]);
                rate_ = u32(&fmt[4]);
                bits_ = (int)u16(&fmt[14]);
                if (format == 0xFFFE && len >= 26) format = u16(&fmt[24]);
                if (len & 1u) std::fseek(file_, 1, SEEK_CUR);
            }
            else if (std::memcmp(ch, "data", 4) == 0)
            {
                bytesLeft_ = len;
                break;
            }
            else if (std::fseek(file_, (long)(len + (len & 1u)), SEEK_CUR) != 0)
                return fail();
        }
        isFloat_ = format == 3 && bits_ == 32;
        const bool pcm = format == 1 && (bits_ == 16 || bits_ == 24 || bits_ == 32);
        if (channels_ < 1 || channels_ > 16 || (!isFloat_ && !pcm)) return fail();
        frameBytes_ = (size_t)channels_ * (size_t)(bits_ / 8);
        scratch_.resize(kChunkFrames * frameBytes_);
        return true;
    }

    // Reads up to `frames` frames into interleaved stereo `out`. Returns the number read; 0 at the end.
    size_t read(float* out, size_t frames)
    {
        if (file_ == nullptr) return 0;
        frames = std::min(frames, std::min(kChunkFrames, (size_t)(bytesLeft_ / frameBytes_)));
        if (frames == 0) return 0;
        const size_t got = std::fread(scratch_.data(), frameBytes_, frames, file_);
        bytesLeft_ -= (uint32_t)(got * frameBytes_);
        const size_t bytes = (size_t)(bits_ / 8);
        for (size_t i = 0; i < got; ++i)
        {
            const uint8_t* s = scratch_.data() + i * frameBytes_;
            const float l = sample(s);
            const float r = channels_ > 1 ? sample(s + bytes) : l;
            out[2 * i] = l;
            out[2 * i + 1] = r;
        }
        return got;
    }

    void close()
    {
        if (file_) std::fclose(file_);
        file_ = nullptr;
        bytesLeft_ = 0;
    }

    uint32_t rate() const { return rate_; }

private:
    static uint32_t u16(const uint8_t* p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
    static uint32_t u32(const uint8_t* p) { return u16(p) | (u16(p + 2) << 16); }
    bool fail() { close(); return false; }

    float sample(const uint8_t* s) const
    {
        if (isFloat_) { float v; std::memcpy(&v, s, 4); return v; }
        if (bits_ == 16) return (float)(int16_t)(s[0] | (s[1] << 8)) / 32768.0f;
        if (bits_ == 24) return (float)((int32_t)(((uint32_t)s[0] << 8) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 24)) >> 8) / 8388608.0f;
        return (float)(int32_t)u32(s) / 2147483648.0f;
    }

    std::FILE* file_ = nullptr;
    int channels_ = 0, bits_ = 0;
    uint32_t rate_ = 0, bytesLeft_ = 0;
    bool isFloat_ = false;
    size_t frameBytes_ = 0;
    std::vector<uint8_t> scratch_;
};

// Single producer (disk thread) / single consumer (audio thread) ring of stereo frames.
struct StemRing
{
    std::vector<float> data = std::vector<float>(kRingFrames * 2);
    std::atomic<size_t> written{0}, read{0};
    std::atomic<bool> present{false};   // this strip has a stem in the current song
    std::atomic<bool> finished{false};  // the file has been read to the end
};

struct Song
{
    std::string name;
    std::vector<std::string> stems;   // full paths, strip order
};

} // namespace

class DubStemMix : public mpc::Plugin
{
public:
    enum Params
    {
        kVolume,
        kFader1, kFader6 = kFader1 + kStrips - 1,
        kMute1, kMute6 = kMute1 + kStrips - 1,
        kNext, kPlaying, kState, kStart, kStartPos, kLastCC, kLastNote, kCpu, kUnderruns, kTime,
        kNumParams
    };
    enum State { kStopped, kRunning, kLoading, kEnded };
    enum Start { kNoStart, kStartPlay, kStartPlayStart };

    static mpc::PluginInfo makeInfo()
    {
        mpc::PluginInfo i;
        i.name = "DubStemMix";
        i.vendor = "YoanDev";
        i.uniqueId = MPC_FOURCC('D', 's', 'M', 'x');   // == "uid" in plugin.json
        i.version = 1;
        i.isInstrument = true;
        i.numInputs = 0;
        i.numOutputs = 2;
        return i;
    }

    DubStemMix() : mpc::Plugin(makeInfo())
    {
        scanSongs();
        std::vector<std::string> names;
        for (const Song& s : songs_) names.push_back(s.name);
        if (names.empty()) names.push_back("(no songs)");
        if (names.size() == 1) names.push_back("-");   // a choice needs two entries

        // Parameter 0 is nudged by the host on load: the master volume is harmless.
        addParam(mpc::floatParam("volume", "Volume", 0.0f, 1.0f, 1.0f));
        for (int s = 0; s < kStrips; ++s)
        {
            const std::string id = "fader" + std::to_string(s + 1), name = "Fader " + std::to_string(s + 1);
            addParam(mpc::floatParam(id.c_str(), name.c_str(), 0.0f, 1.0f, 0.8f));
        }
        for (int s = 0; s < kStrips; ++s)
        {
            const std::string id = "mute" + std::to_string(s + 1), name = "Mute " + std::to_string(s + 1);
            addParam(mpc::boolParam(id.c_str(), name.c_str(), false));
        }
        // The song played after this one (PLAY START or end of song). Picked on screen.
        addParam(mpc::choiceParam("next", "Next", names, songs_.size() > 1 ? 1 : 0));
        // Read-only diagnostics, written by the plugin.
        addParam(mpc::choiceParam("playing", "Playing", names, 0));
        addParam(mpc::choiceParam("state", "State", {"Stopped", "Playing", "Loading", "Ended"}, 0));
        addParam(mpc::choiceParam("start", "Last start", {"-", "PLAY", "PLAY START"}, 0));
        addParam(mpc::floatParam("startpos", "Start pos", 0.0f, 1024.0f, 0.0f, "beats", 2));
        addParam(mpc::intParam("lastcc", "Last CC", -1, 127, -1));
        addParam(mpc::intParam("lastnote", "Last note", -1, 127, -1));
        addParam(mpc::floatParam("cpu", "CPU", 0.0f, 100.0f, 0.0f, "%", 1));
        addParam(mpc::intParam("underruns", "Underruns", 0, 99999, 0));
        addParam(mpc::floatParam("time", "Time", 0.0f, 3600.0f, 0.0f, "", 0));

        if (!songs_.empty()) loadSong(0);
        disk_ = std::thread([this] { diskLoop(); });
    }

    ~DubStemMix() override
    {
        quit_.store(true);
        if (disk_.joinable()) disk_.join();
    }

    void prepare(double sampleRate, int) override
    {
        sampleRate_ = sampleRate;
        // Gain smoothing: about 10 ms.
        smooth_ = 1.0f - std::exp(-1.0f / (0.010f * (float)sampleRate));
    }

    bool formatValue(int index, float v, std::string& out) override
    {
        char buf[32];
        if (index == kVolume || (index >= kFader1 && index <= kFader6))
        {
            const float g = faderGain(v);
            if (g <= 0.00001f) out = "-inf dB";
            else { std::snprintf(buf, sizeof buf, "%.1f dB", 20.0f * std::log10(g)); out = buf; }
            return true;
        }
        if (index == kTime)
        {
            std::snprintf(buf, sizeof buf, "%d:%02d", (int)v / 60, (int)v % 60);
            out = buf;
            return true;
        }
        if ((index == kLastCC || index == kLastNote) && v < 0) { out = "-"; return true; }
        return false;
    }

    void process(mpc::ProcessContext& ctx) override
    {
        const double t0 = nowSeconds();
        const int n = ctx.numFrames;
        float* outL = ctx.outputs[0];
        float* outR = ctx.outputs[1];

        handleMidi(ctx);
        handleTransport(ctx.transport, n);

#ifdef DSM_OFFLINE
        // Offline test hosts render faster than real time: wait for the disk instead of dropping out.
        while (playing_ && !songs_.empty() && readyGen_.load() != loadGen_.load()) std::this_thread::yield();
#endif
        const bool loaded = readyGen_.load(std::memory_order_acquire) == loadGen_.load(std::memory_order_relaxed);
        const bool running = playing_ && loaded && !songs_.empty() && !ended_;
        setDisplay(kState, (float)(ended_ ? kEnded : !playing_ ? kStopped : loaded ? kRunning : kLoading));

        float target[kStrips];
        for (int s = 0; s < kStrips; ++s)
            target[s] = getBool(kMute1 + s) ? 0.0f : faderGain(get(kFader1 + s));
        const float volume = faderGain(get(kVolume));

        if (running)
        {
            bool allDone = true, anyPresent = false;
            for (int s = 0; s < kStrips; ++s)
            {
                StemRing& ring = rings_[s];
                if (!ring.present.load(std::memory_order_relaxed)) continue;
                anyPresent = true;
                const size_t r = ring.read.load(std::memory_order_relaxed);
                size_t w = ring.written.load(std::memory_order_acquire);
#ifdef DSM_OFFLINE
                while (w - r < (size_t)n && !ring.finished.load()) { std::this_thread::yield(); w = ring.written.load(std::memory_order_acquire); }
#endif
                const size_t take = std::min((size_t)n, w - r);
                float g = gain_[s];
                for (size_t i = 0; i < take; ++i)
                {
                    g += (target[s] - g) * smooth_;
                    const size_t k = ((r + i) & (kRingFrames - 1)) * 2;
                    outL[i] += ring.data[k] * g;
                    outR[i] += ring.data[k + 1] * g;
                }
                gain_[s] = g;
                ring.read.store(r + take, std::memory_order_release);
                const bool finished = ring.finished.load(std::memory_order_acquire);
                if (take < (size_t)n && !finished) underruns_++;
                if (!(finished && w == r + take)) allDone = false;
            }
            for (int i = 0; i < n; ++i) { outL[i] *= volume; outR[i] *= volume; }
            framesPlayed_ += n;
            if (anyPresent && allDone) advance();   // end of song: the next one starts on its own
        }

        // CPU: time spent in this call against the block's duration, smoothed.
        const double load = (nowSeconds() - t0) / ((double)n / sampleRate_) * 100.0;
        cpu_ += (float)(load - cpu_) * 0.02f;

        // Refresh the read-only displays about 5 times a second.
        displayCounter_ += n;
        if (displayCounter_ >= (int)(sampleRate_ / 5))
        {
            displayCounter_ = 0;
            setDisplay(kCpu, cpu_);
            setDisplay(kUnderruns, (float)underruns_);
            setDisplay(kTime, (float)(framesPlayed_ / sampleRate_));
        }
    }

private:
    static float faderGain(float position) { return std::pow(position, 2.5f); }

    // Writes a read-only parameter and tells the screen, only when it changed.
    void setDisplay(int index, float plain)
    {
        if (std::fabs(get(index) - plain) < 1e-6f) return;
        set(index, plain);
        notifyHostParameterChanged(index);
    }

    void handleMidi(const mpc::ProcessContext& ctx)
    {
        for (int i = 0; i < ctx.numMidiEvents; ++i)
        {
            const mpc::MidiEvent& e = ctx.midi[i];
            if (e.isController())
            {
                setDisplay(kLastCC, (float)e.controller());
                for (int s = 0; s < kStrips; ++s)
                    if (e.controller() == kFaderCC[s]) setDisplay(kFader1 + s, (float)e.controllerValue() / 127.0f);
            }
            else if (e.isNoteOn())
            {
                setDisplay(kLastNote, (float)e.note());
                for (int s = 0; s < kStrips; ++s)
                    if (e.note() == kMuteNote[s]) setDisplay(kMute1 + s, getBool(kMute1 + s) ? 0.0f : 1.0f);
            }
        }
    }

    void handleTransport(const mpc::Transport& t, int frames)
    {
        if (!t.valid) return;
        if (t.playing && !playing_)
        {
            // PLAY START puts the MPC's position back to the start; PLAY resumes from where it was.
            const bool fromStart = t.ppqValid && t.ppqPos < 0.01;
            setDisplay(kStart, (float)(fromStart ? kStartPlayStart : kStartPlay));
            setDisplay(kStartPos, t.ppqValid ? (float)t.ppqPos : 0.0f);
            // The first start of a song only plays it; PLAY START moves on once it has been heard.
            if ((fromStart && framesPlayed_ > 0) || ended_) advance();
        }
        else if (t.playing && playing_ && t.ppqValid && lastPpqValid_ && jumpedToStart(t))
        {
            // PLAY START pressed while playing: the MPC never stops, its position just jumps back.
            setDisplay(kStart, (float)kStartPlayStart);
            setDisplay(kStartPos, (float)t.ppqPos);
            advance();
        }
        playing_ = t.playing;
        lastPpqValid_ = t.playing && t.ppqValid;
        lastPpq_ = t.ppqPos;
        lastBlockBeats_ = (double)frames / sampleRate_ * (t.tempoValid ? t.bpm : 120.0) / 60.0;
    }

    // True when the position jumped back, unless it is the MPC's sequence looping:
    // a loop goes back exactly at its end, which is on a bar line, while PLAY START comes anywhere.
    bool jumpedToStart(const mpc::Transport& t) const
    {
        if (t.ppqPos > lastPpq_ - 0.001) return false;   // the position only moves forward otherwise
        const double expected = lastPpq_ + lastBlockBeats_;
        const double slack = lastBlockBeats_ + 0.001;
        if (t.cycling && t.cycleEndPpq > t.cycleStartPpq)
            return expected < t.cycleEndPpq - slack;
        const double bar = t.timeSigDenominator > 0 ? 4.0 * t.timeSigNumerator / t.timeSigDenominator : 4.0;
        const double toBarLine = std::ceil(expected / bar - 1e-9) * bar - expected;
        const double fromBarLine = expected - std::floor(expected / bar + 1e-9) * bar;
        return toBarLine > slack && fromBarLine > slack;
    }

    // Moves to the song picked as "Next", then points "Next" at the one after it.
    void advance()
    {
        const int next = getInt(kNext);
        if (next >= (int)songs_.size() || next == current_)
        {
            ended_ = true;
            return;
        }
        loadSong(next);
        if (next + 1 < (int)songs_.size()) setDisplay(kNext, (float)(next + 1));
    }

    // Asks the disk thread to open a song. Called from the constructor or the audio thread.
    void loadSong(int index)
    {
        current_ = index;
        ended_ = false;
        framesPlayed_ = 0;
        requestedSong_.store(index, std::memory_order_relaxed);
        loadGen_.fetch_add(1, std::memory_order_release);
        setDisplay(kPlaying, (float)index);
    }

    void scanSongs()
    {
        const std::string root = mpc::contentPath("Songs");
        for (const std::string& dir : listDir(root, true))
        {
            Song song;
            song.name = dir;
            for (const std::string& f : listDir(root + "/" + dir, false))
                if ((int)song.stems.size() < kStrips) song.stems.push_back(root + "/" + dir + "/" + f);
            if (!song.stems.empty()) songs_.push_back(std::move(song));
        }
        mpc::log("DubStemMix: %d song(s) in %s", (int)songs_.size(), root.c_str());
    }

    // The disk thread: opens the requested song, then keeps every ring topped up.
    void diskLoop()
    {
        WavReader readers[kStrips];
        std::vector<float> chunk(kChunkFrames * 2);
        int gen = -1;
        while (!quit_.load())
        {
            const int wanted = loadGen_.load(std::memory_order_acquire);
            if (wanted != gen && !songs_.empty())
            {
                // The audio thread does not read the rings until readyGen_ catches up with loadGen_.
                gen = wanted;
                const Song& song = songs_[(size_t)requestedSong_.load(std::memory_order_relaxed)];
                for (int s = 0; s < kStrips; ++s)
                {
                    StemRing& ring = rings_[s];
                    ring.read.store(0, std::memory_order_relaxed);
                    ring.written.store(0, std::memory_order_relaxed);
                    ring.finished.store(false, std::memory_order_relaxed);
                    const bool ok = s < (int)song.stems.size() && readers[s].open(song.stems[(size_t)s]);
                    if (!ok) readers[s].close();
                    if (ok && readers[s].rate() != 44100)
                        mpc::log("DubStemMix: %s is %u Hz, the MPC plays at 44100 Hz", song.stems[(size_t)s].c_str(), readers[s].rate());
                    ring.present.store(ok, std::memory_order_relaxed);
                    while (ok && fill(ring, readers[s], chunk)) {}
                }
                readyGen_.store(gen, std::memory_order_release);
                continue;
            }
            bool busy = false;
            for (int s = 0; s < kStrips; ++s)
                if (rings_[s].present.load(std::memory_order_relaxed)) busy |= fill(rings_[s], readers[s], chunk);
            if (!busy) std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }

    // Reads one chunk into the ring if there is room. Returns true when it read something.
    static bool fill(StemRing& ring, WavReader& reader, std::vector<float>& chunk)
    {
        if (ring.finished.load(std::memory_order_relaxed)) return false;
        const size_t w = ring.written.load(std::memory_order_relaxed);
        const size_t r = ring.read.load(std::memory_order_acquire);
        const size_t room = kRingFrames - (w - r);
        if (room < kChunkFrames) return false;
        const size_t got = reader.read(chunk.data(), kChunkFrames);
        for (size_t i = 0; i < got; ++i)
        {
            const size_t k = ((w + i) & (kRingFrames - 1)) * 2;
            ring.data[k] = chunk[2 * i];
            ring.data[k + 1] = chunk[2 * i + 1];
        }
        ring.written.store(w + got, std::memory_order_release);
        if (got == 0) ring.finished.store(true, std::memory_order_release);
        return got > 0;
    }

    std::vector<Song> songs_;
    StemRing rings_[kStrips];
    std::thread disk_;
    std::atomic<bool> quit_{false};
    std::atomic<int> loadGen_{0}, readyGen_{-1}, requestedSong_{0};

    // Audio thread state.
    double sampleRate_ = 44100.0;
    float smooth_ = 0.002f;
    float gain_[kStrips] = {};
    bool playing_ = false, ended_ = false, lastPpqValid_ = false;
    double lastPpq_ = 0.0, lastBlockBeats_ = 0.0;
    int current_ = 0;
    long long framesPlayed_ = 0;
    int underruns_ = 0, displayCounter_ = 0;
    float cpu_ = 0.0f;
};

MPC_PLUGIN_ENTRY(DubStemMix)
