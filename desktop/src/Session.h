// Session.h - a song as the Mac app saves it: the `.dubstem` project (PRD § 5.8), and the `.dubset` setlist.
//
// Same files as the Mac app (Sources/DubStemMixCore/Project.swift): a project made on one opens on the other.
// What this app does not handle yet (Audio Unit slots and inserts, for instance) is kept as it was read and
// written back untouched.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Engine.h"
#include "Stems.h"

#include <vector>

namespace dsm {

// A file of a project, written both as an absolute path and relative to the document: the project survives
// its whole folder being moved.
struct FileRef
{
    juce::File file;                    // where it was found, or where it should be
    juce::String path, relativePath;    // as written in the document
    bool missing = false;

    static FileRef of(const juce::File& f)
    {
        FileRef r;
        r.file = f;
        r.path = f.getFullPathName();
        return r;
    }

    static FileRef read(const juce::var& v, const juce::File& document)
    {
        FileRef r;
        r.path = v["path"].toString();
        r.relativePath = v["relativePath"].toString();
        const juce::File absolute = juce::File::isAbsolutePath(r.path) ? juce::File(r.path) : juce::File();
        const juce::File relative = r.relativePath.isNotEmpty() ? document.getParentDirectory().getChildFile(r.relativePath) : juce::File();
        r.file = absolute.existsAsFile() ? absolute : relative.existsAsFile() ? relative : absolute;
        r.missing = !r.file.existsAsFile();
        return r;
    }

    juce::var write(const juce::File& document) const
    {
        auto* o = new juce::DynamicObject();
        // A file not found keeps what the document said: it may come back on another machine.
        o->setProperty("path", missing ? path : file.getFullPathName());
        o->setProperty("relativePath", missing ? relativePath
                                               : file.getRelativePathFrom(document.getParentDirectory()).replaceCharacter('\\', '/'));
        return juce::var(o);
    }
};

class Session
{
public:
    static constexpr const char* kExtension = "dubstem";

    juce::File document;                 // nowhere until the first save
    juce::String title;
    double bpm = 0.0;                    // 0: unknown
    bool loop = true;
    std::vector<FileRef> strips[kStems]; // the stems placed on each strip
    std::vector<FileRef> pool;           // "Stems to place"
    juce::String stripNames[kStems];     // names given by hand; empty: from the file names

    bool isEmpty() const
    {
        for (const auto& strip : strips) if (!strip.empty()) return false;
        return pool.empty();
    }

    // ---- Names ----

    juce::String displayTitle() const
    {
        if (title.isNotEmpty()) return title;
        if (document != juce::File()) return document.getFileNameWithoutExtension();
        // Not named yet: what the placed stems' file names have in common ("Artist - Title (Bass)" -> "Artist - Title").
        juce::StringArray names;
        for (const auto& strip : strips) for (const FileRef& f : strip) names.add(f.file.getFileNameWithoutExtension());
        if (names.isEmpty()) return "Untitled";
        juce::String common = names[0];
        for (const juce::String& name : names)
        {
            int same = 0;
            while (same < common.length() && same < name.length() && common[same] == name[same]) ++same;
            common = common.substring(0, same);
        }
        if (names.size() > 1) common = common.trimCharactersAtEnd(" -_([.");
        return common.isNotEmpty() ? common : juce::String("Untitled");
    }

    // The strip's name: the one given, else what differs between the stems' file names (PRD § 5.1).
    juce::String stripName(int s) const
    {
        if (stripNames[s].isNotEmpty()) return stripNames[s];
        if (strips[s].empty()) return {};
        std::vector<std::string> firsts;
        int mine = -1;
        for (int i = 0; i < kStems; ++i)
        {
            if (strips[i].empty()) continue;
            if (i == s) mine = (int)firsts.size();
            firsts.push_back(strips[i][0].file.getFullPathName().toStdString());
        }
        const std::vector<std::string> labels = stems::stripLabels(firsts);
        return mine >= 0 && mine < (int)labels.size() ? juce::String::fromUTF8(labels[(size_t)mine].c_str()) : juce::String();
    }

    SongFiles files() const
    {
        SongFiles song;
        for (int s = 0; s < kStems; ++s)
            for (const FileRef& f : strips[s])
                if (!f.missing) song.strips[s].push_back(f.file.getFullPathName().toStdString());
        return song;
    }

