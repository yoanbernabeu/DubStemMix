// Main.cpp - DubStemMix for the desktop (PRD § 17.5): the app, its window, the keyboard, the checks.
//
// For now the engine is the MPC plugin's (see Engine.h) and the songs come from an "Export to MPC" folder.
//
//   dubstemmix-desktop [folder]                 folder: an export folder, a card, or the plugin's own folder
//   dubstemmix-desktop --selftest               no sound card: plays test songs and checks the levels
//   dubstemmix-desktop --snapshot out.png [mix|fx|master|inserts] [folder]
//                                               draws the console to a picture, no window, no sound card
//
// Keyboard, as on the Mac (PRD § 11.6): Space play / pause, N next song, D drop (held), H hold (held),
// C crash, R rewind, Esc panic.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "Board.h"

#include <cstdio>
#include <thread>

namespace {

using dsm::Engine;

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

// Plays the engine with no sound card, at real-time pace (its disk thread expects that).
class SilentPlayer
{
public:
    SilentPlayer() : thread_([this] { run(); }) {}
    ~SilentPlayer() { running_.store(false); thread_.join(); }

private:
    void run()
    {
        static float left[dsm::kChunk], right[dsm::kChunk];
        auto next = std::chrono::steady_clock::now();
        while (running_.load())
        {
            Engine::get().render(left, right, dsm::kChunk);
            next += std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(dsm::kChunk / dsm::kRate));
            std::this_thread::sleep_until(next);
        }
    }
    std::atomic<bool> running_{true};
    std::thread thread_;
};

void wait(double seconds) { std::this_thread::sleep_for(std::chrono::duration<double>(seconds)); }

// ----------------------------------------------------------------------------------------------------
// Window
// ----------------------------------------------------------------------------------------------------

class MainComponent : public juce::Component, private juce::Timer
{
public:
    MainComponent()
    {
        juce::AudioDeviceManager::AudioDeviceSetup setup;
        setup.sampleRate = dsm::kRate;
        setup.bufferSize = 256;
        soundError_ = devices_.initialise(0, 2, nullptr, true, {}, &setup);
        devices_.addAudioCallback(&output_);

        board_.onSoundCard = [this] { showSoundSettings(); };
        addAndMakeVisible(board_);
        setWantsKeyboardFocus(true);
        setSize(dsm::Board::kWidth, dsm::Board::kHeight);
        startTimerHz(30);
    }

    ~MainComponent() override
    {
        stopTimer();
        devices_.removeAudioCallback(&output_);
        devices_.closeAudioDevice();
        console_.shutdown();
    }

    void paint(juce::Graphics& g) override { g.fillAll(dsm::look::bg); }

    // The board is drawn at 1440 x 900 and scaled to the window, centred.
    void resized() override
    {
        const float scale = juce::jmin((float)getWidth() / (float)dsm::Board::kWidth, (float)getHeight() / (float)dsm::Board::kHeight);
        board_.setTransform(juce::AffineTransform::scale(scale).translated(((float)getWidth() - (float)dsm::Board::kWidth * scale) * 0.5f,
                                                                           ((float)getHeight() - (float)dsm::Board::kHeight * scale) * 0.5f));
    }

    bool keyPressed(const juce::KeyPress& key) override
    {
        Engine& engine = Engine::get();
        const juce::juce_wchar c = juce::CharacterFunctions::toLowerCase(key.getTextCharacter());
        if (key == juce::KeyPress::spaceKey) { engine.togglePlay(); return true; }
        if (key == juce::KeyPress::escapeKey) { engine.panic(); return true; }
        if (c == 'n') { engine.nextSong(); return true; }
        if (c == 'c') { engine.tap(dsm::kCrashNote); return true; }
        if (c == 'r') { engine.tap(dsm::kRewindNote); return true; }
        return c == 'd' || c == 'h';   // held gestures: see keyStateChanged
    }

