// Engine.h - the sound side of DubStemMix for the desktop: the engine, the sound card, the MIDImix.
//
// The engine (DubEngine.cpp) still presents itself as the MPC framework's plugin: MIDI in, audio out at
// 44.1 kHz, and parameters found by name, which are what the screen shows and sets. Songs and the transport
// go through dsm::transport() (StripSource.h).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <juce_audio_utils/juce_audio_utils.h>

#include "mpc_vst2_abi.h"
#include "FX.h"
#include "StripSource.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <map>
#include <string>

// The engine's entry point (DubEngine.cpp).
extern "C" AEffect* VSTPluginMain(audioMasterCallback host);

namespace dsm {

constexpr double kRate = 44100.0;   // the engine's only rate, like the MPC; other sound cards are resampled to
constexpr int kChunk = 512;         // the engine is fed at most this many frames at a time
constexpr int kStrips = 8;          // the console's strips
constexpr int kStems = kStemStrips;  // strips 1 to 6 carry stems, 7 and 8 the effects (PRD § 14)
constexpr int kSongSlots = 24;      // songs listed at a time

// MIDImix factory mapping (Sources/DubStemMixCore/MidiMix.swift). LEDs are lit by a Note On on the button's note.
constexpr int kBankLeftNote = 25, kBankRightNote = 26;
inline int muteNote(int strip) { return 1 + 3 * strip; }
inline int recArmNote(int strip) { return 3 + 3 * strip; }
// The engine's gestures that are not on the console, as the notes it takes them from.
constexpr int kDropNote = 38, kCrashNote = 40, kRewindNote = 41;

enum Page { kMix, kFx, kMaster, kInserts };

// Single-producer, single-consumer queue of 3-byte MIDI messages towards the audio thread.
struct MidiQueue
{
    std::array<uint32_t, 1024> items{};
    std::atomic<size_t> read{0}, written{0};

    void push(uint8_t status, uint8_t a, uint8_t b)
    {
        const size_t w = written.load(std::memory_order_relaxed);
        if (w - read.load(std::memory_order_acquire) >= items.size()) return;   // full: drop
        items[w % items.size()] = (uint32_t)status | ((uint32_t)a << 8) | ((uint32_t)b << 16);
        written.store(w + 1, std::memory_order_release);
    }
    bool pop(uint8_t out[3])
    {
        const size_t r = read.load(std::memory_order_relaxed);
        if (r == written.load(std::memory_order_acquire)) return false;
        const uint32_t m = items[r % items.size()];
        out[0] = (uint8_t)m; out[1] = (uint8_t)(m >> 8); out[2] = (uint8_t)(m >> 16);
        read.store(r + 1, std::memory_order_release);
        return true;
    }
};

struct Engine
{
    AEffect* plugin = nullptr;
    MidiQueue fromConsole, fromScreen;    // one producer each: the MIDI thread, the window's thread
    std::atomic<float> lastLevel{0.0f};   // last output sample (left), for the self-test
    VstTimeInfo timeInfo{};

    // Parameter indices, found once by the name the plugin gives them. -1 when the plugin has none.
    int master = -1, delaySync = -1, reverbModel = -1, bus3Model = -1, throwTarget = -1, page = -1;
    int next = -1, nowPlaying = -1, state = -1, timeLeft = -1, underruns = -1, listPage = -1, listPrev = -1, listNext = -1;
    int fader[kStems], mute[kStems], send[kStems][3], solo[kStems], keep[kStems], name[kStems];
    int insert[kStems], insertValue[kStems][3];
    int mode[2];                          // strips 5 and 6: stem or instrument
    int busTo[fx::BusCount];
    int lampMute[kStrips], lampRec[kStrips], meter[kStrips];
    int effect[fx::Count];
    int cue[kSongSlots], slot[kSongSlots], title[kSongSlots];

    static Engine& get() { static Engine instance; return instance; }

    void open()
    {
        plugin = VSTPluginMain(&Engine::host);
        plugin->dispatcher(plugin, effOpen, 0, 0, nullptr, 0.0f);
        plugin->dispatcher(plugin, effSetSampleRate, 0, 0, nullptr, (float)kRate);
        plugin->dispatcher(plugin, effSetBlockSize, 0, kChunk, nullptr, 0.0f);
        plugin->dispatcher(plugin, effMainsChanged, 0, 1, nullptr, 0.0f);
        bind();
    }

