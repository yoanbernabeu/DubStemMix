// Main.cpp - DubStemMix for the desktop, milestone L1 (PRD § 17.5): the JUCE base.
//
// For now the engine is the MPC plugin's (mpc/DubStemMix/src, compiled into this program unchanged). JUCE
// gives it a sound card, the MIDImix (in, and out for the LEDs) and a plain window. It plays the songs of an
// "Export to MPC" folder. Keyboard: Space = play / pause, N = next song.
//
//   dubstemmix-desktop [folder]     folder: an export folder, a card, or the plugin's own folder
//   dubstemmix-desktop --selftest   no sound card: plays test songs and checks the levels
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <juce_audio_utils/juce_audio_utils.h>

#include "mpc_vst2_abi.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <thread>

// The MPC plugin's entry point (mpc/DubStemMix/src/DubStemMix.cpp).
extern "C" AEffect* VSTPluginMain(audioMasterCallback host);

namespace {

constexpr double kRate = 44100.0;   // the engine's only rate, like the MPC; other sound cards are resampled to
constexpr int kChunk = 512;         // the engine is fed at most this many frames at a time
constexpr int kStrips = 8;

// MIDImix factory mapping (Sources/DubStemMixCore/MidiMix.swift): LEDs are lit by a Note On on the button's note.
constexpr int kBankLeftNote = 25, kBankRightNote = 26;
inline int muteNote(int strip) { return 1 + 3 * strip; }
inline int recArmNote(int strip) { return 3 + 3 * strip; }
// The plugin's GO gesture (pad 15: play the next song now), with its default "Pad 1 note" of 24.
constexpr int kGoNote = 48;

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

// The plugin's engine, driven the way the MPC drives it: a transport, MIDI in, audio out at 44.1 kHz.
struct Engine
{
    AEffect* fx = nullptr;
    std::atomic<bool> playing{false};
    double ppq = 0.0;                     // audio thread only: moves while playing, never goes back
    MidiQueue fromConsole, fromKeys;      // one producer each: the MIDI thread, the window's thread
    std::atomic<float> lastLevel{0.0f};   // last output sample (left), for the self-test
    VstTimeInfo timeInfo{};

    void open()
    {
        fx = VSTPluginMain(&Engine::host);
        fx->dispatcher(fx, effOpen, 0, 0, nullptr, 0.0f);
        fx->dispatcher(fx, effSetSampleRate, 0, 0, nullptr, (float)kRate);
        fx->dispatcher(fx, effSetBlockSize, 0, kChunk, nullptr, 0.0f);
        fx->dispatcher(fx, effMainsChanged, 0, 1, nullptr, 0.0f);
    }

    static VstIntPtr host(AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float);

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
            fx->dispatcher(fx, effProcessEvents, 0, 0, &events, 0.0f);
        }
    }

    // Audio thread: `frames` frames at 44.1 kHz.
    void render(float* left, float* right, int frames)
    {
        deliver(fromConsole);
        deliver(fromKeys);
        for (int done = 0; done < frames;)
        {
            const int n = std::min(kChunk, frames - done);
            float* outs[2] = {left + done, right + done};
            fx->processReplacing(fx, nullptr, outs, n);
            if (playing.load(std::memory_order_relaxed)) ppq += n / kRate * 2.0;   // 120 BPM
            done += n;
        }
        if (frames > 0) lastLevel.store(left[frames - 1], std::memory_order_relaxed);
    }

    // Parameters, by the name the plugin gives them (they are its screen's values).
    int param(const char* name) const
    {
        for (int i = 0; i < fx->numParams; ++i)
        {
            char buf[64] = {};
            fx->dispatcher(fx, effGetParamName, i, 0, buf, 0.0f);
            if (std::strcmp(buf, name) == 0) return i;
        }
        return -1;
    }
    float value(int index) const { return index < 0 ? 0.0f : fx->getParameter(fx, index); }
    juce::String text(int index) const
    {
        if (index < 0) return {};
        char buf[64] = {};
        fx->dispatcher(fx, effGetParamDisplay, index, 0, buf, 0.0f);
        return juce::String::fromUTF8(buf);
    }
};

Engine engine;

