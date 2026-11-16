// Recorder.h - recorded sessions (PRD § 5.9): the master as a 32-bit float WAV written off the audio thread,
// one folder per session with its sheet, and the MP3 export.
//
// Same folders and same files as the Mac app (Sources/DubStemMixCore/RecordingSession.swift, SessionExport.swift):
// a session recorded on one shows in the other's list.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <juce_audio_formats/juce_audio_formats.h>

#include "DubDSP.h"
#include "lame.h"

#include <atomic>
#include <ctime>
#include <functional>
#include <vector>

namespace dsm {

// The master, after the limiter, at the engine's rate. Float keeps what goes over 0 dB with the limiter off.
class Recorder
{
public:
    static Recorder& get() { static Recorder instance; return instance; }

    bool start(const juce::File& file, double sampleRate)
    {
        stop();
        file.deleteFile();
        std::unique_ptr<juce::FileOutputStream> stream(file.createOutputStream());
        if (stream == nullptr) return false;
        juce::WavAudioFormat wav;
        juce::AudioFormatWriter* writer = wav.createWriterFor(stream.get(), sampleRate, 2, 32, {}, 0);   // 32 bits: float
        if (writer == nullptr) return false;
        stream.release();   // the writer owns it now
        auto threaded = std::make_unique<juce::AudioFormatWriter::ThreadedWriter>(writer, thread_, 131072);
        frames_.store(0);
        rate_ = sampleRate;
        const juce::ScopedLock lock(lock_);
        writer_ = std::move(threaded);
        recording_.store(true);
        return true;
    }

    void stop()
    {
        recording_.store(false);
        std::unique_ptr<juce::AudioFormatWriter::ThreadedWriter> finished;
        {
            const juce::ScopedLock lock(lock_);
            finished = std::move(writer_);
        }
        finished.reset();   // flushes what is left and closes the file
    }

    bool isRecording() const { return recording_.load(); }
    double seconds() const { return rate_ > 0 ? (double)frames_.load() / rate_ : 0.0; }

    // Audio thread: never waits for the disk.
    void write(const float* left, const float* right, int frames)
    {
        if (!recording_.load(std::memory_order_relaxed)) return;
        const juce::ScopedTryLock lock(lock_);
        if (!lock.isLocked() || writer_ == nullptr) return;
        const float* channels[2] = {left, right};
        if (writer_->write(channels, frames)) frames_.fetch_add(frames, std::memory_order_relaxed);
    }

private:
    Recorder() : thread_("DubStemMix recorder") { thread_.startThread(); }
    ~Recorder() { stop(); thread_.stopThread(4000); }

    juce::TimeSliceThread thread_;
    juce::CriticalSection lock_;
    std::unique_ptr<juce::AudioFormatWriter::ThreadedWriter> writer_;
    std::atomic<bool> recording_{false};
    std::atomic<juce::int64> frames_{0};
    double rate_ = 44100.0;
};

// A session's sheet: session.json for the app, session.txt for a human (and for YouTube chapters).
struct RecordingSession
{
    struct Track { double time = 0.0; juce::String title; };

    juce::Time started, ended;
    bool finished = false;
    double duration = 0.0, sampleRate = 44100.0;
    juce::String setlist, device;
    bool limiterOn = true, limiterToggled = false;
    std::vector<Track> tracks;

    static constexpr const char* kAudio = "session.wav";
    static constexpr const char* kInfo = "session.json";
    static constexpr const char* kText = "session.txt";
    static constexpr const char* kMp3 = "session.mp3";

    // "2026-10-11 21h30", or with the seconds when two sessions start in the same minute. Local time.
    static juce::File makeFolder(const juce::File& parent, juce::Time start)
    {
        parent.createDirectory();
        for (const char* format : {"%Y-%m-%d %Hh%M", "%Y-%m-%d %Hh%Mm%Ss"})
        {
            const juce::File folder = parent.getChildFile(start.formatted(format));
            if (!folder.exists() && folder.createDirectory().wasOk()) return folder;
        }
        return {};
    }

    static juce::String timestamp(double seconds)
    {
        const int total = juce::jmax(0, (int)seconds);
        const int hours = total / 3600, minutes = total / 60 % 60, secs = total % 60;
        return hours > 0 ? juce::String::formatted("%d:%02d:%02d", hours, minutes, secs) : juce::String::formatted("%02d:%02d", minutes, secs);
    }

    // The Mac reads and writes its dates as "2026-10-11T19:30:00Z" (UTC, no fraction): so does this app.
    static juce::String iso(juce::Time time)
    {
        const std::time_t seconds = (std::time_t)(time.toMilliseconds() / 1000);
        std::tm utc{};
#if JUCE_WINDOWS
        gmtime_s(&utc, &seconds);
#else
        gmtime_r(&seconds, &utc);
#endif
        return juce::String::formatted("%04d-%02d-%02dT%02d:%02d:%02dZ", utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec);
    }