    static VstIntPtr host(AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
    {
        Engine& e = get();
        if (opcode == audioMasterVersion) return 2400;
        if (opcode == audioMasterGetSampleRate) return (VstIntPtr)kRate;
        if (opcode == audioMasterGetBlockSize) return kChunk;
        if (opcode == audioMasterGetTime)
        {
            VstTimeInfo& t = e.timeInfo;
            std::memset(&t, 0, sizeof t);
            t.sampleRate = kRate;
            t.tempo = 120.0;
            t.flags = kVstTempoValid;
            return (VstIntPtr)&t;
        }
        return 0;
    }

    // Audio thread: `frames` frames at 44.1 kHz.
    void render(float* left, float* right, int frames)
    {
        deliver(fromConsole);
        deliver(fromScreen);
        for (int done = 0; done < frames;)
        {
            const int n = std::min(kChunk, frames - done);
            float* outs[2] = {left + done, right + done};
            plugin->processReplacing(plugin, nullptr, outs, n);
            done += n;
        }
        if (frames > 0) lastLevel.store(left[frames - 1], std::memory_order_relaxed);
    }

    // ---- What the screen reads and sets (window's thread) ----

    float value(int index) const { return index < 0 ? 0.0f : plugin->getParameter(plugin, index); }
    bool on(int index) const { return value(index) > 0.5f; }
    int choice(int index, int count) const { return (int)std::lround(value(index) * (float)(count - 1)); }
    void set(int index, float normalised) { if (index >= 0) plugin->setParameter(plugin, index, juce::jlimit(0.0f, 1.0f, normalised)); }
    void setChoice(int index, int which, int count) { set(index, (float)which / (float)(count - 1)); }
    juce::String text(int index) const
    {
        if (index < 0) return {};
        char buf[64] = {};
        plugin->dispatcher(plugin, effGetParamDisplay, index, 0, buf, 0.0f);
        return juce::String::fromUTF8(buf);
    }

    // Buttons, as the console sends them.
    void press(int note) { fromScreen.push(0x90, (uint8_t)note, 127); }
    void lift(int note) { fromScreen.push(0x80, (uint8_t)note, 0); }
    void tap(int note) { press(note); lift(note); }

    // ---- Transport ----

    bool isPlaying() const { return transport().playing.load() && !transport().ended.load(); }
    void togglePlay()
    {
        Transport& t = transport();
        if (isPlaying()) { t.playing.store(false); return; }
        if (t.ended.load()) t.seekTo.store(0);   // played to its end: from the top again
        t.playing.store(true);
    }
    void restartSong() { transport().seekTo.store(0); }
    double seconds() const { return (double)transport().position.load() / kRate; }
    double duration() const { return (double)transport().length.load() / kRate; }
    void seekSeconds(double s) { transport().seekTo.store((long long)(juce::jmax(0.0, s) * kRate)); }
    void panic() { press(kBankLeftNote); press(kBankRightNote); lift(kBankLeftNote); lift(kBankRightNote); }

    int currentPage() const { return choice(page, 4); }
    // The console only has BANK LEFT (back to MIX) and BANK RIGHT (one page on): walk there.
    void showPage(int wanted)
    {
        int from = currentPage();
        if (wanted < from) { tap(kBankLeftNote); from = kMix; }
        for (; from < wanted; ++from) tap(kBankRightNote);
    }

    bool isInstrument(int strip) const { return (strip == 4 || strip == 5) && on(mode[strip - 4]); }

    // The parameter under a strip's knob on the current page, or -1 (the plugin's own knobTarget).
    int knobTarget(int strip, int row) const
    {
        auto effectOrNone = [this](int p) { return p == fx::None ? -1 : effect[p]; };
        switch (currentPage())
        {
            case kMix:
                if (strip >= kStems) return effectOrNone(fx::kEffectStripLayout[strip - kStems][row]);
                if (isInstrument(strip)) return effectOrNone(fx::kInstrumentLayout[strip - 4][row]);
                return send[strip][row];
            case kFx: return effectOrNone(fx::kFxLayout[strip][row]);
            case kMaster: return effectOrNone(fx::kMasterLayout[strip][row]);
            default:
                if (strip >= kStems || row >= fx::insert::knobCount(choice(insert[strip], fx::insert::KindCount))) return -1;
                return insertValue[strip][row];
        }
    }
    // The effect parameter (fx::Param) under a knob, or fx::None for a send, an insert knob or nothing.
    int knobEffect(int strip, int row) const
    {
        switch (currentPage())
        {
            case kMix:
                if (strip >= kStems) return fx::kEffectStripLayout[strip - kStems][row];
                return isInstrument(strip) ? fx::kInstrumentLayout[strip - 4][row] : (int)fx::None;
            case kFx: return fx::kFxLayout[strip][row];
            case kMaster: return fx::kMasterLayout[strip][row];
            default: return fx::None;
        }
    }
    int faderTarget(int strip) const { return strip < kStems ? fader[strip] : effect[fx::kEffectStripFader[strip - kStems]]; }

private:
    void deliver(MidiQueue& queue)
    {
        uint8_t m[3];
        while (queue.pop(m))
        {
            VstMidiEvent e{};
            e.type = kVstMidiType;
            e.byteSize = sizeof e;
            e.midiData[0] = (char)m[0]; e.midiData[1] = (char)m[1]; e.midiData[2] = (char)m[2];
            VstEvents events{};
            events.numEvents = 1;
            events.events[0] = reinterpret_cast<VstEvent*>(&e);
            plugin->dispatcher(plugin, effProcessEvents, 0, 0, &events, 0.0f);
        }
    }

    void bind()
    {
        std::map<std::string, int> byName;
        for (int i = 0; i < plugin->numParams; ++i)
        {
            char buf[64] = {};
            plugin->dispatcher(plugin, effGetParamName, i, 0, buf, 0.0f);
            byName.emplace(buf, i);
        }
        auto find = [&byName](const std::string& n) { const auto it = byName.find(n); return it == byName.end() ? -1 : it->second; };
        auto numbered = [&find](const char* prefix, int n, const char* suffix = "") { return find(prefix + std::to_string(n) + suffix); };

        master = find("Master");
        delaySync = find("Delay sync");
        reverbModel = find("Reverb");
        bus3Model = find("Bus 3");
        throwTarget = find("Throw");
        busTo[fx::Delay] = find("DLY> to");
        busTo[fx::Reverb] = find("REV> to");
        busTo[fx::Bus3] = find("PHS> to");
        page = find("Page");
        next = find("Next");
        nowPlaying = find("Playing");
        state = find("State");
        timeLeft = find("Time left");
        underruns = find("Underruns");
        listPage = find("List page");
        listPrev = find("Page back");
        listNext = find("Page on");
        mode[0] = find("Strip 5");
        mode[1] = find("Strip 6");
        for (int s = 0; s < kStems; ++s)
        {
            fader[s] = numbered("Fader ", s + 1);
            mute[s] = numbered("Mute ", s + 1);
            send[s][0] = numbered("DLY ", s + 1);
            send[s][1] = numbered("REV ", s + 1);
            send[s][2] = numbered("PHS ", s + 1);
            solo[s] = numbered("Solo ", s + 1);
            keep[s] = numbered("Keep ", s + 1);
            name[s] = numbered("Name ", s + 1);
            insert[s] = numbered("Insert ", s + 1);
            for (int i = 0; i < 3; ++i) insertValue[s][i] = numbered("Insert ", s + 1, i == 0 ? "A" : i == 1 ? "B" : "C");
        }
        for (int s = 0; s < kStrips; ++s)
        {
            lampMute[s] = numbered("Lamp M", s + 1);
            lampRec[s] = numbered("Lamp R", s + 1);
            meter[s] = numbered("Meter ", s + 1);
        }
        for (int p = 0; p < fx::Count; ++p) effect[p] = find(fx::info(p).name);
        for (int i = 0; i < kSongSlots; ++i)
        {
            cue[i] = numbered("Cue ", i + 1);
            slot[i] = numbered("Slot ", i + 1);
            title[i] = numbered("Title ", i + 1);
        }
    }
};

// ----------------------------------------------------------------------------------------------------
// Sound card: the engine's 44.1 kHz, resampled when the card runs at another rate
// ----------------------------------------------------------------------------------------------------

class Output : public juce::AudioIODeviceCallback
{
public:
    std::atomic<float> load{0.0f};    // % of the buffer's duration spent computing it
    std::atomic<int> lateBuffers{0};  // buffers that took longer to compute than they last

