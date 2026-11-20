// Sessions.h - the recorded sessions (PRD § 5.9): a screen of its own, away from the live console. The
// sessions of the recordings folder, the most recent first; the one chosen shows its sheet and can be
// exported to MP3, shown in the file manager, or moved to the trash.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Board.h"

namespace dsm {

class Sessions : public juce::Component
{
public:
    std::function<void()> onBack, onFolder;
    std::function<void(const juce::String& question, std::function<void()>)> onConfirm;

    explicit Sessions(AppModel& app) : app_(app)
    {
        setSize(Board::kWidth, Board::kHeight);
        setOpaque(true);
    }

    void open()
    {
        refresh();
        selected_ = entries_.empty() ? -1 : 0;
    }

    void refresh()
    {
        const juce::File chosen = selected_ >= 0 && selected_ < (int)entries_.size() ? entries_[(size_t)selected_].folder : juce::File();
        entries_ = listSessions(app_.recordingsFolder());
        selected_ = -1;
        for (int i = 0; i < (int)entries_.size(); ++i) if (entries_[(size_t)i].folder == chosen) selected_ = i;
    }

    int count() const { return (int)entries_.size(); }
    const SessionEntry* chosen() const { return selected_ >= 0 && selected_ < (int)entries_.size() ? &entries_[(size_t)selected_] : nullptr; }