    // DROP and HOLD last as long as their key is down.
    bool keyStateChanged(bool) override
    {
        held(dropDown_, 'D', dsm::kDropNote);
        held(holdDown_, 'H', dsm::muteNote(6));
        return false;
    }

private:
    static void held(bool& wasDown, int keyCode, int note)
    {
        const bool down = juce::KeyPress::isKeyCurrentlyDown(keyCode);
        if (down == wasDown) return;
        wasDown = down;
        if (down) Engine::get().press(note); else Engine::get().lift(note);
    }

    void timerCallback() override
    {
        if (++ticks_ % 30 == 1) console_.poll();
        console_.lightLeds();

        dsm::Board::Status& status = board_.status;
        status.consoleConnected = console_.connected;
        status.consoleLeds = console_.hasLeds();
        status.consoleName = console_.name;
        status.load = output_.load.load();
        status.lateBuffers = output_.lateBuffers.load();
        if (juce::AudioIODevice* device = devices_.getCurrentAudioDevice())
        {
            const double rate = device->getCurrentSampleRate();
            status.card = device->getName();
            status.cardDetail = juce::String(rate / 1000.0, 1) + dsm::look::u(" kHz · buffer ") + juce::String(device->getCurrentBufferSizeSamples());
            status.soundError = {};
        }
        else status.soundError = soundError_.isEmpty() ? juce::String("no sound card") : soundError_;
        board_.repaint();
    }

    void showSoundSettings()
    {
        auto* selector = new juce::AudioDeviceSelectorComponent(devices_, 0, 0, 2, 2, false, false, true, false);
        selector->setSize(520, 360);
        juce::DialogWindow::LaunchOptions options;
        options.content.setOwned(selector);
        options.dialogTitle = "Sound card";
        options.dialogBackgroundColour = dsm::look::surface;
        options.escapeKeyTriggersCloseButton = true;
        options.resizable = false;
        options.launchAsync();
    }

    juce::String soundError_;
    juce::AudioDeviceManager devices_;
    dsm::Output output_;
    dsm::Console console_;
    dsm::Board board_;
    int ticks_ = 0;
    bool dropDown_ = false, holdDown_ = false;
};

class MainWindow : public juce::DocumentWindow
{
public:
    MainWindow() : juce::DocumentWindow("DubStemMix", dsm::look::bg, juce::DocumentWindow::allButtons)
    {
        setUsingNativeTitleBar(true);
        setContentOwned(new MainComponent(), true);
        setResizable(true, false);
        setResizeLimits(960, 600, 4000, 2500);
        // Fit the screen, keeping the board's shape.
        const juce::Rectangle<int> area = juce::Desktop::getInstance().getDisplays().getPrimaryDisplay()->userArea.reduced(40);
        const float scale = juce::jmin(1.0f, (float)area.getWidth() / (float)dsm::Board::kWidth, (float)area.getHeight() / (float)dsm::Board::kHeight);
        centreWithSize((int)((float)dsm::Board::kWidth * scale), (int)((float)dsm::Board::kHeight * scale));
        setVisible(true);
        if (juce::Component* content = getContentComponent()) content->grabKeyboardFocus();
    }
    void closeButtonPressed() override { juce::JUCEApplication::getInstance()->systemRequestedQuit(); }
};

// ----------------------------------------------------------------------------------------------------
// Checks without a window
// ----------------------------------------------------------------------------------------------------

void writeSong(const juce::File& root, const char* name, float level, double seconds)
{
    const juce::File dir = root.getChildFile("Content").getChildFile("Songs").getChildFile(name);
    dir.createDirectory();
    juce::FileOutputStream out(dir.getChildFile("1 - stem.wav"));
    const uint32_t frames = (uint32_t)(seconds * dsm::kRate), data = frames * 4;
    out.write("RIFF", 4); out.writeInt((int)(36 + data)); out.write("WAVEfmt ", 8);
    out.writeInt(16); out.writeShort(1); out.writeShort(2); out.writeInt(44100); out.writeInt(44100 * 4);
    out.writeShort(4); out.writeShort(16);
    out.write("data", 4); out.writeInt((int)data);
    const short sample = (short)(level * 32767.0f);
    for (uint32_t i = 0; i < frames * 2; ++i) out.writeShort(sample);
}