    juce::String text() const
    {
        juce::StringArray lines;
        lines.add("DubStemMix session");
        lines.add("");
        lines.add("Date: " + started.formatted("%Y-%m-%d"));
        lines.add("Time: " + started.formatted("%H:%M:%S") + (finished ? juce::String::fromUTF8(" – ") + ended.formatted("%H:%M:%S") : juce::String(" (not finished)")));
        lines.add("Duration: " + timestamp(duration));
        if (setlist.isNotEmpty()) lines.add("Setlist: " + setlist);
        const juce::String rate = std::fmod(sampleRate, 1000.0) == 0.0 ? juce::String((int)(sampleRate / 1000.0)) + " kHz" : juce::String(sampleRate / 1000.0, 1) + " kHz";
        lines.add("Audio: " + (device.isNotEmpty() ? device + ", " : juce::String()) + rate + ", 32-bit float WAV");
        lines.add(juce::String("Limiter: ") + (limiterOn ? "on" : "off") + (limiterToggled ? " (switched during the session)" : ""));
        lines.add("");
        lines.add("Tracklist");
        if (tracks.empty()) lines.add("(no song played)");
        for (const Track& track : tracks) lines.add(timestamp(track.time) + " " + track.title);
        return lines.joinIntoString("\n") + "\n";
    }

    bool save(const juce::File& folder) const
    {
        auto* o = new juce::DynamicObject();
        o->setProperty("started", iso(started));
        if (finished) o->setProperty("ended", iso(ended));
        o->setProperty("duration", duration);
        if (setlist.isNotEmpty()) o->setProperty("setlist", setlist);
        if (device.isNotEmpty()) o->setProperty("device", device);
        o->setProperty("sampleRate", sampleRate);
        o->setProperty("limiterOn", limiterOn);
        o->setProperty("limiterToggled", limiterToggled);
        juce::Array<juce::var> list;
        for (const Track& track : tracks)
        {
            auto* t = new juce::DynamicObject();
            t->setProperty("time", track.time);
            t->setProperty("title", track.title);
            list.add(juce::var(t));
        }
        o->setProperty("tracks", list);
        return folder.getChildFile(kInfo).replaceWithText(juce::JSON::toString(juce::var(o)))
               && folder.getChildFile(kText).replaceWithText(text(), false, false, "\n");
    }

