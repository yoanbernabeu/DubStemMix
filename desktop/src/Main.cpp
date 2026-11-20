// Main.cpp - DubStemMix for the desktop (PRD § 17.5): the app, its window, the keyboard, the checks.
//
//   dubstemmix-desktop [song.dubstem | set.dubset]   opens a project or a setlist made here or on the Mac
//   dubstemmix-desktop --selftest                    no sound card: makes test songs, plays them, checks
//   dubstemmix-desktop --screentest [folder]         no window: plays the console's screen like a user (clicks,
//                                                    drags, drops, menus), checks, and saves pictures in folder
//   dubstemmix-desktop --split song [folder] [reference]  splits a song with the real models and checks the stems
//   dubstemmix-desktop --fetch-models folder         downloads the separation model's files there, checked
//   dubstemmix-desktop --check-plugins [name]        looks for the plugins installed, lists them, tries those named
//   dubstemmix-desktop --snapshot out.png [mix|fx|master|inserts] [song.dubstem | set.dubset]
//                                                    draws the console to a picture, no window, no sound card
//
// Keyboard, as on the Mac: Space play / pause, N and P next and previous song of the setlist, T tap tempo,
// D drop (held), H hold (held), C crash, R rewind, Esc panic; Ctrl/Cmd + O, S, Shift + S, N for the session.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "Workshop.h"
#include "Sessions.h"
#include "Preparation.h"

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
    explicit MainComponent(dsm::AppModel& app) : app_(app), board_(app), workshop_(app), sessions_(app), preparation_(app)
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

        // Stem separation (PRD § 12): its questions are dialogs; its screen follows app_.preparing.
        app_.ask = [this](const juce::String& title, const juce::String& question, const juce::String& yes, std::function<void()> then)
        {
            juce::AlertWindow::showOkCancelBox(juce::MessageBoxIconType::QuestionIcon, title, question, yes, "Cancel", this,
                                               juce::ModalCallbackFunction::create([then = std::move(then)](int ok) { if (ok == 1) then(); }));
        };
        board_.onSplit = [this]
        {
            chooser_ = std::make_unique<juce::FileChooser>("A full song to split into drums, bass, instruments and vocals", songsFolder(), kAudioFiles);
            chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles,
                                  [this](const juce::FileChooser& c) { if (c.getResult() != juce::File()) app_.splitSong(c.getResult()); });
        };
        board_.onPrepare = [this] { app_.prepareSongs({}); };
        preparation_.onAddSongs = [this]
        {
            chooser_ = std::make_unique<juce::FileChooser>("Songs to prepare (each one gets its stems and a ready project)", songsFolder(), kAudioFiles);
            chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles | juce::FileBrowserComponent::canSelectMultipleItems,
                                  [this](const juce::FileChooser& c) { if (c.getResults().size() > 0) app_.prepareSongs(c.getResults()); });
        };
        preparation_.onFolder = [this]
        {
            chooser_ = std::make_unique<juce::FileChooser>("Folder where separated stems are written", app_.stemsFolder());
            chooser_->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories,
                                  [this](const juce::FileChooser& c) { if (c.getResult().isDirectory()) app_.settings.setStemsFolder(c.getResult()); });
        };
        preparation_.onConfirm = [this](const juce::String& question, std::function<void()> yes) { confirm("Stem separation", question, std::move(yes)); };
        addChildComponent(preparation_);
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
        preparation_.setTransform(fit);
    }

    bool keyPressed(const juce::KeyPress& key) override
    {
        // The workshop is not for playing: only its own keys answer there. While songs are prepared, nothing plays.
        if (workshop_.isVisible()) return workshop_.keyPressed(key);
        if (preparation_.isVisible()) return false;
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
        if (workshop_.isVisible() || sessions_.isVisible() || preparation_.isVisible()) return false;
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
        app_.followSplit();
        // The preparation screen takes the console's place for as long as the mode lasts (PRD § 12.6).
        if (app_.preparing != preparation_.isVisible())
        {
            if (app_.preparing) { workshop_.setVisible(false); sessions_.setVisible(false); }
            preparation_.setVisible(app_.preparing);
            board_.setVisible(!app_.preparing);
            grabKeyboardFocus();
        }
        app_.plugins.sync();
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
        if (preparation_.isVisible()) preparation_.repaint();
        else if (workshop_.isVisible()) workshop_.repaint(); else if (sessions_.isVisible()) sessions_.repaint(); else board_.repaint();
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
        if (workshop_.isVisible() || preparation_.isVisible()) return;
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
    dsm::Preparation preparation_;
    static constexpr const char* kAudioFiles = "*.wav;*.aif;*.aiff;*.flac;*.mp3;*.ogg;*.m4a";
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

// The tests' own plugin: a gain, with one setting ("Gain") and its state. Loaded through the same slots,
// macros and project entries as an installed plugin.
class TestGain : public juce::AudioProcessor
{
public:
    TestGain() : juce::AudioProcessor(BusesProperties().withInput("In", juce::AudioChannelSet::stereo(), true).withOutput("Out", juce::AudioChannelSet::stereo(), true))
    {
        addParameter(gain_ = new juce::AudioParameterFloat(juce::ParameterID("gain", 1), "Gain", 0.0f, 1.0f, 1.0f));
        addParameter(tone_ = new juce::AudioParameterFloat(juce::ParameterID("tone", 1), "Tone", 0.0f, 1.0f, 0.5f));
    }
    const juce::String getName() const override { return "Test Gain"; }
    void prepareToPlay(double, int) override {}
    void releaseResources() override {}
    void processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override { buffer.applyGain(gain_->get()); }
    double getTailLengthSeconds() const override { return 0.0; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    juce::AudioProcessorEditor* createEditor() override { return nullptr; }
    bool hasEditor() const override { return false; }
    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram(int) override {}
    const juce::String getProgramName(int) override { return {}; }
    void changeProgramName(int, const juce::String&) override {}
    void getStateInformation(juce::MemoryBlock& data) override { const float v[2] = {gain_->get(), tone_->get()}; data.append(v, sizeof v); }
    void setStateInformation(const void* data, int size) override
    {
        if (size < (int)(2 * sizeof(float))) return;
        const float* v = static_cast<const float*>(data);
        *gain_ = v[0];
        *tone_ = v[1];
    }

private:
    juce::AudioParameterFloat* gain_ = nullptr;
    juce::AudioParameterFloat* tone_ = nullptr;
};

void addTestPlugin(dsm::AppModel& app)
{
    app.plugins.addInternal("Test Gain", [] { return std::unique_ptr<juce::AudioProcessor>(new TestGain()); });
}

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

// The tests' separator: each "network" gives back a fixed share of the mix, through the real chunks and
// overlap-add, so the four stems add up to the song.
class FakeSeparator : public dsm::split::Separator
{
public:
    static inline std::atomic<int> calls{0}, delayMs{0};
    static float share(int stem)
    {
        const float shares[dsm::split::StemCount] = {0.5f, 0.25f, 0.125f, 0.125f};
        return shares[stem];
    }

    bool separate(int stem, const dsm::split::Stereo& mix, dsm::split::Stereo& out, const std::function<void(int, int)>& progress,
                  const std::function<bool()>& cancelled, juce::String& error) override
    {
        using namespace dsm::split;
        ++calls;
        const int count = chunkCount(mix.size());
        Accumulator accumulator(mix.size());
        std::vector<float> left((size_t)kChunk), right((size_t)kChunk);
        for (int chunk = 0; chunk < count; ++chunk)
        {
            if (cancelled()) { error = "cancelled"; return false; }
            const long long start = (long long)chunk * kStride;
            const int length = (int)juce::jmin((long long)kChunk, mix.size() - start);
            for (int i = 0; i < length; ++i)
            {
                left[(size_t)i] = mix.left[(size_t)(start + i)] * share(stem);
                right[(size_t)i] = mix.right[(size_t)(start + i)] * share(stem);
            }
            accumulator.add(left.data(), right.data(), start, length);
            if (delayMs.load() > 0) wait(delayMs.load() * 0.001);
            progress(chunk + 1, count);
        }
        out = accumulator.finish();
        return true;
    }
};

// A short pulse at `at` seconds, 16-bit, any rate, mono or stereo: where it lands after decoding tells the timing.
juce::File writePulse(const juce::File& folder, const char* name, int rate, int channels, double seconds, double at)
{
    folder.createDirectory();
    const juce::File file = folder.getChildFile(name);
    file.deleteFile();
    juce::FileOutputStream out(file);
    const uint32_t frames = (uint32_t)(seconds * rate), data = frames * 2 * (uint32_t)channels;
    out.write("RIFF", 4); out.writeInt((int)(36 + data)); out.write("WAVEfmt ", 8);
    out.writeInt(16); out.writeShort(1); out.writeShort((short)channels); out.writeInt(rate); out.writeInt(rate * 2 * channels);
    out.writeShort((short)(2 * channels)); out.writeShort(16);
    out.write("data", 4); out.writeInt((int)data);
    for (uint32_t i = 0; i < frames; ++i)
    {
        const double t = ((double)i / rate - at) / 0.001;
        const short sample = (short)(24000.0 * std::exp(-0.5 * t * t));
        for (int c = 0; c < channels; ++c) out.writeShort(sample);
    }
    return file;
}

// Polls the app as its timer would, until the separation's background work is over.
void waitForSplit(dsm::AppModel& app, double atMost = 30.0)
{
    for (double waited = 0.0; waited < atMost; waited += 0.02)
    {
        app.followSplit();
        if (!app.splitBusy()) return;
        wait(0.02);
    }
}

// `--split song [folder] [reference folder]`: splits a song with the real models (never run by the automatic
// tests: they are not downloaded there) and says how well the four stems add up to the song (PRD § 12.5).
// With a reference folder holding the same four files (the Mac app's, say), says how far each stem is from it.
int runSplitCheck(const juce::File& source, const juce::File& root, const juce::File& reference)
{
    using namespace dsm::split;
    const ModelStore models(dsm::Settings::folderFor(false).getChildFile("Models").getChildFile(Catalog::htdemucs().name).getChildFile(Catalog::htdemucs().shortRevision()),
                            Catalog::htdemucs());
    if (!models.isReady()) { std::fprintf(stderr, "the models are not in %s\n", models.directory().getFullPathName().toRawUTF8()); return 1; }
    const double started = juce::Time::getMillisecondCounterHiRes();
    int lastStem = -1;
    const Result result = run(source, root, models.catalog().id(), [&models] { return std::unique_ptr<Separator>(new OnnxSeparator(models)); },
                              [&lastStem](const Progress& p) { if (p.stem != lastStem) { lastStem = p.stem; std::printf("%s...\n", stemName(p.stem)); std::fflush(stdout); } },
                              [] { return false; });
    if (!result.ok) { std::fprintf(stderr, "split failed: %s\n", result.error.toRawUTF8()); return 1; }
    const double seconds = audioSeconds(source), work = (juce::Time::getMillisecondCounterHiRes() - started) * 0.001;
    std::printf("%s in %s\n", result.reused ? "already split" : "split", result.folder.getFullPathName().toRawUTF8());
    if (!result.reused) std::printf("%.0f s of work for %.0f s of song (x%.2f)\n", work, seconds, work / juce::jmax(1.0, seconds));

    Stereo mix, stems[StemCount];
    juce::String error;
    if (!loadAudio(source, mix, error)) return 1;
    auto energy = [](const Stereo& a) { double e = 0.0; for (size_t i = 0; i < a.left.size(); ++i) e += (double)a.left[i] * a.left[i] + (double)a.right[i] * a.right[i]; return e; };
    auto decibels = [](double ratio) { return 10.0 * std::log10(juce::jmax(1.0e-12, ratio)); };
    Stereo rest = mix;
    // Two files may differ by a sample or two when their rate was converted by two different programs.
    auto sameLength = [](const Stereo& a, const Stereo& b) { return std::llabs(a.size() - b.size()) <= 2; };
    for (int s = 0; s < StemCount; ++s)
    {
        if (!loadAudio(result.stems[s], stems[s], error) || !sameLength(stems[s], mix)) { std::fprintf(stderr, "%s: wrong length\n", stemName(s)); return 1; }
        for (size_t i = 0; i < juce::jmin(rest.left.size(), stems[s].left.size()); ++i) { rest.left[i] -= stems[s].left[i]; rest.right[i] -= stems[s].right[i]; }
        std::printf("%-12s %6.1f dB under the song\n", stemName(s), -decibels(energy(stems[s]) / energy(mix)));
    }
    const double match = -decibels(energy(rest) / energy(mix));
    std::printf("the stems add up to the song within %.1f dB (25 dB or more expected)\n", match);
    bool ok = match >= 25.0;
    if (reference.isDirectory())
        for (int s = 0; s < StemCount; ++s)
        {
            Stereo other;
            if (!loadAudio(reference.getChildFile(stemFile(s)), other, error) || !sameLength(other, stems[s])) { std::printf("%-12s no reference of the same length\n", stemName(s)); ok = false; continue; }
            Stereo difference = stems[s];
            for (size_t i = 0; i < juce::jmin(difference.left.size(), other.left.size()); ++i) { difference.left[i] -= other.left[i]; difference.right[i] -= other.right[i]; }
            std::printf("%-12s differs from the reference by %.1f dB under the stem\n", stemName(s), -decibels(energy(difference) / juce::jmax(1.0e-12, energy(other))));
        }
    return ok ? 0 : 1;
}

// `--fetch-models folder`: downloads the separation model's files into a folder, as the app does once the
// user has agreed (resumed if cut, size and SHA-256 checked). For checking the download on a new system.
int runFetchModels(const juce::File& folder)
{
    using namespace dsm::split;
    const ModelStore models(folder, Catalog::htdemucs());
    std::printf("%d of %d files already in %s\n", models.readyCount(), (int)models.catalog().files.size(), folder.getFullPathName().toRawUTF8());
    juce::String error;
    juce::int64 shown = -1;
    const bool ok = models.download([&shown](juce::int64 received, juce::int64 total)
                                    {
                                        if (received / 50000000 == shown) return;
                                        shown = received / 50000000;
                                        std::printf("%lld / %lld MB\n", (long long)(received / 1000000), (long long)(total / 1000000));
                                        std::fflush(stdout);
                                    }, [] { return false; }, error);
    std::printf("%s\n", ok ? "the four files are there and match their checksums" : ("download failed: " + error).toRawUTF8());
    return ok ? 0 : 1;
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
        // Third-party plugins (PRD § 5.5, § 11.5), with the tests' own gain plugin.
        addTestPlugin(app);
        app.open(project);
        wait(0.8);
        engine.togglePlay();
        wait(0.8);
        // (The bass stem was deleted above: only strip 1 sounds here.)
        expect("before any plugin: strip 1", level(), 0.35f * unity);
        dsm::Slot& insert1 = app.plugins.insert[0];
        app.setPlugin(insert1, "internal:Test Gain");
        yes("a plugin goes into strip 1's insert", insert1.holdsPlugin() && app.message.isEmpty());
        wait(0.5);
        expect("...at its own settings: nothing changes yet", level(), 0.35f * unity);
        app.plugins.assign(insert1, 0, 0);   // first INSERTS knob of the strip = the plugin's Gain
        expect("a macro takes the plugin's value: the knob does not jump", engine.value(engine.insertValue[0][0]), 1.0f);
        engine.set(engine.insertValue[0][0], 0.5f);
        app.plugins.sync();
        wait(0.5);
        expect("the knob turned down halves strip 1 through the plugin", level(), 0.35f * 0.5f * unity);
        insert1.plugin->parameter(0)->setValueNotifyingHost(0.25f);
        app.plugins.sync();
        expect("a setting changed in the plugin's own window comes back to the knob", engine.value(engine.insertValue[0][0]), 0.25f);
        dsm::Slot& reverbSlot = app.plugins.bus[fx::Reverb];
        app.setPlugin(reverbSlot, "internal:Test Gain");
        app.plugins.assign(reverbSlot, 0, 1);   // first knob of the reverb on the FX page = the plugin's Tone
        engine.set(engine.effect[fx::ReverbDecay], 0.3f);
        app.plugins.sync();
        expect("a bus plugin: the FX page's reverb knob drives its macro", reverbSlot.plugin->parameter(1)->getValue(), 0.3f);
        yes("...and the engine calls it in place of the built-in reverb", dsm::hooks().bus[fx::Reverb].load() == reverbSlot.plugin.get());
        app.save();
        const juce::var withPlugins = juce::JSON::parse(project.loadFileAsString());
        yes("the project keeps the plugins under the app's own key", withPlugins["desktop"]["inserts"]["0"]["plugin"].toString() == "internal:Test Gain"
                                                                       && withPlugins["desktop"]["slots"]["reverb"]["macros"][0].toString() == "1");
        yes("...and writes no built-in insert for that strip in the Mac's entries", withPlugins["inserts"]["0"].isVoid());

        app.newSession();
        yes("New: every slot back to its built-in effect", !insert1.holdsPlugin() && !reverbSlot.holdsPlugin() && dsm::hooks().insert[0].load() == nullptr);
        app.open(project);
        wait(0.8);
        yes("the project opens with its plugins in their slots", insert1.holdsPlugin() && reverbSlot.holdsPlugin());
        expect("...with their settings", insert1.plugin->parameter(0)->getValue(), 0.25f);
        yes("...and their macros", insert1.macros[0] == 0 && reverbSlot.macros[0] == 1);
        engine.togglePlay();
        wait(0.8);
        expect("...and sounds the same", level(), 0.35f * 0.25f * unity);
        dsm::Slot& insert2 = app.plugins.insert[1];
        app.setPlugin(insert2, "internal:Test Gain");
        yes("the same plugin elsewhere gets the macros it had last time", insert2.macros[0] == 1);
        app.setPlugin(insert2, {});
        yes("back to the built-in insert: none", !insert2.holdsPlugin() && engine.choice(engine.insert[1], fx::insert::KindCount) == fx::insert::None);

        // A plugin that is not installed here: said, the built-in effect stays, the project keeps it.
        juce::var gone = juce::JSON::parse(project.loadFileAsString());
        gone["desktop"]["inserts"]["0"].getDynamicObject()->setProperty("plugin", "VST3-Gone-1234");
        gone["desktop"]["inserts"]["0"].getDynamicObject()->setProperty("name", "Gone Verb");
        project.replaceWithText(juce::JSON::toString(gone));
        app.open(project);
        yes("a plugin not installed is said", app.message.contains("Gone Verb") && !insert1.holdsPlugin());
        app.setBpm(81.0);
        app.save();
        yes("...and stays in the project", juce::JSON::parse(project.loadFileAsString())["desktop"]["inserts"]["0"]["plugin"].toString() == "VST3-Gone-1234");
        app.setPlugin(insert1, {});
        app.setPlugin(reverbSlot, {});
        app.save();

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
    // ---- Stem separation (PRD § 12), without the models: chunks, decoding, files, the list, the app's steps ----
    {
        using namespace dsm::split;
        expect("a song shorter than one chunk is one chunk", (float)chunkCount(1), 1.0f);
        expect("...a chunk's stride too", (float)chunkCount(kStride), 1.0f);
        expect("...one sample more makes two", (float)chunkCount(kStride + 1), 2.0f);
        expect("a 3 minute song is 31 chunks", (float)chunkCount(7938000), 31.0f);
        const std::vector<float> w = window();
        expect("the window starts just above zero", w[0], 1.0f / (float)kOverlap, 1.0e-7f);
        expect("...is 1 past the overlap", w[(size_t)kOverlap], 1.0f, 0.0f);
        expect("...and ends as it starts", w[(size_t)kChunk - 1], 1.0f / (float)kOverlap, 1.0e-7f);

        const juce::File songs = root.getChildFile("split");
        const juce::File abc = songs.getChildFile("abc.txt");
        songs.createDirectory();
        abc.replaceWithText("abc");
        yes("SHA-256 is the standard one", sha256(abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

        // Decoding: any rate, mono or stereo, lands at 44.1 kHz stereo, in time.
        auto peakAt = [](const Stereo& a) { size_t best = 0; for (size_t i = 0; i < a.left.size(); ++i) if (std::fabs(a.left[i]) > std::fabs(a.left[best])) best = i; return (float)best; };
        Stereo decoded;
        juce::String error;
        yes("a mono file at 22.05 kHz is read", loadAudio(writePulse(songs, "mono.wav", 22050, 1, 2.0, 1.0), decoded, error));
        expect("...as 2 s at 44.1 kHz", (float)decoded.size(), 88200.0f, 2.0f);
        expect("...its pulse still at 1 s", peakAt(decoded), 44100.0f, 2.0f);
        yes("...on both sides", decoded.size() > 44100 && decoded.right[44100] == decoded.left[44100] && decoded.left[44100] > 0.5f);
        yes("a stereo file at 48 kHz is read", loadAudio(writePulse(songs, "stereo48.wav", 48000, 2, 2.0, 1.0), decoded, error));
        expect("...as 2 s at 44.1 kHz", (float)decoded.size(), 88200.0f, 2.0f);
        expect("...its pulse still at 1 s", peakAt(decoded), 44100.0f, 2.0f);
        const juce::File broken = songs.getChildFile("Broken.wav");
        broken.replaceWithText("this is not sound");
        yes("a file that is not sound is refused", !loadAudio(broken, decoded, error) && error.isNotEmpty());

        // One song through the job, with the tests' separator.
        const juce::File song = writeClicks(songs, "(Jah Clicks - Riddim).wav", 120.0, 20.0);
        const juce::File stemsRoot = root.getChildFile("stems out");
        const juce::String modelId = Catalog::htdemucs().id();
        yes("the model is named as in the Mac app's manifests", modelId == "htdemucs_ft@8616370e");
        auto fake = [] { return std::unique_ptr<Separator>(new FakeSeparator()); };
        std::atomic<bool> stop{false};
        FakeSeparator::calls = 0;
        Result result = run(song, stemsRoot, modelId, fake, [&stop](const Progress& p) { if (p.stem == 1) stop.store(true); }, [&stop] { return stop.load(); });
        yes("a cancelled split says so", !result.ok && result.cancelled);
        yes("...and leaves nothing behind", stemsRoot.findChildFiles(juce::File::findFilesAndDirectories, false).isEmpty());
        float lastFraction = 0.0f;
        result = run(song, stemsRoot, modelId, fake, [&lastFraction](const Progress& p) { lastFraction = (float)p.fraction(); }, [] { return false; });
        yes("a song is split", result.ok && !result.reused);
        expect("...its progress ends at 100 %", lastFraction, 1.0f, 0.0f);
        const juce::String fingerprint = sha256(song);
        yes("...into a folder named after the file and its fingerprint", result.folder == stemsRoot.getChildFile("(Jah Clicks - Riddim) [" + fingerprint.substring(0, 8) + "]"));
        Stereo mix, sum;
        loadAudio(song, mix, error);
        sum.resize(mix.size());
        bool format = true, lengths = true;
        for (int st = 0; st < StemCount; ++st)
        {
            std::unique_ptr<juce::AudioFormatReader> reader(audioFormats().createReaderFor(result.stems[st]));
            format = format && reader != nullptr && reader->usesFloatingPointData && reader->bitsPerSample == 32 && reader->numChannels == 2 && reader->sampleRate == 44100.0;
            Stereo one;
            lengths = loadAudio(result.stems[st], one, error) && one.size() == mix.size() && lengths;
            if (one.size() == mix.size()) for (size_t i = 0; i < one.left.size(); ++i) { sum.left[i] += one.left[i]; sum.right[i] += one.right[i]; }
        }
        yes("drums.wav, bass.wav, instruments.wav and vocals.wav are there", result.folder.getChildFile("drums.wav").existsAsFile() && result.folder.getChildFile("bass.wav").existsAsFile()
                                                                              && result.folder.getChildFile("instruments.wav").existsAsFile() && result.folder.getChildFile("vocals.wav").existsAsFile());
        yes("...32-bit float stereo files at 44.1 kHz", format);
        yes("...as long as the song", lengths);
        float worst = 0.0f;
        for (size_t i = 0; i < mix.left.size(); ++i) worst = juce::jmax(worst, std::fabs(sum.left[i] - mix.left[i]), std::fabs(sum.right[i] - mix.right[i]));
        expect("the chunks are put back together without a seam", worst, 0.0f, 1.0e-4f);
        const juce::var manifest = juce::JSON::parse(result.folder.getChildFile("stems.json").loadFileAsString());
        yes("the manifest names the file's fingerprint and the model", manifest["fingerprint"].toString() == fingerprint && manifest["model"].toString() == modelId
                                                                         && manifest["source"].toString() == song.getFullPathName() && (double)manifest["created"] > 7.0e8);
        const int callsBefore = FakeSeparator::calls.load();
        result = run(song, stemsRoot, modelId, fake, [](const Progress&) {}, [] { return false; });
        yes("the same song again is not computed again", result.ok && result.reused && FakeSeparator::calls.load() == callsBefore);
        result = run(song, stemsRoot, "another@model", fake, [](const Progress&) {}, [] { return false; });
        yes("...unless the model changed", result.ok && !result.reused);

        // The model files: asked for, checked, never half there. Served here from a folder, not from the network.
        const juce::File served = root.getChildFile("served");
        served.createDirectory();
        Catalog catalog;
        catalog.name = "testmodel";
        catalog.revision = "0123456789abcdef";
        catalog.repository = "tests/only";
        for (int st = 0; st < StemCount; ++st)
        {
            const juce::File file = served.getChildFile(juce::String(modelName(st)) + ".onnx");
            file.replaceWithText(juce::String::repeatedString(juce::String(modelName(st)) + " weights ", 4000 + st));
            catalog.files.push_back({st, file.getFileName(), file.getSize(), sha256(file), juce::URL(file).toString(false)});
        }
        ModelStore store(root.getChildFile("models"), catalog);
        yes("no model file at first", store.status() == ModelStore::Missing && !store.isReady());
        juce::int64 lastReceived = 0;
        // A download cut short earlier: what is there is kept or started over, never trusted blindly.
        store.directory().createDirectory();
        store.directory().getChildFile(catalog.files[0].name + ".part").replaceWithText("half a file");
        yes("the download brings the four files", store.download([&lastReceived](juce::int64 received, juce::int64) { lastReceived = received; }, [] { return false; }, error));
        yes("...all of them, checked", store.isReady() && lastReceived == catalog.totalBytes() && sha256(store.file(Vocals)) == catalog.files[Vocals].sha256);
        yes("...with no leftover", store.directory().findChildFiles(juce::File::findFiles, false, "*.part").isEmpty());
        store.file(Bass).deleteFile();
        yes("a file gone: the engine is partly there", store.status() == ModelStore::Partial && store.readyCount() == 3);
        Catalog wrong = catalog;
        wrong.files[Bass].sha256 = "00";
        const ModelStore wrongStore(store.directory(), wrong);
        yes("a file that does not match its checksum is refused", !wrongStore.download([](juce::int64, juce::int64) {}, [] { return false; }, error) && error.contains("checksum"));
        yes("...and thrown away", !store.file(Bass).existsAsFile() && store.directory().findChildFiles(juce::File::findFiles, false, "*.part").isEmpty());
        yes("deleting the engine removes its files", store.remove() && store.status() == ModelStore::Missing);

        // The preparation list.
        Queue queue;
        const juce::File a = songs.getChildFile("a.wav"), b = songs.getChildFile("b.wav"), c = songs.getChildFile("c.wav");
        expect("songs join the list", (float)(queue.add(a, 100.0) + queue.add(b, 200.0) + queue.add(c, -1.0)), 3.0f);
        expect("...never twice while they wait", (float)queue.add(a, 100.0), 0.0f);
        queue.move(queue.items()[2].id, -1);
        yes("a waiting song moves up", queue.items()[1].source == c);
        const Queue::Item* first = queue.startNext();
        yes("the first waiting song starts", first != nullptr && first->source == a && queue.running() != nullptr && queue.startNext() == nullptr);
        queue.remove(queue.items()[0].id);
        expect("the song under way cannot be removed", (float)queue.items().size(), 3.0f);
        expect("time left: the song under way, then the waiting ones at the measured speed", (float)queue.timeLeft(0.5, 20.0), 120.0f, 0.01f);
        expect("...unknown until a speed is known", (float)queue.timeLeft(0.0, 20.0), -1.0f);
        queue.finish(queue.items()[0].id, a.withFileExtension("dubstem"), false);
        queue.cancelAll();
        yes("cancelling empties the list but keeps what is done", queue.items().size() == 1 && queue.items()[0].status == Queue::Done && !queue.hasWork());

        // The app's steps, with the tests' separator and the served model files.
        yes("a project's file is named like the Mac app names it", capitalised("JAH CLICKS - DON'T RIDDIM") == "Jah Clicks - Don't Riddim");
        app.models = ModelStore(root.getChildFile("app models"), catalog);
        app.makeSeparator = fake;
        juce::String asked;
        bool answer = false;
        app.ask = [&asked, &answer](const juce::String& title, const juce::String&, const juce::String& button, std::function<void()> then)
        {
            asked = title + " / " + button;
            if (answer) then();
        };
        app.newSession();
        app.splitSong(song);
        yes("without the engine, splitting asks before any download", asked.startsWith("Download the separation engine?") && asked.contains("MB") && !app.splitBusy());
        yes("...and a no downloads nothing", app.models.status() == ModelStore::Missing);
        answer = true;
        app.splitSong(song);
        yes("a yes starts the download", app.splitBusy() && app.splitStatus().kind == dsm::AppModel::SplitStatus::Downloading);
        waitForSplit(app);   // the download, which hands over to the split
        waitForSplit(app);
        yes("...then the song is split", app.models.isReady() && !app.splitBusy() && app.message.isEmpty());
        yes("its stems are on strips 1 to 4, in order", app.session.strips[0].size() == 1 && app.session.strips[0][0].file.getFileName() == "drums.wav"
                                                          && app.session.strips[1][0].file.getFileName() == "bass.wav" && app.session.strips[2][0].file.getFileName() == "instruments.wav"
                                                          && app.session.strips[3][0].file.getFileName() == "vocals.wav" && app.session.strips[4].empty());
        yes("...named DRUMS, BASS, INSTRUMENTS, VOCALS", app.session.stripName(0) == "DRUMS" && app.session.stripName(1) == "BASS"
                                                           && app.session.stripName(2) == "INSTRUMENTS" && app.session.stripName(3) == "VOCALS");
        yes("...the original in the stems to place", app.session.pool.size() == 1 && app.session.pool[0].file == song);
        yes("...in a new session named after the song, not saved, stopped", app.session.title == "JAH CLICKS - RIDDIM" && !app.hasDocument() && !engine.isPlaying());
        yes("...written in the Stems folder of the DubStemMix folder", app.session.strips[0][0].file.getParentDirectory().getParentDirectory() == app.home.getChildFile("Stems"));
        asked = {};
        engine.togglePlay();
        answer = false;
        app.splitSong(song);
        yes("splitting while a song plays warns first", asked.startsWith("Split while playing?") && !app.splitBusy());
        engine.togglePlay();

        // Preparation mode: several songs, a project each.
        const juce::File second = writeClicks(songs, "Second Tune.wav", 100.0, 12.0);
        answer = true;
        app.prepareSongs({song, second, broken, abc});
        yes("PREPARE SONGS enters the mode with the audio files given", app.preparing && app.prepQueue.items().size() == 3);
        for (int i = 0; i < 1500 && app.prepQueue.hasWork(); ++i) { app.followSplit(); wait(0.02); }
        expect("two songs are prepared", (float)app.prepQueue.count(Queue::Done), 2.0f);
        expect("...the file that is not sound has failed, and the list went on", (float)app.prepQueue.count(Queue::Failed), 1.0f);
        const juce::File prepared = app.prepQueue.items()[1].project;
        yes("a project is written beside the stems", prepared.getFileName() == "Second Tune.dubstem" && prepared.getSiblingFile("vocals.wav").existsAsFile());
        dsm::Session reread;
        yes("...which opens", dsm::Session::load(prepared, reread, error));
        yes("...with its four stems named, the original aside, its title", reread.strips[3].size() == 1 && !reread.strips[3][0].missing && reread.stripName(3) == "VOCALS"
                                                                             && reread.pool.size() == 1 && reread.pool[0].file == second && reread.title == "SECOND TUNE");
        expect("...and its tempo", (float)reread.bpm, 100.0f, 1.5f);
        yes("the speed measured is kept for the next time", app.settings.splitSpeed() > 0.0);
        yes("the session open before is still there", app.session.title == "JAH CLICKS - RIDDIM");
        yes("the mode is left once the list is done", app.leavePreparation() && !app.preparing && app.prepQueue.items().empty());
        app.prepareSongs({second});
        for (int i = 0; i < 500 && app.prepQueue.hasWork(); ++i) { app.followSplit(); wait(0.02); }
        yes("a song already prepared is not prepared again", app.prepQueue.items().size() == 1 && app.prepQueue.items()[0].status == Queue::Done && app.prepQueue.items()[0].reused);
        app.leavePreparation();

        // Cancel all: the song under way stops, nothing of it stays.
        const juce::File third = writeClicks(songs, "Third Tune.wav", 90.0, 12.0);
        FakeSeparator::delayMs = 300;
        app.prepareSongs({third, writeClicks(songs, "Fourth Tune.wav", 90.0, 6.0)});
        wait(0.2);
        yes("the mode cannot be left while a song is split", app.splitBusy() && !app.leavePreparation());
        app.cancelPreparation();
        yes("CANCEL ALL empties the list at once", app.prepQueue.items().empty());
        waitForSplit(app);
        FakeSeparator::delayMs = 0;
        yes("...stops the song under way", !app.splitBusy());
        yes("...and leaves nothing of it", !folderFor(third, sha256(third), app.stemsFolder()).exists()
                                             && app.stemsFolder().findChildFiles(juce::File::findDirectories, false, "*.tmp").isEmpty());
        app.leavePreparation();
        app.ask = nullptr;
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
        pickedItem = 2;   // Sub
        user.click(stripX(1), thirdY);
        expect("INSERTS page: the insert's menu gives strip 2 the sub", (float)engine.choice(engine.insert[1], fx::insert::KindCount), (float)fx::insert::Sub);
        user.click(masterX, pageY[0]);
        wait(0.3);
        expect("the MIX button comes back to MIX", (float)engine.currentPage(), (float)dsm::kMix);

        // ---- Bus cards: where a bus is sent, its model, pre / post ----
        user.click(250.0f + 151.0f, 189.0f);
        expect("delay card: TO sends the delay to the reverb", (float)engine.choice(engine.busTo[fx::Delay], 3), 1.0f);
        pickedItem = 2;   // Spring
        user.click(250.0f + 393.0f + 60.0f, 212.0f);
        yes("reverb card: the effect's name opens its menu", menuItems.contains("Plate|Spring|") && menuItems.contains("Open plugin window"));
        expect("...and picking Spring gives the spring", (float)engine.choice(engine.reverbModel, 2), 1.0f);
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

        // ---- A plugin, through the menus (PRD § 5.5) ----
        addTestPlugin(app);
        pickedItem = 100;   // the first plugin of the list
        user.click(250.0f + 393.0f + 60.0f, 212.0f);
        yes("reverb card: the menu lists the plugins by maker, and puts one in the slot", app.plugins.bus[fx::Reverb].holdsPlugin());
        user.click(masterX, pageY[1]);
        wait(0.3);
        pickedItem = 11;   // its second parameter
        user.click(stripX(2), knobY[0]);
        yes("FX page: a click on an empty macro lists the plugin's parameters", menuItems.contains("Gain|Tone|"));
        yes("...and gives it the one picked", app.plugins.bus[fx::Reverb].macros[0] == 1);
        user.drag(stripX(2), knobY[0], stripX(2), knobY[0] - 40.0f);
        app.plugins.sync();
        expect("...which the knob then drives", app.plugins.bus[fx::Reverb].plugin->parameter(1)->getValue(), 0.75f, 0.01f);
        user.picture(pictures.getChildFile("screen-plugin.png"));
        pickedItem = 2;   // Spring: the built-in reverb again
        user.click(250.0f + 393.0f + 60.0f, 212.0f);
        yes("the menu puts the built-in effect back", !app.plugins.bus[fx::Reverb].holdsPlugin());
        user.click(masterX, pageY[0]);
        wait(0.3);

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

        // ---- Stem separation (PRD § 12), with the tests' separator in place of the models ----
        {
            using namespace dsm::split;
            app.makeSeparator = [] { return std::unique_ptr<Separator>(new FakeSeparator()); };
            app.engineReady = [] { return true; };
            dsm::transport().playing.store(false);
            int splitAsked = 0, addAsked = 0;
            board.onSplit = [&splitAsked] { ++splitAsked; };
            board.onPrepare = [&app] { app.prepareSongs({}); };
            user.click(65.0f, 750.0f);
            yes("SPLIT A SONG asks for a song", splitAsked == 1);
            const juce::File toSplit = root.getChildFile("to split");
            toSplit.createDirectory();
            const juce::File tune = writeClicks(toSplit, "Roots Tune.wav", 110.0, 10.0);
            FakeSeparator::delayMs = 200;
            user.drop({tune}, 65.0f, 750.0f);
            yes("a song dropped on SPLIT A SONG is being split", app.splitBusy() && app.splitStatus().kind == dsm::AppModel::SplitStatus::Splitting);
            wait(0.3);
            user.picture(pictures.getChildFile("screen-splitting.png"));
            FakeSeparator::delayMs = 0;
            waitForSplit(app);
            user.look();
            yes("...its four stems land on strips 1 to 4 with their names", app.session.strips[3].size() == 1 && app.session.stripName(0) == "DRUMS"
                                                                             && app.session.stripName(3) == "VOCALS" && app.session.title == "ROOTS TUNE");
            yes("...and the song itself waits in the stems to place", app.session.pool.size() == 1 && app.session.pool[0].file == tune);
            user.picture(pictures.getChildFile("screen-split.png"));

            user.click(166.0f, 750.0f);
            yes("PREPARE SONGS opens the preparation mode", app.preparing);
            dsm::Preparation preparation(app);
            ScreenUser preparer(preparation);
            juce::String confirmAsked;
            preparation.onAddSongs = [&addAsked] { ++addAsked; };
            preparation.onConfirm = [&confirmAsked](const juce::String& q, std::function<void()>) { confirmAsked = q; };
            preparer.click(1125.0f, 42.0f);
            yes("ADD SONGS asks for songs", addAsked == 1);
            const juce::File notSound = toSplit.getChildFile("Noise.wav");
            notSound.replaceWithText("not sound at all");
            FakeSeparator::delayMs = 150;
            preparer.drop({writeClicks(toSplit, "First Dub.wav", 100.0, 8.0), notSound, writeClicks(toSplit, "Second Dub.wav", 120.0, 8.0),
                           writeClicks(toSplit, "Third Dub.wav", 90.0, 8.0)}, 700.0f, 400.0f);
            expect("songs dropped on the screen join the list", (float)app.prepQueue.items().size(), 4.0f);
            yes("...and the first one starts", app.splitBusy() && app.prepQueue.items()[0].status == Queue::Running);
            wait(0.4);
            app.followSplit();
            preparer.picture(pictures.getChildFile("screen-preparing.png"));
            preparer.click(1396.0f, 112.0f + 3.0f * 52.0f + 24.0f);
            yes("the cross removes a waiting song", app.prepQueue.items().size() == 3 && app.prepQueue.items()[2].source.getFileName() == "Second Dub.wav");
            yes("the mode cannot be left while songs are prepared", !app.leavePreparation() && app.preparing);
            FakeSeparator::delayMs = 0;
            for (int i = 0; i < 1500 && app.prepQueue.hasWork(); ++i) { app.followSplit(); wait(0.02); }
            preparer.look();
            yes("the songs end READY, the file that is not sound FAILED", app.prepQueue.count(Queue::Done) == 2 && app.prepQueue.count(Queue::Failed) == 1);
            yes("...each with its project beside its stems", app.prepQueue.items()[0].project.getFileName() == "First Dub.dubstem" && app.prepQueue.items()[0].project.existsAsFile());
            yes("the screen sums it up", preparation.summary() == dsm::look::u("2 / 3 PREPARED · 1 FAILED · ALL DONE"));
            preparer.picture(pictures.getChildFile("screen-prepared.png"));
            preparer.click(900.0f, 785.0f);
            yes("DELETE asks before removing the engine's files", app.models.status() == ModelStore::Missing || confirmAsked.contains("Delete"));
            preparer.click(1322.0f, 42.0f);
            yes("BACK TO CONSOLE leaves the mode", !app.preparing);
            yes("...where the session is still the one left", app.session.title == "ROOTS TUNE");
        }
    }
    root.deleteRecursively();
    std::printf("Result: %s\n", failures == 0 ? "all passed" : "FAILED");
    std::fflush(stdout);
    return failures == 0 ? 0 : 1;
}

// Looks for the plugins installed, lists them, and tries the ones whose name holds `wanted`: loaded in the
// reverb's slot, a second of sound through them, their parameters counted. The scan runs in the background
// while the app's main thread stays free, as in the app: Audio Units need it to load.
class PluginCheck : private juce::Timer
{
public:
    PluginCheck(const juce::String& wanted, std::function<void(int)> done) : wanted_(wanted), done_(std::move(done))
    {
        Engine::get().open();
        app_.plugins.scan();
        startTimer(200);
    }

private:
    void timerCallback() override
    {
        if (app_.plugins.scanning.load()) return;
        stopTimer();
        const std::vector<dsm::PluginHost::Choice> choices = app_.plugins.choices();
        std::printf("%d effect plugin(s) found\n", (int)choices.size());
        for (const auto& choice : choices) std::printf("  %s - %s\n", choice.manufacturer.toRawUTF8(), choice.name.toRawUTF8());
        int failures = 0, tried = 0;
        if (wanted_.isNotEmpty())
        {
            SilentPlayer player;
            for (const auto& choice : choices)
            {
                if (!choice.name.containsIgnoreCase(wanted_)) continue;
                ++tried;
                dsm::Slot& slot = app_.plugins.bus[fx::Reverb];
                app_.setPlugin(slot, choice.identifier);
                if (!slot.holdsPlugin()) { std::printf("FAIL  %s: %s\n", choice.name.toRawUTF8(), app_.message.toRawUTF8()); ++failures; continue; }
                wait(1.0);
                juce::MemoryBlock state;
                slot.plugin->processor->getStateInformation(state);
                std::printf("PASS  %s: loaded, %d parameters, %d bytes of state, %d in / %d out\n", choice.name.toRawUTF8(),
                            slot.plugin->processor->getParameters().size(), (int)state.getSize(), slot.plugin->processor->getTotalNumInputChannels(),
                            slot.plugin->processor->getTotalNumOutputChannels());
                app_.setPlugin(slot, {});
            }
            if (tried == 0) std::printf("no plugin named like \"%s\"\n", wanted_.toRawUTF8());
        }
        std::fflush(stdout);
        done_(failures == 0 ? 0 : 1);
    }

    dsm::AppModel app_;
    juce::String wanted_;
    std::function<void(int)> done_;
};

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
        const int pluginCheck = arguments.indexOf("--check-plugins");
        if (pluginCheck >= 0)
        {
            pluginCheck_ = std::make_unique<PluginCheck>(pluginCheck + 1 < arguments.size() ? arguments[pluginCheck + 1] : juce::String(),
                                                         [this](int code) { finish(code); });
            return;
        }
        const int splitCheck = arguments.indexOf("--split");
        if (splitCheck >= 0)
        {
            const juce::File here = juce::File::getCurrentWorkingDirectory();
            if (splitCheck + 1 >= arguments.size()) { std::fprintf(stderr, "--split needs a song\n"); finish(1); return; }
            finish(runSplitCheck(here.getChildFile(arguments[splitCheck + 1]),
                                 splitCheck + 2 < arguments.size() ? here.getChildFile(arguments[splitCheck + 2])
                                                                   : juce::File::getSpecialLocation(juce::File::tempDirectory).getChildFile("dubstemmix-split"),
                                 splitCheck + 3 < arguments.size() ? here.getChildFile(arguments[splitCheck + 3]) : juce::File()));
            return;
        }
        const int fetchModels = arguments.indexOf("--fetch-models");
        if (fetchModels >= 0)
        {
            if (fetchModels + 1 >= arguments.size()) { std::fprintf(stderr, "--fetch-models needs a folder\n"); finish(1); return; }
            finish(runFetchModels(juce::File::getCurrentWorkingDirectory().getChildFile(arguments[fetchModels + 1])));
            return;
        }
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
        pluginCheck_.reset();
        window_.reset();
        app_.reset();
    }
    // Quitting with songs still to prepare asks first: they would be lost, the prepared ones stay (PRD § 12.6).
    void systemRequestedQuit() override
    {
        if (app_ == nullptr || window_ == nullptr || !app_->prepQueue.hasWork()) { quit(); return; }
        const int left = app_->prepQueue.count(dsm::split::Queue::Waiting) + app_->prepQueue.count(dsm::split::Queue::Running);
        juce::AlertWindow::showOkCancelBox(juce::MessageBoxIconType::QuestionIcon, "Songs are being prepared",
                                           "Quitting drops the " + juce::String(left) + (left == 1 ? " song" : " songs")
                                           + " not prepared yet. Songs already prepared stay on disk.", "Quit", "Keep Preparing", window_.get(),
                                           juce::ModalCallbackFunction::create([](int ok) { if (ok == 1) juce::JUCEApplication::quit(); }));
    }

private:
    void finish(int code)
    {
        setApplicationReturnValue(code);
        quit();
    }

    std::unique_ptr<dsm::AppModel> app_;
    std::unique_ptr<MainWindow> window_;
    std::unique_ptr<PluginCheck> pluginCheck_;
};

} // namespace

START_JUCE_APPLICATION(DubStemMixApplication)
