// AppModel.h - what the app does with songs, behind the screen: the open session and its stems, saving,
// the setlist, the tempo. No drawing here.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Session.h"
#include "Tempo.h"

#include <juce_data_structures/juce_data_structures.h>

namespace dsm {

// What belongs to this computer, not to a song (PRD § 5.4, § 5.8, § 5.12): the limiter switch, pre / post sends
// per bus, the recent files. Kept in the user's settings folder.
class Settings
{
public:
    // `forTest`: a settings file of its own, thrown away at the end.
    explicit Settings(bool forTest) : forTest_(forTest)
    {
        juce::PropertiesFile::Options options;
        options.applicationName = forTest ? "DubStemMix-selftest" : "DubStemMix";
        options.filenameSuffix = ".settings";
        options.folderName = "DubStemMix";
        options.osxLibrarySubFolder = "Application Support";
        file_ = std::make_unique<juce::PropertiesFile>(options);
        transport().limiterOn.store(file_->getBoolValue("limiterOn", true));
        for (int b = 0; b < 3; ++b) transport().preFader[b].store(file_->getBoolValue("preFader" + juce::String(b), false));
    }

    void setLimiterOn(bool on) { transport().limiterOn.store(on); file_->setValue("limiterOn", on); }
    void setPreFader(int bus, bool pre) { transport().preFader[bus].store(pre); file_->setValue("preFader" + juce::String(bus), pre); }

    // The 10 last projects and setlists opened, newest first; files that are gone are not shown.
    juce::Array<juce::File> recent() const
    {
        juce::Array<juce::File> files;
        for (const juce::String& path : juce::StringArray::fromLines(file_->getValue("recent")))
            if (juce::File::isAbsolutePath(path) && juce::File(path).existsAsFile()) files.add(juce::File(path));
        return files;
    }
    void noteRecent(const juce::File& file)
    {
        juce::StringArray paths = juce::StringArray::fromLines(file_->getValue("recent"));
        paths.removeString(file.getFullPathName());
        paths.insert(0, file.getFullPathName());
        while (paths.size() > 10) paths.remove(paths.size() - 1);
        file_->setValue("recent", paths.joinIntoString("\n"));
    }
    void clearRecent() { file_->setValue("recent", ""); }

    // Where sessions are recorded: the DubStemMix folder unless another was chosen (PRD § 5.12).
    juce::File recordingFolder(const juce::File& fallback) const
    {
        const juce::String chosen = file_->getValue("recordingFolder");
        return juce::File::isAbsolutePath(chosen) ? juce::File(chosen) : fallback;
    }
    void setRecordingFolder(const juce::File& folder) { file_->setValue("recordingFolder", folder.getFullPathName()); }

    // Projects dropped into the library from elsewhere: remembered from one launch to the next (PRD § 13).
    juce::Array<juce::File> libraryExtras() const
    {
        juce::Array<juce::File> files;
        for (const juce::String& path : juce::StringArray::fromLines(file_->getValue("library")))
            if (juce::File::isAbsolutePath(path) && juce::File(path).existsAsFile()) files.add(juce::File(path));
        return files;
    }
    void addLibraryExtra(const juce::File& file)
    {
        juce::StringArray paths = juce::StringArray::fromLines(file_->getValue("library"));
        paths.addIfNotAlreadyThere(file.getFullPathName());
        file_->setValue("library", paths.joinIntoString("\n"));
    }

    ~Settings()
    {
        const juce::File file = file_->getFile();
        file_.reset();
        if (forTest_) file.deleteFile();
    }

private:
    bool forTest_;
    std::unique_ptr<juce::PropertiesFile> file_;
};

class AppModel
{
public:
    Settings settings;
    Session session = Session::fresh();

    explicit AppModel(bool forTest = false) : settings(forTest)
    {
        home = juce::File::getSpecialLocation(juce::File::userMusicDirectory).getChildFile("DubStemMix");
    }

    // ---- The DubStemMix folder: the library and the setlists (PRD § 13) ----