// Same gestures and same expected levels as the MPC plugin's own test (mpc/tests/transport_test.cpp),
// then the screen's own way in: its buttons and the values it sets.
int runSelfTest()
{
    const juce::File root = juce::File::getSpecialLocation(juce::File::tempDirectory)
                                .getChildFile("dubstemmix-desktop-" + juce::String(juce::Time::currentTimeMillis()));
    writeSong(root, "A", 0.25f, 30.0);
    writeSong(root, "B", 0.50f, 30.0);
    setEnvironment("MPC_PLUGIN_FOLDER", root.getFullPathName());
    Engine& engine = Engine::get();
    engine.open();

    int failures = 0;
    {
        SilentPlayer player;
        auto expect = [&failures](const char* what, float got, float want)
        {
            const bool ok = std::fabs(got - want) < 0.003f;
            if (!ok) failures++;
            std::printf("%s  %-52s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, (double)got, (double)want);
        };
        auto level = [&engine] { return engine.lastLevel.load(); };
        auto cc = [&engine](int number, int value) { engine.fromConsole.push(0xB0, (uint8_t)number, (uint8_t)value); };

        // Mac gain structure: fader^2.5 x 0.5 on the strip, master^2.5 x 0.5 x 2 (make-up). Faders default to 0.8.
        const float masterGain = std::pow(0.8f, 2.5f);
        const float unity = std::pow(0.8f, 2.5f) * 0.5f * masterGain;
        const float faderUp = 0.50f * 0.5f * masterGain;   // song B with fader 1 at the top

        wait(0.5);
        expect("stopped: silence", level(), 0.0f);
        engine.togglePlay();
        wait(1.0);
        expect("Space: song A plays", level(), 0.25f * unity);
        engine.nextSong();
        wait(1.0);
        expect("N: song B plays", level(), 0.50f * unity);
        cc(19, 0);
        wait(0.6);
        expect("fader 1 down (CC 19 = 0): silence", level(), 0.0f);
        cc(19, 127);
        wait(0.6);
        expect("fader 1 up (CC 19 = 127)", level(), faderUp);
        engine.fromConsole.push(0x90, 1, 127);
        wait(0.6);
        expect("MUTE 1 (note 1): silence", level(), 0.0f);
        expect("MUTE 1 lamp lit (the console's LED)", engine.value(engine.lampMute[0]), 1.0f);
        engine.fromConsole.push(0x80, 1, 0);
        engine.fromConsole.push(0x90, 1, 127);
        engine.fromConsole.push(0x80, 1, 0);
        wait(0.6);
        expect("MUTE 1 again: back", level(), faderUp);

        // The screen: MUTE and the fader with the mouse, the pages, a setting of the FX page.
        engine.set(engine.mute[0], 1.0f);
        wait(0.6);
        expect("screen: MUTE 1 clicked, silence", level(), 0.0f);
        engine.set(engine.mute[0], 0.0f);
        engine.set(engine.fader[0], 0.8f);
        wait(0.6);
        expect("screen: fader 1 dragged to its default level", level(), 0.50f * unity);
        engine.showPage(dsm::kMaster);
        wait(0.3);
        expect("screen: MASTER page button", (float)engine.currentPage(), (float)dsm::kMaster);
        expect("MASTER page: strip 2's top knob is KILL BASS", (float)engine.knobTarget(1, 0), (float)engine.effect[fx::KillBass]);
        engine.showPage(dsm::kFx);
        wait(0.3);
        expect("screen: FX page button (back through MIX)", (float)engine.currentPage(), (float)dsm::kFx);
        expect("FX page: strip 1's top knob is the delay time", (float)engine.knobTarget(0, 0), (float)engine.effect[fx::DelayTime]);
        engine.showPage(dsm::kMix);
        wait(0.3);
        expect("screen: MIX page button", (float)engine.currentPage(), (float)dsm::kMix);
        expect("MIX page: strip 1's top knob is its delay send", (float)engine.knobTarget(0, 0), (float)engine.send[0][0]);
        expect("MIX page: strip 5 is the siren", engine.isInstrument(4) ? 1.0f : 0.0f, 1.0f);

        engine.togglePlay();
        wait(0.6);
        expect("Space: pause, silence", level(), 0.0f);
    }
    std::printf("disk dropouts: %s\n", engine.text(engine.underruns).toRawUTF8());
    root.deleteRecursively();
    std::printf("Result: %s\n", failures == 0 ? "all passed" : "FAILED");
    std::fflush(stdout);
    return failures == 0 ? 0 : 1;
}

// Draws the console to a PNG: how the look is checked without a screen.
int runSnapshot(const juce::File& target, const juce::String& pageName)
{
    Engine& engine = Engine::get();
    {
        SilentPlayer player;
        wait(0.4);
        engine.showPage(pageName == "fx" ? dsm::kFx : pageName == "master" ? dsm::kMaster : pageName == "inserts" ? dsm::kInserts : dsm::kMix);
        engine.togglePlay();
        wait(1.5);
    }
    dsm::Board board;
    board.status.soundError = "snapshot";
    const juce::Image image = board.createComponentSnapshot(board.getLocalBounds(), true, 1.0f);
    target.deleteFile();
    juce::FileOutputStream out(target);
    if (!out.openedOk() || !juce::PNGImageFormat().writeImageToStream(image, out))
    {
        std::fprintf(stderr, "cannot write %s\n", target.getFullPathName().toRawUTF8());
        return 1;
    }
    return 0;
}

class DubStemMixApplication : public juce::JUCEApplication
{
public:
    const juce::String getApplicationName() override { return "DubStemMix"; }
    const juce::String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override { return true; }

    void initialise(const juce::String&) override
    {
        juce::StringArray arguments = getCommandLineParameterArray();
        if (arguments.contains("--selftest")) { finish(runSelfTest()); return; }

        const juce::File here = juce::File::getCurrentWorkingDirectory();
        juce::File snapshot;
        juce::String snapshotPage;
        const int at = arguments.indexOf("--snapshot");
        if (at >= 0)
        {
            if (at + 1 >= arguments.size()) { std::fprintf(stderr, "--snapshot needs a file name\n"); finish(1); return; }
            snapshot = here.getChildFile(arguments[at + 1]);
            arguments.removeRange(at, 2);
            for (const char* page : {"mix", "fx", "master", "inserts"})
                if (arguments.contains(page)) { snapshotPage = page; arguments.removeString(page); }
        }

        // Songs: the folder given, else the repository's own test songs when started from it.
        juce::String folder;
        if (arguments.size() > 0)
        {
            folder = pluginFolder(here.getChildFile(arguments[0]));
            if (folder.isEmpty())
            {
                std::fprintf(stderr, "No Content/Songs folder in %s\n(expected an Export to MPC folder, a card, or the plugin's folder)\n",
                             arguments[0].toRawUTF8());
                finish(1);
                return;
            }
        }
        else
            for (const char* guess : {"mpc/DubStemMix", "../mpc/DubStemMix", "../../mpc/DubStemMix"})
                if (folder.isEmpty()) folder = pluginFolder(here.getChildFile(guess));
        if (folder.isNotEmpty()) setEnvironment("MPC_PLUGIN_FOLDER", folder);
        else std::fprintf(stderr, "No songs folder. Start with: dubstemmix-desktop <export folder>\n");

        Engine::get().open();
        if (snapshot != juce::File()) { finish(runSnapshot(snapshot, snapshotPage)); return; }
        window_ = std::make_unique<MainWindow>();
    }

    void shutdown() override { window_.reset(); }
    void systemRequestedQuit() override { quit(); }

private:
    void finish(int code)
    {
        setApplicationReturnValue(code);
        quit();
    }

    std::unique_ptr<MainWindow> window_;
};

} // namespace

START_JUCE_APPLICATION(DubStemMixApplication)