VstIntPtr Engine::host(AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
{
    if (opcode == audioMasterVersion) return 2400;
    if (opcode == audioMasterGetSampleRate) return (VstIntPtr)kRate;
    if (opcode == audioMasterGetBlockSize) return kChunk;
    if (opcode == audioMasterGetTime)
    {
        VstTimeInfo& t = engine.timeInfo;
        std::memset(&t, 0, sizeof t);
        t.sampleRate = kRate;
        t.tempo = 120.0;
        t.ppqPos = engine.ppq;
        t.flags = kVstTempoValid | kVstPpqPosValid | (engine.playing.load(std::memory_order_relaxed) ? kVstTransportPlaying : 0);
        return (VstIntPtr)&t;
    }
    return 0;
}

// The two keyboard gestures.
void togglePlay() { engine.playing.store(!engine.playing.load()); }
void nextSong()
{
    engine.fromKeys.push(0x90, kGoNote, 127);
    engine.fromKeys.push(0x80, kGoNote, 0);
}

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
        engine.fromConsole.push(d[0], d[1], d[2]);
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

// ----------------------------------------------------------------------------------------------------
// Songs folder
// ----------------------------------------------------------------------------------------------------

// The folder holding Content/Songs, from what the user gave: an export folder or a card
// ("VST2 Plugins/YoanDev - VST - DubStemMix" inside), or the plugin's folder itself. Empty when not found.
juce::String pluginFolder(const juce::File& given)
{
    const juce::File inExport = given.getChildFile("VST2 Plugins").getChildFile("YoanDev - VST - DubStemMix");
    if (inExport.getChildFile("Content").getChildFile("Songs").isDirectory()) return inExport.getFullPathName();
    if (given.getChildFile("Content").getChildFile("Songs").isDirectory()) return given.getFullPathName();
    return {};
}

void setEnvironment(const char* name, const juce::String& value)
{
#if JUCE_WINDOWS
    _putenv_s(name, value.toRawUTF8());
#else
    setenv(name, value.toRawUTF8(), 1);
#endif
}

// ----------------------------------------------------------------------------------------------------
// Window
// ----------------------------------------------------------------------------------------------------

class MainComponent : public juce::Component, private juce::Timer
{
public:
    explicit MainComponent(juce::String folder) : folder_(std::move(folder))
    {
        bind();
        juce::AudioDeviceManager::AudioDeviceSetup setup;
        setup.sampleRate = kRate;
        setup.bufferSize = 256;
        const juce::String error = devices_.initialise(0, 2, nullptr, true, {}, &setup);
        if (error.isNotEmpty()) soundError_ = error;
        devices_.addAudioCallback(&output_);

        soundButton_.setButtonText("Sound card...");
        soundButton_.onClick = [this] { showSoundSettings(); };
        soundButton_.setWantsKeyboardFocus(false);
        addAndMakeVisible(soundButton_);

        setWantsKeyboardFocus(true);
        setSize(1100, 620);
        startTimerHz(30);
    }

    ~MainComponent() override
    {
        stopTimer();
        devices_.removeAudioCallback(&output_);
        devices_.closeAudioDevice();
        console_.shutdown();
    }

    bool keyPressed(const juce::KeyPress& key) override
    {
        if (key == juce::KeyPress::spaceKey) { togglePlay(); return true; }
        if (key.getTextCharacter() == 'n' || key.getTextCharacter() == 'N') { nextSong(); return true; }
        return false;
    }

    void resized() override { soundButton_.setBounds(getWidth() - 150, 10, 136, 26); }

    void paint(juce::Graphics& g) override
    {
        const juce::Colour background(0xff14110f), surface(0xff2e2823), cream(0xffede3cf), dim(0xff9a8f7e);
        const juce::Colour delay(0xffd9a441), sage(0xff7e9b5a), red(0xffe5412d);
        g.fillAll(background);
        g.setFont(juce::FontOptions(15.0f));
        int y = 10;
        auto line = [&](const juce::String& text, juce::Colour colour)
        {
            g.setColour(colour);
            g.drawText(text, 14, y, getWidth() - 180, 20, juce::Justification::centredLeft);
            y += 22;
        };

        // Song
        const juce::String title = engine.text(playing_);
        if (folder_.isEmpty()) line("No songs folder. Start with: dubstemmix-desktop <export folder>", red);
        else if (title.isEmpty()) line("No song found in " + folder_, red);
        else line(title + "   |   " + engine.text(state_) + "   |   time left " + engine.text(timeLeft_)
                  + "   |   next: " + engine.text(next_) + "   |   page " + engine.text(page_), cream);
        line("Space = play / pause    N = next song", dim);

        // Sound card and console
        if (juce::AudioIODevice* device = devices_.getCurrentAudioDevice())
        {
            const double rate = device->getCurrentSampleRate();
            const int buffer = device->getCurrentBufferSizeSamples();
            line(device->getName() + " (" + device->getTypeName() + ")   " + juce::String(buffer) + " frames at "
                 + juce::String((int)rate) + " Hz = " + juce::String(buffer * 1000.0 / rate, 1) + " ms   |   load "
                 + juce::String(output_.load.load(), 1) + " %   |   late buffers " + juce::String(output_.lateBuffers.load())
                 + "   |   disk dropouts " + engine.text(underruns_), dim);
        }
        else line("No sound: " + (soundError_.isEmpty() ? juce::String("no sound card open") : soundError_), red);
        if (console_.connected) line("MIDImix connected: " + console_.name + (console_.hasLeds() ? " (LEDs on)" : " (no LED port)"), sage);
        else line("MIDImix not connected", delay);
        y += 8;

        // Console mirror: name, fader, meter, MUTE and REC ARM lamps.
        const int columnWidth = (getWidth() - 28) / (kStrips + 1);
        const int top = y + 24, height = juce::jmax(100, getHeight() - top - 60);
        auto bar = [&](int x, int width, float value, juce::Colour colour)
        {
            g.setColour(surface);
            g.fillRect(x, top, width, height);
            const int filled = (int)(height * juce::jlimit(0.0f, 1.0f, value));
            g.setColour(colour);
            g.fillRect(x, top + height - filled, width, filled);
        };
        for (int s = 0; s <= kStrips; ++s)
        {
            const bool isMaster = s == kStrips;
            const int x = 14 + s * columnWidth;
            const juce::String label = isMaster ? "MASTER" : s == 6 ? "7 DELAY" : s == 7 ? "8 SPACE"
                                       : juce::String(s + 1) + " " + engine.text(name_[s]);
            g.setColour(cream);
            g.drawText(label, x, y, columnWidth - 8, 20, juce::Justification::centredLeft);
            bar(x, 28, engine.value(isMaster ? master_ : fader_[s]), cream);
            if (isMaster) continue;
            bar(x + 36, 10, engine.value(meter_[s]), sage);
            g.setColour(engine.value(lampMute_[s]) > 0.5f ? cream : surface.brighter(0.15f));
            g.drawText("MUTE", x, top + height + 8, columnWidth - 8, 18, juce::Justification::centredLeft);
            g.setColour(engine.value(lampRec_[s]) > 0.5f ? delay : surface.brighter(0.15f));
            g.drawText("REC ARM", x, top + height + 28, columnWidth - 8, 18, juce::Justification::centredLeft);
        }
    }

private:
    void bind()
    {
        master_ = engine.param("Master");
        playing_ = engine.param("Playing");
        next_ = engine.param("Next");
        state_ = engine.param("State");
        timeLeft_ = engine.param("Time left");
        page_ = engine.param("Page");
        underruns_ = engine.param("Underruns");
        for (int s = 0; s < kStrips; ++s)
        {
            const juce::String n(s + 1);
            // Faders 7 and 8 are the delay and reverb returns (PRD § 14).
            fader_[s] = engine.param(s == 6 ? "DLY Return" : s == 7 ? "REV Return" : ("Fader " + n).toRawUTF8());
            name_[s] = engine.param(("Name " + n).toRawUTF8());
            lampMute_[s] = engine.param(("Lamp M" + n).toRawUTF8());
            lampRec_[s] = engine.param(("Lamp R" + n).toRawUTF8());
            meter_[s] = engine.param(("Meter " + n).toRawUTF8());
        }
    }

    void timerCallback() override
    {
        if (++ticks_ % 30 == 1) console_.poll();
        // The plugin's lamps, sent to the console's LEDs (the MPC cannot do this, a computer can).
        for (int s = 0; s < kStrips; ++s)
        {
            console_.led(muteNote(s), engine.value(lampMute_[s]) > 0.5f);
            console_.led(recArmNote(s), engine.value(lampRec_[s]) > 0.5f);
        }
        // BANK LEDs as on the Mac (PRD § 11.1): MIX = left, FX = right, MASTER and INSERTS = both.
        const int page = (int)std::lround(engine.value(page_) * 3.0f);
        console_.led(kBankLeftNote, page == 0 || page >= 2);
        console_.led(kBankRightNote, page >= 1);
        repaint();
    }

    void showSoundSettings()
    {
        auto* selector = new juce::AudioDeviceSelectorComponent(devices_, 0, 0, 2, 2, false, false, true, false);
        selector->setSize(520, 360);
        juce::DialogWindow::LaunchOptions options;
        options.content.setOwned(selector);
        options.dialogTitle = "Sound card";
        options.dialogBackgroundColour = juce::Colour(0xff1e1a17);
        options.escapeKeyTriggersCloseButton = true;
        options.resizable = false;
        options.launchAsync();
    }

    juce::String folder_, soundError_;
    juce::AudioDeviceManager devices_;
    Output output_;
    Console console_;
    juce::TextButton soundButton_;
    int ticks_ = 0;
    int master_ = -1, playing_ = -1, next_ = -1, state_ = -1, timeLeft_ = -1, page_ = -1, underruns_ = -1;
    int fader_[kStrips], name_[kStrips], lampMute_[kStrips], lampRec_[kStrips], meter_[kStrips];
};

class MainWindow : public juce::DocumentWindow
{
public:
    explicit MainWindow(const juce::String& folder)
        : juce::DocumentWindow("DubStemMix", juce::Colour(0xff14110f), juce::DocumentWindow::allButtons)
    {
        setUsingNativeTitleBar(true);
        setContentOwned(new MainComponent(folder), true);
        setResizable(true, false);
        centreWithSize(getWidth(), getHeight());
        setVisible(true);
        if (juce::Component* content = getContentComponent()) content->grabKeyboardFocus();
    }
    void closeButtonPressed() override { juce::JUCEApplication::getInstance()->systemRequestedQuit(); }
};

// ----------------------------------------------------------------------------------------------------
// Self-test: no sound card. A thread plays the engine at real-time pace (its disk thread expects that).
// Same gestures and same expected levels as the MPC plugin's own test (mpc/tests/transport_test.cpp).
// ----------------------------------------------------------------------------------------------------

void writeSong(const juce::File& root, const char* name, float level, double seconds)
{
    const juce::File dir = root.getChildFile("Content").getChildFile("Songs").getChildFile(name);
    dir.createDirectory();
    juce::FileOutputStream out(dir.getChildFile("1 - stem.wav"));
    const uint32_t frames = (uint32_t)(seconds * kRate), data = frames * 4;
    out.write("RIFF", 4); out.writeInt((int)(36 + data)); out.write("WAVEfmt ", 8);
    out.writeInt(16); out.writeShort(1); out.writeShort(2); out.writeInt(44100); out.writeInt(44100 * 4);
    out.writeShort(4); out.writeShort(16);
    out.write("data", 4); out.writeInt((int)data);
    const short sample = (short)(level * 32767.0f);
    for (uint32_t i = 0; i < frames * 2; ++i) out.writeShort(sample);
}

int runSelfTest()
{
    const juce::File root = juce::File::getSpecialLocation(juce::File::tempDirectory)
                                .getChildFile("dubstemmix-desktop-" + juce::String(juce::Time::currentTimeMillis()));
    writeSong(root, "A", 0.25f, 20.0);
    writeSong(root, "B", 0.50f, 20.0);
    setEnvironment("MPC_PLUGIN_FOLDER", root.getFullPathName());
    engine.open();

    std::atomic<bool> running{true};
    std::thread audio([&running]
    {
        static float left[kChunk], right[kChunk];
        auto next = std::chrono::steady_clock::now();
        while (running.load())
        {
            engine.render(left, right, kChunk);
            next += std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(kChunk / kRate));
            std::this_thread::sleep_until(next);
        }
    });

    int failures = 0;
    auto wait = [](double seconds) { std::this_thread::sleep_for(std::chrono::duration<double>(seconds)); };
    auto expect = [&failures](const char* what, float got, float want)
    {
        const bool ok = std::fabs(got - want) < 0.003f;
        if (!ok) failures++;
        std::printf("%s  %-46s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, (double)got, (double)want);
    };
    auto level = [] { return engine.lastLevel.load(); };
    auto cc = [](int number, int value) { engine.fromConsole.push(0xB0, (uint8_t)number, (uint8_t)value); };

    // Mac gain structure: fader^2.5 x 0.5 on the strip, master^2.5 x 0.5 x 2 (make-up). Faders default to 0.8.
    const float masterGain = std::pow(0.8f, 2.5f);
    const float unity = std::pow(0.8f, 2.5f) * 0.5f * masterGain;

    wait(0.5);
    expect("stopped: silence", level(), 0.0f);
    togglePlay();
    wait(1.0);
    expect("Space: song A plays", level(), 0.25f * unity);
    nextSong();
    wait(1.0);
    expect("N: song B plays", level(), 0.50f * unity);
    cc(19, 0);
    wait(0.6);
    expect("fader 1 down (CC 19 = 0): silence", level(), 0.0f);
    cc(19, 127);
    wait(0.6);
    expect("fader 1 up (CC 19 = 127)", level(), 0.50f * 0.5f * masterGain);
    engine.fromConsole.push(0x90, 1, 127);
    wait(0.6);
    expect("MUTE 1 (note 1): silence", level(), 0.0f);
    expect("MUTE 1 lamp lit (the console's LED)", engine.value(engine.param("Lamp M1")), 1.0f);
    engine.fromConsole.push(0x80, 1, 0);
    engine.fromConsole.push(0x90, 1, 127);
    engine.fromConsole.push(0x80, 1, 0);
    wait(0.6);
    expect("MUTE 1 again: back", level(), 0.50f * 0.5f * masterGain);
    togglePlay();
    wait(0.6);
    expect("Space: pause, silence", level(), 0.0f);

    running.store(false);
    audio.join();
    std::printf("disk dropouts: %s\n", engine.text(engine.param("Underruns")).toRawUTF8());
    root.deleteRecursively();
    std::printf("Result: %s\n", failures == 0 ? "all passed" : "FAILED");
    std::fflush(stdout);
    return failures == 0 ? 0 : 1;
}

class DubStemMixApplication : public juce::JUCEApplication
{
public:
    const juce::String getApplicationName() override { return "DubStemMix"; }
    const juce::String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override { return true; }

    void initialise(const juce::String&) override
    {
        const juce::StringArray arguments = getCommandLineParameterArray();
        if (arguments.contains("--selftest"))
        {
            setApplicationReturnValue(runSelfTest());
            quit();
            return;
        }

        // Songs: the folder given, else the repository's own test songs when started from it.
        juce::String folder;
        const juce::File here = juce::File::getCurrentWorkingDirectory();
        if (arguments.size() > 0)
        {
            folder = pluginFolder(here.getChildFile(arguments[0]));
            if (folder.isEmpty())
            {
                std::fprintf(stderr, "No Content/Songs folder in %s\n(expected an Export to MPC folder, a card, or the plugin's folder)\n",
                             arguments[0].toRawUTF8());
                setApplicationReturnValue(1);
                quit();
                return;
            }
        }
        else
            for (const char* guess : {"mpc/DubStemMix", "../mpc/DubStemMix", "../../mpc/DubStemMix"})
                if (folder.isEmpty()) folder = pluginFolder(here.getChildFile(guess));
        if (folder.isNotEmpty()) setEnvironment("MPC_PLUGIN_FOLDER", folder);

        engine.open();
        window_ = std::make_unique<MainWindow>(folder);
    }

    void shutdown() override { window_.reset(); }
    void systemRequestedQuit() override { quit(); }

private:
    std::unique_ptr<MainWindow> window_;
};

} // namespace

START_JUCE_APPLICATION(DubStemMixApplication)