    int missingCount() const
    {
        int n = 0;
        for (const auto& strip : strips) for (const FileRef& f : strip) n += f.missing ? 1 : 0;
        return n;
    }

    // ---- Reading and writing ----

    static bool load(const juce::File& file, Session& out, juce::String& error)
    {
        const juce::var root = juce::JSON::parse(file.loadFileAsString());
        if (!root.isObject()) { error = "not a DubStemMix project"; return false; }
        out = Session();
        out.document = file;
        out.root_ = root;
        out.title = root["title"].toString();
        out.bpm = root["bpm"].isVoid() ? 0.0 : (double)root["bpm"];
        out.loop = root["loop"].isVoid() ? true : (bool)root["loop"];
        if (const juce::Array<juce::var>* stems = root["stems"].getArray())
            for (const juce::var& entry : *stems)
            {
                const int strip = (int)entry["strip"];
                const FileRef ref = FileRef::read(entry["file"], file);
                // Strips 7 and 8 no longer carry stems (PRD § 14): theirs go back to the stems to place.
                if (strip >= 0 && strip < kStems) out.strips[strip].push_back(ref); else out.pool.push_back(ref);
            }
        if (const juce::Array<juce::var>* pool = root["pool"].getArray())
            for (const juce::var& entry : *pool) out.pool.push_back(FileRef::read(entry, file));
        for (int s = 0; s < kStems; ++s) out.stripNames[s] = root["stripNames"][juce::Identifier(juce::String(s))].toString();
        return true;
    }

    // Writes the document. The engine's settings must have been collected first (collect()).
    bool save(const juce::File& file)
    {
        juce::DynamicObject* o = object();
        o->setProperty("version", 1);
        o->setProperty("title", title);
        if (bpm > 0) o->setProperty("bpm", bpm); else o->removeProperty("bpm");
        o->setProperty("loop", loop);
        juce::Array<juce::var> stemList, poolList;
        for (int s = 0; s < kStems; ++s)
            for (const FileRef& f : strips[s])
            {
                auto* entry = new juce::DynamicObject();
                entry->setProperty("file", f.write(file));
                entry->setProperty("strip", s);
                stemList.add(juce::var(entry));
            }
        for (const FileRef& f : pool) poolList.add(f.write(file));
        o->setProperty("stems", stemList);
        o->setProperty("pool", poolList);
        auto* names = new juce::DynamicObject();
        for (int s = 0; s < kStems; ++s)
            if (stripNames[s].isNotEmpty()) names->setProperty(juce::Identifier(juce::String(s)), stripNames[s]);
        o->setProperty("stripNames", juce::var(names));
        if (!file.replaceWithText(juce::JSON::toString(root_))) return false;
        document = file;
        return true;
    }

    // What the document would hold now: compared from time to time, to save on its own once it has a place.
    juce::String fingerprint() const
    {
        juce::String s = title + "|" + juce::String(bpm) + "|" + (loop ? "1" : "0") + "|" + juce::JSON::toString(root_["fx"], true)
                         + juce::JSON::toString(root_["busSends"], true) + juce::JSON::toString(root_["inserts"], true)
                         + juce::JSON::toString(root_["keep"], true) + root_["reverbModel"].toString() + root_["bus3Model"].toString()
                         + root_["throwTarget"].toString() + (root_["delaySync"] ? "s" : "-") + juce::JSON::toString(root_["desktop"], true);
        for (int i = 0; i < kStems; ++i)
        {
            s << "|" << stripNames[i];
            for (const FileRef& f : strips[i]) s << ";" << f.file.getFullPathName();
        }
        for (const FileRef& f : pool) s << "#" << f.file.getFullPathName();
        return s;
    }

    // ---- The engine's settings, kept per song (PRD § 5.8). Faders, sends and mutes are not: the console holds them. ----

