// Main.cpp - DubStemMix for the desktop (PRD § 17.5): the app, its window, the keyboard, the checks.
//
//   dubstemmix-desktop [song.dubstem | set.dubset]   opens a project or a setlist made here or on the Mac
//   dubstemmix-desktop --selftest                    no sound card: makes test songs, plays them, checks
//   dubstemmix-desktop --screentest [folder]         no window: plays the console's screen like a user (clicks,
//                                                    drags, drops, menus), checks, and saves pictures in folder
//   dubstemmix-desktop --snapshot out.png [mix|fx|master|inserts] [song.dubstem | set.dubset]
//                                                    draws the console to a picture, no window, no sound card
//
// Keyboard, as on the Mac: Space play / pause, N and P next and previous song of the setlist, T tap tempo,
// D drop (held), H hold (held), C crash, R rewind, Esc panic; Ctrl/Cmd + O, S, Shift + S, N for the session.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "Workshop.h"
#include "Sessions.h"

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
    explicit MainComponent(dsm::AppModel& app) : app_(app), board_(app), workshop_(app), sessions_(app)
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
        board_.onWorkshop = [this] { enterWorkshop(); };
        addAndMakeVisible(board_);

        workshop_.onBack = [this] { leaveWorkshop(); };
        workshop_.onAskText = board_.onAskText;
        workshop_.onConfirm = [this](const juce::String& question, std::function<void()> yes) { confirm("Setlists", question, std::move(yes)); };
        workshop_.onLocate = [this](int line)
        {
            chooser_ = std::make_unique<juce::FileChooser>("Folder holding the song", songsFolder());
            chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories,
                                  [this, line](const juce::FileChooser& c) { if (c.getResult().isDirectory()) workshop_.locate(line, c.getResult()); });
        };
        addChildComponent(workshop_);

        board_.onRecord = [this] { record(); };
        board_.onSessions = [this] { showSessions(true); };
        sessions_.onBack = [this] { showSessions(false); };
        sessions_.onConfirm = workshop_.onConfirm;
        sessions_.onFolder = [this]
        {
            chooser_ = std::make_unique<juce::FileChooser>("Folder where sessions are recorded", app_.recordingsFolder());
            chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories,
                                  [this](const juce::FileChooser& c)
                                  {
                                      if (!c.getResult().isDirectory()) return;
                                      app_.settings.setRecordingFolder(c.getResult());
                                      sessions_.open();
                                  });
        };
        addChildComponent(sessions_);
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
        const juce::AffineTransform fit = juce::AffineTransform::scale(scale).translated(((float)getWidth() - (float)dsm::Board::kWidth * scale) * 0.5f,
                                                                                         ((float)getHeight() - (float)dsm::Board::kHeight * scale) * 0.5f);
        board_.setTransform(fit);
        workshop_.setTransform(fit);
        sessions_.setTransform(fit);
    }

    bool keyPressed(const juce::KeyPress& key) override
    {
        // The workshop is not for playing: only its own keys answer there.
        if (workshop_.isVisible()) return workshop_.keyPressed(key);
        Engine& engine = Engine::get();
        const juce::juce_wchar c = juce::CharacterFunctions::toLowerCase((juce::juce_wchar)key.getKeyCode());
        if (key.getModifiers().isCommandDown())
        {
            // Ctrl/Cmd + R records; with Shift, the recorded sessions.
            if (c == 'r') { if (key.getModifiers().isShiftDown()) showSessions(!sessions_.isVisible()); else record(); return true; }
            if (sessions_.isVisible()) return false;
            if (c == 'o') { openDialog(); return true; }
            if (c == 's') { save(key.getModifiers().isShiftDown()); return true; }
            if (c == 'n') { newSession(); return true; }
            return false;
        }
        if (sessions_.isVisible()) return false;
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
        if (workshop_.isVisible() || sessions_.isVisible()) return false;
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
        app_.followRecording();
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
        if (workshop_.isVisible()) workshop_.repaint(); else if (sessions_.isVisible()) sessions_.repaint(); else board_.repaint();
    }

    // ---- Recording (PRD § 5.9) ----

    void record()
    {
        juce::AudioIODevice* device = devices_.getCurrentAudioDevice();
        app_.toggleRecording(device != nullptr ? device->getName() : juce::String());
    }

    // The recorded sessions take the console's place; the music and a recording under way go on.
    void showSessions(bool show)
    {
        if (workshop_.isVisible()) return;
        if (show) sessions_.open();
        sessions_.setVisible(show);
        board_.setVisible(!show);
        grabKeyboardFocus();
    }

    // ---- The setlist workshop takes the console's place (PRD § 13) ----

    void confirm(const juce::String& title, const juce::String& question, std::function<void()> yes)
    {
        juce::AlertWindow::showOkCancelBox(juce::MessageBoxIconType::QuestionIcon, title, question, "OK", "Cancel", this,
                                           juce::ModalCallbackFunction::create([yes = std::move(yes)](int ok) { if (ok == 1) yes(); }));
    }

    // Entering while a song plays asks first, then stops it. The open session is left as it is.
    void enterWorkshop()
    {
        auto enter = [this]
        {
            dsm::transport().playing.store(false);
            app_.autosave();
            workshop_.open();
            board_.setVisible(false);
            workshop_.setVisible(true);
            workshop_.grabKeyboardFocus();
        };
        if (Engine::get().isPlaying()) confirm("Setlists", "The song is playing. Stop it and open the setlists?", enter); else enter();
    }

    void leaveWorkshop()
    {
        workshop_.close();
        workshop_.setVisible(false);
        board_.setVisible(true);
        grabKeyboardFocus();
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
    dsm::Workshop workshop_;
    dsm::Sessions sessions_;
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
    auto yes = [&expect](const char* what, bool ok) { expect(what, ok ? 1.0f : 0.0f, 1.0f); };
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
        // Recording (PRD § 5.9): the master as a float WAV in a session folder, with the songs played.
        app.home = root.getChildFile("home");
        app.newSession();
        app.addFiles({clicks}, 0);
        wait(0.6);
        engine.togglePlay();
        wait(0.4);
        app.toggleRecording("Test card");
        yes("REC starts a recording", app.isRecording());
        wait(1.2);
        app.followRecording();
        app.settings.setLimiterOn(false);
        app.followRecording();
        app.settings.setLimiterOn(true);
        app.open(project);
        app.followRecording();
        engine.togglePlay();
        wait(0.8);
        app.followRecording();
        const double recorded = app.recordingSeconds();
        app.toggleRecording("Test card");
        yes("REC again stops it", !app.isRecording());
        const std::vector<dsm::SessionEntry> sessions = dsm::listSessions(app.recordingsFolder());
        expect("the session is in the recordings folder", (float)sessions.size(), 1.0f);
        if (sessions.size() == 1)
        {
            const dsm::SessionEntry& entry = sessions[0];
            juce::WavAudioFormat wavFormat;
            std::unique_ptr<juce::AudioFormatReader> reader(wavFormat.createReaderFor(entry.audio().createInputStream().release(), true));
            yes("session.wav is a 32-bit float stereo file at the engine's rate", reader != nullptr && reader->usesFloatingPointData && reader->bitsPerSample == 32
                                                                                   && reader->numChannels == 2 && reader->sampleRate == 44100.0);
            expect("...as long as what was recorded", reader != nullptr ? (float)((double)reader->lengthInSamples / 44100.0) : 0.0f, (float)recorded, 0.3f);
            expect("the sheet holds that duration", (float)entry.session.duration, (float)recorded, 0.05f);
            yes("the song playing at REC opens the tracklist at 00:00", entry.session.tracks.size() == 2 && entry.session.tracks[0].time == 0.0
                                                                          && entry.session.tracks[0].title == "Clicks");
            yes("a song started later enters it with its time", entry.session.tracks.size() == 2 && entry.session.tracks[1].time > 1.0
                                                                  && entry.session.tracks[1].title == "Zion Gate Dub");
            yes("the limiter switched during the session is noted", entry.session.limiterOn && entry.session.limiterToggled);
            const juce::String sheet = entry.folder.getChildFile("session.txt").loadFileAsString();
            yes("session.txt reads as a tracklist", sheet.contains("Tracklist\n00:00 Clicks\n00:0") && sheet.contains("Audio: Test card, 44.1 kHz, 32-bit float WAV")
                                                      && sheet.contains("Limiter: on (switched during the session)"));
            const juce::String started = juce::JSON::parse(entry.folder.getChildFile("session.json").loadFileAsString())["started"].toString();
            yes("session.json dates are written as the Mac reads them", started.length() == 20 && started.endsWithChar('Z') && started[10] == 'T');

            app.exportMp3(entry);
            for (int i = 0; i < 80 && app.exportProgress.load() >= 0.0; ++i) wait(0.25);
            app.tick();
            yes("Export MP3 writes session.mp3 beside the WAV", entry.hasMp3() && entry.mp3().getSize() > 4000);
            yes("...and says what gain it applied", app.message.startsWith("MP3 written"));
        }
        expect("the gain aims at -14 LUFS when the peaks allow", (float)dsm::mp3::gainFor(-20.0, -6.0), 4.5f);
        expect("...and stops 1.5 dB under the peaks otherwise", (float)dsm::mp3::gainFor(-30.0, -3.0), 1.5f);
        app.open(project);

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

// ----------------------------------------------------------------------------------------------------
// Screen test: the real console, played like a user would - clicks, drags, double-clicks, right-clicks and
// files dropped at the controls' places - with no window and no sound card. What it cannot reach: the
// system's own file dialogs, and how it sounds.
// ----------------------------------------------------------------------------------------------------

class ScreenUser
{
public:
    explicit ScreenUser(juce::Component& board) : board_(board) {}

    // The board lays out its controls as it draws: look before touching.
    void look() { board_.createComponentSnapshot(board_.getLocalBounds(), true, 1.0f); }

    void press(float x, float y, bool right = false) { look(); board_.mouseDown(event({x, y}, {x, y}, right, false)); }
    void release(float x, float y) { board_.mouseUp(event({x, y}, {x, y}, false, false)); wait(0.05); }
    void click(float x, float y) { press(x, y); release(x, y); }
    void rightClick(float x, float y) { press(x, y, true); release(x, y); }
    void doubleClick(float x, float y) { look(); board_.mouseDoubleClick(event({x, y}, {x, y}, false, false)); }
    void drag(float x, float y, float toX, float toY, bool shift = false)
    {
        press(x, y);
        board_.mouseDrag(event({toX, toY}, {x, y}, false, true, shift));
        board_.mouseUp(event({toX, toY}, {x, y}, false, true));
        wait(0.05);
    }
    void drop(const juce::Array<juce::File>& files, float x, float y)
    {
        juce::StringArray paths;
        for (const juce::File& f : files) paths.add(f.getFullPathName());
        if (auto* target = dynamic_cast<juce::FileDragAndDropTarget*>(&board_)) target->filesDropped(paths, (int)x, (int)y);
    }
    bool picture(const juce::File& file)
    {
        const juce::Image image = board_.createComponentSnapshot(board_.getLocalBounds(), true, 1.0f);
        file.deleteFile();
        juce::FileOutputStream out(file);
        return out.openedOk() && juce::PNGImageFormat().writeImageToStream(image, out);
    }

private:
    juce::MouseEvent event(juce::Point<float> at, juce::Point<float> downAt, bool right, bool dragged, bool shift = false)
    {
        int flags = right ? juce::ModifierKeys::rightButtonModifier : juce::ModifierKeys::leftButtonModifier;
        if (shift) flags |= juce::ModifierKeys::shiftModifier;
        const juce::Time now = juce::Time::getCurrentTime();
        return juce::MouseEvent(juce::Desktop::getInstance().getMainMouseSource(), at, juce::ModifierKeys(flags), 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                                &board_, &board_, now, downAt, now, 1, dragged);
    }
    juce::Component& board_;
};

int runScreenTest(const juce::File& pictures)
{
    const juce::File root = juce::File::getSpecialLocation(juce::File::tempDirectory)
                                .getChildFile("dubstemmix-screen-" + juce::String(juce::Time::currentTimeMillis()));
    const juce::File kick = writeStem(root, "Tune (Kick).wav", 0.25f, 20.0);
    const juce::File bass = writeStem(root, "Tune (Bass).wav", 0.20f, 20.0);
    const juce::File keys = writeStem(root, "Tune (Keys).wav", 0.10f, 20.0);
    const juce::File horns = writeStem(root, "Tune (Horns).wav", 0.05f, 20.0);

    Engine& engine = Engine::get();
    engine.open();
    dsm::AppModel app(true);
    app.newSession();
    dsm::Board board(app);
    board.status.soundError = "screen test";
    ScreenUser user(board);
    dsm::Transport& t = dsm::transport();

    // What a dialog would answer.
    juce::String typed;
    int pickedItem = 0, opened = 0, saved = 0, fresh = 0;
    juce::String menuItems;
    board.onAskText = [&typed](const juce::String&, const juce::String&, std::function<void(const juce::String&)> done) { done(typed); };
    board.showMenu = [&pickedItem, &menuItems](juce::PopupMenu& menu, std::function<void(int)> picked)
    {
        menuItems = {};
        for (juce::PopupMenu::MenuItemIterator it(menu); it.next();) menuItems << it.getItem().text << "|";
        picked(pickedItem);
    };
    board.onOpen = [&opened] { ++opened; };
    board.onSave = [&saved] { ++saved; };
    board.onNew = [&fresh] { ++fresh; };
    board.onOpenFile = [&app](const juce::File& f) { if (app.open(f) && f.hasFileExtension("dubset")) app.openSong(0); };

    int failures = 0;
    auto expect = [&failures](const char* what, float got, float want, float tolerance = 0.003f)
    {
        const bool ok = std::fabs(got - want) <= tolerance;
        if (!ok) failures++;
        std::printf("%s  %-62s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, (double)got, (double)want);
    };
    auto yes = [&expect](const char* what, bool ok) { expect(what, ok ? 1.0f : 0.0f, 1.0f); };
    {
        SilentPlayer player;
        auto level = [&engine] { return engine.lastLevel.load(); };
        const float masterGain = std::pow(0.8f, 2.5f);
        const float unity = std::pow(0.8f, 2.5f) * 0.5f * masterGain;
        // Where things are on the 1440 x 900 board.
        auto stripX = [](int s) { return 329.0f + 122.0f * (float)s + 57.0f; };
        const float knobY[3] = {322.0f, 414.0f, 506.0f}, muteY = 605.0f, throwY = 641.0f, thirdY = 671.0f, nameY = 576.0f;
        const float faderTop = 705.0f, faderBottom = 811.0f, poolRow = 182.0f;
        const float pageY[4] = {327.0f, 363.0f, 399.0f, 435.0f}, masterX = 1363.0f;

        // ---- Stems: dropped, carried, placed from the menu ----
        user.drop({kick, bass, keys}, 100.0f, 400.0f);
        expect("files dropped on the sidebar: in the stems to place", (float)app.session.pool.size(), 3.0f);
        user.drag(116.0f, poolRow, stripX(0), 500.0f);
        expect("a stem carried from the list onto strip 1", (float)app.session.strips[0].size(), 1.0f);
        yes("...it is the kick", app.session.strips[0].size() == 1 && app.session.strips[0][0].file == kick);
        pickedItem = 2;   // "Place on strip 2"
        user.rightClick(116.0f, poolRow);
        yes("right-click on a stem: the menu offers the strips", menuItems.contains("Place on strip 2") && menuItems.contains("Remove"));
        yes("...and places the bass on strip 2", app.session.strips[1].size() == 1 && app.session.strips[1][0].file == bass);
        user.drop({horns}, stripX(3), 600.0f);
        yes("a file dropped on strip 4 goes there", app.session.strips[3].size() == 1 && app.session.pool.size() == 1);
        pickedItem = 100;   // "Back to the stems to place"
        user.rightClick(stripX(3), 842.0f);
        yes("right-click on a strip's stem: back to the stems to place", app.session.strips[3].empty() && app.session.pool.size() == 2);
        wait(0.8);

        // ---- Transport ----
        user.click(273.0f, 42.0f);
        wait(0.8);
        yes("the play button starts the song", engine.isPlaying());
        expect("...strips 1 and 2 sound", level(), 0.45f * unity);
        user.click(250.0f + 1172.0f * 0.5f, 117.0f);
        wait(0.5);
        expect("a click in the middle of the waveform jumps there", (float)engine.seconds(), 10.5f, 0.7f);
        user.click(325.0f, 42.0f);
        wait(0.4);
        expect("the back button returns to the start", (float)engine.seconds(), 0.4f, 0.4f);
        const bool loopBefore = app.session.loop;
        user.click(377.0f, 42.0f);
        yes("the loop button switches the loop", app.session.loop != loopBefore && t.loop.load() == app.session.loop);

        // ---- A strip: fader, MUTE, THROW held, a send knob, KEEP, SOLO ----
        user.drag(stripX(0) - 12.0f, 740.0f, stripX(0) - 12.0f, faderBottom + 6.0f);
        wait(0.6);
        expect("fader 1 dragged to the bottom: only strip 2 left", level(), 0.20f * unity);
        user.drag(stripX(0) - 12.0f, faderBottom, stripX(0) - 12.0f, faderTop);
        wait(0.6);
        expect("fader 1 dragged to the top", level(), 0.25f * 0.5f * masterGain + 0.20f * unity);
        user.click(stripX(0), muteY);
        wait(0.6);
        expect("MUTE 1 clicked: only strip 2 left", level(), 0.20f * unity);
        yes("...its lamp is lit", engine.on(engine.lampMute[0]));
        user.click(stripX(0), muteY);
        user.press(stripX(1), throwY);
        wait(0.3);
        yes("THROW 2 held: lit while it is down", engine.on(engine.lampRec[1]));
        user.release(stripX(1), throwY);
        wait(0.3);
        yes("...and off when let go", !engine.on(engine.lampRec[1]));
        user.drag(stripX(0), knobY[0], stripX(0), knobY[0] - 80.0f);
        expect("the delay send of strip 1 turned up by dragging", engine.value(engine.send[0][0]), 0.5f, 0.01f);
        user.click(stripX(1), thirdY);
        yes("KEEP 2 clicked", engine.on(engine.keep[1]));
        user.click(masterX, 647.0f);
        user.click(stripX(1), muteY);
        yes("SOLO, then MUTE 2: strip 2 soloed", engine.on(engine.solo[1]) && !engine.on(engine.mute[1]));
        user.click(stripX(1), muteY);
        user.click(masterX, 647.0f);
        yes("...and off again", !engine.on(engine.solo[1]));

        // ---- Pages, an effect knob, an insert ----
        user.click(masterX, pageY[1]);
        wait(0.3);
        expect("the FX button shows the FX page", (float)engine.currentPage(), (float)dsm::kFx);
        const float before = engine.value(engine.effect[fx::DelayFeedback]);
        user.drag(stripX(0), knobY[1], stripX(0), knobY[1] - 40.0f);
        expect("FX page: strip 1's middle knob is the delay feedback", engine.value(engine.effect[fx::DelayFeedback]), before + 0.25f, 0.01f);
        user.picture(pictures.getChildFile("screen-fx.png"));
        user.click(masterX, pageY[3]);
        wait(0.3);
        expect("the INSERTS button shows the INSERTS page", (float)engine.currentPage(), (float)dsm::kInserts);
        user.click(stripX(1), thirdY);
        expect("INSERTS page: a click gives strip 2 the sub", (float)engine.choice(engine.insert[1], fx::insert::KindCount), (float)fx::insert::Sub);
        user.click(masterX, pageY[0]);
        wait(0.3);
        expect("the MIX button comes back to MIX", (float)engine.currentPage(), (float)dsm::kMix);

        // ---- Bus cards: where a bus is sent, its model, pre / post ----
        user.click(250.0f + 151.0f, 189.0f);
        expect("delay card: TO sends the delay to the reverb", (float)engine.choice(engine.busTo[fx::Delay], 3), 1.0f);
        user.click(250.0f + 393.0f + 60.0f, 212.0f);
        expect("reverb card: a click on the model gives the spring", (float)engine.choice(engine.reverbModel, 2), 1.0f);
        user.click(250.0f + 393.0f + 172.0f, 212.0f);
        yes("reverb card: POST becomes PRE", t.preFader[fx::Reverb].load());
        user.click(250.0f + 282.0f, 212.0f);
        yes("delay card: POST becomes PRE", t.preFader[fx::Delay].load());
        user.picture(pictures.getChildFile("screen-mix.png"));

        // ---- Tempo ----
        app.setBpm(70.0);
        user.click(1011.0f, 51.0f);
        expect("x2 doubles the tempo", (float)app.session.bpm, 140.0f);
        user.click(977.0f, 51.0f);
        expect("÷2 halves it", (float)app.session.bpm, 70.0f);
        user.drag(910.0f, 35.0f, 910.0f, 15.0f);
        expect("the tempo dragged up by 20 points", (float)app.session.bpm, 75.0f);
        const bool syncBefore = engine.on(engine.delaySync);
        user.click(1049.0f, 51.0f);
        yes("SYNC switches the delay's sync", engine.on(engine.delaySync) != syncBefore);
        for (int i = 0; i < 4; ++i) { user.click(979.0f, 30.0f); wait(0.5); }
        // Each tap also redraws the board first, so the taps are a little more than half a second apart.
        expect("four taps about half a second apart set the tempo", (float)app.session.bpm, 108.0f, 14.0f);

        // ---- Names, the limiter, the session buttons ----
        typed = "Screen Dub";
        user.doubleClick(500.0f, 32.0f);
        yes("double-click on the title renames the song", app.session.displayTitle() == "Screen Dub");
        typed = "sub bass";
        user.doubleClick(stripX(1), nameY);
        yes("double-click on a strip's name renames it", app.session.stripName(1) == "SUB BASS");
        user.click(masterX, 839.0f);
        yes("LIMITER ON clicked: off", !t.limiterOn.load());
        user.click(masterX, 839.0f);
        yes("...and on again", t.limiterOn.load());
        user.click(1202.0f, 42.0f);
        user.click(1275.0f, 42.0f);
        user.click(1120.0f, 42.0f);
        yes("SAVE, NEW and OPEN ask their dialogs", saved == 1 && fresh == 1 && opened == 1);

        // ---- A setlist: dropped on the window, a song picked in the sidebar ----
        const juce::File first = root.getChildFile("First.dubstem"), second = root.getChildFile("Second.dubstem");
        app.saveAs(first);
        app.rename("Second Tune");
        app.saveAs(second);
        const juce::File set = root.getChildFile("Night.dubset");
        set.replaceWithText("{\"version\": 1, \"name\": \"Night\", \"projects\": [{\"path\": \"\", \"relativePath\": \"First.dubstem\", \"color\": 2, \"tag\": \"opener\"},"
                            " {\"path\": \"\", \"relativePath\": \"Second.dubstem\"}]}");
        user.drop({set}, 700.0f, 500.0f);
        wait(0.5);
        expect("a setlist dropped on the window opens on its first song", (float)app.setlistIndex, 0.0f);
        expect("...with its two songs", (float)app.setlist.songs.size(), 2.0f);
        // Two stems wait to be placed: their rows, then the setlist's.
        const float firstRow = 132.0f + 16.0f + 16.0f + 2.0f * 40.0f + 12.0f + 34.0f;
        user.click(116.0f, firstRow + 42.0f + 19.0f);
        wait(0.5);
        expect("a click on the second song loads it", (float)app.setlistIndex, 1.0f);
        yes("...stopped, with its title", !engine.isPlaying() && app.session.displayTitle() == "Second Tune");
        pickedItem = 0;
        user.click(1120.0f, 42.0f);
        yes("OPEN now lists the recent files", menuItems.contains("Night") && menuItems.contains("(setlist)") && menuItems.contains("Clear Menu"));
        user.picture(pictures.getChildFile("screen-setlist.png"));
        t.preFader[fx::Reverb].store(false);
        t.preFader[fx::Delay].store(false);

        // ---- Recording and the recorded sessions (PRD § 5.9) ----
        app.home = root.getChildFile("home");
        int recordAsked = 0;
        board.onRecord = [&recordAsked, &app] { ++recordAsked; app.toggleRecording("Screen card"); };
        engine.togglePlay();
        user.click(1369.0f, 42.0f);
        yes("the REC button starts a recording", recordAsked == 1 && app.isRecording());
        wait(1.0);
        user.picture(pictures.getChildFile("screen-recording.png"));
        user.click(1369.0f, 42.0f);
        yes("...and stops it", !app.isRecording() && app.lastRecording.getChildFile("session.wav").existsAsFile());
        engine.togglePlay();
        {
            dsm::Sessions sessions(app);
            ScreenUser listener(sessions);
            juce::String asked;
            sessions.onConfirm = [&asked](const juce::String& q, std::function<void()>) { asked = q; };   // the test never trashes anything
            sessions.open();
            expect("the recorded sessions screen lists the session", (float)sessions.count(), 1.0f);
            yes("...and shows it", sessions.chosen() != nullptr && sessions.chosen()->folder == app.lastRecording);
            listener.click(635.0f, 810.0f);
            for (int i = 0; i < 80 && app.exportProgress.load() >= 0.0; ++i) wait(0.25);
            app.tick();
            listener.look();
            yes("EXPORT MP3 writes the session's MP3, or says why it cannot", app.lastRecording.getChildFile("session.mp3").existsAsFile()
                                                                               || app.message.contains("silent"));
            listener.click(1015.0f, 810.0f);
            yes("MOVE TO TRASH asks first", asked.contains("to the trash"));
            listener.picture(pictures.getChildFile("screen-sessions.png"));
        }

        // ---- The setlist workshop (PRD § 13) ----
        const juce::File songs = app.home.getChildFile("Songs");
        songs.createDirectory();
        const char* titles[4] = {"Alpha Steppa", "Bass Culture", "Chant Down", "Dread Time"};
        juce::File projects[4];
        for (int i = 0; i < 4; ++i)
        {
            app.newSession();
            app.addFiles({i % 2 == 0 ? kick : bass}, 0);
            app.setBpm(70.0 + i);
            wait(0.5);
            projects[i] = songs.getChildFile(juce::String(titles[i]) + ".dubstem");
            app.saveAs(projects[i]);
        }
        dsm::Workshop workshop(app);
        ScreenUser editor(workshop);
        juce::String question;
        workshop.onAskText = board.onAskText;
        workshop.showMenu = board.showMenu;
        workshop.onConfirm = [&question](const juce::String& q, std::function<void()> yes) { question = q; yes(); };
        int back = 0;
        workshop.onBack = [&back] { ++back; };
        workshop.open();
        expect("the library lists every project of the DubStemMix folder", (float)app.library.size(), 4.0f);
        yes("...by title, with its tempo", app.library.size() == 4 && app.library[0].title == "Alpha Steppa" && app.library[3].bpm == 73.0);

        typed = "Friday";
        editor.click(51.0f, 715.0f);
        yes("NEW asks a name and creates the setlist in the Setlists folder", app.editing.name == "Friday" && app.setlistsFolder().getChildFile("Friday.dubset").existsAsFile());
        const float libraryRow0 = 140.0f + 15.0f, lineRow0 = 140.0f + 17.0f;
        editor.drag(500.0f, libraryRow0, 1000.0f, lineRow0);
        editor.drag(500.0f, libraryRow0 + 34.0f * 2, 1000.0f, 400.0f);
        editor.drag(500.0f, libraryRow0 + 34.0f, 1000.0f, lineRow0 + 38.0f);
        yes("songs dragged from the library land where they are dropped", app.editing.songs.size() == 3 && app.editing.songs[0].title == "Alpha Steppa"
                                                                           && app.editing.songs[1].title == "Bass Culture" && app.editing.songs[2].title == "Chant Down");
        editor.drag(500.0f, libraryRow0, 1000.0f, 400.0f);
        expect("a song already in the setlist is not added twice", (float)app.editing.songs.size(), 3.0f);
        editor.drag(1000.0f, lineRow0 + 38.0f * 2, 1000.0f, lineRow0 - 10.0f);
        yes("a line dragged to the top moves there", app.editing.songs[0].title == "Chant Down" && app.editing.songs[1].title == "Alpha Steppa");
        editor.click(820.0f + 76.0f, lineRow0);
        expect("a click on the colour dot gives the line its first colour", (float)app.editing.songs[0].colour, 0.0f);
        typed = "opener";
        editor.click(820.0f + 400.0f, lineRow0);
        yes("a click on the tag asks for it", app.editing.songs[0].tag == "opener");
        pickedItem = 104;   // Colour > Green
        editor.rightClick(1000.0f, lineRow0 + 38.0f);
        expect("right-click > Colour > Green", (float)app.editing.songs[1].colour, 3.0f);
        dsm::Setlist reread;
        juce::String error;
        dsm::Setlist::load(app.setlistsFolder().getChildFile("Friday.dubset"), reread, error);
        yes("every change is written at once: order, colour and tag are in the file", reread.songs.size() == 3 && reread.songs[0].title == "Chant Down"
                                                                                        && reread.songs[0].colour == 0 && reread.songs[0].tag == "opener" && reread.songs[1].colour == 3);
        yes("...and the screen says so", app.editingSaved.startsWith(juce::String::fromUTF8("SAVED · ")));

        workshop.setSearch("dread");
        expect("the search narrows the library", (float)workshop.shownLibrary().size(), 1.0f);
        editor.drag(500.0f, libraryRow0, 1000.0f, 600.0f);
        yes("...and the song found can be dragged in", app.editing.songs.size() == 4 && app.editing.songs[3].title == "Dread Time");
        workshop.setSearch("");
        editor.click(1000.0f, lineRow0 + 38.0f * 3);
        workshop.keyPressed(juce::KeyPress(juce::KeyPress::backspaceKey));
        expect("a selected line is removed with Backspace", (float)app.editing.songs.size(), 3.0f);

        editor.click(354.0f + 12.0f, libraryRow0);
        yes("the play mark of a library song starts its preview", dsm::Preview::get().isPlaying(projects[0].getFullPathName()));
        editor.picture(pictures.getChildFile("screen-workshop.png"));
        editor.click(354.0f + 12.0f, libraryRow0);
        yes("...and stops it", !dsm::Preview::get().isPlaying());

        editor.click(138.0f, 715.0f);
        yes("DUPLICATE makes a copy and opens it", app.editing.name == "Friday copy" && app.setlistFiles.size() == 2 && app.editing.songs.size() == 3);
        typed = "Saturday";
        editor.click(228.0f, 715.0f);
        yes("RENAME renames its file", app.editing.name == "Saturday" && app.setlistsFolder().getChildFile("Saturday.dubset").existsAsFile()
                                         && !app.setlistsFolder().getChildFile("Friday copy.dubset").existsAsFile());
        editor.click(300.0f, 715.0f);
        yes("DELETE asks, then removes the setlist, not its songs", question.contains("Saturday") && app.setlistFiles.size() == 1 && projects[0].existsAsFile());
        editor.click(100.0f, 144.0f);
        yes("a click on a setlist opens it", app.editing.name == "Friday");
        editor.click(1326.0f, 97.0f);
        yes("LOAD IN THE CONSOLE gives the setlist to the console and goes back", back == 1 && app.setlist.name == "Friday" && app.setlist.songs.size() == 3 && app.setlistIndex == -1);

        // Back on the console: the sidebar's "+" and the reordering menu.
        app.openSong(0);
        wait(0.5);
        pickedItem = 1;   // the only song of the library not in the setlist
        const float header = 132.0f + 16.0f + 54.0f + 12.0f;
        user.click(173.0f, header + 5.0f);
        yes("the sidebar's + lists only the songs not in the setlist", menuItems == "Dread Time|");
        yes("...and adds the one picked right after the song open", app.setlist.songs.size() == 4 && app.setlist.songs[1].title == "Dread Time");
        pickedItem = 2;   // Move down
        user.rightClick(116.0f, header + 34.0f + 19.0f);
        yes("right-click > Move down moves the open song, which stays the open one", app.setlist.songs[1].title == "Chant Down" && app.setlistIndex == 1);
        user.picture(pictures.getChildFile("screen-console-setlist.png"));
        dsm::Setlist::load(app.setlist.document, reread, error);
        yes("...and the setlist's file follows", reread.songs.size() == 4 && reread.songs[0].title == "Dread Time");
    }
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
        const int screenTest = arguments.indexOf("--screentest");
        if (screenTest >= 0)
        {
            const juce::File pictures = screenTest + 1 < arguments.size() ? juce::File::getCurrentWorkingDirectory().getChildFile(arguments[screenTest + 1])
                                                                          : juce::File::getSpecialLocation(juce::File::tempDirectory);
            pictures.createDirectory();
            finish(runScreenTest(pictures));
            return;
        }

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