    void audioDeviceAboutToStart(juce::AudioIODevice* device) override
    {
        cardRate_ = device->getCurrentSampleRate();
        left_.reset();
        right_.reset();
        held_ = 0;
        lateBuffers.store(0);
    }
    void audioDeviceStopped() override {}

    void audioDeviceIOCallbackWithContext(const float* const*, int, float* const* out, int channels, int frames,
                                          const juce::AudioIODeviceCallbackContext&) override
    {
        const auto t0 = std::chrono::steady_clock::now();
        juce::ScopedNoDenormals noDenormals;
        Engine& engine = Engine::get();
        if (frames > kMaxFrames) frames = kMaxFrames;
        float* left = cardL_;
        float* right = cardR_;
        if (std::fabs(cardRate_ - kRate) < 1.0)
            engine.render(left, right, frames);
        else
        {
            // Keep enough engine audio ahead of the interpolators, then let them take what they need.
            const double ratio = kRate / cardRate_;
            const int needed = (int)std::ceil(frames * ratio) + 8;
            while (held_ < needed)
            {
                const int n = std::min(kChunk, kHeld - held_);
                engine.render(engineL_ + held_, engineR_ + held_, n);
                held_ += n;
            }
            const int used = left_.process(ratio, engineL_, left, frames);
            right_.process(ratio, engineR_, right, frames);
            held_ -= used;
            std::memmove(engineL_, engineL_ + used, sizeof(float) * (size_t)held_);
            std::memmove(engineR_, engineR_ + used, sizeof(float) * (size_t)held_);
        }
        for (int c = 0; c < channels; ++c)
            if (out[c] != nullptr) std::memcpy(out[c], c == 0 ? left : c == 1 ? right : silence_, sizeof(float) * (size_t)frames);

        const double spent = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        const double budget = frames / cardRate_;
        if (spent > budget) lateBuffers.fetch_add(1, std::memory_order_relaxed);
        const float smoothed = load.load(std::memory_order_relaxed);
        load.store(smoothed + ((float)(spent / budget * 100.0) - smoothed) * 0.05f, std::memory_order_relaxed);
    }

private:
    static constexpr int kMaxFrames = 8192, kHeld = 32768;
    double cardRate_ = kRate;
    juce::LagrangeInterpolator left_, right_;
    int held_ = 0;
    float cardL_[kMaxFrames] = {}, cardR_[kMaxFrames] = {}, silence_[kMaxFrames] = {};
    float engineL_[kHeld] = {}, engineR_[kHeld] = {};
};

// ----------------------------------------------------------------------------------------------------
// MIDImix: in (knobs, faders, buttons) and out (LEDs)
// ----------------------------------------------------------------------------------------------------

class Console : public juce::MidiInputCallback
{
public:
    bool connected = false;
    juce::String name;

