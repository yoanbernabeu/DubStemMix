// Workshop.h - the setlist workshop (PRD § 13): a screen of its own, in place of the console, to build sets.
// Three columns - my setlists, the library, the setlist - and a preview of a song's raw mix at the bottom.
// Every change is written at once. The console is for playing; nothing plays through the effects here.
//
// Drawn at 1440 x 900 like the console's board, with the same bricks.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Board.h"

namespace dsm {

class Workshop : public juce::Component, public juce::FileDragAndDropTarget
{
public:
    std::function<void()> onBack;
    std::function<void(const juce::String& what, const juce::String& current, std::function<void(const juce::String&)>)> onAskText;
    std::function<void(const juce::String& question, std::function<void()>)> onConfirm;
    std::function<void(int line)> onLocate;
    std::function<void(juce::PopupMenu&, std::function<void(int)>)> showMenu = [](juce::PopupMenu& menu, std::function<void(int)> picked)
    {
        menu.showMenuAsync(juce::PopupMenu::Options(), std::move(picked));
    };

    explicit Workshop(AppModel& app) : app_(app)
    {
        setSize(Board::kWidth, Board::kHeight);
        setOpaque(true);
        search_.setFont(look::mono(10.0f));
        search_.setTextToShowWhenEmpty("Search the library", look::dim);
        search_.setColour(juce::TextEditor::backgroundColourId, look::surface);
        search_.setColour(juce::TextEditor::outlineColourId, look::border);
        search_.setColour(juce::TextEditor::focusedOutlineColourId, look::dim);
        search_.setColour(juce::TextEditor::textColourId, look::text);
        search_.setBounds(350, 104, 450, 26);
        search_.onTextChange = [this] { libraryScroll_ = 0; repaint(); };
        search_.onEscapeKey = [this] { search_.setText({}); grabKeyboardFocus(); };
        search_.onReturnKey = [this] { grabKeyboardFocus(); };
        addAndMakeVisible(search_);
        setWantsKeyboardFocus(true);
    }

    // Called when the workshop is shown: the folder is read again, the console's setlist is the one edited.
    void open()
    {
        app_.scanLibrary();
        if (app_.editing.document == juce::File() && app_.setlist.document != juce::File()) app_.edit(app_.setlist.document);
        selected_ = -1;
    }

    void close() { Preview::get().stop(); }

    void setSearch(const juce::String& text) { search_.setText(text, true); }

    // The library's songs matching the search.
    std::vector<SongInfo> shownLibrary() const
    {
        const juce::String wanted = search_.getText().trim();
        std::vector<SongInfo> shown;
        for (const SongInfo& song : app_.library)
            if (wanted.isEmpty() || song.title.containsIgnoreCase(wanted)) shown.push_back(song);
        return shown;
    }

    // Finds a missing song of the setlist by its file name in a folder (PRD § 13).
    bool locate(int line, const juce::File& folder)
    {
        Setlist& set = app_.editing;
        if (line < 0 || line >= (int)set.songs.size()) return false;
        const juce::String wanted = set.songs[(size_t)line].project.path.replaceCharacter('\\', '/').fromLastOccurrenceOf("/", false, false);
        const juce::Array<juce::File> found = folder.findChildFiles(juce::File::findFiles, true, wanted.isEmpty() ? "*.dubstem" : wanted);
        if (found.size() != 1 || set.indexOf(found[0]) >= 0) return false;
        const int colour = set.songs[(size_t)line].colour;
        const juce::String tag = set.songs[(size_t)line].tag;
        set.songs[(size_t)line] = Setlist::line(found[0]);
        set.songs[(size_t)line].colour = colour;
        set.songs[(size_t)line].tag = tag;
        app_.saveEditing();
        return true;
    }

    // Projects dropped from the file manager join the library, and are remembered.
    bool isInterestedInFileDrag(const juce::StringArray&) override { return true; }
    void filesDropped(const juce::StringArray& paths, int, int) override
    {
        for (const juce::String& path : paths) app_.addToLibrary(juce::File(path));
        repaint();
    }

