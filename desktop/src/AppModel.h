// AppModel.h - what the app does with songs, behind the screen: the open session and its stems, saving,
// the setlist, the tempo. No drawing here.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Session.h"

namespace dsm {

class AppModel
{
public:
    Session session = Session::fresh();
    Setlist setlist;
    int setlistIndex = -1;       // the setlist's song now open, or -1
    juce::String message;        // the last thing worth telling (an error, a missing stem)

    static bool isAudio(const juce::File& f)
    {
        return f.hasFileExtension("wav;aif;aiff;flac;mp3;ogg;m4a");
    }

    // ---- Sessions ----

    void newSession()
    {
        Engine& engine = Engine::get();
        session = Session::fresh();
        setlistIndex = -1;
        for (int s = 0; s < kStems; ++s) { engine.set(engine.mute[s], 0.0f); engine.set(engine.solo[s], 0.0f); }
        session.apply(engine);
        reload(false);
        saved_ = session.fingerprint();
        message = {};
    }

    bool open(const juce::File& file)
    {
        if (file.hasFileExtension("dubset")) return openSetlist(file);
        juce::String error;
        Session loaded;
        if (!Session::load(file, loaded, error)) { message = file.getFileName() + ": " + error; return false; }
        session = std::move(loaded);
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
        if (!session.save(file)) { message = "cannot write " + file.getFileName(); return false; }
        saved_ = session.fingerprint();
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
        if (strip >= 0) reload(true);
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

    // A song of the setlist is loaded stopped, at its start; the previous one's effect tails ring on.
    bool openSong(int index)
    {
        if (index < 0 || index >= (int)setlist.songs.size() || setlist.songs[(size_t)index].project.missing) return false;
        autosave();
        if (!open(setlist.songs[(size_t)index].project.file)) return false;
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
        autosave();
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

    juce::String saved_;
    double lastTap_ = 0.0, tapSum_ = 0.0;
    int taps_ = 0, heard_ = 0, seenSongGen_ = 0;
    long long resumeAt_ = -1;
    bool resumePlaying_ = false;
};

} // namespace dsm