    juce::File home;                       // ~/Music/DubStemMix
    std::vector<SongInfo> library;         // every project found, by title
    std::vector<juce::File> setlistFiles;  // every setlist of the Setlists folder, by name
    Setlist editing;                       // the setlist open in the workshop
    juce::String editingSaved;             // "SAVED · 18:42"

    juce::File setlistsFolder() const { return home.getChildFile("Setlists"); }

    void scanLibrary()
    {
        library.clear();
        juce::Array<juce::File> files = home.findChildFiles(juce::File::findFiles, true, "*.dubstem");
        for (const juce::File& extra : settings.libraryExtras()) files.addIfNotAlreadyThere(extra);
        for (const juce::File& f : files) library.push_back(SongInfo::read(f));
        std::sort(library.begin(), library.end(), [](const SongInfo& a, const SongInfo& b) { return a.title.compareIgnoreCase(b.title) < 0; });
        setlistFiles.clear();
        juce::Array<juce::File> sets = setlistsFolder().findChildFiles(juce::File::findFiles, false, "*.dubset");
        sets.sort();
        for (const juce::File& f : sets) setlistFiles.push_back(f);
    }

    void addToLibrary(const juce::File& project)
    {
        if (!project.hasFileExtension("dubstem")) return;
        settings.addLibraryExtra(project);
        scanLibrary();
    }

    // ---- The workshop's setlist: every change is written at once ----

    bool edit(const juce::File& file)
    {
        juce::String error;
        Setlist loaded;
        if (!Setlist::load(file, loaded, error)) { message = file.getFileName() + ": " + error; return false; }
        editing = std::move(loaded);
        editingSaved = {};
        return true;
    }

    void saveEditing()
    {
        if (editing.document == juce::File()) return;
        if (editing.save()) editingSaved = juce::String::fromUTF8("SAVED · ") + juce::Time::getCurrentTime().formatted("%H:%M");
        // The console plays the same file: it follows.
        if (editing.document == setlist.document) reloadConsoleSetlist();
    }

    juce::File freeSetlistFile(const juce::String& wanted) const
    {
        const juce::String base = juce::File::createLegalFileName(wanted.trim().isEmpty() ? juce::String("Setlist") : wanted.trim());
        juce::File file = setlistsFolder().getChildFile(base + ".dubset");
        for (int n = 2; file.existsAsFile(); ++n) file = setlistsFolder().getChildFile(base + " " + juce::String(n) + ".dubset");
        return file;
    }

    void newSetlist(const juce::String& name)
    {
        editing = Setlist();
        editing.document = freeSetlistFile(name);
        editing.name = editing.document.getFileNameWithoutExtension();
        saveEditing();
        scanLibrary();
    }

    void duplicateSetlist()
    {
        if (editing.document == juce::File()) return;
        editing.document = freeSetlistFile(editing.name + " copy");
        editing.name = editing.document.getFileNameWithoutExtension();
        saveEditing();
        scanLibrary();
    }

    void renameSetlist(const juce::String& name)
    {
        if (editing.document == juce::File() || name.trim().isEmpty()) return;
        const juce::File old = editing.document, target = freeSetlistFile(name);
        const bool wasConsole = old == setlist.document;
        editing.document = target;
        editing.name = target.getFileNameWithoutExtension();
        if (editing.save()) old.deleteFile();
        if (wasConsole) setlist.document = target;
        saveEditing();
        scanLibrary();
    }

    void deleteSetlist()
    {
        if (editing.document == juce::File()) return;
        editing.document.deleteFile();
        editing = Setlist();
        editingSaved = {};
        scanLibrary();
    }

    // "LOAD IN THE CONSOLE": the setlist being built becomes the console's. No song is opened.
    void loadInConsole()
    {
        if (editing.document == juce::File()) return;
        saveEditing();
        openSetlist(editing.document);
        settings.noteRecent(editing.document);
    }

    // ---- The console's setlist, live (PRD § 13): reorder, and add a song after the one playing ----

    void moveSong(int index, int by)
    {
        const int to = index + by;
        if (index < 0 || index >= (int)setlist.songs.size() || to < 0 || to >= (int)setlist.songs.size()) return;
        const juce::File current = setlistIndex >= 0 ? setlist.songs[(size_t)setlistIndex].project.file : juce::File();
        setlist.move(index, to);
        setlistIndex = current != juce::File() ? setlist.indexOf(current) : -1;
        setlist.save();
    }