    bool keyPressed(const juce::KeyPress& key) override
    {
        if ((key == juce::KeyPress::backspaceKey || key == juce::KeyPress::deleteKey) && selected_ >= 0)
        {
            removeLine(selected_);
            return true;
        }
        return false;
    }

    void paint(juce::Graphics& g) override
    {
        zones_.clear();
        g.fillAll(look::bg);
        drawHeader(g);
        drawSetlists(g);
        drawLibrary(g);
        drawSetlist(g);
        drawPreview(g);
        if (carrying_)
        {
            const juce::Rectangle<float> tag(carryAt_.x + 10.0f, carryAt_.y - 10.0f, 200.0f, 22.0f);
            Board::card(g, tag, look::text, look::text, 3.0f);
            Board::write(g, carryName_, tag.reduced(6.0f, 0.0f), look::name(10.0f), look::bg);
        }
    }

    void mouseDown(const juce::MouseEvent& e) override
    {
        grabKeyboardFocus();
        active_.reset();
        for (auto it = zones_.rbegin(); it != zones_.rend(); ++it)
            if (it->area.contains(e.position)) { active_ = std::make_unique<Zone>(*it); break; }
        if (active_ == nullptr) return;
        if (e.mods.isPopupMenu())
        {
            if (active_->menu) active_->menu();
            active_.reset();
            return;
        }
        if (active_->seek) active_->seek(e.position.x);
    }

    void mouseDrag(const juce::MouseEvent& e) override
    {
        if (active_ == nullptr) return;
        if (active_->seek) { active_->seek(e.position.x); return; }
        if (active_->carry == 0 || e.getDistanceFromDragStart() < 4) return;
        carrying_ = true;
        carryAt_ = e.position;
        carryName_ = active_->name;
        repaint();
    }

    void mouseUp(const juce::MouseEvent& e) override
    {
        if (active_ != nullptr)
        {
            if (carrying_) dropCarried(e.position);
            else if (active_->click && !active_->seek) active_->click();
        }
        carrying_ = false;
        active_.reset();
        repaint();
    }

    void mouseDoubleClick(const juce::MouseEvent& e) override
    {
        for (auto it = zones_.rbegin(); it != zones_.rend(); ++it)
            if (it->onDouble && it->area.contains(e.position)) { const auto action = it->onDouble; action(); return; }
    }

    void mouseWheelMove(const juce::MouseEvent& e, const juce::MouseWheelDetails& wheel) override
    {
        const int step = wheel.deltaY > 0 ? -1 : wheel.deltaY < 0 ? 1 : 0;
        if (e.position.x >= 350.0f && e.position.x < 810.0f) libraryScroll_ = juce::jmax(0, libraryScroll_ + step);
        else if (e.position.x >= 810.0f) lineScroll_ = juce::jmax(0, lineScroll_ + step);
        else setlistScroll_ = juce::jmax(0, setlistScroll_ + step);
        repaint();
    }

private:
    struct Zone
    {
        juce::Rectangle<float> area;
        std::function<void()> click, menu, onDouble;
        std::function<void(float)> seek;   // pressed and dragged: the x under the pointer
        int carry = 0, index = -1;         // 1: a song of the library, 2: a line of the setlist
        juce::File file;
        juce::String name;
    };

    static constexpr float kTop = 84.0f, kListTop = 140.0f, kListBottom = 740.0f, kLibraryRow = 34.0f, kLineRow = 38.0f;
    static constexpr float kSetX = 820.0f, kSetRight = 1422.0f;

    Zone& zone(juce::Rectangle<float> area, std::function<void()> click = {})
    {
        Zone z;
        z.area = area;
        z.click = std::move(click);
        zones_.push_back(std::move(z));
        return zones_.back();
    }

    // ---- Changes: written at once ----

