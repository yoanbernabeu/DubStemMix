// Board.h - the console's screen, in the Mac app's look (PRD § 5.10, § 5.11): a faithful mirror of the
// MIDImix, playable with the mouse. Sidebar (setlist, status), transport, the three bus cards, strips 1-6
// (stems, or the siren / Syndrum), the effect strips 7-8 and the master column with the pages and gestures.
//
// Drawn at a fixed 1440 x 900 and scaled to the window by its parent. Everything on it is read from, and
// written to, the engine's parameters: the board keeps no mix state of its own.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Engine.h"
#include "Waveform.h"
#include "BinaryData.h"

#include <functional>
#include <vector>

namespace dsm {

namespace look {
const juce::Colour bg(0xff14110f), surface(0xff1e1a17), border(0xff2e2823), text(0xffede3cf), dim(0xff9a8f7e);
const juce::Colour delay(0xffd9a441), reverb(0xff7e9b5a), bus3(0xffc2553a), rec(0xffe5412d);

inline juce::Typeface::Ptr face(int which)
{
    static const juce::Typeface::Ptr faces[3] = {
        juce::Typeface::createSystemTypefaceFor(BinaryData::ArchivoLabel_ttf, BinaryData::ArchivoLabel_ttfSize),
        juce::Typeface::createSystemTypefaceFor(BinaryData::ArchivoText_ttf, BinaryData::ArchivoText_ttfSize),
        juce::Typeface::createSystemTypefaceFor(BinaryData::JetBrainsMonoMedium_ttf, BinaryData::JetBrainsMonoMedium_ttfSize),
    };
    return faces[which];
}
// A string literal holding non-ASCII characters (the source files are UTF-8).
inline juce::String u(const char* utf8) { return juce::String::fromUTF8(utf8); }
// Archivo, bold and wide, for labels; Archivo for names; JetBrains Mono for values.
inline juce::Font label(float size) { return juce::Font(juce::FontOptions(face(0)).withHeight(size * 1.25f)); }
inline juce::Font name(float size) { return juce::Font(juce::FontOptions(face(1)).withHeight(size * 1.25f)); }
inline juce::Font mono(float size) { return juce::Font(juce::FontOptions(face(2)).withHeight(size * 1.3f)); }
} // namespace look

class Board : public juce::Component
{
public:
    static constexpr int kWidth = 1440, kHeight = 900;

    // What the board cannot read from the engine, given by its owner at each frame.
    struct Status
    {
        bool consoleConnected = false, consoleLeds = false;
        juce::String consoleName, card, cardDetail, soundError;
        float load = 0.0f;
        int lateBuffers = 0;
    };
    Status status;
    std::function<void()> onSoundCard;

    Board()
    {
        setSize(kWidth, kHeight);
        setOpaque(true);
        if (const char* folder = std::getenv("MPC_PLUGIN_FOLDER")) waveforms_.setFolder(juce::String::fromUTF8(folder));
    }

    // SOLO held (the console's SOLO button, or the SOLO button of the master column): MUTE then solos.
    void setSoloMode(bool on) { soloMode_ = on; }

    void paint(juce::Graphics& g) override
    {
        zones_.clear();
        g.fillAll(look::bg);
        drawSidebar(g);
        drawTransport(g);
        drawBuses(g);
        drawRowLabels(g);
        for (int s = 0; s < kStrips; ++s) drawStrip(g, s);
        drawMaster(g);
    }

    void mouseDown(const juce::MouseEvent& e) override
    {
        active_.reset();
        for (auto it = zones_.rbegin(); it != zones_.rend(); ++it)
            if (it->area.contains(e.position)) { active_ = std::make_unique<Zone>(*it); break; }
        if (active_ == nullptr) return;
        Engine& engine = Engine::get();
        Zone& z = *active_;
        switch (z.kind)
        {
            case Zone::Knob: z.startValue = engine.value(z.param); break;
            case Zone::Fader: case Zone::Slider: drag(e); break;
            case Zone::Toggle: engine.set(z.param, engine.on(z.param) ? 0.0f : 1.0f); break;
            case Zone::Cycle: engine.setChoice(z.param, (engine.choice(z.param, z.count) + 1) % z.count, z.count); break;
            case Zone::Hold: engine.press(z.note); break;
            case Zone::Tap: engine.tap(z.note); break;
            case Zone::Call: if (z.call) z.call(); break;
        }
        repaint();
    }

    void mouseDrag(const juce::MouseEvent& e) override { if (active_ != nullptr) drag(e); }

    void mouseUp(const juce::MouseEvent&) override
    {
        if (active_ != nullptr && active_->kind == Zone::Hold) Engine::get().lift(active_->note);
        active_.reset();
    }

private:
    struct Zone
    {
        enum Kind { Knob, Fader, Slider, Toggle, Cycle, Hold, Tap, Call };
        juce::Rectangle<float> area;
        Kind kind = Call;
        int param = -1, count = 0, note = -1;
        float startValue = 0.0f;
        std::function<void()> call;
    };

    void drag(const juce::MouseEvent& e)
    {
        Engine& engine = Engine::get();
        const Zone& z = *active_;
        if (z.kind == Zone::Knob)
            engine.set(z.param, z.startValue - (float)e.getDistanceFromDragStartY() / 160.0f);
        else if (z.kind == Zone::Fader)
            engine.set(z.param, (z.area.getBottom() - 13.0f - e.position.y) / (z.area.getHeight() - 26.0f));
        else if (z.kind == Zone::Slider)
            engine.set(z.param, (e.position.x - z.area.getX()) / z.area.getWidth());
    }

