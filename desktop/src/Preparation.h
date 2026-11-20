// Preparation.h - the preparation mode (PRD § 12.6): a list of songs split one after the other, each into
// its four stems and a ready project beside them. A screen of its own, in place of the console; playback is
// off while it lasts. The separation engine's files and the stems' folder are managed from here too.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Board.h"

namespace dsm {

class Preparation : public juce::Component, public juce::FileDragAndDropTarget
{
public:
    std::function<void()> onAddSongs, onFolder;
    std::function<void(const juce::String& question, std::function<void()>)> onConfirm;
    std::function<void(juce::PopupMenu&, std::function<void(int)>)> showMenu = [](juce::PopupMenu& menu, std::function<void(int)> picked)
    {
        menu.showMenuAsync(juce::PopupMenu::Options(), std::move(picked));
    };

    explicit Preparation(AppModel& app) : app_(app)
    {
        setSize(Board::kWidth, Board::kHeight);
        setOpaque(true);
    }

    // Songs or a folder dropped anywhere on the screen join the end of the list.
    bool isInterestedInFileDrag(const juce::StringArray&) override { return true; }
    void filesDropped(const juce::StringArray& paths, int, int) override
    {
        juce::Array<juce::File> files;
        for (const juce::String& path : paths) files.add(juce::File(path));
        app_.prepareSongs(files);
        repaint();
    }

    // "1 H 05", "42 MIN", "< 1 MIN"
    static juce::String duration(double seconds)
    {
        const int minutes = (int)std::ceil(seconds / 60.0);
        if (minutes < 1) return "< 1 MIN";
        return minutes >= 60 ? juce::String(minutes / 60) + " H " + juce::String(minutes % 60).paddedLeft('0', 2) : juce::String(minutes) + " MIN";
    }

    static juce::String length(double seconds)
    {
        const int total = (int)std::lround(juce::jmax(0.0, seconds));
        return juce::String(total / 60) + ":" + juce::String(total % 60).paddedLeft('0', 2);
    }

    // "3 / 10 PREPARED · 1 FAILED · ABOUT 42 MIN LEFT"
    juce::String summary() const
    {
        const AppModel::SplitStatus status = app_.splitStatus();
        if (status.kind == AppModel::SplitStatus::Downloading)
            return look::u("DOWNLOADING THE ENGINE… ") + juce::String(status.received / 1000000) + " / " + juce::String(status.total / 1000000) + " MB";
        const split::Queue& queue = app_.prepQueue;
        const int done = queue.count(split::Queue::Done), failed = queue.count(split::Queue::Failed), all = (int)queue.items().size();
        juce::StringArray parts;
        parts.add(juce::String(done) + " / " + juce::String(all) + " PREPARED");
        if (failed > 0) parts.add(juce::String(failed) + " FAILED");
        if (status.cancelling) parts.add(look::u("CANCELLING…"));
        else if (app_.splitBusy())
        {
            const double left = app_.prepTimeLeft();
            parts.add(left >= 0 ? "ABOUT " + duration(left) + " LEFT" : look::u("ESTIMATING TIME LEFT…"));
        }
        else if (all > 0 && done + failed == all) parts.add("ALL DONE");
        else if (queue.count(split::Queue::Waiting) > 0) parts.add("WAITING");
        return parts.joinIntoString(look::u(" · "));
    }

    juce::String engineLine() const
    {
        const split::Catalog& c = app_.models.catalog();
        const AppModel::SplitStatus status = app_.splitStatus();
        if (status.kind == AppModel::SplitStatus::Downloading)
            return look::u("downloading… ") + juce::String(status.received / 1000000) + " / " + juce::String(status.total / 1000000) + " MB";
        switch (app_.models.status())
        {
            case split::ModelStore::Ready:   return c.name + " ready (" + c.shortRevision() + ")";
            case split::ModelStore::Partial: return c.name + ": " + juce::String(app_.models.readyCount()) + " of " + juce::String((int)c.files.size()) + " files";
            default:                         return c.name + " not downloaded (" + juce::String(c.megabytes()) + " MB)";
        }
    }