    void changed()
    {
        app_.saveEditing();
        app_.scanLibrary();
        repaint();
    }

    void removeLine(int line)
    {
        app_.editing.remove(line);
        selected_ = -1;
        changed();
    }

    // Where a carried song lands in the setlist: before the line under the pointer, or at the end.
    int lineAt(float y) const
    {
        const int line = lineScroll_ + (int)std::floor((y - kListTop + kLineRow * 0.5f) / kLineRow);
        return juce::jlimit(0, (int)app_.editing.songs.size(), line);
    }

    void dropCarried(juce::Point<float> at)
    {
        Setlist& set = app_.editing;
        if (at.x < 810.0f || set.document == juce::File()) return;
        if (active_->carry == 1)
        {
            // No song twice: the line it already has blinks instead (PRD § 13).
            const int already = set.insert(active_->file, lineAt(at.y));
            if (already >= 0) { flash_ = already; flashUntil_ = juce::Time::getMillisecondCounterHiRes() + 900.0; return; }
        }
        else if (active_->carry == 2)
        {
            int to = lineAt(at.y);
            if (to > active_->index) --to;
            set.move(active_->index, to);
        }
        changed();
    }

    void togglePreview(const juce::File& project)
    {
        Preview& preview = Preview::get();
        const juce::String key = project.getFullPathName();
        if (preview.isPlaying(key)) { preview.stop(); return; }
        previewFiles_ = SongInfo::stems(project);
        previewTitle_ = SongInfo::read(project).title;
        preview.play(previewFiles_, key);
    }

    static void playMark(juce::Graphics& g, juce::Rectangle<float> r, bool playing, juce::Colour colour)
    {
        g.setColour(colour);
        if (playing) { g.fillRect(r.getCentreX() - 5.0f, r.getCentreY() - 5.0f, 10.0f, 10.0f); return; }
        juce::Path triangle;
        triangle.addTriangle(r.getCentreX() - 4.0f, r.getCentreY() - 6.0f, r.getCentreX() - 4.0f, r.getCentreY() + 6.0f, r.getCentreX() + 6.0f, r.getCentreY());
        g.fillPath(triangle);
    }

    // ---- Header ----

    void drawHeader(juce::Graphics& g)
    {
        const juce::Font logo = look::label(21.0f);
        float x = 18.0f;
        const std::pair<const char*, juce::Colour> parts[3] = {{"DUB", look::delay}, {"STEM", look::reverb}, {"MIX", look::bus3}};
        for (const auto& part : parts)
        {
            const float w = juce::GlyphArrangement::getStringWidth(logo, part.first);
            Board::write(g, part.first, {x, 14.0f, w + 2.0f, 30.0f}, logo, part.second);
            x += w;
        }
        Board::write(g, "SETLISTS", {250.0f, 20.0f, 300.0f, 24.0f}, look::label(17.0f), look::text);
        Board::write(g, "Build your sets here; the console is for playing.", {250.0f, 44.0f, 600.0f, 16.0f}, look::mono(10.0f), look::dim);
        const juce::Rectangle<float> back(1222.0f, 22.0f, 200.0f, 40.0f);
        Board::card(g, back, look::surface, look::border, 4.0f);
        Board::write(g, "BACK TO CONSOLE", back, look::label(11.5f), look::text, juce::Justification::centred);
        zone(back, [this] { if (onBack) onBack(); });
    }

    // ---- Column 1: my setlists ----

