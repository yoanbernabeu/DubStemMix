// Main.cpp - DubStemMix for the desktop (PRD § 17.5): the app, its window, the keyboard, the checks.
//
//   dubstemmix-desktop [song.dubstem | set.dubset]   opens a project or a setlist made here or on the Mac
//   dubstemmix-desktop --selftest                    no sound card: makes test songs, plays them, checks
//   dubstemmix-desktop --snapshot out.png [mix|fx|master|inserts] [song.dubstem | set.dubset]
//                                                    draws the console to a picture, no window, no sound card
//
// Keyboard, as on the Mac: Space play / pause, N and P next and previous song of the setlist, T tap tempo,
// D drop (held), H hold (held), C crash, R rewind, Esc panic; Ctrl/Cmd + O, S, Shift + S, N for the session.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "Board.h"

#include <cstdio>
#include <thread>

namespace {

using dsm::Engine;

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
    explicit MainComponent(dsm::AppModel& app) : app_(app), board_(app)
    {
        juce::AudioDeviceManager::AudioDeviceSetup setup;
        setup.sampleRate = dsm::kRate;
        setup.bufferSize = 256;
        soundError_ = devices_.initialise(0, 2, nullptr, true, {}, &setup);
        devices_.addAudioCallback(&output_);

        board_.onSoundCard = [this] { showSoundSettings(); };
        board_.onOpen = [this] { openDialog(); };
        board_.onSave = [this] { save(false); };
        board_.onNew = [this] { newSession(); };
        board_.onAddStems = [this] { addStemsDialog(); };
        board_.onOpenFile = [this](const juce::File& f) { openFile(f); };
        board_.onLocate = [this] { locateDialog(); };
        board_.onAskText = [this](const juce::String& what, const juce::String& current, std::function<void(const juce::String&)> done)
        {
            askText(what, current, std::move(done));
        };
        addAndMakeVisible(board_);
        setWantsKeyboardFocus(true);
        setSize(dsm::Board::kWidth, dsm::Board::kHeight);
        startTimerHz(30);
    }

    ~MainComponent() override
    {
        stopTimer();
        app_.autosave();
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
        const juce::juce_wchar c = juce::CharacterFunctions::toLowerCase((juce::juce_wchar)key.getKeyCode());
        if (key.getModifiers().isCommandDown())
        {
            if (c == 'o') { openDialog(); return true; }
            if (c == 's') { save(key.getModifiers().isShiftDown()); return true; }
            if (c == 'n') { newSession(); return true; }
            return false;
        }
        if (key == juce::KeyPress::spaceKey) { engine.togglePlay(); return true; }
        if (key == juce::KeyPress::escapeKey) { engine.panic(); return true; }
        if (c == 'n') { app_.step(+1); return true; }
        if (c == 'p') { app_.step(-1); return true; }
        if (c == 't') { app_.tap(); return true; }
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
        const bool down = juce::KeyPress::isKeyCurrentlyDown(keyCode) && !juce::ModifierKeys::currentModifiers.isCommandDown();
        if (down == wasDown) return;
        wasDown = down;
        if (down) Engine::get().press(note); else Engine::get().lift(note);
    }

    void timerCallback() override
    {
        if (++ticks_ % 30 == 1) { console_.poll(); app_.tick(); }
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

    // ---- Session dialogs ----

    static juce::File songsFolder()
    {
        const juce::File folder = juce::File::getSpecialLocation(juce::File::userMusicDirectory).getChildFile("DubStemMix");
        return folder.isDirectory() ? folder : juce::File::getSpecialLocation(juce::File::userHomeDirectory);
    }

    // A setlist opens on its first song, as when that song is clicked.
    void openFile(const juce::File& file)
    {
        app_.autosave();
        if (app_.open(file) && file.hasFileExtension("dubset")) app_.openSong(0);
    }

    void openDialog()
    {
        chooser_ = std::make_unique<juce::FileChooser>("Open a project or a setlist", songsFolder(), "*.dubstem;*.dubset");
        chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles,
                              [this](const juce::FileChooser& c) { if (c.getResult() != juce::File()) openFile(c.getResult()); });
    }

    // Nothing is written until the user has chosen where (PRD § 5.8); afterwards the session saves itself.
    void save(bool asCopy)
    {
        if (app_.hasDocument() && !asCopy) { app_.save(); return; }
        const juce::File start = app_.hasDocument() ? app_.session.document : songsFolder().getChildFile(app_.session.displayTitle() + ".dubstem");
        chooser_ = std::make_unique<juce::FileChooser>("Save the session", start, "*.dubstem");
        chooser_->launchAsync(juce::FileBrowserComponent::saveMode | juce::FileBrowserComponent::canSelectFiles | juce::FileBrowserComponent::warnAboutOverwriting,
                              [this](const juce::FileChooser& c)
                              {
                                  if (c.getResult() != juce::File()) app_.saveAs(c.getResult().withFileExtension("dubstem"));
                              });
    }