    // Returns false when the song is already in the setlist (no song twice).
    bool addAfterCurrent(const juce::File& project)
    {
        if (setlist.document == juce::File()) return false;
        if (setlist.insert(project, setlistIndex + 1) >= 0) return false;
        setlist.save();
        return true;
    }
    Setlist setlist;
    int setlistIndex = -1;       // the setlist's song now open, or -1
    juce::String message;        // the last thing worth telling (an error, a missing stem)

    static bool isAudio(const juce::File& f)
    {
        return f.hasFileExtension("wav;aif;aiff;flac;mp3;ogg;m4a");
    }

    // ---- Recording (PRD § 5.9): the master, one folder per session, a sheet with the songs played ----

    juce::File lastRecording;                   // the folder of the session just recorded
    std::atomic<double> exportProgress{-1.0};   // 0..1 while an MP3 is being made, else -1
    juce::File exporting;                       // the session being exported

    juce::File recordingsFolder() const { return settings.recordingFolder(home); }
    bool isRecording() const { return Recorder::get().isRecording(); }
    double recordingSeconds() const { return Recorder::get().seconds(); }

    void toggleRecording(const juce::String& soundCard)
    {
        if (isRecording()) { finishRecording(); return; }
        const juce::Time start = juce::Time::getCurrentTime();
        const juce::File folder = RecordingSession::makeFolder(recordingsFolder(), start);
        if (folder == juce::File() || !Recorder::get().start(folder.getChildFile(RecordingSession::kAudio), kRate))
        {
            message = "cannot start recording in " + recordingsFolder().getFullPathName();
            return;
        }
        recording_ = RecordingSession();
        recording_.started = start;
        recording_.setlist = setlist.songs.empty() ? juce::String() : setlist.name;
        recording_.device = soundCard;
        recording_.sampleRate = kRate;
        recording_.limiterOn = transport().limiterOn.load();
        // The song already playing opens the tracklist at 00:00.
        if (Engine::get().isPlaying() && !session.isEmpty())
        {
            recording_.tracks.push_back({0.0, session.displayTitle()});
            loggedLoad_ = songLoads_;
        }
        else loggedLoad_ = -1;
        limiterNoted_ = false;
        recordingFolder_ = folder;
        recording_.save(folder);
        message = {};
    }

    void finishRecording()
    {
        if (!isRecording()) return;
        const double seconds = recordingSeconds();
        Recorder::get().stop();
        recording_.ended = juce::Time::getCurrentTime();
        recording_.finished = true;
        recording_.duration = seconds;
        recording_.save(recordingFolder_);
        lastRecording = recordingFolder_;
    }

    // Called many times a second: a song loaded since the last entry enters the tracklist when it starts
    // playing; the limiter switched during the session is noted.
    void followRecording()
    {
        if (!isRecording()) return;
        bool changed = false;
        if (Engine::get().isPlaying() && loggedLoad_ != songLoads_ && !session.isEmpty())
        {
            loggedLoad_ = songLoads_;
            recording_.tracks.push_back({recordingSeconds(), session.displayTitle()});
            changed = true;
        }
        if (!limiterNoted_ && transport().limiterOn.load() != recording_.limiterOn)
        {
            recording_.limiterToggled = true;
            limiterNoted_ = true;
            changed = true;
        }
        if (changed) { recording_.duration = recordingSeconds(); recording_.save(recordingFolder_); }
    }

    // MP3 of a recorded session, in the background; its file is written beside the WAV.
    void exportMp3(const SessionEntry& entry)
    {
        if (exportProgress.load() >= 0.0) return;
        exporting = entry.folder;
        exportProgress.store(0.0);
        const juce::File wav = entry.audio(), target = entry.mp3();
        const juce::String title = "DubStemMix " + entry.folder.getFileName();
        pool_.addJob([this, wav, target, title]
        {
            const mp3::Result result = mp3::exportSession(wav, target, title, [this](double p) { exportProgress.store(p); },
                                                          [this] { return cancelExport_.load(); });
            exportResult_ = result.ok ? juce::String("MP3 written: ") + juce::String(result.gain, 1) + " dB applied (" + juce::String(result.loudness, 1) + " LUFS before)"
                                      : "MP3 export: " + result.error;
            exportDone_.store(true);
            exportProgress.store(-1.0);
        });
    }