    void drawSetlists(juce::Graphics& g)
    {
        Board::write(g, "MY SETLISTS", {18.0f, kTop, 300.0f, 14.0f}, look::mono(9.0f), look::dim);
        Board::write(g, app_.setlistsFolder().getFullPathName(), {18.0f, kTop + 16.0f, 312.0f, 12.0f}, look::mono(7.5f), look::dim);
        float y = 124.0f;
        const int room = (int)((680.0f - y) / 44.0f);
        setlistScroll_ = juce::jlimit(0, juce::jmax(0, (int)app_.setlistFiles.size() - room), setlistScroll_);
        for (int i = setlistScroll_; i < (int)app_.setlistFiles.size() && i < setlistScroll_ + room; ++i)
        {
            const juce::File file = app_.setlistFiles[(size_t)i];
            const bool current = file == app_.editing.document;
            const juce::Rectangle<float> row(18.0f, y, 312.0f, 40.0f);
            if (current) { g.setColour(look::text); g.fillRoundedRectangle(row, 3.0f); } else Board::card(g, row, look::surface, look::border, 3.0f);
            Board::write(g, file.getFileNameWithoutExtension(), {30.0f, y + 4.0f, 290.0f, 18.0f}, look::name(12.0f), current ? look::bg : look::text);
            if (current)
                Board::write(g, juce::String((int)app_.editing.songs.size()) + look::u(" SONGS · ") + Board::clock(app_.editing.totalSeconds()),
                             {30.0f, y + 22.0f, 290.0f, 12.0f}, look::mono(8.0f), look::bg.withAlpha(0.7f));
            zone(row, [this, file] { Preview::get().stop(); app_.edit(file); selected_ = -1; lineScroll_ = 0; });
            y += 44.0f;
        }
        if (app_.setlistFiles.empty())
            Board::write(g, "No setlist yet: NEW starts one.", {18.0f, y, 312.0f, 14.0f}, look::mono(9.0f), look::dim);

        const bool any = app_.editing.document != juce::File();
        struct Action { const char* caption; float x, width; bool enabled; };
        const Action actions[4] = {{"NEW", 18.0f, 66.0f, true}, {"DUPLICATE", 90.0f, 96.0f, any}, {"RENAME", 192.0f, 72.0f, any}, {"DELETE", 270.0f, 60.0f, any}};
        for (int i = 0; i < 4; ++i)
        {
            const juce::Rectangle<float> b(actions[i].x, 700.0f, actions[i].width, 30.0f);
            Board::button(g, b, actions[i].caption, false, look::text, 9.5f, actions[i].enabled);
            if (!actions[i].enabled) continue;
            zone(b, [this, i]
            {
                if (i == 0 && onAskText) onAskText("Name of the new setlist", "New setlist", [this](const juce::String& name) { app_.newSetlist(name); selected_ = -1; });
                else if (i == 1) app_.duplicateSetlist();
                else if (i == 2 && onAskText) onAskText("Name of the setlist", app_.editing.name, [this](const juce::String& name) { app_.renameSetlist(name); });
                else if (i == 3 && onConfirm) onConfirm("Delete the setlist \"" + app_.editing.name + "\"? Its songs stay on the disk.", [this] { app_.deleteSetlist(); selected_ = -1; });
            });
        }
    }

    // ---- Column 2: the library ----