    // A session never saved asks before it is replaced.
    void newSession()
    {
        if (app_.hasDocument() || app_.session.isEmpty()) { app_.autosave(); app_.newSession(); return; }
        juce::AlertWindow::showOkCancelBox(juce::MessageBoxIconType::QuestionIcon, "New session",
                                           "This session was never saved. Start a new one and lose it?", "New session", "Cancel", this,
                                           juce::ModalCallbackFunction::create([this](int ok) { if (ok == 1) app_.newSession(); }));
    }

    void addStemsDialog()
    {
        chooser_ = std::make_unique<juce::FileChooser>("Stems to place", songsFolder(), "*.wav;*.aif;*.aiff;*.flac;*.mp3;*.ogg;*.m4a");
        chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles | juce::FileBrowserComponent::canSelectMultipleItems,
                              [this](const juce::FileChooser& c) { app_.addFiles(c.getResults(), -1); });
    }

    // Missing stems are looked for, by file name, in a folder the user picks (PRD § 5.8).
    void locateDialog()
    {
        chooser_ = std::make_unique<juce::FileChooser>("Folder holding the missing stems", songsFolder());
        chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories,
                              [this](const juce::FileChooser& c) { if (c.getResult().isDirectory()) app_.locate(c.getResult()); });
    }

    void askText(const juce::String& what, const juce::String& current, std::function<void(const juce::String&)> done)
    {
        auto* box = new juce::AlertWindow(what, {}, juce::MessageBoxIconType::NoIcon, this);
        box->addTextEditor("text", current);
        box->addButton("OK", 1, juce::KeyPress(juce::KeyPress::returnKey));
        box->addButton("Cancel", 0, juce::KeyPress(juce::KeyPress::escapeKey));
        box->enterModalState(true, juce::ModalCallbackFunction::create([box, done = std::move(done)](int ok)
        {
            if (ok == 1) done(box->getTextEditorContents("text"));
        }), true);
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

    dsm::AppModel& app_;
    juce::String soundError_;
    juce::AudioDeviceManager devices_;
    dsm::Output output_;
    dsm::Console console_;
    dsm::Board board_;
    std::unique_ptr<juce::FileChooser> chooser_;
    int ticks_ = 0;
    bool dropDown_ = false, holdDown_ = false;
};