    // ---- Sessions ----

    void newSession()
    {
        Engine& engine = Engine::get();
        session = Session::fresh();
        ++songLoads_;
        ++tempoJob_;
        detecting_.store(false);
        setlistIndex = -1;
        for (int s = 0; s < kStems; ++s) { engine.set(engine.mute[s], 0.0f); engine.set(engine.solo[s], 0.0f); }
        session.apply(engine);
        reload(false);
        saved_ = session.fingerprint();
        message = {};
    }

    // Opens a project or a setlist chosen by the user: it joins the recent files.
    bool open(const juce::File& file)
    {
        const bool ok = load(file);
        if (ok) settings.noteRecent(file);
        return ok;
    }

    bool load(const juce::File& file)
    {
        if (file.hasFileExtension("dubset")) return openSetlist(file);
        juce::String error;
        Session loaded;
        if (!Session::load(file, loaded, error)) { message = file.getFileName() + ": " + error; return false; }
        session = std::move(loaded);
        ++songLoads_;
        ++tempoJob_;
        detecting_.store(false);
        Engine& engine = Engine::get();
        session.apply(engine);
        reload(false);
        session.collect(engine);
        saved_ = session.fingerprint();
        const int missing = session.missingCount();
        message = missing > 0 ? juce::String(missing) + (missing == 1 ? " stem not found" : " stems not found") : juce::String();
        return true;
    }

    bool hasDocument() const { return session.document != juce::File(); }

    bool save() { return hasDocument() && saveAs(session.document); }

    bool saveAs(const juce::File& file)
    {
        session.collect(Engine::get());
        if (session.title.isEmpty()) session.title = file.getFileNameWithoutExtension();
        const bool isNewPlace = file != session.document;
        if (!session.save(file)) { message = "cannot write " + file.getFileName(); return false; }
        saved_ = session.fingerprint();
        if (isNewPlace) settings.noteRecent(file);
        return true;
    }

    // Once the session has a place, changes are saved on their own (PRD § 5.8). Called about once a second.
    void autosave()
    {
        if (!hasDocument()) return;
        session.collect(Engine::get());
        if (session.fingerprint() != saved_) save();
    }

    bool isSaved()
    {
        if (!hasDocument()) return false;
        session.collect(Engine::get());
        return session.fingerprint() == saved_;
    }

    // ---- Stems: the user places them, the app assigns nothing on its own (PRD § 5.1) ----

    // Files (or folders) dropped or picked: on a strip when `strip` >= 0, else in the stems to place.
    void addFiles(const juce::Array<juce::File>& given, int strip)
    {
        juce::Array<juce::File> files;
        for (const juce::File& f : given)
        {
            if (f.isDirectory())
            {
                juce::Array<juce::File> inside = f.findChildFiles(juce::File::findFiles, false);
                inside.sort();
                for (const juce::File& child : inside) if (isAudio(child)) files.add(child);
            }
            else if (isAudio(f)) files.add(f);
        }
        if (files.isEmpty()) return;
        for (const juce::File& f : files)
        {
            if (holds(f)) continue;
            if (strip >= 0 && strip < kStems) session.strips[strip].push_back(FileRef::of(f));
            else session.pool.push_back(FileRef::of(f));
        }
        if (strip >= 0) { reload(true); detectTempo(false); }
    }

    // Moves a stem: from the stems to place (fromStrip < 0) or a strip, to a strip or back (toStrip < 0).
    void move(int fromStrip, int index, int toStrip)
    {
        std::vector<FileRef>& from = fromStrip < 0 ? session.pool : session.strips[fromStrip];
        if (index < 0 || index >= (int)from.size() || fromStrip == toStrip) return;
        const FileRef ref = from[(size_t)index];
        from.erase(from.begin() + index);
        (toStrip < 0 ? session.pool : session.strips[toStrip]).push_back(ref);
        reload(true);
        if (toStrip >= 0) detectTempo(false);
    }