    void drawLibrary(juce::Graphics& g)
    {
        const std::vector<SongInfo> shown = shownLibrary();
        Board::write(g, look::u("LIBRARY · ") + juce::String((int)shown.size()) + (shown.size() == 1 ? " SONG" : " SONGS"), {350.0f, kTop, 300.0f, 14.0f}, look::mono(9.0f), look::dim);
        Board::write(g, "drag a song into the setlist", {560.0f, kTop, 240.0f, 14.0f}, look::mono(8.0f), look::dim, juce::Justification::centredRight);
        const int room = (int)((kListBottom - kListTop) / kLibraryRow);
        libraryScroll_ = juce::jlimit(0, juce::jmax(0, (int)shown.size() - room), libraryScroll_);
        float y = kListTop;
        for (int i = libraryScroll_; i < (int)shown.size() && i < libraryScroll_ + room; ++i)
        {
            const SongInfo& song = shown[(size_t)i];
            const bool inSet = app_.editing.indexOf(song.file) >= 0;
            const bool playing = Preview::get().isPlaying(song.file.getFullPathName());
            const juce::Rectangle<float> row(350.0f, y, 450.0f, kLibraryRow - 4.0f);
            Board::card(g, row, look::surface, playing ? look::delay : look::border, 3.0f);
            const juce::Rectangle<float> play(354.0f, y + 3.0f, 24.0f, 24.0f);
            playMark(g, play, playing, playing ? look::delay : look::dim);
            Board::write(g, song.title, {384.0f, y, 270.0f, kLibraryRow - 4.0f}, look::name(11.0f), inSet ? look::dim : look::text);
            Board::write(g, song.bpm > 0 ? juce::String((int)std::lround(song.bpm)) + " BPM" : juce::String(), {660.0f, y, 66.0f, kLibraryRow - 4.0f}, look::mono(8.5f), look::dim,
                         juce::Justification::centredRight);
            Board::write(g, song.seconds > 0 ? Board::clock(song.seconds) : juce::String(), {730.0f, y, 60.0f, kLibraryRow - 4.0f}, look::mono(8.5f), look::dim,
                         juce::Justification::centredRight);
            Zone& z = zone(row);
            z.carry = 1; z.file = song.file; z.name = song.title;
            const juce::File file = song.file;
            zone(play, [this, file] { togglePreview(file); });
            y += kLibraryRow;
        }
        if (app_.library.empty())
            Board::write(g, "No project found in " + app_.home.getFullPathName(), {350.0f, kListTop, 450.0f, 14.0f}, look::mono(9.0f), look::dim);
    }

    // ---- Column 3: the setlist ----