    void apply(Engine& engine) const
    {
        const juce::var fxValues = root_["fx"];
        for (int p = 0; p < fx::Count; ++p)
        {
            const juce::var v = fxValues[juce::Identifier(fx::info(p).id)];
            engine.set(engine.effect[p], v.isVoid() ? fx::info(p).def : (float)(double)v);
        }
        engine.set(engine.delaySync, root_["delaySync"] ? 1.0f : 0.0f);
        engine.setChoice(engine.reverbModel, root_["reverbModel"].toString() == "spring" ? 1 : 0, 2);
        engine.setChoice(engine.bus3Model, root_["bus3Model"].toString() == "flanger" ? 1 : 0, 2);
        const juce::String target = root_["throwTarget"].toString();
        engine.setChoice(engine.throwTarget, target == "reverb" ? 1 : target == "both" ? 2 : 0, 3);

        // Bus-to-bus sends: where each bus's return also goes. A project from before them sends the delay to the reverb.
        const juce::var sends = root_["busSends"];
        for (int b = 0; b < fx::BusCount; ++b)
        {
            const juce::String to = sends.isVoid() ? juce::String(b == fx::Delay ? "reverb" : "none") : sends[juce::Identifier(busKey(b))].toString();
            int which = 0;
            for (int other = 0, k = 0; other < fx::BusCount; ++other)
                if (other != b && (++k, to == busKey(other))) which = k;
            engine.setChoice(engine.busTo[b], which, 3);
        }

        for (int s = 0; s < kStems; ++s) engine.set(engine.keep[s], 0.0f);
        if (const juce::Array<juce::var>* keep = root_["keep"].getArray())
            for (const juce::var& s : *keep)
                if ((int)s >= 0 && (int)s < kStems) engine.set(engine.keep[(int)s], 1.0f);

        for (int s = 0; s < kStems; ++s)
        {
            const juce::var insert = root_["inserts"][juce::Identifier(juce::String(s))];
            const juce::String kind = insert["kind"].toString();
            const int which = kind == "sub" ? fx::insert::Sub : kind == "autoWah" ? fx::insert::Wah : fx::insert::None;
            engine.setChoice(engine.insert[s], which, fx::insert::KindCount);
            const juce::Array<juce::var>* values = insert["values"].getArray();
            for (int i = 0; i < fx::insert::knobCount(which); ++i)
                engine.set(engine.insertValue[s][i], values != nullptr && i < values->size() ? (float)(double)(*values)[i]
                                                                                              : fx::insert::knob(which, i).def);
        }
        transport().bpm.store(bpm);
        transport().loop.store(loop);
    }

    // What the app keeps in the document under a key of its own (its plugins, which the Mac app does not read).
    juce::var extra(const char* key) const { return root_[juce::Identifier(key)]; }
    void setExtra(const char* key, const juce::var& value) { object()->setProperty(juce::Identifier(key), value); }

    // `pluginStrips`: a bit per strip whose insert is a plugin of this app; its entry here is left alone.
    void collect(const Engine& engine, unsigned pluginStrips = 0)
    {
        juce::DynamicObject* o = object();
        auto* fxValues = new juce::DynamicObject();
        for (int p = 0; p < fx::Count; ++p) fxValues->setProperty(juce::Identifier(fx::info(p).id), (double)engine.value(engine.effect[p]));
        o->setProperty("fx", juce::var(fxValues));
        o->setProperty("delaySync", engine.on(engine.delaySync));
        o->setProperty("reverbModel", engine.choice(engine.reverbModel, 2) == 1 ? "spring" : "plate");
        o->setProperty("bus3Model", engine.choice(engine.bus3Model, 2) == 1 ? "flanger" : "phaser");
        const char* targets[3] = {"delay", "reverb", "both"};
        o->setProperty("throwTarget", targets[engine.choice(engine.throwTarget, 3)]);

        auto* sends = new juce::DynamicObject();
        for (int b = 0; b < fx::BusCount; ++b)
        {
            const int which = engine.choice(engine.busTo[b], 3);
            juce::String to = "none";
            for (int other = 0, k = 0; other < fx::BusCount; ++other)
                if (other != b && ++k == which) to = busKey(other);
            sends->setProperty(juce::Identifier(busKey(b)), to);
        }
        o->setProperty("busSends", juce::var(sends));

        juce::Array<juce::var> keep;
        for (int s = 0; s < kStems; ++s) if (engine.on(engine.keep[s])) keep.add(s);
        o->setProperty("keep", keep);

        // Built-in inserts are rewritten; an Audio Unit insert from the Mac stays as it was read.
        juce::DynamicObject::Ptr inserts = root_["inserts"].getDynamicObject() != nullptr ? root_["inserts"].getDynamicObject()
                                                                                          : new juce::DynamicObject();
        for (int s = 0; s < kStems; ++s)
        {
            const juce::Identifier key{juce::String(s)};
            if (pluginStrips & (1u << s)) continue;
            const int which = engine.choice(engine.insert[s], fx::insert::KindCount);
            const bool plugin = !inserts->getProperty(key)["plugin"].isVoid();
            if (which == fx::insert::None) { if (!plugin) inserts->removeProperty(key); continue; }
            auto* entry = new juce::DynamicObject();
            entry->setProperty("kind", which == fx::insert::Sub ? "sub" : "autoWah");
            juce::Array<juce::var> values;
            for (int i = 0; i < fx::insert::knobCount(which); ++i) values.add((double)engine.value(engine.insertValue[s][i]));
            entry->setProperty("values", values);
            inserts->setProperty(key, juce::var(entry));
        }
        o->setProperty("inserts", juce::var(inserts.get()));
        bpm = transport().bpm.load();
        loop = transport().loop.load();
        if (engine.duration() > 0) o->setProperty("duration", engine.duration());
    }