    // ---- Names ----

    void rename(const juce::String& title) { if (title.trim().isNotEmpty()) session.title = title.trim(); }
    void renameStrip(int strip, const juce::String& name) { session.stripNames[strip] = name.trim().toUpperCase(); }

    // ---- Missing stems: looked for by file name in a folder the user picks (PRD § 5.8) ----

    int locate(const juce::File& folder)
    {
        juce::Array<juce::File> found = folder.findChildFiles(juce::File::findFiles, true);
        int back = 0;
        auto fix = [&found, &back](FileRef& ref)
        {
            if (!ref.missing) return;
            const juce::String wantedName = juce::File::createLegalFileName(ref.path.replaceCharacter('\\', '/').fromLastOccurrenceOf("/", false, false));
            const juce::String wantedFolder = ref.path.replaceCharacter('\\', '/').upToLastOccurrenceOf("/", false, false).fromLastOccurrenceOf("/", false, false);
            juce::Array<juce::File> matches;
            for (const juce::File& f : found) if (f.getFileName() == wantedName) matches.add(f);
            // Several files with that name: the one in a folder of the same name, if there is just one.
            if (matches.size() > 1)
            {
                juce::Array<juce::File> sameFolder;
                for (const juce::File& f : matches) if (f.getParentDirectory().getFileName() == wantedFolder) sameFolder.add(f);
                matches = sameFolder;
            }
            if (matches.size() != 1) return;
            ref = FileRef::of(matches[0]);
            ++back;
        };
        for (auto& strip : session.strips) for (FileRef& ref : strip) fix(ref);
        for (FileRef& ref : session.pool) fix(ref);
        if (back > 0) reload(false);
        const int missing = session.missingCount();
        message = missing > 0 ? juce::String(missing) + (missing == 1 ? " stem not found" : " stems not found") : juce::String();
        return back;
    }

    void remove(int fromStrip, int index)
    {
        std::vector<FileRef>& from = fromStrip < 0 ? session.pool : session.strips[fromStrip];
        if (index < 0 || index >= (int)from.size()) return;
        from.erase(from.begin() + index);
        if (fromStrip >= 0) reload(true);
    }

    // ---- Tempo (PRD § 5.7) ----

    void setBpm(double bpm)
    {
        session.bpm = bpm <= 0 ? 0.0 : juce::jlimit(30.0, 300.0, bpm);
        transport().bpm.store(session.bpm);
    }

    // The tempo is worked out when stems are placed, never when one is already known; `force` is the AUTO button.
    void detectTempo(bool force)
    {
        if (!force && session.bpm > 0) return;
        const std::vector<std::string> files = placedFiles();
        if (files.empty()) return;
        const int job = ++tempoJob_;
        detecting_.store(true);
        pool_.addJob([this, files, job]
        {
            const double bpm = tempo::detect(files);
            if (job == tempoJob_.load()) { detected_.store(bpm); detecting_.store(false); }
        });
    }
    bool isDetectingTempo() const { return detecting_.load(); }

    void tap()
    {
        const double now = juce::Time::getMillisecondCounterHiRes() * 0.001;
        if (now - lastTap_ > 2.5) taps_ = 0;
        if (taps_ > 0) tapSum_ += now - lastTap_; else tapSum_ = 0.0;
        lastTap_ = now;
        if (++taps_ >= 3) setBpm(60.0 / (tapSum_ / (double)(taps_ - 1)));
    }

    void toggleLoop()
    {
        session.loop = !session.loop;
        transport().loop.store(session.loop);
    }

    // ---- Setlist: played from the sidebar (PRD § 5.8) ----

    bool openSetlist(const juce::File& file)
    {
        juce::String error;
        Setlist loaded;
        if (!Setlist::load(file, loaded, error)) { message = file.getFileName() + ": " + error; return false; }
        setlist = std::move(loaded);
        setlistIndex = -1;
        message = {};
        return true;
    }