    static bool load(const juce::File& folder, RecordingSession& out)
    {
        const juce::var root = juce::JSON::parse(folder.getChildFile(kInfo).loadFileAsString());
        if (!root.isObject()) return false;
        out = RecordingSession();
        out.started = juce::Time::fromISO8601(root["started"].toString());
        out.finished = !root["ended"].isVoid();
        if (out.finished) out.ended = juce::Time::fromISO8601(root["ended"].toString());
        out.duration = (double)root["duration"];
        out.setlist = root["setlist"].toString();
        out.device = root["device"].toString();
        out.sampleRate = root["sampleRate"].isVoid() ? 44100.0 : (double)root["sampleRate"];
        out.limiterOn = root["limiterOn"].isVoid() ? true : (bool)root["limiterOn"];
        out.limiterToggled = (bool)root["limiterToggled"];
        if (const juce::Array<juce::var>* list = root["tracks"].getArray())
            for (const juce::var& t : *list) out.tracks.push_back({(double)t["time"], t["title"].toString()});
        return true;
    }
};

// A session of the recordings folder.
struct SessionEntry
{
    juce::File folder;
    RecordingSession session;
    juce::File audio() const { return folder.getChildFile(RecordingSession::kAudio); }
    juce::File mp3() const { return folder.getChildFile(RecordingSession::kMp3); }
    bool hasMp3() const { return mp3().existsAsFile(); }
};

// The sessions of the recordings folder, the most recent first. Old recordings (a lone WAV) are not sessions.
inline std::vector<SessionEntry> listSessions(const juce::File& parent)
{
    std::vector<SessionEntry> entries;
    for (const juce::File& folder : parent.findChildFiles(juce::File::findDirectories, false))
    {
        SessionEntry entry;
        entry.folder = folder;
        if (folder.getChildFile(RecordingSession::kAudio).existsAsFile() && RecordingSession::load(folder, entry.session)) entries.push_back(std::move(entry));
    }
    std::sort(entries.begin(), entries.end(), [](const SessionEntry& a, const SessionEntry& b) { return a.session.started > b.session.started; });
    return entries;
}

// MP3 export of a session, afterwards (PRD § 5.9): 320 kb/s, same rate as the WAV, brought to -14 LUFS with
// peaks at -1.5 dB at most. A gain only, never compression: a very dynamic session stays a little under.
namespace mp3 {

constexpr double kTargetLoudness = -14.0, kPeakCeiling = -1.5;
constexpr int kBitrate = 320;

struct Result
{
    bool ok = false;
    juce::String error;
    double loudness = 0.0, truePeak = 0.0, gain = 0.0;   // LUFS and dBTP of the WAV, dB applied
};

inline double gainFor(double loudness, double truePeak) { return juce::jmin(kTargetLoudness - loudness, kPeakCeiling - truePeak); }

// `progress` gets 0..1; `cancelled` is asked between chunks.
inline Result exportSession(const juce::File& wav, const juce::File& target, const juce::String& title,
                            const std::function<void(double)>& progress, const std::function<bool()>& cancelled)
{
    Result result;
    juce::WavAudioFormat format;
    constexpr int kChunk = 65536;
    juce::AudioBuffer<float> buffer(2, kChunk);
    auto open = [&]() { return std::unique_ptr<juce::AudioFormatReader>(format.createReaderFor(wav.createInputStream().release(), true)); };

    // Pass 1: loudness and true peak.
    std::unique_ptr<juce::AudioFormatReader> reader = open();
    if (reader == nullptr || reader->lengthInSamples <= 0) { result.error = "cannot read the recording"; return result; }
    const double rate = reader->sampleRate;
    const juce::int64 total = reader->lengthInSamples;
    DubLoudness* meter = dub_loudness_create(rate);
    if (meter == nullptr) { result.error = "out of memory"; return result; }
    for (juce::int64 at = 0; at < total; at += kChunk)
    {
        if (cancelled()) { dub_loudness_destroy(meter); result.error = "cancelled"; return result; }
        const int n = (int)juce::jmin((juce::int64)kChunk, total - at);
        reader->read(&buffer, 0, n, at, true, true);
        dub_loudness_add(meter, buffer.getReadPointer(0), buffer.getReadPointer(1), n);
        progress(0.5 * (double)(at + n) / (double)total);
    }
    result.loudness = dub_loudness_integrated(meter);
    result.truePeak = dub_loudness_true_peak(meter);
    dub_loudness_destroy(meter);
    if (!std::isfinite(result.loudness) || !std::isfinite(result.truePeak)) { result.error = "the recording is silent"; return result; }
    result.gain = gainFor(result.loudness, result.truePeak);
    const float scale = (float)std::pow(10.0, result.gain / 20.0);

    // Pass 2: encode into a temporary file, put in place of the old MP3 only once complete.
    lame_global_flags* lame = lame_init();
    if (lame == nullptr) { result.error = "the MP3 encoder failed"; return result; }
    lame_set_in_samplerate(lame, (int)rate);
    lame_set_out_samplerate(lame, (int)rate);
    lame_set_num_channels(lame, 2);
    lame_set_mode(lame, JOINT_STEREO);
    lame_set_brate(lame, kBitrate);
    lame_set_VBR(lame, vbr_off);
    lame_set_quality(lame, 2);
    id3tag_init(lame);
    id3tag_set_title(lame, title.toRawUTF8());
    const juce::File partial = target.getSiblingFile("." + target.getFileName() + ".partial");
    partial.deleteFile();
    std::unique_ptr<juce::FileOutputStream> out(partial.createOutputStream());
    if (lame_init_params(lame) < 0 || out == nullptr)
    {
        lame_close(lame);
        result.error = out == nullptr ? "cannot write the MP3" : "the MP3 encoder failed";
        return result;
    }
    std::vector<unsigned char> encoded((size_t)(kChunk * 5 / 4 + 7200));
    bool failed = false;
    for (juce::int64 at = 0; at < total && !failed; at += kChunk)
    {
        if (cancelled()) { failed = true; result.error = "cancelled"; break; }
        const int n = (int)juce::jmin((juce::int64)kChunk, total - at);
        reader->read(&buffer, 0, n, at, true, true);
        buffer.applyGain(0, n, scale);
        const int written = lame_encode_buffer_ieee_float(lame, buffer.getReadPointer(0), buffer.getReadPointer(1), n, encoded.data(), (int)encoded.size());
        if (written < 0 || !out->write(encoded.data(), (size_t)written)) { failed = true; result.error = "the MP3 encoder failed"; }
        progress(0.5 + 0.5 * (double)(at + n) / (double)total);
    }
    if (!failed)
    {
        const int written = lame_encode_flush(lame, encoded.data(), (int)encoded.size());
        if (written < 0 || !out->write(encoded.data(), (size_t)written)) { failed = true; result.error = "the MP3 encoder failed"; }
    }
    lame_close(lame);
    out.reset();
    if (failed) { partial.deleteFile(); return result; }
    target.deleteFile();
    if (!partial.moveFileTo(target)) { partial.deleteFile(); result.error = "cannot write the MP3"; return result; }
    result.ok = true;
    return result;
}

} // namespace mp3
} // namespace dsm