    // A new session starts like the app does (PRD § 5.8): factory effect settings, buses on their own.
    static Session fresh()
    {
        Session s;
        auto* sends = new juce::DynamicObject();
        for (int b = 0; b < fx::BusCount; ++b) sends->setProperty(juce::Identifier(busKey(b)), "none");
        s.object()->setProperty("busSends", juce::var(sends));
        return s;
    }

    // A song prepared from its separated stems (PRD § 12.6), as "Split a song" would leave the session: the stems
    // in order on the first strips with their names, the original in the stems to place, effects and bus routing
    // as at launch. Built without the engine: it is written from a background thread.
    static Session separated(const juce::String& title, const std::vector<std::pair<juce::File, juce::String>>& stems,
                             const juce::File& original, double seconds, double bpm)
    {
        Session s = fresh();
        s.title = title;
        s.bpm = bpm;
        for (size_t i = 0; i < stems.size() && i < (size_t)kStems; ++i)
        {
            s.strips[i].push_back(FileRef::of(stems[i].first));
            s.stripNames[i] = stems[i].second;
        }
        s.pool.push_back(FileRef::of(original));
        auto* fxValues = new juce::DynamicObject();
        for (int p = 0; p < fx::Count; ++p) fxValues->setProperty(juce::Identifier(fx::info(p).id), (double)fx::info(p).def);
        s.object()->setProperty("fx", juce::var(fxValues));
        if (seconds > 0) s.object()->setProperty("duration", seconds);
        return s;
    }

private:
    static const char* busKey(int bus) { return bus == fx::Delay ? "delay" : bus == fx::Reverb ? "reverb" : "bus3"; }

    juce::DynamicObject* object()
    {
        if (root_.getDynamicObject() == nullptr) root_ = juce::var(new juce::DynamicObject());
        return root_.getDynamicObject();
    }

    juce::var root_;   // the document as read: what this app does not know stays in it
};

// What a project says about itself, read without opening it: for the library and the setlist's lines.
struct SongInfo
{
    juce::File file;
    juce::String title;
    double bpm = 0.0, seconds = 0.0;

    static SongInfo read(const juce::File& file)
    {
        SongInfo info;
        info.file = file;
        info.title = file.getFileNameWithoutExtension();
        const juce::var project = juce::JSON::parse(file.loadFileAsString());
        if (project["title"].toString().isNotEmpty()) info.title = project["title"].toString();
        info.bpm = project["bpm"].isVoid() ? 0.0 : (double)project["bpm"];
        info.seconds = project["duration"].isVoid() ? 0.0 : (double)project["duration"];
        return info;
    }

    // The stems placed on the project's strips: what a preview plays.
    static std::vector<std::string> stems(const juce::File& file)
    {
        std::vector<std::string> files;
        const juce::var project = juce::JSON::parse(file.loadFileAsString());
        if (const juce::Array<juce::var>* list = project["stems"].getArray())
            for (const juce::var& entry : *list)
            {
                const FileRef ref = FileRef::read(entry["file"], file);
                if (!ref.missing && (int)entry["strip"] >= 0 && (int)entry["strip"] < kStems) files.push_back(ref.file.getFullPathName().toStdString());
            }
        return files;
    }
};

// A setlist (.dubset): an ordered list of projects, with a colour and a tag per line (PRD § 13). The colour
// and the tag belong to the line, not to the song: the same song can open one set and close another.
struct Setlist
{
    static constexpr int kColours = 8;