    void zone(Zone::Kind kind, juce::Rectangle<float> area, int param, int count = 0, int note = -1)
    {
        if ((kind == Zone::Knob || kind == Zone::Fader || kind == Zone::Slider || kind == Zone::Toggle || kind == Zone::Cycle) && param < 0) return;
        Zone z;
        z.area = area; z.kind = kind; z.param = param; z.count = count; z.note = note;
        zones_.push_back(std::move(z));
    }
    void call(juce::Rectangle<float> area, std::function<void()> action)
    {
        Zone z;
        z.area = area; z.kind = Zone::Call; z.call = std::move(action);
        zones_.push_back(std::move(z));
    }

    // ---- Drawing bricks ----

    static void write(juce::Graphics& g, const juce::String& s, juce::Rectangle<float> r, const juce::Font& font,
                      juce::Colour colour, juce::Justification where = juce::Justification::centredLeft)
    {
        g.setColour(colour);
        g.setFont(font);
        g.drawText(s, r, where, true);
    }

    static void card(juce::Graphics& g, juce::Rectangle<float> r, juce::Colour fill, juce::Colour outline, float radius = 6.0f)
    {
        g.setColour(fill);
        g.fillRoundedRectangle(r, radius);
        g.setColour(outline);
        g.drawRoundedRectangle(r.reduced(0.5f), radius, 1.0f);
    }

    // A console button: outlined when off, a solid block of its colour when lit.
    static void button(juce::Graphics& g, juce::Rectangle<float> r, const juce::String& caption, bool lit,
                       juce::Colour litColour = look::text, float size = 11.5f, bool enabled = true)
    {
        if (lit) { g.setColour(litColour); g.fillRoundedRectangle(r, 3.0f); }
        else card(g, r, look::surface, look::border, 3.0f);
        write(g, caption, r, look::label(size), lit ? look::bg : enabled ? look::dim : look::border, juce::Justification::centred);
    }

    static void pill(juce::Graphics& g, juce::Rectangle<float> r, const juce::String& caption, bool lit, juce::Colour litColour)
    {
        if (lit) { g.setColour(litColour); g.fillRoundedRectangle(r, 3.0f); }
        else { g.setColour(look::border); g.drawRoundedRectangle(r.reduced(0.5f), 3.0f, 1.0f); }
        write(g, caption, r, look::mono(8.0f), lit ? look::bg : look::dim, juce::Justification::centred);
    }