    void drawSetlist(juce::Graphics& g)
    {
        Setlist& set = app_.editing;
        if (set.document == juce::File())
        {
            Board::write(g, "Pick a setlist on the left, or start a NEW one.", {kSetX, kTop, 500.0f, 16.0f}, look::mono(10.0f), look::dim);
            return;
        }
        Board::write(g, set.name.toUpperCase(), {kSetX, kTop - 4.0f, 300.0f, 22.0f}, look::label(15.0f), look::text);
        zone({kSetX, kTop - 4.0f, 300.0f, 22.0f}).onDouble = [this]
        {
            if (onAskText) onAskText("Name of the setlist", app_.editing.name, [this](const juce::String& name) { app_.renameSetlist(name); });
        };
        Board::write(g, juce::String((int)set.songs.size()) + look::u(" SONGS · ") + Board::clock(set.totalSeconds())
                        + (app_.editingSaved.isNotEmpty() ? look::u("   ·   ") + app_.editingSaved : juce::String()),
                     {kSetX, kTop + 20.0f, 320.0f, 14.0f}, look::mono(9.0f), look::dim);
        const juce::Rectangle<float> save(1150.0f, kTop - 2.0f, 72.0f, 30.0f), load(1230.0f, kTop - 2.0f, 192.0f, 30.0f);
        Board::button(g, save, "SAVE", false, look::text, 9.5f);
        zone(save, [this] { app_.saveEditing(); });
        Board::button(g, load, "LOAD IN THE CONSOLE", true, look::text, 9.5f);
        zone(load, [this] { app_.loadInConsole(); if (onBack) onBack(); });

        const int room = (int)((kListBottom - kListTop) / kLineRow);
        lineScroll_ = juce::jlimit(0, juce::jmax(0, (int)set.songs.size() - room), lineScroll_);
        const bool flashing = juce::Time::getMillisecondCounterHiRes() < flashUntil_ && ((int)(juce::Time::getMillisecondCounterHiRes() / 150.0) % 2 == 0);
        float y = kListTop;
        for (int i = lineScroll_; i < (int)set.songs.size() && i < lineScroll_ + room; ++i)
        {
            const Setlist::Song& song = set.songs[(size_t)i];
            const bool playing = Preview::get().isPlaying(song.project.file.getFullPathName());
            const juce::Rectangle<float> row(kSetX, y, kSetRight - kSetX, kLineRow - 4.0f);
            const bool lit = i == selected_ || (flashing && i == flash_);
            Board::card(g, row, lit ? look::border : look::surface, flashing && i == flash_ ? look::delay : playing ? look::delay : i == selected_ ? look::dim : look::border, 3.0f);
            if (song.colour >= 0) { g.setColour(look::lineColour(song.colour)); g.fillRect(row.getX(), row.getY() + 2.0f, 3.0f, row.getHeight() - 4.0f); }
            Board::write(g, juce::String(i + 1).paddedLeft('0', 2), {kSetX + 12.0f, y, 24.0f, kLineRow - 4.0f}, look::mono(9.0f), look::dim);
            const juce::Rectangle<float> play(kSetX + 38.0f, y + 5.0f, 24.0f, 24.0f), dot(kSetX + 68.0f, y + 9.0f, 16.0f, 16.0f);
            if (!song.project.missing) playMark(g, play, playing, playing ? look::delay : look::dim);
            g.setColour(song.colour >= 0 ? look::lineColour(song.colour) : look::border.brighter(0.2f));
            if (song.colour >= 0) g.fillEllipse(dot.reduced(3.0f)); else g.drawEllipse(dot.reduced(3.0f), 1.0f);
            Board::write(g, song.project.missing ? song.title + "  (not found)" : song.title, {kSetX + 92.0f, y, 250.0f, kLineRow - 4.0f}, look::name(11.5f),
                         song.project.missing ? look::rec : look::text);
            const juce::Rectangle<float> tag(kSetX + 350.0f, y + 8.0f, 110.0f, 18.0f);
            Board::pill(g, tag, song.tag.isEmpty() ? juce::String("+ TAG") : song.tag.toUpperCase(), song.tag.isNotEmpty(), look::text);
            Board::write(g, song.bpm > 0 ? juce::String((int)std::lround(song.bpm)) + " BPM" : juce::String(), {kSetX + 468.0f, y, 60.0f, kLineRow - 4.0f}, look::mono(8.5f), look::dim,
                         juce::Justification::centredRight);
            Board::write(g, song.seconds > 0 ? Board::clock(song.seconds) : juce::String(), {kSetX + 532.0f, y, 58.0f, kLineRow - 4.0f}, look::mono(8.5f), look::dim,
                         juce::Justification::centredRight);

            Zone& z = zone(row, [this, i] { selected_ = i; });
            z.carry = 2; z.index = i; z.name = song.title;
            z.menu = [this, i] { lineMenu(i); };
            if (!song.project.missing)
            {
                const juce::File file = song.project.file;
                zone(play, [this, file] { togglePreview(file); });
            }
            // The colour dot goes through the palette, then back to none.
            zone(dot.expanded(3.0f), [this, i]
            {
                int& colour = app_.editing.songs[(size_t)i].colour;
                colour = colour + 1 >= Setlist::kColours ? -1 : colour + 1;
                changed();
            });
            zone(tag, [this, i] { askTag(i); });
            y += kLineRow;
        }
        if (set.songs.empty())
            Board::write(g, "Empty: drag songs here from the library.", {kSetX, kListTop, 500.0f, 16.0f}, look::mono(10.0f), look::dim);
    }

    void askTag(int line)
    {
        if (!onAskText) return;
        const juce::StringArray used = app_.editing.tags();
        onAskText("Tag" + (used.isEmpty() ? juce::String() : " (used here: " + used.joinIntoString(", ") + ")"), app_.editing.songs[(size_t)line].tag,
                  [this, line](const juce::String& tag) { app_.editing.songs[(size_t)line].tag = tag.trim(); changed(); });
    }