    struct Song
    {
        FileRef project;
        juce::String title;
        double bpm = 0.0, seconds = 0.0;
        int colour = -1;
        juce::String tag;
        bool played = false;   // heard at least 30 s since the app started; never written
    };

    juce::File document;
    juce::String name;
    std::vector<Song> songs;

    static Song line(const juce::File& project)
    {
        Song song;
        song.project = FileRef::of(project);
        song.project.missing = !project.existsAsFile();
        if (!song.project.missing)
        {
            const SongInfo info = SongInfo::read(project);
            song.title = info.title; song.bpm = info.bpm; song.seconds = info.seconds;
        }
        else song.title = project.getFileNameWithoutExtension();
        return song;
    }

    static bool load(const juce::File& file, Setlist& out, juce::String& error)
    {
        const juce::var root = juce::JSON::parse(file.loadFileAsString());
        if (!root.isObject()) { error = "not a DubStemMix setlist"; return false; }
        out = Setlist();
        out.document = file;
        out.root_ = root;
        out.name = root["name"].toString();
        if (out.name.isEmpty()) out.name = file.getFileNameWithoutExtension();
        if (const juce::Array<juce::var>* projects = root["projects"].getArray())
            for (const juce::var& entry : *projects)
            {
                const FileRef ref = FileRef::read(entry, file);
                Song song = line(ref.file);
                song.project = ref;
                song.colour = entry["color"].isVoid() ? -1 : (int)entry["color"];
                song.tag = entry["tag"].toString();
                out.songs.push_back(std::move(song));
            }
        return true;
    }

    // Written at every change (PRD § 13). What this app does not know in the document stays in it.
    bool save()
    {
        if (document == juce::File()) return false;
        if (root_.getDynamicObject() == nullptr) root_ = juce::var(new juce::DynamicObject());
        juce::DynamicObject* o = root_.getDynamicObject();
        o->setProperty("version", 1);
        o->setProperty("name", name);
        juce::Array<juce::var> projects;
        for (const Song& song : songs)
        {
            juce::var entry = song.project.write(document);
            if (song.colour >= 0) entry.getDynamicObject()->setProperty("color", song.colour);
            if (song.tag.isNotEmpty()) entry.getDynamicObject()->setProperty("tag", song.tag);
            projects.add(entry);
        }
        o->setProperty("projects", projects);
        document.getParentDirectory().createDirectory();
        return document.replaceWithText(juce::JSON::toString(root_));
    }

    int indexOf(const juce::File& project) const
    {
        for (int i = 0; i < (int)songs.size(); ++i) if (songs[(size_t)i].project.file == project) return i;
        return -1;
    }

    // No song twice in a setlist: returns where it already is, or -1 when it was added at `at`.
    int insert(const juce::File& project, int at)
    {
        const int already = indexOf(project);
        if (already >= 0) return already;
        songs.insert(songs.begin() + juce::jlimit(0, (int)songs.size(), at), line(project));
        return -1;
    }

    void move(int from, int to)
    {
        if (from < 0 || from >= (int)songs.size()) return;
        to = juce::jlimit(0, (int)songs.size() - 1, to);
        if (to == from) return;
        Song song = std::move(songs[(size_t)from]);
        songs.erase(songs.begin() + from);
        songs.insert(songs.begin() + to, std::move(song));
    }

    void remove(int index)
    {
        if (index >= 0 && index < (int)songs.size()) songs.erase(songs.begin() + index);
    }

    double totalSeconds() const
    {
        double total = 0.0;
        for (const Song& song : songs) total += song.seconds;
        return total;
    }

    // Tags already used in this setlist, offered when typing a new one.
    juce::StringArray tags() const
    {
        juce::StringArray all;
        for (const Song& song : songs) if (song.tag.isNotEmpty()) all.addIfNotAlreadyThere(song.tag);
        return all;
    }

private:
    juce::var root_;
};

} // namespace dsm