    // A knob: a full arc of its bus's colour, a short needle. `value` < 0 draws an empty seat.
    static void knob(juce::Graphics& g, float cx, float cy, float radius, float value, juce::Colour colour)
    {
        const float from = -juce::MathConstants<float>::pi * 0.75f, to = juce::MathConstants<float>::pi * 0.75f;
        if (value < 0.0f)
        {
            g.setColour(look::border);
            const float dashes[2] = {3.0f, 4.0f};
            juce::Path ring, dashed;
            ring.addEllipse(cx - radius * 0.7f, cy - radius * 0.7f, radius * 1.4f, radius * 1.4f);
            juce::PathStrokeType(1.0f).createDashedStroke(dashed, ring, dashes, 2);
            g.fillPath(dashed);
            return;
        }
        juce::Path track;
        track.addCentredArc(cx, cy, radius, radius, 0.0f, from, to, true);
        g.setColour(look::border.brighter(0.07f));
        g.strokePath(track, juce::PathStrokeType(6.5f, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
        const float angle = from + (to - from) * juce::jlimit(0.0f, 1.0f, value);
        const bool open = value > 0.004f;
        if (open)
        {
            juce::Path arc;
            arc.addCentredArc(cx, cy, radius, radius, 0.0f, from, angle, true);
            g.setColour(colour);
            g.strokePath(arc, juce::PathStrokeType(6.5f, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
        }
        g.setColour(look::surface.brighter(0.04f));
        g.fillEllipse(cx - radius * 0.62f, cy - radius * 0.62f, radius * 1.24f, radius * 1.24f);
        const float nx = std::sin(angle), ny = -std::cos(angle);
        g.setColour(open ? colour : look::dim);
        g.drawLine(cx + nx * radius * 0.18f, cy + ny * radius * 0.18f, cx + nx * radius * 0.52f, cy + ny * radius * 0.52f, 3.0f);
    }

    static void fader(juce::Graphics& g, juce::Rectangle<float> r, float value)
    {
        const float cx = r.getCentreX();
        g.setColour(look::border);
        g.fillRoundedRectangle(cx - 2.0f, r.getY(), 4.0f, r.getHeight(), 2.0f);
        const float y = r.getBottom() - 13.0f - (r.getHeight() - 26.0f) * juce::jlimit(0.0f, 1.0f, value);
        const juce::Rectangle<float> cap(cx - 18.0f, y - 13.0f, 36.0f, 26.0f);
        g.setColour(look::text);
        g.fillRoundedRectangle(cap, 2.5f);
        g.setColour(look::bg);
        g.fillRect(cap.getX() + 2.0f, cap.getCentreY() - 1.0f, cap.getWidth() - 4.0f, 2.0f);
    }

    // Sage, then ochre, then red at the top.
    static void meter(juce::Graphics& g, juce::Rectangle<float> r, float value)
    {
        const int segments = 22;
        const float h = r.getHeight() / (float)segments;
        const int lit = (int)std::lround(juce::jlimit(0.0f, 1.0f, value) * (float)segments);
        for (int i = 0; i < segments; ++i)
        {
            const juce::Colour colour = i >= segments - 2 ? look::rec : i >= segments - 6 ? look::delay : look::reverb;
            g.setColour(i < lit ? colour : look::border.withAlpha(0.7f));
            g.fillRect(r.getX(), r.getBottom() - (float)(i + 1) * h + 1.0f, r.getWidth(), h - 2.0f);
        }
    }

    static void dot(juce::Graphics& g, float x, float y, juce::Colour colour)
    {
        g.setColour(colour);
        g.fillEllipse(x, y, 6.0f, 6.0f);
    }

    // ---- What a control is, on the current page ----

    static juce::Colour busColour(int bus) { return bus == fx::Delay ? look::delay : bus == fx::Reverb ? look::reverb : look::bus3; }

    juce::String bus3Name(bool brief = false) const
    {
        const Engine& engine = Engine::get();
        const bool flanger = engine.choice(engine.bus3Model, 2) == 1;
        return brief ? (flanger ? "FLG" : "PHS") : (flanger ? "FLANGER" : "PHASER");
    }
    juce::String busBrief(int bus) const { return bus == fx::Delay ? "DLY" : bus == fx::Reverb ? "REV" : bus3Name(true); }

    // The bus a bus's return is also sent to, or -1.
    int busTarget(int bus) const
    {
        const Engine& engine = Engine::get();
        const int which = engine.choice(engine.busTo[bus], 3);
        // The plugin's choices skip the bus itself: {-, the two other buses in order}.
        for (int b = 0, k = 0; b < fx::BusCount; ++b)
            if (b != bus && ++k == which) return b;
        return -1;
    }

    // Where a bus's return is also sent ("DLY>REV"), or "DLY>-" when nowhere.
    juce::String sendCaption(int bus) const
    {
        const int other = busTarget(bus);
        return busBrief(bus) + ">" + (other < 0 ? juce::String("-") : busBrief(other));
    }

    static juce::Colour effectColour(int p)
    {
        switch (fx::info(p).kernel)
        {
            case fx::DelayKernel: return look::delay;
            case fx::ReverbKernel: return look::reverb;
            case fx::Bus3Kernel: return look::bus3;
            case fx::NoKernel:
                if (p == fx::DelayReturn || p == fx::DelayToReverb || p == fx::SirenDelay || p == fx::SyndrumDelay) return look::delay;
                if (p == fx::ReverbReturn || p == fx::ReverbSend || p == fx::SirenReverb || p == fx::SyndrumReverb) return look::reverb;
                return look::bus3;
            default: return look::text;
        }
    }

    juce::String effectCaption(int p, bool onMixPage) const
    {
        if (p == fx::DelayToReverb) return sendCaption(fx::Delay);
        if (p == fx::ReverbSend) return sendCaption(fx::Reverb);
        if (p == fx::Bus3Send) return sendCaption(fx::Bus3);
        if (onMixPage)
        {
            if (p == fx::DelayTime) return "DLY SPEED";
            if (p == fx::DelayFeedback) return "DLY FEEDBACK";
            if (p == fx::ReverbDecay) return "REV LENGTH";
            if (p == fx::PhaserRate) return bus3Name(true) + " RATE";
        }
        if (p == fx::DelayReturn) return "DLY RETURN";
        if (p == fx::ReverbReturn) return "REV RETURN";
        if (p == fx::PhaserReturn) return bus3Name(true) + " RETURN";
        return fx::info(p).label;
    }

    // The header over a strip's knobs, and its colour, on the current page. Empty: a plain stem strip.
    juce::String stripHeader(int s, juce::Colour& colour) const
    {
        const Engine& engine = Engine::get();
        colour = look::text;
        switch (engine.currentPage())
        {
            case kMix:
                if (s == 6) { colour = look::delay; return "DELAY"; }
                if (s == 7) { colour = look::reverb; return "SPACE"; }
                if (engine.isInstrument(s)) { colour = look::rec; return s == 4 ? "SIREN" : "SYNDRUM"; }
                return {};
            case kFx:
                if (s < 2) { colour = look::delay; return "DELAY"; }
                if (s < 4) { colour = look::reverb; return "REVERB"; }
                if (s < 6) { colour = look::bus3; return bus3Name(); }
                return s == 6 ? "RETURNS" : "ROUTING";
            case kMaster:
                if (s == 0) return "BIG KNOB";
                if (s == 1) return "KILLS";
                if (s == 2) return "DUBPLATE";
                if (s == 3) { colour = look::delay; return "DELAY+"; }
                return {};
            default:
                if (s >= kStems) return {};
                switch (engine.choice(engine.insert[s], fx::insert::KindCount))
                {
                    case fx::insert::Sub: return "SUB";
                    case fx::insert::Wah: return "AUTO-WAH";
                    default: colour = look::dim; return "NO INSERT";
                }
        }
    }

    // ---- Sidebar: logo, session, setlist, status ----

    void drawSidebar(juce::Graphics& g)
    {
        const Engine& engine = Engine::get();
        g.setColour(look::border);
        g.fillRect(232.0f, 0.0f, 1.0f, (float)kHeight);

        const juce::Font logo = look::label(21.0f);
        float x = 18.0f;
        const std::pair<const char*, juce::Colour> parts[3] = {{"DUB", look::delay}, {"STEM", look::reverb}, {"MIX", look::bus3}};
        for (const auto& part : parts)
        {
            const float w = juce::GlyphArrangement::getStringWidth(logo, part.first);
            write(g, part.first, {x, 14.0f, w + 2.0f, 30.0f}, logo, part.second);
            x += w;
        }

        write(g, "NOW PLAYING", {18.0f, 62.0f, 200.0f, 12.0f}, look::mono(8.5f), look::dim);
        const juce::String title = engine.text(engine.nowPlaying);
        write(g, title.isEmpty() ? juce::String("NO SONG") : title.toUpperCase(), {18.0f, 74.0f, 204.0f, 18.0f}, look::label(12.5f), look::text);

        // Setlist: touch a song to play it next.
        write(g, "SETLIST", {18.0f, 124.0f, 100.0f, 12.0f}, look::mono(8.5f), look::dim);
        const juce::String pages = engine.text(engine.listPage);
        if (pages.fromLastOccurrenceOf("/", false, false).trim().getIntValue() > 1)
        {
            write(g, pages, {120.0f, 124.0f, 50.0f, 12.0f}, look::mono(8.5f), look::dim, juce::Justification::centredRight);
            pill(g, {176.0f, 122.0f, 18.0f, 16.0f}, "<", false, look::text);
            pill(g, {198.0f, 122.0f, 18.0f, 16.0f}, ">", false, look::text);
            call({176.0f, 122.0f, 18.0f, 16.0f}, [] { Engine::get().set(Engine::get().listPrev, 1.0f); });
            call({198.0f, 122.0f, 18.0f, 16.0f}, [] { Engine::get().set(Engine::get().listNext, 1.0f); });
        }
        float y = 146.0f;
        for (int i = 0; i < kSongSlots && y < 780.0f; ++i)
        {
            // Empty, Song, Played, Playing, Next, Played + next, Playing + next.
            const int slotState = engine.choice(engine.slot[i], 7);
            if (slotState == 0) continue;
            const bool current = slotState == 3 || slotState == 6, next = slotState >= 4, played = slotState == 2 || slotState == 5;
            const juce::Rectangle<float> row(18.0f, y, 196.0f, 38.0f);
            const juce::String line = engine.text(engine.title[i]);
            if (current) { g.setColour(look::text); g.fillRoundedRectangle(row, 3.0f); }
            if (next && !current) { g.setColour(look::delay); g.fillRect(row.getX(), row.getY() + 2.0f, 2.0f, row.getHeight() - 4.0f); }
            write(g, line.substring(0, 2), {row.getX() + 8.0f, y, 22.0f, 38.0f}, look::mono(9.0f), current ? look::bg.withAlpha(0.6f) : look::dim);
            write(g, line.substring(2).trim(), {row.getX() + 30.0f, y + 3.0f, 160.0f, 18.0f}, look::name(11.5f),
                  current ? look::bg : played ? look::dim : look::text);
            const juce::String note = current ? (next ? look::u("PLAYING · AGAIN NEXT") : "PLAYING") : next ? "NEXT" : played ? "PLAYED" : "";
            write(g, note, {row.getX() + 30.0f, y + 20.0f, 160.0f, 12.0f}, look::mono(8.0f),
                  current ? look::bg.withAlpha(0.7f) : next ? look::delay : look::dim);
            const int cue = engine.cue[i];
            call(row, [cue] { Engine::get().set(cue, 1.0f); });
            y += 42.0f;
        }

        // Status
        y = 818.0f;
        dot(g, 18.0f, y + 3.0f, status.consoleConnected ? look::reverb : look::rec);
        write(g, "MIDIMIX", {32.0f, y, 60.0f, 12.0f}, look::mono(8.5f), look::text);
        write(g, status.consoleConnected ? (status.consoleLeds ? "connected" : "connected, no LEDs") : "not found",
              {80.0f, y, 150.0f, 12.0f}, look::mono(8.5f), look::dim);
        y += 20.0f;
        const bool sound = status.soundError.isEmpty();
        dot(g, 18.0f, y + 3.0f, sound ? look::reverb : look::rec);
        write(g, "AUDIO", {32.0f, y, 60.0f, 12.0f}, look::mono(8.5f), look::text);
        write(g, sound ? status.card : status.soundError, {68.0f, y, 160.0f, 12.0f}, look::mono(8.5f), look::dim);
        write(g, sound ? status.cardDetail : juce::String(), {68.0f, y + 14.0f, 160.0f, 12.0f}, look::mono(8.5f), look::dim);
        y += 34.0f;
        const juce::String dropouts = juce::String(status.lateBuffers + engine.text(engine.underruns).getIntValue());
        dot(g, 18.0f, y + 3.0f, dropouts == "0" ? look::reverb : look::delay);
        write(g, "DSP", {32.0f, y, 60.0f, 12.0f}, look::mono(8.5f), look::text);
        write(g, juce::String((int)std::lround(status.load)) + look::u("% · ") + dropouts + " dropouts", {58.0f, y, 170.0f, 12.0f}, look::mono(8.5f), look::dim);
    }

    // ---- Top: transport, song, time left, sound card ----

    void drawTransport(juce::Graphics& g)
    {
        Engine& engine = Engine::get();
        const bool playing = engine.playing.load();

        const juce::Rectangle<float> play(250.0f, 22.0f, 46.0f, 40.0f), restart(302.0f, 22.0f, 46.0f, 40.0f);
        g.setColour(look::text);
        g.fillRoundedRectangle(play, 4.0f);
        g.setColour(look::bg);
        if (playing)
        {
            g.fillRect(play.getCentreX() - 7.0f, play.getCentreY() - 8.0f, 5.0f, 16.0f);
            g.fillRect(play.getCentreX() + 2.0f, play.getCentreY() - 8.0f, 5.0f, 16.0f);
        }
        else
        {
            juce::Path triangle;
            triangle.addTriangle(play.getCentreX() - 6.0f, play.getCentreY() - 9.0f, play.getCentreX() - 6.0f, play.getCentreY() + 9.0f,
                                 play.getCentreX() + 9.0f, play.getCentreY());
            g.fillPath(triangle);
        }
        call(play, [] { Engine::get().togglePlay(); });

        card(g, restart, look::surface, look::border, 4.0f);
        g.setColour(look::text);
        g.fillRect(restart.getCentreX() - 8.0f, restart.getCentreY() - 7.0f, 3.0f, 14.0f);
        juce::Path back;
        back.addTriangle(restart.getCentreX() + 7.0f, restart.getCentreY() - 7.0f, restart.getCentreX() + 7.0f, restart.getCentreY() + 7.0f,
                         restart.getCentreX() - 4.0f, restart.getCentreY());
        g.fillPath(back);
        call(restart, [] { Engine::get().restartSong(); });

        const juce::String title = engine.text(engine.nowPlaying);
        write(g, title.isEmpty() ? juce::String("NO SONG") : title.toUpperCase(), {366.0f, 20.0f, 700.0f, 24.0f}, look::label(17.0f), look::text);
        const juce::String left = engine.text(engine.timeLeft);
        write(g, engine.text(engine.state).toUpperCase() + look::u(" · ") + left + look::u(" · NEXT ") + engine.text(engine.next),
              {366.0f, 44.0f, 760.0f, 16.0f}, look::mono(11.0f), look::dim);

        const juce::Rectangle<float> sound(1262.0f, 22.0f, 160.0f, 40.0f);
        card(g, sound, look::surface, look::border, 4.0f);
        write(g, look::u("SOUND CARD…"), sound, look::label(11.5f), look::text, juce::Justification::centred);
        call(sound, [this] { if (onSoundCard) onSoundCard(); });

        // Waveform of the whole song, with the playhead; the last 30 s turn ochre (PRD § 5.6).
        const juce::Rectangle<float> bar(250.0f, 78.0f, 1172.0f, 78.0f);
        card(g, bar, look::surface, look::border);
        const int songs = waveforms_.songCount();
        const std::shared_ptr<const Waveform> wave = waveforms_.get(engine.choice(engine.nowPlaying, juce::jmax(2, songs)));
        if (wave == nullptr || wave->seconds <= 0.0)
        {
            if (songs > 0) write(g, "READING THE WAVEFORM", bar, look::mono(9.0f), look::dim, juce::Justification::centred);
            return;
        }
        // The engine only gives the time left, in whole seconds: the playhead glides between two ticks.
        const int secondsLeft = left.fromFirstOccurrenceOf("-", false, false).upToFirstOccurrenceOf(":", false, false).getIntValue() * 60
                                + left.fromLastOccurrenceOf(":", false, false).getIntValue();
        const double now = juce::Time::getMillisecondCounterHiRes() * 0.001;
        if (secondsLeft != lastSecondsLeft_) { lastSecondsLeft_ = secondsLeft; lastTick_ = now; }
        const bool running = playing && engine.choice(engine.state, 4) == 1;
        const double position = juce::jlimit(0.0, wave->seconds, wave->seconds - secondsLeft + (running ? juce::jmin(0.98, now - lastTick_) : 0.0));
        const float done = (float)(position / wave->seconds);
        const juce::Rectangle<float> area = bar.reduced(2.0f, 6.0f);
        const float pitch = area.getWidth() / (float)Waveforms::kBars;
        const double lastThirty = wave->seconds - 30.0;
        for (int i = 0; i < Waveforms::kBars; ++i)
        {
            const float at = ((float)i + 0.5f) / (float)Waveforms::kBars;
            const float h = juce::jmax(1.5f, wave->peaks[(size_t)i] * area.getHeight() * 0.92f);
            const bool ending = at * wave->seconds >= lastThirty;
            const juce::Colour colour = ending ? look::delay : look::text;
            g.setColour(at <= done ? colour : colour.withAlpha(ending ? 0.45f : 0.28f));
            g.fillRect(area.getX() + (float)i * pitch, area.getCentreY() - h * 0.5f, juce::jmax(1.0f, pitch - 1.0f), h);
        }
        g.setColour(look::delay);
        g.fillRect(area.getX() + area.getWidth() * done - 1.0f, bar.getY() + 1.0f, 2.0f, bar.getHeight() - 2.0f);
    }

    // ---- The three bus cards ----

    void drawBuses(juce::Graphics& g)
    {
        Engine& engine = Engine::get();
        const juce::String titles[3] = {"DELAY", "REVERB", bus3Name()};
        const juce::String models[3] = {"Dub Delay", engine.choice(engine.reverbModel, 2) == 1 ? "Spring" : "Plate",
                                        engine.choice(engine.bus3Model, 2) == 1 ? "Tape Flanger" : "Bi-Phaser"};
        const juce::String summaries[3] = {
            engine.text(engine.effect[fx::DelayTime]) + look::u(" · FB ") + engine.text(engine.effect[fx::DelayFeedback]),
            "decay " + engine.text(engine.effect[fx::ReverbDecay]),
            engine.text(engine.effect[fx::PhaserRate]) + look::u(" · depth ") + engine.text(engine.effect[fx::PhaserDepth])};
        for (int b = 0; b < fx::BusCount; ++b)
        {
            const juce::Colour colour = busColour(b);
            const juce::Rectangle<float> r(250.0f + (float)b * 393.0f, 170.0f, 386.0f, 64.0f);
            card(g, r, colour.withAlpha(0.10f).overlaidWith(look::surface.withAlpha(0.6f)), colour.withAlpha(0.55f));
            g.setColour(colour);
            g.fillRoundedRectangle(r.getX() + 12.0f, r.getY() + 12.0f, 4.0f, 40.0f, 2.0f);
            write(g, titles[b], {r.getX() + 28.0f, r.getY() + 10.0f, 90.0f, 18.0f}, look::label(12.5f), colour);
            write(g, models[b], {r.getX() + 28.0f, r.getY() + 32.0f, 120.0f, 20.0f}, look::name(12.5f), look::dim);
            if (b == fx::Reverb) zone(Zone::Cycle, {r.getX() + 28.0f, r.getY() + 30.0f, 120.0f, 24.0f}, engine.reverbModel, 2);
            if (b == fx::Bus3) zone(Zone::Cycle, {r.getX() + 28.0f, r.getY() + 30.0f, 120.0f, 24.0f}, engine.bus3Model, 2);

            // Where this bus's return also goes (bus-to-bus sends, PRD § 5.3): touch to change.
            float x = r.getX() + 118.0f;
            const juce::Rectangle<float> to(x, r.getY() + 11.0f, 66.0f, 16.0f);
            pill(g, to, "TO " + sendCaption(b).fromFirstOccurrenceOf(">", false, false), engine.choice(engine.busTo[b], 3) != 0, colour);
            zone(Zone::Cycle, to, engine.busTo[b], 3);
            x += 72.0f;
            if (b == fx::Delay)
            {
                const juce::Rectangle<float> sync(x, r.getY() + 11.0f, 40.0f, 16.0f);
                pill(g, sync, "SYNC", engine.on(engine.delaySync), colour);
                zone(Zone::Toggle, sync, engine.delaySync);
                const juce::Rectangle<float> target(r.getX() + 152.0f, r.getY() + 34.0f, 104.0f, 16.0f);
                const char* targets[3] = {"THROW > DLY", "THROW > REV", "THROW > BOTH"};
                pill(g, target, targets[engine.choice(engine.throwTarget, 3)], false, colour);
                zone(Zone::Cycle, target, engine.throwTarget, 3);
            }
            write(g, summaries[b], {r.getRight() - 190.0f, r.getY() + 10.0f, 178.0f, 18.0f}, look::mono(10.0f), look::dim, juce::Justification::centredRight);
        }

        // Bus-to-bus sends drawn as cables (PRD § 5.3): from the source card's output socket to the target
        // card's input socket, dashed while the send knob is at zero.
        auto socket = [&g](float x, juce::Colour colour)
        {
            g.setColour(look::bg);
            g.fillEllipse(x - 4.0f, 230.0f, 8.0f, 8.0f);
            g.setColour(colour);
            g.drawEllipse(x - 3.5f, 230.5f, 7.0f, 7.0f, 1.5f);
        };
        for (int b = 0; b < fx::BusCount; ++b)
        {
            const int target = busTarget(b);
            if (target < 0) continue;
            const juce::Colour colour = busColour(b);
            const float from = 250.0f + (float)b * 393.0f + 240.0f, to = 250.0f + (float)target * 393.0f + 147.0f;
            juce::Path cable;
            cable.startNewSubPath(from, 234.0f);
            cable.quadraticTo((from + to) * 0.5f, 234.0f + 24.0f, to, 234.0f);
            if (engine.value(engine.effect[fx::kBusSend[b]]) > 0.004f)
            {
                g.setColour(colour);
                g.strokePath(cable, juce::PathStrokeType(2.0f, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
            }
            else
            {
                const float dashes[2] = {4.0f, 4.0f};
                juce::Path dashed;
                juce::PathStrokeType(1.5f).createDashedStroke(dashed, cable, dashes, 2);
                g.setColour(colour.withAlpha(0.7f));
                g.fillPath(dashed);
            }
            socket(from, colour);
            socket(to, colour);
        }
    }

    // ---- Left of the strips: what the three knob rows are ----

    void drawRowLabels(juce::Graphics& g)
    {
        const bool mix = Engine::get().currentPage() == kMix;
        const juce::String names[3] = {"DELAY", "REVERB", bus3Name()};
        const char* rows[3] = {"TOP", "MID", "LOW"};
        for (int row = 0; row < 3; ++row)
        {
            const float y = 310.0f + (float)row * 92.0f;
            if (!mix) { write(g, rows[row], {250.0f, y + 8.0f, 70.0f, 12.0f}, look::mono(8.5f), look::dim); continue; }
            g.setColour(busColour(row));
            g.fillRect(250.0f, y - 4.0f, 22.0f, 3.0f);
            write(g, names[row], {250.0f, y + 2.0f, 76.0f, 16.0f}, look::label(11.0f), busColour(row));
            write(g, "SEND", {250.0f, y + 18.0f, 70.0f, 12.0f}, look::mono(8.0f), look::dim);
        }
    }

    // ---- A strip: 1-6 stems (or the siren / Syndrum), 7-8 the effects ----

    static juce::Rectangle<float> stripBounds(int s)
    {
        if (s < kStems) return {329.0f + (float)s * 122.0f, 248.0f, 114.0f, 634.0f};
        return s == 6 ? juce::Rectangle<float>(1074.0f, 248.0f, 100.0f, 634.0f) : juce::Rectangle<float>(1182.0f, 248.0f, 114.0f, 634.0f);
    }

    void drawStrip(juce::Graphics& g, int s)
    {
        Engine& engine = Engine::get();
        const int page = engine.currentPage();
        const bool isEffect = s >= kStems, isInstrument = engine.isInstrument(s);
        const juce::Rectangle<float> r = stripBounds(s);
        const float cx = r.getCentreX();
        const juce::Colour tint = s == 6 ? look::delay : s == 7 ? look::reverb : look::border;
        card(g, r, isEffect ? tint.withAlpha(0.07f).overlaidWith(look::surface.withAlpha(0.7f)) : look::surface,
             isEffect ? tint.withAlpha(0.45f) : look::border);

        // Header: the strip's number, and what its knobs drive on this page.
        juce::Colour headColour;
        const juce::String head = stripHeader(s, headColour);
        if (head.isEmpty()) write(g, juce::String(s + 1), {r.getX(), r.getY() + 14.0f, r.getWidth(), 16.0f}, look::mono(9.5f), look::dim, juce::Justification::centred);
        else
        {
            const juce::Font font = look::label(10.5f);
            const float w = juce::GlyphArrangement::getStringWidth(font, head);
            const float x0 = cx - (w + 12.0f) * 0.5f;
            write(g, juce::String(s + 1), {x0, r.getY() + 14.0f, 10.0f, 16.0f}, look::mono(9.5f), look::dim);
            write(g, head, {x0 + 12.0f, r.getY() + 14.0f, w + 4.0f, 16.0f}, font, headColour);
        }
        if (page != kMix && head.isNotEmpty() && headColour != look::dim)
            card(g, {r.getX() + 9.0f, r.getY() + 38.0f, r.getWidth() - 18.0f, 276.0f}, headColour.withAlpha(0.07f), headColour.withAlpha(0.35f), 4.0f);

        // Knobs
        for (int row = 0; row < 3; ++row)
        {
            const float cy = r.getY() + 74.0f + (float)row * 92.0f;
            const int target = engine.knobTarget(s, row);
            if (target < 0) { knob(g, cx, cy, 30.0f, -1.0f, look::border); continue; }
            const int effect = engine.knobEffect(s, row);
            const bool plainSend = page == kMix && !isEffect && !isInstrument;
            const juce::Colour colour = plainSend ? busColour(row) : effect != fx::None ? effectColour(effect) : look::text;
            knob(g, cx, cy, plainSend ? 30.0f : 24.0f, engine.value(target), colour);
            zone(Zone::Knob, {cx - 36.0f, cy - 36.0f, 72.0f, 72.0f}, target);
            juce::String value = engine.text(target);
            if (plainSend)
                write(g, value.upToFirstOccurrenceOf(" ", false, false), {r.getX(), cy + 36.0f, r.getWidth(), 14.0f}, look::mono(9.5f), look::text, juce::Justification::centred);
            else
            {
                const juce::String caption = effect != fx::None ? effectCaption(effect, page == kMix)
                                             : juce::String(fx::insert::knob(engine.choice(engine.insert[s], fx::insert::KindCount), row).label);
                write(g, caption, {r.getX(), cy + 26.0f, r.getWidth(), 13.0f}, look::label(8.5f), colour, juce::Justification::centred);
                write(g, value, {r.getX(), cy + 39.0f, r.getWidth(), 13.0f}, look::mono(9.0f), look::text, juce::Justification::centred);
            }
        }

        // Name
        const juce::String name = s == 6 ? "DELAY" : s == 7 ? "SPACE" : engine.text(engine.name[s]);
        const juce::Colour nameColour = s == 6 ? look::delay : s == 7 ? look::reverb : isInstrument ? look::rec : look::text;
        write(g, name, {r.getX() + 4.0f, r.getY() + 318.0f, r.getWidth() - 8.0f, 20.0f}, look::label(13.0f), nameColour, juce::Justification::centred);

        // Buttons: the console's MUTE and REC ARM, under the names they have on this strip.
        const juce::Rectangle<float> first(r.getX() + 10.0f, r.getY() + 342.0f, r.getWidth() - 20.0f, 30.0f);
        const juce::Rectangle<float> second = first.translated(0.0f, 36.0f);
        const juce::Rectangle<float> third(r.getX() + 10.0f, r.getY() + 414.0f, r.getWidth() - 20.0f, 18.0f);
        const bool lampM = engine.on(engine.lampMute[s]), lampR = engine.on(engine.lampRec[s]);
        if (isEffect || isInstrument)
        {
            const char* firstNames[4] = {"HOLD", "HIT", "HOLD", "FX ONLY"};
            const juce::String secondNames[4] = {"RISE", "ROLL", look::u("×2"), "TAPE STOP"};
            const int which = s - 4;
            const juce::Colour lit = isInstrument ? look::rec : tint;
            button(g, first, firstNames[which], lampM, lit);
            zone(Zone::Hold, first, -1, 0, muteNote(s));
            button(g, second, secondNames[which], lampR, lit);
            zone(Zone::Hold, second, -1, 0, recArmNote(s));
            if (isInstrument)
            {
                // The siren's wave and the Syndrum's roll value: on the screen only (PRD § 15).
                const int p = engine.effect[s == 4 ? fx::SirenWave : fx::SyndrumRoll];
                pill(g, third, (s == 4 ? juce::String() : juce::String("ROLL ")) + engine.text(p), false, look::text);
                const int steps = s == 4 ? 2 : fx::kRollCount;
                call(third, [p, steps]
                {
                    Engine& e = Engine::get();
                    const int now = fx::step(e.value(p), steps);
                    e.set(p, ((float)((now + 1) % steps) + 0.5f) / (float)steps);
                });
            }
        }
        else
        {
            const bool soloed = engine.on(engine.solo[s]);
            button(g, first, soloed ? "SOLO" : "MUTE", lampM || soloed, soloed ? look::reverb : look::text);
            zone(Zone::Toggle, first, soloMode_ ? engine.solo[s] : engine.mute[s]);
            button(g, second, "THROW", lampR, look::delay);
            zone(Zone::Hold, second, -1, 0, recArmNote(s));
            if (page == kInserts)
            {
                const juce::String kinds[3] = {look::u("INSERT · NONE"), look::u("INSERT · SUB"), look::u("INSERT · WAH")};
                const int kind = engine.choice(engine.insert[s], fx::insert::KindCount);
                pill(g, third, kinds[kind], kind != fx::insert::None, look::text);
                zone(Zone::Cycle, third, engine.insert[s], fx::insert::KindCount);
            }
            else
            {
                pill(g, third, "KEEP", engine.on(engine.keep[s]), look::text);
                zone(Zone::Toggle, third, engine.keep[s]);
            }
        }

        // Fader and meter
        const juce::Rectangle<float> track(cx - 32.0f, r.getY() + 444.0f, 40.0f, 132.0f);
        const int faderParam = engine.faderTarget(s);
        fader(g, track, engine.value(faderParam));
        zone(Zone::Fader, track.expanded(6.0f, 0.0f), faderParam);
        meter(g, {cx + 18.0f, r.getY() + 444.0f, 8.0f, 132.0f}, engine.value(engine.meter[s]));

        // Foot
        const float footY = r.getY() + 588.0f;
        if (isEffect)
        {
            write(g, s == 6 ? "DLY RETURN" : "REV RETURN", {r.getX(), footY, r.getWidth(), 12.0f}, look::mono(8.5f), look::dim, juce::Justification::centred);
            write(g, engine.text(faderParam), {r.getX(), footY + 14.0f, r.getWidth(), 12.0f}, look::mono(8.5f), look::text, juce::Justification::centred);
        }
        else if (isInstrument)
        {
            // Reverb and bus 3 sends of the instrument: with the mouse only (PRD § 15).
            for (int i = 0; i < 2; ++i)
            {
                const int p = engine.effect[fx::kInstrumentSends[s - 4][i + 1]];
                const float y = footY + (float)i * 14.0f;
                write(g, busBrief(i + 1), {r.getX() + 10.0f, y, 26.0f, 10.0f}, look::mono(8.0f), busColour(i + 1));
                const juce::Rectangle<float> bar(r.getX() + 38.0f, y + 3.0f, r.getWidth() - 50.0f, 4.0f);
                g.setColour(look::border);
                g.fillRoundedRectangle(bar, 2.0f);
                g.setColour(busColour(i + 1));
                g.fillRoundedRectangle(bar.withWidth(bar.getWidth() * engine.value(p)), 2.0f);
                zone(Zone::Slider, bar.expanded(0.0f, 5.0f), p);
            }
        }
        else
            write(g, engine.text(faderParam), {r.getX(), footY, r.getWidth(), 12.0f}, look::mono(8.5f), look::dim, juce::Justification::centred);
    }

    // ---- Master column: pages, gestures, master fader ----

    void drawMaster(juce::Graphics& g)
    {
        Engine& engine = Engine::get();
        const juce::Rectangle<float> r(1304.0f, 248.0f, 118.0f, 634.0f);
        card(g, r, look::surface, look::dim.withAlpha(0.5f));
        write(g, "OUT", {r.getX(), r.getY() + 14.0f, r.getWidth(), 12.0f}, look::mono(8.5f), look::dim, juce::Justification::centred);
        write(g, "MASTER", {r.getX(), r.getY() + 26.0f, r.getWidth(), 20.0f}, look::label(14.0f), look::text, juce::Justification::centred);

        write(g, "PAGE", {r.getX() + 12.0f, r.getY() + 46.0f, 60.0f, 12.0f}, look::mono(8.0f), look::dim);
        const char* pages[4] = {"MIX", "FX", "MASTER", "INSERTS"};
        const int page = engine.currentPage();
        for (int p = 0; p < 4; ++p)
        {
            const juce::Rectangle<float> b(r.getX() + 11.0f, r.getY() + 64.0f + (float)p * 36.0f, r.getWidth() - 22.0f, 30.0f);
            button(g, b, pages[p], p == page);
            call(b, [p] { Engine::get().showPage(p); });
        }

        write(g, "GESTURES", {r.getX() + 12.0f, r.getY() + 216.0f, 80.0f, 12.0f}, look::mono(8.0f), look::dim);
        const bool spring = engine.choice(engine.reverbModel, 2) == 1;
        struct Gesture { const char* caption; Zone::Kind kind; int note; bool lit; bool enabled; };
        const Gesture gestures[4] = {{"DROP", Zone::Hold, kDropNote, false, true},
                                     {"REWIND", Zone::Tap, kRewindNote, false, true},
                                     {"HOLD", Zone::Hold, muteNote(6), engine.on(engine.lampMute[6]), true},
                                     {"CRASH", Zone::Tap, kCrashNote, false, spring}};   // the spring only (PRD § 11.4)
        for (int i = 0; i < 4; ++i)
        {
            const juce::Rectangle<float> b(r.getX() + 11.0f, r.getY() + 234.0f + (float)i * 36.0f, r.getWidth() - 22.0f, 30.0f);
            button(g, b, gestures[i].caption, gestures[i].lit, look::delay, 11.5f, gestures[i].enabled);
            if (gestures[i].enabled) zone(gestures[i].kind, b, -1, 0, gestures[i].note);
        }
        const juce::Rectangle<float> solo(r.getX() + 11.0f, r.getY() + 384.0f, r.getWidth() - 22.0f, 30.0f);
        button(g, solo, "SOLO", soloMode_, look::reverb);
        call(solo, [this] { soloMode_ = !soloMode_; });

        const juce::Rectangle<float> track(r.getCentreX() - 20.0f, r.getY() + 444.0f, 40.0f, 132.0f);
        fader(g, track, engine.value(engine.master));
        zone(Zone::Fader, track.expanded(6.0f, 0.0f), engine.master);
        write(g, engine.text(engine.master), {r.getX(), r.getY() + 588.0f, r.getWidth(), 12.0f}, look::mono(8.5f), look::dim, juce::Justification::centred);
    }

    std::vector<Zone> zones_;
    std::unique_ptr<Zone> active_;
    bool soloMode_ = false;
    Waveforms waveforms_;
    int lastSecondsLeft_ = -1;
    double lastTick_ = 0.0;
};

} // namespace dsm