    void lineMenu(int line)
    {
        static const char* names[Setlist::kColours] = {"Red", "Rust", "Amber", "Green", "Teal", "Blue", "Purple", "Cream"};
        juce::PopupMenu menu, colours;
        colours.addItem(100, "None");
        for (int c = 0; c < Setlist::kColours; ++c) colours.addItem(101 + c, names[c]);
        menu.addSubMenu("Colour", colours);
        menu.addItem(2, look::u("Tag…"));
        if (app_.editing.songs[(size_t)line].project.missing) menu.addItem(3, look::u("Locate…"));
        menu.addSeparator();
        menu.addItem(1, "Remove from the setlist");
        showMenu(menu, [this, line](int picked)
        {
            if (picked == 1) removeLine(line);
            else if (picked == 2) askTag(line);
            else if (picked == 3) { if (onLocate) onLocate(line); }
            else if (picked >= 100 && picked <= 100 + Setlist::kColours) { app_.editing.songs[(size_t)line].colour = picked - 101; changed(); }
        });
    }

    // ---- Preview: the raw mix of one song, with a waveform to jump in ----

    void drawPreview(juce::Graphics& g)
    {
        const juce::Rectangle<float> r(18.0f, 760.0f, 1404.0f, 120.0f);
        Board::card(g, r, look::surface, look::border);
        Preview& preview = Preview::get();
        if (!preview.isPlaying())
        {
            Board::write(g, "PREVIEW", {34.0f, 772.0f, 200.0f, 14.0f}, look::mono(9.0f), look::dim);
            Board::write(g, "Press the play mark of a song to hear its raw mix, without effects. It plays on the console's sound card.",
                         r, look::mono(9.5f), look::dim, juce::Justification::centred);
            return;
        }
        const double position = preview.position(), length = preview.length();
        Board::write(g, look::u("PREVIEW · ") + previewTitle_.toUpperCase(), {34.0f, 770.0f, 800.0f, 16.0f}, look::label(10.5f), look::delay);
        Board::write(g, Board::clock(position) + " / " + Board::clock(length), {1100.0f, 770.0f, 200.0f, 16.0f}, look::mono(9.5f), look::dim, juce::Justification::centredRight);
        const juce::Rectangle<float> stop(1318.0f, 766.0f, 90.0f, 24.0f);
        Board::button(g, stop, "STOP", false, look::text, 9.5f);
        zone(stop, [] { Preview::get().stop(); });

        const juce::Rectangle<float> area(34.0f, 796.0f, 1372.0f, 72.0f);
        const float done = length > 0 ? (float)juce::jlimit(0.0, 1.0, position / length) : 0.0f;
        const std::shared_ptr<const Waveform> wave = waveforms_.get(previewFiles_);
        if (wave != nullptr && wave->seconds > 0)
        {
            const float pitch = area.getWidth() / (float)Waveforms::kBars;
            for (int i = 0; i < Waveforms::kBars; ++i)
            {
                const float at = ((float)i + 0.5f) / (float)Waveforms::kBars;
                const float h = juce::jmax(1.5f, wave->peaks[(size_t)i] * area.getHeight() * 0.92f);
                g.setColour(at <= done ? look::text : look::text.withAlpha(0.28f));
                g.fillRect(area.getX() + (float)i * pitch, area.getCentreY() - h * 0.5f, juce::jmax(1.0f, pitch - 1.0f), h);
            }
        }
        g.setColour(look::delay);
        g.fillRect(area.getX() + area.getWidth() * done - 1.0f, area.getY(), 2.0f, area.getHeight());
        zone(area).seek = [area](float x)
        {
            Preview& p = Preview::get();
            p.seek(juce::jlimit(0.0, 1.0, (double)((x - area.getX()) / area.getWidth())) * p.length());
        };
    }

    AppModel& app_;
    juce::TextEditor search_;
    Waveforms waveforms_;
    std::vector<Zone> zones_;
    std::unique_ptr<Zone> active_;
    int setlistScroll_ = 0, libraryScroll_ = 0, lineScroll_ = 0, selected_ = -1, flash_ = -1;
    double flashUntil_ = 0.0;
    bool carrying_ = false;
    juce::Point<float> carryAt_;
    juce::String carryName_, previewTitle_;
    std::vector<std::string> previewFiles_;
};

} // namespace dsm