    void paint(juce::Graphics& g) override
    {
        zones_.clear();
        g.fillAll(look::bg);
        // An export that has just ended shows in the list.
        const bool exporting = app_.exportProgress.load() >= 0.0;
        if (wasExporting_ && !exporting) refresh();
        wasExporting_ = exporting;

        const juce::Font logo = look::label(21.0f);
        float x = 18.0f;
        const std::pair<const char*, juce::Colour> parts[3] = {{"DUB", look::delay}, {"STEM", look::reverb}, {"MIX", look::bus3}};
        for (const auto& part : parts)
        {
            const float w = juce::GlyphArrangement::getStringWidth(logo, part.first);
            Board::write(g, part.first, {x, 14.0f, w + 2.0f, 30.0f}, logo, part.second);
            x += w;
        }
        Board::write(g, "RECORDED SESSIONS", {250.0f, 20.0f, 400.0f, 24.0f}, look::label(17.0f), look::text);
        Board::write(g, app_.recordingsFolder().getFullPathName(), {250.0f, 44.0f, 700.0f, 16.0f}, look::mono(10.0f), look::dim);
        const juce::Rectangle<float> folder(1040.0f, 22.0f, 170.0f, 40.0f), back(1222.0f, 22.0f, 200.0f, 40.0f);
        Board::card(g, folder, look::surface, look::border, 4.0f);
        Board::write(g, look::u("FOLDER…"), folder, look::label(11.5f), look::text, juce::Justification::centred);
        zone(folder, [this] { if (onFolder) onFolder(); });
        Board::card(g, back, look::surface, look::border, 4.0f);
        Board::write(g, "BACK TO CONSOLE", back, look::label(11.5f), look::text, juce::Justification::centred);
        zone(back, [this] { if (onBack) onBack(); });

        // The sessions
        Board::write(g, juce::String(count()) + (count() == 1 ? " SESSION" : " SESSIONS"), {18.0f, 84.0f, 300.0f, 14.0f}, look::mono(9.0f), look::dim);
        const int room = (int)((860.0f - 110.0f) / 48.0f);
        scroll_ = juce::jlimit(0, juce::jmax(0, count() - room), scroll_);
        float y = 110.0f;
        for (int i = scroll_; i < count() && i < scroll_ + room; ++i)
        {
            const SessionEntry& entry = entries_[(size_t)i];
            const bool current = i == selected_;
            const juce::Rectangle<float> row(18.0f, y, 500.0f, 44.0f);
            if (current) { g.setColour(look::text); g.fillRoundedRectangle(row, 3.0f); } else Board::card(g, row, look::surface, look::border, 3.0f);
            Board::write(g, entry.folder.getFileName(), {30.0f, y + 4.0f, 320.0f, 20.0f}, look::name(12.5f), current ? look::bg : look::text);
            const int songs = (int)entry.session.tracks.size();
            Board::write(g, RecordingSession::timestamp(entry.session.duration) + look::u(" · ") + juce::String(songs) + (songs == 1 ? " song" : " songs")
                            + (entry.session.finished ? "" : look::u(" · not finished")),
                         {30.0f, y + 24.0f, 320.0f, 14.0f}, look::mono(8.5f), current ? look::bg.withAlpha(0.7f) : look::dim);
            if (entry.hasMp3()) Board::pill(g, {458.0f, y + 13.0f, 46.0f, 18.0f}, "MP3", true, look::reverb);
            zone(row, [this, i] { selected_ = i; });
            y += 48.0f;
        }
        if (entries_.empty())
            Board::write(g, "No session yet: REC on the console records the master.", {18.0f, 110.0f, 500.0f, 16.0f}, look::mono(10.0f), look::dim);

        // The session chosen: its sheet, as written in session.txt.
        const SessionEntry* entry = chosen();
        if (entry == nullptr) return;
        const juce::Rectangle<float> sheet(540.0f, 110.0f, 882.0f, 660.0f);
        Board::card(g, sheet, look::surface, look::border);
        juce::StringArray lines = juce::StringArray::fromLines(entry->session.text());
        float ly = sheet.getY() + 18.0f;
        for (int i = 0; i < lines.size() && ly < sheet.getBottom() - 20.0f; ++i)
        {
            const bool heading = i == 0 || lines[i] == "Tracklist";
            Board::write(g, lines[i], {sheet.getX() + 22.0f, ly, sheet.getWidth() - 44.0f, 18.0f}, heading ? look::label(11.0f) : look::mono(10.5f), heading ? look::delay : look::text);
            ly += 20.0f;
        }

        const bool busy = app_.exportProgress.load() >= 0.0, mine = busy && app_.exporting == entry->folder;
        const juce::Rectangle<float> exportButton(540.0f, 790.0f, 190.0f, 40.0f), show(740.0f, 790.0f, 170.0f, 40.0f), trash(920.0f, 790.0f, 190.0f, 40.0f);
        if (mine)
        {
            Board::card(g, exportButton, look::surface, look::border, 4.0f);
            g.setColour(look::reverb);
            g.fillRoundedRectangle(exportButton.reduced(3.0f).withWidth((exportButton.getWidth() - 6.0f) * (float)app_.exportProgress.load()), 3.0f);
            Board::write(g, look::u("EXPORTING…"), exportButton, look::label(11.0f), look::text, juce::Justification::centred);
        }
        else
        {
            Board::button(g, exportButton, entry->hasMp3() ? "EXPORT MP3 AGAIN" : "EXPORT MP3", false, look::text, 11.0f, !busy);
            if (!busy) zone(exportButton, [this, e = *entry] { app_.exportMp3(e); });
        }
        Board::button(g, show, "SHOW IN FILES", false, look::text, 11.0f);
        zone(show, [e = *entry] { e.folder.revealToUser(); });
        Board::button(g, trash, "MOVE TO TRASH", false, look::rec, 11.0f, !mine);
        if (!mine)
            zone(trash, [this, e = *entry]
            {
                if (onConfirm) onConfirm("Move the session \"" + e.folder.getFileName() + "\" to the trash?", [this, e] { e.folder.moveToTrash(); refresh(); if (count() > 0) selected_ = 0; });
            });
        if (app_.message.isNotEmpty())
            Board::write(g, app_.message, {540.0f, 842.0f, 880.0f, 16.0f}, look::mono(9.5f), look::dim);
    }

    void mouseUp(const juce::MouseEvent& e) override
    {
        for (auto it = zones_.rbegin(); it != zones_.rend(); ++it)
            if (it->area.contains(e.position)) { const auto action = it->click; if (action) action(); break; }
        repaint();
    }

    void mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails& wheel) override
    {
        scroll_ = juce::jmax(0, scroll_ + (wheel.deltaY > 0 ? -1 : wheel.deltaY < 0 ? 1 : 0));
        repaint();
    }

private:
    struct Zone { juce::Rectangle<float> area; std::function<void()> click; };
    void zone(juce::Rectangle<float> area, std::function<void()> click) { zones_.push_back({area, std::move(click)}); }

    AppModel& app_;
    std::vector<SessionEntry> entries_;
    std::vector<Zone> zones_;
    int selected_ = -1, scroll_ = 0;
    bool wasExporting_ = false;
};

} // namespace dsm