class MainWindow : public juce::DocumentWindow
{
public:
    explicit MainWindow(dsm::AppModel& app) : juce::DocumentWindow("DubStemMix", dsm::look::bg, juce::DocumentWindow::allButtons)
    {
        setUsingNativeTitleBar(true);
        setContentOwned(new MainComponent(app), true);
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

// A stem holding a constant level: the output level then tells what is playing.
juce::File writeStem(const juce::File& folder, const char* name, float level, double seconds, int rate = 44100)
{
    folder.createDirectory();
    const juce::File file = folder.getChildFile(name);
    file.deleteFile();
    juce::FileOutputStream out(file);
    const uint32_t frames = (uint32_t)(seconds * rate), data = frames * 4;
    out.write("RIFF", 4); out.writeInt((int)(36 + data)); out.write("WAVEfmt ", 8);
    out.writeInt(16); out.writeShort(1); out.writeShort(2); out.writeInt(rate); out.writeInt(rate * 4);
    out.writeShort(4); out.writeShort(16);
    out.write("data", 4); out.writeInt((int)data);
    const short sample = (short)(level * 32767.0f);
    for (uint32_t i = 0; i < frames * 2; ++i) out.writeShort(sample);
    return file;
}

// A click on every beat: what the tempo detection is checked with.
juce::File writeClicks(const juce::File& folder, const char* name, double bpm, double seconds)
{
    const juce::File file = folder.getChildFile(name);
    file.deleteFile();
    juce::FileOutputStream out(file);
    const int rate = 44100;
    const uint32_t frames = (uint32_t)(seconds * rate), data = frames * 4;
    out.write("RIFF", 4); out.writeInt((int)(36 + data)); out.write("WAVEfmt ", 8);
    out.writeInt(16); out.writeShort(1); out.writeShort(2); out.writeInt(rate); out.writeInt(rate * 4);
    out.writeShort(4); out.writeShort(16);
    out.write("data", 4); out.writeInt((int)data);
    const double beat = 60.0 / bpm * rate;
    for (uint32_t i = 0; i < frames; ++i)
    {
        const double since = std::fmod((double)i, beat);
        const short sample = since < 400.0 ? (short)(20000.0 * std::sin(since * 0.3) * (1.0 - since / 400.0)) : (short)0;
        out.writeShort(sample);
        out.writeShort(sample);
    }
    return file;
}

int runSelfTest()
{
    const juce::File root = juce::File::getSpecialLocation(juce::File::tempDirectory)
                                .getChildFile("dubstemmix-desktop-" + juce::String(juce::Time::currentTimeMillis()));
    const juce::File kick = writeStem(root, "Song (Kick).wav", 0.25f, 20.0);
    const juce::File snare = writeStem(root, "Song (Snare).wav", 0.10f, 20.0, 48000);   // another rate, same strip
    const juce::File bass = writeStem(root, "Song (Bass).wav", 0.20f, 8.0);             // a short stem
    const juce::File second = writeStem(root, "Other.wav", 0.50f, 20.0);

    Engine& engine = Engine::get();
    engine.open();
    dsm::AppModel app(true);
    dsm::Transport& t = dsm::transport();

    int failures = 0;
    auto expect = [&failures](const char* what, float got, float want, float tolerance = 0.003f)
    {
        const bool ok = std::fabs(got - want) <= tolerance;
        if (!ok) failures++;
        std::printf("%s  %-58s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, (double)got, (double)want);
    };
    {
        SilentPlayer player;
        auto level = [&engine] { return engine.lastLevel.load(); };
        auto cc = [&engine](int number, int value) { engine.fromConsole.push(0xB0, (uint8_t)number, (uint8_t)value); };

        // Mac gain structure: fader^2.5 x 0.5 on the strip, master^2.5 x 0.5 x 2 (make-up). Faders default to 0.8.
        const float masterGain = std::pow(0.8f, 2.5f);
        const float unity = std::pow(0.8f, 2.5f) * 0.5f * masterGain;

        // A new session: stems land in the stems to place, the user puts them on strips (PRD § 5.1).
        app.newSession();
        app.addFiles({kick, snare, bass}, -1);
        expect("three stems dropped: all in the stems to place", (float)app.session.pool.size(), 3.0f);
        app.move(-1, 0, 0);
        wait(0.6);
        expect("a stem placed on strip 1: loaded, stopped", level(), 0.0f);
        expect("strips 5 and 6 stay the siren and the Syndrum", engine.isInstrument(4) && engine.isInstrument(5) ? 1.0f : 0.0f, 1.0f);
        engine.togglePlay();
        wait(0.8);
        expect("Space: strip 1 plays", level(), 0.25f * unity);
        app.move(-1, 0, 0);   // the snare, a 48 kHz file, on the same strip
        app.tick();
        wait(0.6);
        app.tick();
        wait(0.6);
        expect("two stems on a strip are summed, the song goes on", level(), 0.35f * unity);
        expect("...from where it was", (float)engine.seconds(), 2.0f, 1.0f);
        app.move(-1, 0, 1);   // the bass on strip 2: 8 s long
        wait(0.4);
        app.tick();
        wait(0.6);
        expect("a third stem on strip 2", level(), 0.55f * unity);
        expect("strip names from what differs in the file names (BASS)", app.session.stripName(1) == "BASS" ? 1.0f : 0.0f, 1.0f);
        expect("the longest stem gives the song's length (20 s)", (float)engine.duration(), 20.0f, 0.05f);

        // The console, as on the MPC plugin's own test.
        cc(19, 0);
        wait(0.6);
        expect("fader 1 down (CC 19 = 0): only strip 2 left", level(), 0.20f * unity);
        cc(19, 127);
        wait(0.6);
        expect("fader 1 up (CC 19 = 127)", level(), 0.35f * 0.5f * masterGain + 0.20f * unity);
        engine.fromConsole.push(0x90, 1, 127);
        engine.fromConsole.push(0x80, 1, 0);
        wait(0.6);
        expect("MUTE 1 (note 1): only strip 2 left", level(), 0.20f * unity);
        expect("MUTE 1 lamp lit (the console's LED)", engine.value(engine.lampMute[0]), 1.0f);
        engine.set(engine.mute[0], 0.0f);
        engine.set(engine.fader[0], 0.8f);
        wait(0.6);
        expect("screen: MUTE off and fader 1 back to its default", level(), 0.55f * unity);

        // Moving in the song, the short stem's end, the loop.
        engine.seekSeconds(10.0);
        wait(0.8);
        expect("jump to 0:10: past the short stem's end", level(), 0.35f * unity);
        expect("the position follows", (float)engine.seconds(), 10.8f, 0.6f);
        t.loop.store(true);
        engine.seekSeconds(19.5);
        wait(1.3);
        expect("loop on: past the end, the song is back at its start", (float)engine.seconds(), 0.8f, 0.7f);
        expect("...and plays", level(), 0.55f * unity);
        // The loop point itself: no gap, the level never drops.
        engine.seekSeconds(19.3);
        wait(0.3);
        float lowest = 1.0f;
        for (int i = 0; i < 60; ++i) { wait(0.015); lowest = std::fmin(lowest, level()); }
        // Before it only strip 1 sounds (the short stem has ended), after it both: never less than strip 1.
        expect("the loop point is seamless (lowest level across it)", lowest, 0.35f * unity);
        expect("the output meter moves", t.masterPeak.load() > 0.01f ? 1.0f : 0.0f, 1.0f);
        expect("the pre-fader level of strip 1 is read", t.prePeak[0].load() > 0.1f ? 1.0f : 0.0f, 1.0f);
        t.loop.store(false);
        wait(0.4);
        engine.seekSeconds(19.5);
        wait(1.2);
        expect("loop off: the song stops at its end", engine.isPlaying() ? 1.0f : 0.0f, 0.0f);
        expect("...in silence", level(), 0.0f);
        engine.togglePlay();
        wait(0.8);
        expect("Space after the end: from the top", level(), 0.55f * unity);

        // Per-song settings travel with the project (PRD § 5.8); the pages still answer.
        engine.set(engine.effect[fx::DelayFeedback], 0.9f);
        engine.setChoice(engine.reverbModel, 1, 2);
        engine.set(engine.keep[1], 1.0f);
        app.setBpm(72.0);
        const juce::File project = root.getChildFile("Song.dubstem");
        expect("Save As writes the project", app.saveAs(project) ? 1.0f : 0.0f, 1.0f);
        engine.showPage(dsm::kFx);
        wait(0.3);
        expect("FX page: strip 1's top knob is the delay time", (float)engine.knobTarget(0, 0), (float)engine.effect[fx::DelayTime]);
        engine.showPage(dsm::kMix);

        // Another song: loaded stopped at its start, with its own settings.
        app.newSession();
        wait(0.6);
        expect("New: a fresh session, stopped", level(), 0.0f);
        expect("New: factory effect settings", engine.value(engine.effect[fx::DelayFeedback]), fx::info(fx::DelayFeedback).def);
        app.addFiles({second}, 2);
        wait(0.6);
        engine.togglePlay();
        wait(0.8);
        expect("a stem dropped on strip 3 of the new session plays", level(), 0.50f * unity);

        expect("the saved project opens again", app.open(project) ? 1.0f : 0.0f, 1.0f);
        wait(0.8);
        expect("an opened song is stopped at its start", level(), 0.0f);
        expect("its stems are back on their strips", (float)(app.session.strips[0].size() * 10 + app.session.strips[1].size()), 21.0f);
        expect("its delay feedback is back", engine.value(engine.effect[fx::DelayFeedback]), 0.9f);
        expect("its reverb model is back (spring)", (float)engine.choice(engine.reverbModel, 2), 1.0f);
        expect("its KEEP on strip 2 is back", engine.value(engine.keep[1]), 1.0f);
        expect("its tempo is back", (float)app.session.bpm, 72.0f);
        engine.togglePlay();
        wait(0.8);
        expect("and it plays", level(), 0.55f * unity);
        engine.togglePlay();
        wait(0.5);
        expect("Space: pause, silence", level(), 0.0f);

        // Names given by hand, written in the project.
        app.rename("Zion Gate Dub");
        app.renameStrip(0, "riddim");
        app.save();
        app.open(project);
        expect("a renamed song keeps its title", app.session.displayTitle() == "Zion Gate Dub" ? 1.0f : 0.0f, 1.0f);
        expect("a renamed strip keeps its name (RIDDIM)", app.session.stripName(0) == "RIDDIM" ? 1.0f : 0.0f, 1.0f);
        expect("the project is in the recent files, first", app.settings.recent().size() > 0 && app.settings.recent()[0] == project ? 1.0f : 0.0f, 1.0f);

        // Tempo: worked out from the stems when they are placed and no tempo is known; AUTO asks again.
        const juce::File clicks = writeClicks(root, "Clicks.wav", 90.0, 40.0);
        app.newSession();
        app.addFiles({clicks}, 0);
        for (int i = 0; i < 40 && app.isDetectingTempo(); ++i) wait(0.25);
        app.tick();
        expect("tempo found when a stem is placed (clicks at 90 BPM)", (float)app.session.bpm, 90.0f, 0.2f);
        app.setBpm(60.0);
        app.detectTempo(false);
        wait(0.3);
        app.tick();
        expect("a known tempo is left alone", (float)app.session.bpm, 60.0f);
        app.detectTempo(true);
        for (int i = 0; i < 40 && app.isDetectingTempo(); ++i) wait(0.25);
        app.tick();
        expect("AUTO works it out again", (float)app.session.bpm, 90.0f, 0.2f);
        app.open(project);

        // What the Mac wrote and this app does not handle must survive a save here.
        juce::var asMac = juce::JSON::parse(project.loadFileAsString());
        auto* slot = new juce::DynamicObject();
        slot->setProperty("plugin", "an Audio Unit");
        auto* slots = new juce::DynamicObject();
        slots->setProperty("delay", juce::var(slot));
        asMac.getDynamicObject()->setProperty("slots", juce::var(slots));
        project.replaceWithText(juce::JSON::toString(asMac));
        app.open(project);
        app.setBpm(80.0);
        app.save();
        const juce::var again = juce::JSON::parse(project.loadFileAsString());
        expect("a Mac-only setting (an Audio Unit slot) survives a save here", again["slots"]["delay"]["plugin"].toString() == "an Audio Unit" ? 1.0f : 0.0f, 1.0f);
        expect("...with the change made here", (float)(double)again["bpm"], 80.0f);

        // A stem that has gone: said, and kept in the project.
        bass.deleteFile();
        app.open(project);
        expect("a missing stem is counted", (float)app.session.missingCount(), 1.0f);
        app.save();
        const juce::var kept = juce::JSON::parse(project.loadFileAsString());
        expect("...and stays written in the project", (float)kept["stems"].size(), 3.0f);
        // The stem turns up in another folder: LOCATE finds it by its name.
        const juce::File moved = writeStem(root.getChildFile("moved"), "Song (Bass).wav", 0.20f, 8.0);
        expect("LOCATE finds the stem in the folder given", (float)app.locate(root.getChildFile("moved")), 1.0f);
        expect("...nothing is missing any more", (float)app.session.missingCount(), 0.0f);
        expect("...and the project points to it", app.session.strips[1][0].file == moved ? 1.0f : 0.0f, 1.0f);
    }
    std::printf("disk dropouts: %s\n", engine.text(engine.underruns).toRawUTF8());
    root.deleteRecursively();
    std::printf("Result: %s\n", failures == 0 ? "all passed" : "FAILED");
    std::fflush(stdout);
    return failures == 0 ? 0 : 1;
}

// Draws the console to a PNG: how the look is checked without a screen.
int runSnapshot(dsm::AppModel& app, const juce::File& target, const juce::String& pageName)
{
    Engine& engine = Engine::get();
    dsm::Board board(app);
    board.status.soundError = "snapshot";
    SilentPlayer player;
    wait(0.6);
    engine.showPage(pageName == "fx" ? dsm::kFx : pageName == "master" ? dsm::kMaster : pageName == "inserts" ? dsm::kInserts : dsm::kMix);
    engine.togglePlay();
    board.createComponentSnapshot(board.getLocalBounds(), true, 1.0f);   // asks for the waveform
    wait(4.0);
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

        Engine::get().open();
        app_ = std::make_unique<dsm::AppModel>();
        app_->newSession();
        if (arguments.size() > 0)
        {
            const juce::File file = here.getChildFile(arguments[0]);
            if (!app_->open(file))
            {
                std::fprintf(stderr, "%s\n", app_->message.toRawUTF8());
                finish(1);
                return;
            }
            // A setlist starts on its first song, as when it is clicked.
            if (file.hasFileExtension("dubset")) app_->openSong(0);
        }
        if (snapshot != juce::File()) { finish(runSnapshot(*app_, snapshot, snapshotPage)); return; }
        window_ = std::make_unique<MainWindow>(*app_);
    }

    void shutdown() override
    {
        window_.reset();
        app_.reset();
    }
    void systemRequestedQuit() override { quit(); }

private:
    void finish(int code)
    {
        setApplicationReturnValue(code);
        quit();
    }

    std::unique_ptr<dsm::AppModel> app_;
    std::unique_ptr<MainWindow> window_;
};

} // namespace

START_JUCE_APPLICATION(DubStemMixApplication)