    Console() { forgetLeds(); }

    static bool isMidiMix(const juce::String& deviceName)
    {
        return deviceName.containsIgnoreCase("midi mix") || deviceName.containsIgnoreCase("midimix");
    }

    void handleIncomingMidiMessage(juce::MidiInput*, const juce::MidiMessage& message) override
    {
        if (message.getRawDataSize() != 3) return;
        const juce::uint8* d = message.getRawData();
        Engine::get().fromConsole.push(d[0], d[1], d[2]);
    }

    // Called about once a second: plugs the console in when it appears, lets it go when it leaves.
    void poll()
    {
        juce::String id;
        for (const juce::MidiDeviceInfo& device : juce::MidiInput::getAvailableDevices())
            if (isMidiMix(device.name)) { id = device.identifier; name = device.name; break; }
        if (id.isNotEmpty() && !connected)
        {
            in_ = juce::MidiInput::openDevice(id, this);
            if (in_ == nullptr) return;
            in_->start();
            connected = true;
            for (const juce::MidiDeviceInfo& device : juce::MidiOutput::getAvailableDevices())
                if (isMidiMix(device.name)) { out_ = juce::MidiOutput::openDevice(device.identifier); break; }
            forgetLeds();   // light them all again
        }
        else if (id.isEmpty() && connected)
        {
            in_.reset();
            out_.reset();
            connected = false;
        }
    }

    bool hasLeds() const { return out_ != nullptr; }

    void led(int note, bool on)
    {
        if (out_ == nullptr || leds_[note] == (int)on) return;
        leds_[note] = (int)on;
        out_->sendMessageNow(juce::MidiMessage(0x90, note, on ? 127 : 0));
    }

    // The engine's lamps, sent to the console's LEDs (the MPC cannot do this, a computer can).
    void lightLeds()
    {
        const Engine& engine = Engine::get();
        for (int s = 0; s < kStrips; ++s)
        {
            led(muteNote(s), engine.on(engine.lampMute[s]));
            led(recArmNote(s), engine.on(engine.lampRec[s]));
        }
        // BANK LEDs as on the Mac (PRD § 11.1): MIX = left, FX = right, MASTER and INSERTS = both.
        const int page = engine.currentPage();
        led(kBankLeftNote, page == kMix || page >= kMaster);
        led(kBankRightNote, page >= kFx);
    }

    void shutdown()
    {
        for (int n = 0; n < 128; ++n) if (leds_[n] == 1) led(n, false);
        in_.reset();
        out_.reset();
    }

private:
    void forgetLeds() { for (int& v : leds_) v = -1; }

    std::unique_ptr<juce::MidiInput> in_;
    std::unique_ptr<juce::MidiOutput> out_;
    int leds_[128];
};

} // namespace dsm