    void paint(juce::Graphics& g) override
    {
        zones_.clear();
        g.fillAll(look::bg);
        const split::Queue& queue = app_.prepQueue;
        const AppModel::SplitStatus status = app_.splitStatus();
        const bool busy = app_.splitBusy();

        const juce::Font logo = look::label(21.0f);
        float x = 18.0f;
        const std::pair<const char*, juce::Colour> parts[3] = {{"DUB", look::delay}, {"STEM", look::reverb}, {"MIX", look::bus3}};
        for (const auto& part : parts)
        {
            const float w = juce::GlyphArrangement::getStringWidth(logo, part.first);
            Board::write(g, part.first, {x, 14.0f, w + 2.0f, 30.0f}, logo, part.second);
            x += w;
        }
        Board::write(g, "PREPARE SONGS", {250.0f, 20.0f, 400.0f, 24.0f}, look::label(17.0f), look::text);
        Board::write(g, look::u("Each song → drums, bass, instruments, vocals and a ready project beside them · playback is off"),
                     {250.0f, 44.0f, 700.0f, 16.0f}, look::mono(10.0f), look::dim);
        Board::write(g, summary(), {250.0f, 64.0f, 700.0f, 16.0f}, look::mono(10.5f), busy ? look::delay : look::reverb);
        if (app_.message.isNotEmpty())
            Board::write(g, app_.message, {250.0f, 82.0f, 780.0f, 14.0f}, look::mono(9.5f), look::rec);

        // The buttons: add; then cancel while it runs, else start and back.
        const juce::Rectangle<float> add(1040.0f, 22.0f, 170.0f, 40.0f), second(1222.0f, 22.0f, 200.0f, 40.0f), third(1222.0f, 68.0f, 200.0f, 30.0f);
        Board::card(g, add, look::surface, look::border, 4.0f);
        Board::write(g, look::u("ADD SONGS…"), add, look::label(11.5f), look::text, juce::Justification::centred);
        zone(add, [this] { if (onAddSongs) onAddSongs(); });
        if (busy)
        {
            Board::card(g, second, look::surface, look::rec, 4.0f);
            Board::write(g, status.cancelling ? look::u("CANCELLING…") : juce::String("CANCEL ALL"), second, look::label(11.5f), look::rec, juce::Justification::centred);
            if (!status.cancelling) zone(second, [this] { app_.cancelPreparation(); });
        }
        else
        {
            Board::card(g, second, look::surface, look::border, 4.0f);
            Board::write(g, "BACK TO CONSOLE", second, look::label(11.5f), look::text, juce::Justification::centred);
            zone(second, [this] { app_.leavePreparation(); });
            if (queue.count(split::Queue::Waiting) > 0)
            {
                Board::card(g, third, look::surface, look::delay, 4.0f);
                Board::write(g, "START", third, look::label(11.0f), look::delay, juce::Justification::centred);
                zone(third, [this] { app_.startPreparing(); });
            }
        }

        // The list
        const float top = 112.0f, rowHeight = 52.0f;
        const int room = (int)((690.0f - top) / rowHeight), all = (int)queue.items().size();
        scroll_ = juce::jlimit(0, juce::jmax(0, all - room), scroll_);
        float y = top;
        for (int i = scroll_; i < all && i < scroll_ + room; ++i)
        {
            const split::Queue::Item& item = queue.items()[(size_t)i];
            const bool running = item.status == split::Queue::Running;
            const juce::Rectangle<float> row(18.0f, y, 1404.0f, rowHeight - 4.0f);
            Board::card(g, row, look::surface, running ? look::delay : look::border, 4.0f);
            Board::write(g, juce::String(i + 1).paddedLeft('0', 2), {30.0f, y, 30.0f, rowHeight - 4.0f}, look::mono(10.0f), look::dim);
            Board::write(g, split::songTitle(item.source), {64.0f, y + 5.0f, 900.0f, 20.0f}, look::label(12.5f), look::text);
            Board::write(g, item.source.getFileName() + (item.seconds >= 0 ? look::u(" · ") + length(item.seconds) : juce::String()),
                         {64.0f, y + 26.0f, 900.0f, 14.0f}, look::mono(8.5f), look::dim);
            const juce::Rectangle<float> state(1000.0f, y, 410.0f, rowHeight - 4.0f);
            if (item.status == split::Queue::Waiting)
            {
                Board::write(g, "WAITING", state.withTrimmedRight(40.0f), look::mono(9.5f), look::dim, juce::Justification::centredRight);
                const juce::Rectangle<float> remove(1384.0f, y + 12.0f, 24.0f, 24.0f);
                Board::write(g, look::u("×"), remove, look::mono(13.0f), look::dim, juce::Justification::centred);
                zone(remove, [this, id = item.id] { app_.prepQueue.remove(id); });
                // Right-click: the order of the waiting songs.
                zones_.push_back({row.withTrimmedRight(50.0f), nullptr, [this, id = item.id]
                {
                    juce::PopupMenu menu;
                    menu.addItem(1, "Move up");
                    menu.addItem(2, "Move down");
                    menu.addItem(3, "Remove");
                    showMenu(menu, [this, id](int picked)
                    {
                        if (picked == 1) app_.prepQueue.move(id, -1); else if (picked == 2) app_.prepQueue.move(id, +1); else if (picked == 3) app_.prepQueue.remove(id);
                        repaint();
                    });
                }});
            }
            else if (running)
            {
                juce::String detail = look::u("STARTING…");
                if (status.kind == AppModel::SplitStatus::Splitting)
                {
                    detail = split::stemLabel(status.stem) + look::u("… ") + juce::String((int)(status.fraction * 100.0)) + " %";
                    if (status.secondsLeft >= 0) detail << look::u(" · ") << length(status.secondsLeft) << " LEFT";
                }
                Board::write(g, detail, state, look::mono(9.5f), look::delay, juce::Justification::centredRight);
                const juce::Rectangle<float> bar(64.0f, y + 42.0f, 900.0f, 3.0f);
                g.setColour(look::border);
                g.fillRoundedRectangle(bar, 1.5f);
                g.setColour(look::delay);
                g.fillRoundedRectangle(bar.withWidth(bar.getWidth() * (float)juce::jlimit(0.0, 1.0, status.fraction)), 1.5f);
            }
            else if (item.status == split::Queue::Done)
            {
                Board::write(g, item.reused ? "ALREADY PREPARED" : "READY", state.withTrimmedRight(130.0f), look::mono(9.5f), look::reverb, juce::Justification::centredRight);
                const juce::Rectangle<float> show(1290.0f, y + 12.0f, 120.0f, 24.0f);
                Board::write(g, "SHOW IN FILES", show, look::mono(9.0f), look::text, juce::Justification::centredRight);
                zone(show, [project = item.project] { project.revealToUser(); });
            }
            else
                Board::write(g, "FAILED" + look::u(" · ") + item.error, state.withLeft(700.0f), look::mono(9.5f), look::rec, juce::Justification::centredRight);
            y += rowHeight;
        }
        if (all > room)
            Board::write(g, juce::String(scroll_ + 1) + look::u("–") + juce::String(juce::jmin(all, scroll_ + room)) + " of " + juce::String(all),
                         {18.0f, 692.0f, 300.0f, 14.0f}, look::mono(8.5f), look::dim);

        // Where to drop
        const juce::Rectangle<float> drop(18.0f, 712.0f, 1404.0f, 44.0f);
        const float dashes[2] = {3.0f, 3.0f};
        juce::Path outline, dashed;
        outline.addRoundedRectangle(drop, 6.0f);
        juce::PathStrokeType(1.0f).createDashedStroke(dashed, outline, dashes, 2);
        g.setColour(look::dim.withAlpha(0.5f));
        g.fillPath(dashed);
        Board::write(g, all == 0 ? "Drop songs or a folder here" : "Drop more songs here to add them at the end", drop, look::mono(10.0f), look::dim, juce::Justification::centred);
        zone(drop, [this] { if (onAddSongs) onAddSongs(); });

        // The separation engine and the stems' folder (the Mac app has them in its settings).
        const split::ModelStore::Status models = app_.models.status();
        Board::write(g, "ENGINE", {18.0f, 778.0f, 80.0f, 14.0f}, look::mono(8.5f), look::dim);
        Board::write(g, engineLine(), {100.0f, 776.0f, 560.0f, 18.0f}, look::mono(10.0f), models == split::ModelStore::Ready ? look::reverb : look::text);
        const juce::Rectangle<float> first(670.0f, 772.0f, 170.0f, 26.0f), other(850.0f, 772.0f, 100.0f, 26.0f);
        if (status.kind == AppModel::SplitStatus::Downloading)
        {
            Board::button(g, first, status.cancelling ? look::u("CANCELLING…") : juce::String("CANCEL"), false, look::text, 10.0f);
            if (!status.cancelling) zone(first, [this] { app_.cancelSeparation(); });
        }
        else if (models != split::ModelStore::Ready)
        {
            Board::button(g, first, "DOWNLOAD " + juce::String(app_.models.catalog().megabytes()) + " MB", false, look::text, 10.0f, !busy);
            if (!busy) zone(first, [this] { app_.consentToDownload([this] { app_.startDownload(); }); });
        }
        if (models != split::ModelStore::Missing && !busy)
        {
            Board::button(g, other, "DELETE", false, look::text, 10.0f);
            zone(other, [this]
            {
                if (onConfirm) onConfirm("Delete the separation engine's files? They can be downloaded again.", [this] { app_.deleteModels(); });
            });
        }
        Board::write(g, "STEMS", {18.0f, 808.0f, 80.0f, 14.0f}, look::mono(8.5f), look::dim);
        Board::write(g, app_.stemsFolder().getFullPathName(), {100.0f, 806.0f, 560.0f, 18.0f}, look::mono(10.0f), look::text);
        const juce::Rectangle<float> folder(670.0f, 802.0f, 170.0f, 26.0f);
        Board::button(g, folder, look::u("FOLDER…"), false, look::text, 10.0f);
        zone(folder, [this] { if (onFolder) onFolder(); });

        // The weights' license status, in full (PRD § 12.2).
        g.setColour(look::dim);
        g.setFont(look::mono(8.5f));
        g.drawFittedText(app_.models.catalog().licenseNotice(), juce::Rectangle<int>(18, 838, 1404, 44), juce::Justification::topLeft, 3);
    }

    void mouseUp(const juce::MouseEvent& e) override
    {
        for (auto it = zones_.rbegin(); it != zones_.rend(); ++it)
        {
            if (!it->area.contains(e.position)) continue;
            const auto action = e.mods.isPopupMenu() ? it->menu : it->click;
            if (action) { action(); break; }
        }
        repaint();
    }

    void mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails& wheel) override
    {
        scroll_ = juce::jmax(0, scroll_ + (wheel.deltaY > 0 ? -1 : wheel.deltaY < 0 ? 1 : 0));
        repaint();
    }

private:
    struct Zone { juce::Rectangle<float> area; std::function<void()> click, menu; };
    void zone(juce::Rectangle<float> area, std::function<void()> click) { zones_.push_back({area, std::move(click), nullptr}); }

    AppModel& app_;
    std::vector<Zone> zones_;
    int scroll_ = 0;
};

} // namespace dsm