    // After the workshop changed the file the console plays: same songs marked as played, same song open.
    void reloadConsoleSetlist()
    {
        const juce::File current = setlistIndex >= 0 && setlistIndex < (int)setlist.songs.size() ? setlist.songs[(size_t)setlistIndex].project.file : juce::File();
        juce::Array<juce::File> played;
        for (const Setlist::Song& song : setlist.songs) if (song.played) played.add(song.project.file);
        juce::String error;
        Setlist loaded;
        if (!Setlist::load(setlist.document, loaded, error)) return;
        setlist = std::move(loaded);
        for (Setlist::Song& song : setlist.songs) song.played = played.contains(song.project.file);
        setlistIndex = current != juce::File() ? setlist.indexOf(current) : -1;
    }

    // A song of the setlist is loaded stopped, at its start; the previous one's effect tails ring on.
    bool openSong(int index)
    {
        if (index < 0 || index >= (int)setlist.songs.size() || setlist.songs[(size_t)index].project.missing) return false;
        autosave();
        if (!load(setlist.songs[(size_t)index].project.file)) return false;
        setlistIndex = index;
        return true;
    }

    void step(int by)
    {
        if (setlist.songs.empty()) return;
        openSong(juce::jlimit(0, (int)setlist.songs.size() - 1, (setlistIndex < 0 ? (by > 0 ? -1 : 0) : setlistIndex) + by));
    }

    // Called about once a second: a song heard for 30 s is marked as played, until the app closes (PRD § 13).
    void tick()
    {
        Engine& engine = Engine::get();
        if (setlistIndex >= 0 && engine.isPlaying() && ++heard_ >= 30) setlist.songs[(size_t)setlistIndex].played = true;
        // A song whose stems changed while it played comes back where it was.
        const int gen = transport().songGen.load();
        if (gen != seenSongGen_)
        {
            seenSongGen_ = gen;
            if (resumeAt_ >= 0)
            {
                transport().seekTo.store(resumeAt_);
                if (resumePlaying_) transport().playing.store(true);
                resumeAt_ = -1;
            }
        }
        const double found = detected_.exchange(-1.0);
        if (found > 0) setBpm(found);
        if (exportDone_.exchange(false)) message = exportResult_;
        autosave();
    }

    ~AppModel()
    {
        cancelExport_.store(true);
        finishRecording();
        pool_.removeAllJobs(true, 8000);
    }

    // What the waveform is drawn from: every stem placed on a strip.
    std::vector<std::string> placedFiles() const
    {
        std::vector<std::string> files;
        const SongFiles song = session.files();
        for (const auto& strip : song.strips) files.insert(files.end(), strip.begin(), strip.end());
        return files;
    }

private:
    bool holds(const juce::File& f) const
    {
        for (const auto& strip : session.strips) for (const FileRef& r : strip) if (r.file == f) return true;
        for (const FileRef& r : session.pool) if (r.file == f) return true;
        return false;
    }

    // Gives the session's stems to the engine. `keepPlace`: the song goes on from where it was.
    void reload(bool keepPlace)
    {
        Transport& t = transport();
        if (keepPlace && t.length.load() > 0)
        {
            resumeAt_ = t.position.load();
            resumePlaying_ = t.playing.load();
        }
        else { resumeAt_ = -1; heard_ = 0; }
        t.load(session.files());
    }

    RecordingSession recording_;
    juce::File recordingFolder_;
    int songLoads_ = 0, loggedLoad_ = -1;
    bool limiterNoted_ = false;
    std::atomic<bool> cancelExport_{false}, exportDone_{false};
    juce::String exportResult_;
    juce::ThreadPool pool_{1};
    std::atomic<int> tempoJob_{0};
    std::atomic<double> detected_{-1.0};
    std::atomic<bool> detecting_{false};
    juce::String saved_;
    double lastTap_ = 0.0, tapSum_ = 0.0;
    int taps_ = 0, heard_ = 0, seenSongGen_ = 0;
    long long resumeAt_ = -1;
    bool resumePlaying_ = false;
};

} // namespace dsm
