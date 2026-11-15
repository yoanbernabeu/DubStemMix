// DubStemMix.cpp - DubStemMix for MPC (PRD § 16): the Mac app's dub console, played with an Akai MIDImix
// plugged into the MPC, on stems read from the plugin's Content/Songs folder.
//
// SPDX-License-Identifier: MIT
//
// Signal flow (the Mac app's gain structure, AudioEngine.swift):
//
//   strip 1..6: stem (or, on an empty strip 5 / 6, the siren / Syndrum)
//     -> fader (fader^2.5 x 0.5 headroom, 0 while muted)
//          -> master (closed while FX ONLY is held)
//          -> post-fader sends to the DELAY, REVERB and BUS 3 buses (knob^2)
//     -> dub throw (REC ARM held): pre-fader, at full send, to the delay (or reverb, or both)
//   bus: send sum + the other buses' returns (bus-to-bus sends, one chunk late) -> effect, 100 % wet
//     -> return level (knob^2) -> master
//   master: sum x master fader x 0.5 headroom -> +6 dB make-up -> safety limiter -> out
//
// MIDImix (factory mapping), same as on the Mac:
//   MIX page: knobs = sends DLY / REV / PHS on strips 1-6; strips 5-6 empty = siren / Syndrum (pitch, rate or
//   decay, delay send); strip 7 = delay (speed, feedback, reverb length), strip 8 = space (phaser rate, DLY>,
//   REV>). Faders = strip levels; faders 7-8 = delay and reverb returns on every page; master fader = master.
//   MUTE = mute (toggle); REC ARM held = dub throw. Strip 7: MUTE held = HOLD, REC ARM held = x2.
//   Strip 8: MUTE held = FX ONLY, REC ARM held = TAPE STOP. Siren: MUTE held sounds, REC ARM held rises.
//   Syndrum: MUTE hits, REC ARM held rolls. BANK RIGHT = FX page, BANK LEFT = MIX, both = PANIC.
//   Knobs catch up with the value before acting (soft takeover), as on the Mac.
//
// MPC transport: STOP pauses, PLAY resumes, PLAY START jumps to the next song (stopped or playing);
// at the end of a song the next one starts. Effects and instruments keep sounding while stopped.

#include "mpc_plugin.h"

#include "DubDSP.h"
#include "FX.h"
#include "Stems.h"

#include <chrono>
#include <thread>

using stems::StemRing;
using stems::Song;
using stems::WavReader;
using stems::kChunkFrames;
using stems::kRingFrames;

namespace {

constexpr int kStemStrips = 6;
constexpr int kSurfaceStrips = 8;
constexpr int kFirstInstrumentStrip = 4;   // strips 5 and 6
constexpr int kFirstEffectStrip = 6;       // strips 7 and 8

// MIDImix factory mapping: first knob CC of each strip (the fader is +3), MUTE / SOLO / REC ARM notes.
constexpr int kStripCC[kSurfaceStrips] = {16, 20, 24, 28, 46, 50, 54, 58};
constexpr int kMasterCC = 62;
constexpr int kBankLeft = 25, kBankRight = 26;

constexpr float kHeadroom = 0.5f;       // per strip and on the master, given back by the make-up gain
constexpr float kMakeup = 2.0f;         // +6 dB
constexpr float kPickupWindow = 0.04f;
constexpr double kPanicWindow = 1.5;    // seconds between the two BANK buttons
constexpr int kMaxChunk = 512;

// Choice index -> bus, for each source's target menu (DLY> to, REV> to, PHS> to).
constexpr int kBusTargets[3][3] = {{-1, fx::Reverb, fx::Bus3}, {-1, fx::Delay, fx::Bus3}, {-1, fx::Delay, fx::Reverb}};

float faderGain(float position) { return std::pow(std::fmax(0.0f, position), 2.5f); }

// A gain that glides to its target over a few milliseconds, per sample (no zipper noise).
struct Glide
{
    float value = 0, target = 0;
    float next(float a) { value += (target - value) * a; return value; }
};

// A physical control that is not motorised: its last known position, and whether it holds the value.
struct Physical
{
    float value = -1;   // < 0: unknown
    bool picked = true;
};

} // namespace

class DubStemMix : public mpc::Plugin
{
public:
    // Parameter indices. Never reorder: MPC projects store them. Append only.
    enum Params
    {
        kMaster = 0,
        kStripBase = 1,                                   // per stem strip: fader, mute, send DLY, REV, PHS
        kFxBase = kStripBase + kStemStrips * 5,           // fx::Param order
        kDelaySync = kFxBase + fx::Count,
        kReverbModel, kBus3Model, kThrowTarget, kDelayTo, kReverbTo, kBus3To,
        kPage,
        kName1, kMode5 = kName1 + kStemStrips, kMode6,
        kLampMute1, kLampRec1 = kLampMute1 + kSurfaceStrips, kMeter1 = kLampRec1 + kSurfaceStrips,
        kNext = kMeter1 + kSurfaceStrips, kPlaying, kState, kTimeLeft, kStart, kStartPos, kLastCC, kLastNote,
        kCpu, kUnderruns,
        kNumParams
    };
    static int fader(int s) { return kStripBase + s * 5; }
    static int mute(int s) { return kStripBase + s * 5 + 1; }
    static int send(int s, int bus) { return kStripBase + s * 5 + 2 + bus; }
    static int fxParam(int p) { return kFxBase + p; }

    enum Page { kMix, kFx };
    enum State { kStopped, kRunning, kLoading, kEnded };
    enum Start { kNoStart, kStartPlay, kStartPlayStart };
    enum Gesture { kHold, kDouble, kFxOnly, kTapeStop, kSiren, kRise, kRoll, kGestureCount };

    static mpc::PluginInfo makeInfo()
    {
        mpc::PluginInfo i;
        i.name = "DubStemMix";
        i.vendor = "YoanDev";
        i.uniqueId = MPC_FOURCC('D', 's', 'M', 'x');   // == "uid" in plugin.json
        i.version = 2;
        i.isInstrument = true;
        i.numInputs = 0;
        i.numOutputs = 2;
        return i;
    }

    DubStemMix() : mpc::Plugin(makeInfo())
    {
        scanSongs();
        std::vector<std::string> names;
        for (const Song& s : songs_) names.push_back(s.name);
        if (names.empty()) names.push_back("(no songs)");
        if (names.size() == 1) names.push_back("-");   // a choice needs two entries

        // Parameter 0 is nudged by the host on load: the master volume is harmless.
        addParam(mpc::floatParam("master", "Master", 0.0f, 1.0f, 0.8f));
        for (int s = 0; s < kStemStrips; ++s)
        {
            const std::string n = std::to_string(s + 1);
            addParam(mpc::floatParam(("fader" + n).c_str(), ("Fader " + n).c_str(), 0.0f, 1.0f, 0.8f));
            addParam(mpc::boolParam(("mute" + n).c_str(), ("Mute " + n).c_str(), false));
            addParam(mpc::floatParam(("dly" + n).c_str(), ("DLY " + n).c_str(), 0.0f, 1.0f, 0.0f));
            addParam(mpc::floatParam(("rev" + n).c_str(), ("REV " + n).c_str(), 0.0f, 1.0f, 0.0f));
            addParam(mpc::floatParam(("phs" + n).c_str(), ("PHS " + n).c_str(), 0.0f, 1.0f, 0.0f));
        }
        for (int p = 0; p < fx::Count; ++p)
            addParam(mpc::floatParam(fx::info(p).id, fx::info(p).label, 0.0f, 1.0f, fx::info(p).def));
        addParam(mpc::boolParam("delaySync", "Delay sync", false));
        addParam(mpc::choiceParam("reverbModel", "Reverb", {"Plate", "Spring"}, 0));
        addParam(mpc::choiceParam("bus3Model", "Bus 3", {"Phaser", "Flanger"}, 0));
        addParam(mpc::choiceParam("throwTarget", "Throw", {"Delay", "Reverb", "Both"}, 0));
        addParam(mpc::choiceParam("delayTo", "DLY> to", {"-", "REV", "PHS"}, 1));
        addParam(mpc::choiceParam("reverbTo", "REV> to", {"-", "DLY", "PHS"}, 2));
        addParam(mpc::choiceParam("bus3To", "PHS> to", {"-", "DLY", "REV"}, 0));
        // Read-only displays, written by the plugin.
        addParam(mpc::choiceParam("page", "Page", {"MIX", "FX"}, 0));
        for (int s = 0; s < kStemStrips; ++s)
            addParam(mpc::intParam(("name" + std::to_string(s + 1)).c_str(), ("Name " + std::to_string(s + 1)).c_str(), 0, 999, 0));
        addParam(mpc::choiceParam("mode5", "Strip 5", {"Stem", "Siren"}, 1));
        addParam(mpc::choiceParam("mode6", "Strip 6", {"Stem", "Syndrum"}, 1));
        for (int s = 0; s < kSurfaceStrips; ++s)
            addParam(mpc::boolParam(("lampMute" + std::to_string(s + 1)).c_str(), ("Lamp M" + std::to_string(s + 1)).c_str(), false));
        for (int s = 0; s < kSurfaceStrips; ++s)
            addParam(mpc::boolParam(("lampRec" + std::to_string(s + 1)).c_str(), ("Lamp R" + std::to_string(s + 1)).c_str(), false));
        for (int s = 0; s < kSurfaceStrips; ++s)
            addParam(mpc::floatParam(("meter" + std::to_string(s + 1)).c_str(), ("Meter " + std::to_string(s + 1)).c_str(), 0.0f, 1.0f, 0.0f));
        addParam(mpc::choiceParam("next", "Next", names, songs_.size() > 1 ? 1 : 0));
        addParam(mpc::choiceParam("playing", "Playing", names, 0));
        addParam(mpc::choiceParam("state", "State", {"Stopped", "Playing", "Loading", "Ended"}, 0));
        addParam(mpc::floatParam("timeLeft", "Time left", 0.0f, 7200.0f, 0.0f, "", 0));
        addParam(mpc::choiceParam("start", "Last start", {"-", "PLAY", "PLAY START"}, 0));
        addParam(mpc::floatParam("startpos", "Start pos", 0.0f, 1024.0f, 0.0f, "beats", 2));
        addParam(mpc::intParam("lastcc", "Last CC", -1, 127, -1));
        addParam(mpc::intParam("lastnote", "Last note", -1, 127, -1));
        addParam(mpc::floatParam("cpu", "CPU", 0.0f, 100.0f, 0.0f, "%", 1));
        addParam(mpc::intParam("underruns", "Underruns", 0, 99999, 0));

        for (int i = 0; i < kNumParams; ++i) seen_[i] = get(i);
        for (float& v : applied_) v = -1;
        // Effect and instrument knobs never jump at the first touch: they catch up with the value first.
        for (int s = kFirstInstrumentStrip; s < kSurfaceStrips; ++s)
            for (Physical& k : knobs_[s]) k.picked = false;
        for (int s = kFirstEffectStrip; s < kSurfaceStrips; ++s) faders_[s].picked = false;

        delay_ = dub_effect_create(DUB_EFFECT_DELAY);
        reverb_ = dub_effect_create(DUB_EFFECT_REVERB_BUS);
        bus3_ = dub_effect_create(DUB_EFFECT_BUS3);
        siren_ = dub_effect_create(DUB_EFFECT_SIREN);
        syndrum_ = dub_effect_create(DUB_EFFECT_SYNDRUM);
        limiter_ = dub_effect_create(DUB_EFFECT_LIMITER);

        if (!songs_.empty()) loadSong(0);
        disk_ = std::thread([this] { diskLoop(); });
    }

    ~DubStemMix() override
    {
        quit_.store(true);
        if (disk_.joinable()) disk_.join();
        for (DubEffect* e : {delay_, reverb_, bus3_, siren_, syndrum_, limiter_}) dub_effect_destroy(e);
    }

    void prepare(double sampleRate, int) override
    {
        sampleRate_ = sampleRate;
        for (DubEffect* e : {delay_, reverb_, bus3_, siren_, syndrum_, limiter_})
            if (e) dub_effect_prepare(e, sampleRate);
        glide_ = 1.0f - std::exp(-1.0f / (0.005f * (float)sampleRate));   // ~5 ms
        for (float& v : applied_) v = -1;   // push every effect setting again
    }

    bool formatValue(int index, float v, std::string& out) override
    {
        char buf[48];
        if (index == kMaster || (index >= kStripBase && index < kFxBase && (index - kStripBase) % 5 == 0))
        {
            const float g = faderGain(v);
            if (g <= 0.00001f) out = "-inf dB";
            else { std::snprintf(buf, sizeof buf, "%.1f dB", 20.0f * std::log10(g)); out = buf; }
            return true;
        }
        if (index >= kStripBase && index < kFxBase && (index - kStripBase) % 5 >= 2)
        {
            std::snprintf(buf, sizeof buf, "%d %%", (int)std::lround(v * 100));
            out = buf;
            return true;
        }
        if (index >= kFxBase && index < kFxBase + fx::Count)
        {
            out = fx::display(index - kFxBase, v, getBool(kDelaySync), bpm_.load(std::memory_order_relaxed));
            return true;
        }
        if (index >= kName1 && index < kName1 + kStemStrips)
        {
            out = stripLabel((int)std::lround(v), index - kName1);
            return true;
        }
        if (index == kTimeLeft)
        {
            std::snprintf(buf, sizeof buf, "-%d:%02d", (int)v / 60, (int)v % 60);
            out = buf;
            return true;
        }
        if ((index == kLastCC || index == kLastNote) && v < 0) { out = "-"; return true; }
        return false;
    }

    void process(mpc::ProcessContext& ctx) override
    {
        const double t0 = stems::nowSeconds();
        clock_ += ctx.numFrames;
        if (ctx.transport.tempoValid && ctx.transport.bpm > 0) bpm_.store(ctx.transport.bpm, std::memory_order_relaxed);

        followScreen();
        handleMidi(ctx);
        handleTransport(ctx.transport, ctx.numFrames);
        updateSong();
        applyEffects();

        for (int done = 0; done < ctx.numFrames;)
        {
            const int n = std::min(kMaxChunk, ctx.numFrames - done);
            render(ctx.outputs[0] + done, ctx.outputs[1] + done, n);
            done += n;
        }

        const double load = (stems::nowSeconds() - t0) / ((double)ctx.numFrames / sampleRate_) * 100.0;
        cpu_ += (float)(load - cpu_) * 0.02f;
        refreshDisplays(ctx.numFrames);
    }

private:
    // ------------------------------------------------------------------------------------------------
    // Console (MixController.swift)
    // ------------------------------------------------------------------------------------------------

    // Writes a parameter from the console or the plugin, tells the screen, remembers it is ours.
    void setDisplay(int index, float plain)
    {
        if (std::fabs(get(index) - plain) < 1e-6f) return;
        set(index, plain);
        seen_[index] = get(index);
        notifyHostParameterChanged(index);
    }

    bool instrument(int strip) const
    {
        return strip >= kFirstInstrumentStrip && strip < kFirstEffectStrip && instrumentStrip_[strip - kFirstInstrumentStrip];
    }

    // On MIX, what a knob plays when it is not a send: an effect strip's or an instrument's parameter, or -1.
    int mixKnob(int strip, int row) const
    {
        if (strip >= kFirstEffectStrip) return fxParam(fx::kEffectStripLayout[strip - kFirstEffectStrip][row]);
        if (instrument(strip)) return fxParam(fx::kInstrumentLayout[strip - kFirstInstrumentStrip][row]);
        return -1;
    }
    // What a knob drives on the current page: a parameter index, or -1.
    int knobTarget(int strip, int row) const
    {
        if (page_ == kMix)
        {
            const int p = mixKnob(strip, row);
            return p >= 0 ? p : send(strip, row);
        }
        const int p = fx::kFxLayout[strip][row];
        return p == fx::None ? -1 : fxParam(p);
    }
    static int faderTarget(int strip)
    {
        return strip >= kFirstEffectStrip ? fxParam(fx::kEffectStripFader[strip - kFirstEffectStrip]) : fader(strip);
    }

    // A control that does not hold the value acts only once it has reached or crossed it. A control whose
    // position is still unknown takes over at once on the MIX page (the console is right), but an effect
    // parameter never jumps at the first touch (`adopt` false).
    static bool pickUp(Physical& c, float physical, float current, bool adopt)
    {
        const float last = c.value;
        c.value = physical;
        if (c.picked) return true;
        const bool near = std::fabs(physical - current) <= kPickupWindow;
        const bool crossed = last >= 0 ? (last - current) * (physical - current) <= 0 : adopt;
        c.picked = near || crossed;
        return c.picked;
    }
    static void release(Physical& c, float value)
    {
        if (c.value >= 0) c.picked = std::fabs(c.value - value) <= kPickupWindow;
    }

    void catchUp(int strip)
    {
        for (int row = 0; row < 3; ++row)
        {
            Physical& k = knobs_[strip][row];
            const int target = knobTarget(strip, row);
            k.picked = target >= 0 && k.value >= 0 && std::fabs(k.value - get(target)) <= kPickupWindow;
        }
    }

    void setPage(int page)
    {
        page_ = page;
        for (int s = 0; s < kSurfaceStrips; ++s) catchUp(s);
        setDisplay(kPage, (float)page);
    }

    // A value changed on the screen (or a project was loaded): the knob or fader driving it must catch up.
    void followScreen()
    {
        for (int i = 0; i < kDelaySync; ++i)
        {
            const float v = get(i);
            if (v == seen_[i]) continue;
            seen_[i] = v;
            for (int s = 0; s < kSurfaceStrips; ++s)
            {
                for (int row = 0; row < 3; ++row)
                    if (knobTarget(s, row) == i) release(knobs_[s][row], v);
                if (faderTarget(s) == i) release(faders_[s], v);
            }
            if (i == kMaster) release(master_, v);
        }
    }

    void handleMidi(const mpc::ProcessContext& ctx)
    {
        for (int i = 0; i < ctx.numMidiEvents; ++i)
        {
            const mpc::MidiEvent& e = ctx.midi[i];
            if (e.isController())
            {
                setDisplay(kLastCC, (float)e.controller());
                control(e.controller(), (float)e.controllerValue() / 127.0f);
            }
            else if (e.isNoteOn() || e.isNoteOff())
            {
                if (e.isNoteOn()) setDisplay(kLastNote, (float)e.note());
                button(e.note(), e.isNoteOn());
            }
        }
    }

    void control(int cc, float v)
    {
        if (cc == kMasterCC)
        {
            if (pickUp(master_, v, get(kMaster), page_ == kMix)) setDisplay(kMaster, v);
            return;
        }
        for (int s = 0; s < kSurfaceStrips; ++s)
        {
            const int row = cc - kStripCC[s];
            if (row < 0 || row > 3) continue;
            if (row == 3)
            {
                const int target = faderTarget(s);
                const bool adopt = s < kFirstEffectStrip && page_ == kMix;
                if (pickUp(faders_[s], v, get(target), adopt)) setDisplay(target, v);
                return;
            }
            const int target = knobTarget(s, row);
            if (target < 0) { knobs_[s][row].value = v; return; }
            const bool adopt = page_ == kMix && mixKnob(s, row) < 0;
            if (pickUp(knobs_[s][row], v, get(target), adopt)) setDisplay(target, v);
            return;
        }
    }

    void button(int note, bool down)
    {
        if (note == kBankLeft || note == kBankRight) { bank(note == kBankLeft, down); return; }
        if (note < 1 || note > 24) return;
        const int strip = (note - 1) / 3, kind = (note - 1) % 3;   // 0 MUTE, 1 SOLO, 2 REC ARM
        if (kind == 1) return;                                      // SOLO: not on the MPC yet
        const bool isMute = kind == 0;
        if (strip >= kFirstEffectStrip)
        {
            const bool first = strip == kFirstEffectStrip;
            gestures_[first ? (isMute ? kHold : kDouble) : (isMute ? kFxOnly : kTapeStop)] = down;
        }
        else if (instrument(strip))
        {
            if (strip == kFirstInstrumentStrip) gestures_[isMute ? kSiren : kRise] = down;
            else if (isMute) { if (down) dub_effect_set(syndrum_, DUB_SYNDRUM_HIT, 1); hitLamp_ = down; }
            else gestures_[kRoll] = down;
        }
        else if (isMute)
        {
            if (down) setDisplay(mute(strip), getBool(mute(strip)) ? 0.0f : 1.0f);
        }
        else
            throwing_[strip] = down;
        refreshLamps();
    }

    // Each bank button changes the page as it goes down; the second one pressed while the first is held is
    // PANIC: the page goes back to where it was, and the buses are emptied.
    void bank(bool left, bool down)
    {
        long long& mine = left ? bankDownLeft_ : bankDownRight_;
        const long long other = left ? bankDownRight_ : bankDownLeft_;
        mine = down ? clock_ : -1;
        if (!down)
        {
            if (bankDownLeft_ < 0 && bankDownRight_ < 0) pageBeforeBank_ = -1;
            return;
        }
        if (other >= 0 && (double)(clock_ - other) < kPanicWindow * sampleRate_)
        {
            if (pageBeforeBank_ >= 0 && pageBeforeBank_ != page_) setPage(pageBeforeBank_);
            panic();
            return;
        }
        pageBeforeBank_ = page_;
        setPage(left ? kMix : kFx);
    }

    // Empties the three buses (echoes, tails, the held loop); HOLD, tape stop and the instruments let go.
    void panic()
    {
        for (DubEffect* e : {delay_, reverb_, bus3_}) dub_effect_set(e, DUB_EFFECT_CLEAR, 1);
        for (int g : {kHold, kTapeStop, kSiren, kRise, kRoll}) gestures_[g] = false;
        refreshLamps();
    }

    // The console's LEDs, mirrored on the screen (the plugin cannot light the MIDImix).
    void refreshLamps()
    {
        for (int s = 0; s < kSurfaceStrips; ++s)
        {
            bool m = false, r = false;
            if (s == kFirstEffectStrip) { m = gestures_[kHold]; r = gestures_[kDouble]; }
            else if (s == kFirstEffectStrip + 1) { m = gestures_[kFxOnly]; r = gestures_[kTapeStop]; }
            else if (instrument(s) && s == kFirstInstrumentStrip) { m = gestures_[kSiren]; r = gestures_[kRise]; }
            else if (instrument(s)) { m = hitLamp_; r = gestures_[kRoll]; }
            else { m = getBool(mute(s)); r = throwing_[s]; }
            setDisplay(kLampMute1 + s, m ? 1.0f : 0.0f);
            setDisplay(kLampRec1 + s, r ? 1.0f : 0.0f);
        }
    }

    // A strip became an instrument strip (the song has no stem there), or a stem strip again: its gestures
    // let go, its mute and throw are cleared, its knobs catch up with their new targets.
    void updateSong()
    {
        if (readyGen_.load(std::memory_order_acquire) != loadGen_.load(std::memory_order_relaxed)) return;
        bool changed = false;
        for (int i = 0; i < 2; ++i)
        {
            const int strip = kFirstInstrumentStrip + i;
            const bool inst = songs_.empty() || !rings_[strip].present.load(std::memory_order_relaxed);
            if (inst == instrumentStrip_[i]) continue;
            changed = true;
            instrumentStrip_[i] = inst;
            if (i == 0) gestures_[kSiren] = gestures_[kRise] = false;
            else { gestures_[kRoll] = false; hitLamp_ = false; }
            if (inst) { setDisplay(mute(strip), 0.0f); throwing_[strip] = false; }
            for (Physical& k : knobs_[strip]) k.picked = false;
            if (page_ == kMix) catchUp(strip);
            setDisplay(kMode5 + i, inst ? 1.0f : 0.0f);
        }
        if (changed) refreshLamps();
    }

    // ------------------------------------------------------------------------------------------------
    // Effects and mix (AudioEngine.swift)
    // ------------------------------------------------------------------------------------------------

    DubEffect* kernelFor(fx::Kernel k) const
    {
        switch (k)
        {
            case fx::DelayKernel: return delay_;
            case fx::ReverbKernel: return reverb_;
            case fx::Bus3Kernel: return bus3_;
            case fx::SirenKernel: return siren_;
            case fx::SyndrumKernel: return syndrum_;
            default: return nullptr;
        }
    }

    // Pushes the effect settings and gestures to the kernels (only what changed), and sets the gain targets.
    void applyEffects()
    {
        const bool sync = getBool(kDelaySync);
        const double bpm = bpm_.load(std::memory_order_relaxed);
        for (int p = 0; p < fx::Count; ++p)
        {
            DubEffect* k = kernelFor(fx::info(p).kernel);
            if (k == nullptr) continue;
            const float v = fx::engineValue(p, get(fxParam(p)), sync, bpm);
            if (v == applied_[p]) continue;
            applied_[p] = v;
            dub_effect_set(k, fx::info(p).index, v);
        }
        dub_effect_set(reverb_, DUB_SWITCH_SELECT, (float)getInt(kReverbModel));
        dub_effect_set(bus3_, DUB_SWITCH_SELECT, (float)getInt(kBus3Model));
        dub_effect_set(delay_, DUB_DELAY_HOLD, gestures_[kHold] ? 1.0f : 0.0f);
        dub_effect_set(delay_, DUB_DELAY_DOUBLE, gestures_[kDouble] ? 1.0f : 0.0f);
        dub_effect_set(delay_, DUB_DELAY_STOP, gestures_[kTapeStop] ? 1.0f : 0.0f);
        dub_effect_set(siren_, DUB_SIREN_GATE, gestures_[kSiren] ? 1.0f : 0.0f);
        dub_effect_set(siren_, DUB_SIREN_RISE, gestures_[kRise] ? 1.0f : 0.0f);
        dub_effect_set(syndrum_, DUB_SYNDRUM_ROLLING, gestures_[kRoll] ? 1.0f : 0.0f);

        // Gain targets, glided per sample in render().
        const int throwTarget = getInt(kThrowTarget);   // 0 delay, 1 reverb, 2 both
        for (int s = 0; s < kStemStrips; ++s)
        {
            const float g = getBool(mute(s)) ? 0.0f : faderGain(get(fader(s))) * kHeadroom;
            stripGain_[s] = g;
            dry_[s].target = gestures_[kFxOnly] ? 0.0f : g;
            for (int b = 0; b < fx::BusCount; ++b)
            {
                const double position = instrument(s) ? get(fxParam(fx::kInstrumentSends[s - kFirstInstrumentStrip][b]))
                                                      : get(send(s, b));
                const bool thrown = throwing_[s] && (b == fx::Delay ? throwTarget != 1 : b == fx::Reverb && throwTarget != 0);
                post_[s][b].target = g * (float)(position * position);
                pre_[s][b].target = thrown ? kHeadroom : 0.0f;
            }
        }
        const int returns[3] = {fx::DelayReturn, fx::ReverbReturn, fx::PhaserReturn};
        for (int b = 0; b < fx::BusCount; ++b) return_[b].target = (float)fx::value(returns[b], get(fxParam(returns[b])));
        masterGain_.target = faderGain(get(kMaster)) * kHeadroom * kMakeup;

        // Bus-to-bus sends: each bus's knob opens its chosen target, as long as that closes no loop.
        int target[3];
        for (int b = 0; b < 3; ++b) target[b] = kBusTargets[b][getInt(kDelayTo + b)];
        for (int b = 0; b < 3; ++b)
        {
            int t = target[b], hops = 0;
            while (t >= 0 && t != b && hops++ < 3) t = target[t];
            const int to = t == b ? -1 : target[b];   // a loop: this send stays closed
            const float level = (float)fx::value(fx::kBusSend[b], get(fxParam(fx::kBusSend[b])));
            for (int c = 0; c < 3; ++c) busSend_[b][c].target = c == to ? level : 0.0f;
        }
    }

    void render(float* outL, float* outR, int n)
    {
        bool loaded = readyGen_.load(std::memory_order_acquire) == loadGen_.load(std::memory_order_relaxed);
#ifdef DSM_OFFLINE
        // Offline test hosts render faster than real time: wait for the disk instead of dropping out.
        while (playing_ && !songs_.empty() && !ended_ && !loaded)
        {
            std::this_thread::yield();
            loaded = readyGen_.load(std::memory_order_acquire) == loadGen_.load(std::memory_order_relaxed);
        }
#endif
        const bool running = playing_ && loaded && !songs_.empty() && !ended_;

        std::fill(outL, outL + n, 0.0f);
        std::fill(outR, outR + n, 0.0f);
        for (int b = 0; b < 3; ++b)
        {
            std::fill(busL_[b], busL_[b] + n, 0.0f);
            std::fill(busR_[b], busR_[b] + n, 0.0f);
        }
        float peak[kSurfaceStrips] = {};

        bool allDone = true, anyPresent = false;
        for (int s = 0; s < kStemStrips; ++s)
        {
            float* sL = stripL_;
            float* sR = stripR_;
            std::fill(sL, sL + n, 0.0f);
            std::fill(sR, sR + n, 0.0f);
            StemRing& ring = rings_[s];
            if (running && ring.present.load(std::memory_order_relaxed))
            {
                anyPresent = true;
                const size_t r = ring.read.load(std::memory_order_relaxed);
                size_t w = ring.written.load(std::memory_order_acquire);
#ifdef DSM_OFFLINE
                while (w - r < (size_t)n && !ring.finished.load()) { std::this_thread::yield(); w = ring.written.load(std::memory_order_acquire); }
#endif
                const size_t take = std::min((size_t)n, w - r);
                for (size_t i = 0; i < take; ++i)
                {
                    const size_t k = ((r + i) & (kRingFrames - 1)) * 2;
                    sL[i] = ring.data[k];
                    sR[i] = ring.data[k + 1];
                }
                ring.read.store(r + take, std::memory_order_release);
                const bool finished = ring.finished.load(std::memory_order_acquire);
                if (take < (size_t)n && !finished) underruns_++;
                if (!(finished && w == r + take)) allDone = false;
            }
            if (instrument(s)) dub_effect_process(s == kFirstInstrumentStrip ? siren_ : syndrum_, sL, sR, sL, sR, n);

            float stripPeak = 0;
            for (int i = 0; i < n; ++i)
            {
                const float l = sL[i], r = sR[i];
                const float d = dry_[s].next(glide_);
                outL[i] += l * d;
                outR[i] += r * d;
                for (int b = 0; b < 3; ++b)
                {
                    const float g = post_[s][b].next(glide_) + pre_[s][b].next(glide_);
                    busL_[b][i] += l * g;
                    busR_[b][i] += r * g;
                }
                stripPeak = std::fmax(stripPeak, std::fmax(std::fabs(l), std::fabs(r)));
            }
            peak[s] = stripPeak * stripGain_[s] / kHeadroom;   // after the fader, full scale = 1
        }

        // Bus-to-bus sends, one chunk late, then the effects (100 % wet) and their returns.
        for (int from = 0; from < 3; ++from)
            for (int b = 0; b < 3; ++b)
                for (int i = 0; i < n; ++i)
                {
                    const float g = busSend_[from][b].next(glide_);
                    if (lastN_ == 0) continue;
                    const int j = i < lastN_ ? i : lastN_ - 1;
                    busL_[b][i] += lastRetL_[from][j] * g;
                    busR_[b][i] += lastRetR_[from][j] * g;
                }
        DubEffect* buses[3] = {delay_, reverb_, bus3_};
        for (int b = 0; b < 3; ++b)
        {
            dub_effect_process(buses[b], busL_[b], busR_[b], busL_[b], busR_[b], n);
            for (int i = 0; i < n; ++i)
            {
                lastRetL_[b][i] = busL_[b][i];
                lastRetR_[b][i] = busR_[b][i];
                const float g = return_[b].next(glide_);
                outL[i] += busL_[b][i] * g;
                outR[i] += busR_[b][i] * g;
                if (b < 2)
                {
                    const float level = std::fmax(std::fabs(busL_[b][i]), std::fabs(busR_[b][i])) * g;
                    if (level > peak[kFirstEffectStrip + b]) peak[kFirstEffectStrip + b] = level;
                }
            }
        }
        lastN_ = n;

        for (int i = 0; i < n; ++i)
        {
            const float g = masterGain_.next(glide_);
            outL[i] *= g;
            outR[i] *= g;
        }
        dub_effect_process(limiter_, outL, outR, outL, outR, n);

        for (int s = 0; s < kSurfaceStrips; ++s) meterPeak_[s] = std::fmax(meterPeak_[s], peak[s]);
        if (running)
        {
            framesPlayed_ += n;
            if (anyPresent && allDone) advance();   // end of song: the next one starts on its own
        }
    }

    void refreshDisplays(int frames)
    {
        displayCounter_ += frames;
        if (displayCounter_ < (int)(sampleRate_ / 15)) return;
        displayCounter_ = 0;
        for (int s = 0; s < kSurfaceStrips; ++s)
        {
            const float db = meterPeak_[s] > 1e-6f ? 20.0f * std::log10(meterPeak_[s]) : -100.0f;
            const float shown = std::fmin(1.0f, std::fmax(0.0f, (db + 48.0f) / 48.0f));
            meterShown_[s] = std::fmax(shown, meterShown_[s] - 0.06f);   // falls ~0.9 per second
            meterPeak_[s] = 0;
            setDisplay(kMeter1 + s, std::round(meterShown_[s] * 50.0f) / 50.0f);
        }
        if (++slowCounter_ % 3 == 0)
        {
            setDisplay(kCpu, std::round(cpu_ * 10.0f) / 10.0f);
            setDisplay(kUnderruns, (float)underruns_);
            const double total = (double)songFrames_.load(std::memory_order_relaxed);
            setDisplay(kTimeLeft, (float)std::floor(std::fmax(0.0, total - (double)framesPlayed_) / sampleRate_));
            const bool loaded = readyGen_.load(std::memory_order_acquire) == loadGen_.load(std::memory_order_relaxed);
            setDisplay(kState, (float)(ended_ ? kEnded : !playing_ ? kStopped : loaded ? kRunning : kLoading));
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Transport and songs
    // ------------------------------------------------------------------------------------------------

    void handleTransport(const mpc::Transport& t, int frames)
    {
        if (!t.valid) return;
        if (t.playing && !playing_)
        {
            // PLAY START puts the MPC's position back to the start; PLAY resumes from where it was.
            const bool fromStart = t.ppqValid && t.ppqPos < 0.01;
            setDisplay(kStart, (float)(fromStart ? kStartPlayStart : kStartPlay));
            setDisplay(kStartPos, t.ppqValid ? (float)t.ppqPos : 0.0f);
            // The first start of a song only plays it; PLAY START moves on once it has been heard.
            if ((fromStart && framesPlayed_ > 0) || ended_) advance();
        }
        else if (t.playing && playing_ && t.ppqValid && lastPpqValid_ && jumpedToStart(t))
        {
            // PLAY START pressed while playing: the MPC never stops, its position just jumps back.
            setDisplay(kStart, (float)kStartPlayStart);
            setDisplay(kStartPos, (float)t.ppqPos);
            advance();
        }
        playing_ = t.playing;
        lastPpqValid_ = t.playing && t.ppqValid;
        lastPpq_ = t.ppqPos;
        lastBlockBeats_ = (double)frames / sampleRate_ * (t.tempoValid ? t.bpm : 120.0) / 60.0;
    }

    // True when the position jumped back, unless it is the MPC's sequence looping:
    // a loop goes back exactly at its end, which is on a bar line, while PLAY START comes anywhere.
    bool jumpedToStart(const mpc::Transport& t) const
    {
        if (t.ppqPos > lastPpq_ - 0.001) return false;   // the position only moves forward otherwise
        const double expected = lastPpq_ + lastBlockBeats_;
        const double slack = lastBlockBeats_ + 0.001;
        if (t.cycling && t.cycleEndPpq > t.cycleStartPpq)
            return expected < t.cycleEndPpq - slack;
        const double bar = t.timeSigDenominator > 0 ? 4.0 * t.timeSigNumerator / t.timeSigDenominator : 4.0;
        const double toBarLine = std::ceil(expected / bar - 1e-9) * bar - expected;
        const double fromBarLine = expected - std::floor(expected / bar + 1e-9) * bar;
        return toBarLine > slack && fromBarLine > slack;
    }

    // Moves to the song picked as "Next", then points "Next" at the one after it.
    void advance()
    {
        const int next = getInt(kNext);
        if (next >= (int)songs_.size() || next == current_)
        {
            ended_ = true;
            return;
        }
        loadSong(next);
        if (next + 1 < (int)songs_.size()) setDisplay(kNext, (float)(next + 1));
    }

    // Asks the disk thread to open a song. Called from the constructor or the audio thread.
    void loadSong(int index)
    {
        current_ = index;
        ended_ = false;
        framesPlayed_ = 0;
        requestedSong_.store(index, std::memory_order_relaxed);
        loadGen_.fetch_add(1, std::memory_order_release);
        setDisplay(kPlaying, (float)index);
        for (int s = 0; s < kStemStrips; ++s) setDisplay(kName1 + s, (float)index);
    }

    // Strip name on screen for a song: the stem's name, the instrument's on an empty strip 5 or 6.
    std::string stripLabel(int song, int strip) const
    {
        if (song >= 0 && song < (int)songs_.size() && strip < (int)songs_[(size_t)song].labels.size())
            return songs_[(size_t)song].labels[(size_t)strip];
        if (strip == kFirstInstrumentStrip) return "SIREN";
        if (strip == kFirstInstrumentStrip + 1) return "SYNDRUM";
        return "-";
    }

    void scanSongs()
    {
        const std::string root = mpc::contentPath("Songs");
        for (const std::string& dir : stems::listDir(root, true))
        {
            Song song;
            song.name = dir;
            for (const std::string& f : stems::listDir(root + "/" + dir, false))
                if ((int)song.stems.size() < kStemStrips) song.stems.push_back(root + "/" + dir + "/" + f);
            song.labels = stems::stripLabels(song.stems);
            if (!song.stems.empty()) songs_.push_back(std::move(song));
        }
        mpc::log("DubStemMix: %d song(s) in %s", (int)songs_.size(), root.c_str());
    }

    // The disk thread: opens the requested song, then keeps every ring topped up.
    void diskLoop()
    {
        WavReader readers[kStemStrips];
        std::vector<float> chunk(kChunkFrames * 2);
        int gen = -1;
        while (!quit_.load())
        {
            const int wanted = loadGen_.load(std::memory_order_acquire);
            if (wanted != gen && !songs_.empty())
            {
                // The audio thread does not read the rings until readyGen_ catches up with loadGen_.
                gen = wanted;
                const Song& song = songs_[(size_t)requestedSong_.load(std::memory_order_relaxed)];
                size_t longest = 0;
                for (int s = 0; s < kStemStrips; ++s)
                {
                    StemRing& ring = rings_[s];
                    ring.read.store(0, std::memory_order_relaxed);
                    ring.written.store(0, std::memory_order_relaxed);
                    ring.finished.store(false, std::memory_order_relaxed);
                    const bool ok = s < (int)song.stems.size() && readers[s].open(song.stems[(size_t)s]);
                    if (!ok) readers[s].close();
                    if (ok && readers[s].rate() != 44100)
                        mpc::log("DubStemMix: %s is %u Hz, the MPC plays at 44100 Hz", song.stems[(size_t)s].c_str(), readers[s].rate());
                    if (ok) longest = std::max(longest, readers[s].framesLeft());
                    ring.present.store(ok, std::memory_order_relaxed);
                    while (ok && fill(ring, readers[s], chunk)) {}
                }
                songFrames_.store((long long)longest, std::memory_order_relaxed);
                readyGen_.store(gen, std::memory_order_release);
                continue;
            }
            bool busy = false;
            for (int s = 0; s < kStemStrips; ++s)
                if (rings_[s].present.load(std::memory_order_relaxed)) busy |= fill(rings_[s], readers[s], chunk);
            if (!busy) std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }

    // Reads one chunk into the ring if there is room. Returns true when it read something.
    static bool fill(StemRing& ring, WavReader& reader, std::vector<float>& chunk)
    {
        if (ring.finished.load(std::memory_order_relaxed)) return false;
        const size_t w = ring.written.load(std::memory_order_relaxed);
        const size_t r = ring.read.load(std::memory_order_acquire);
        const size_t room = kRingFrames - (w - r);
        if (room < kChunkFrames) return false;
        const size_t got = reader.read(chunk.data(), kChunkFrames);
        for (size_t i = 0; i < got; ++i)
        {
            const size_t k = ((w + i) & (kRingFrames - 1)) * 2;
            ring.data[k] = chunk[2 * i];
            ring.data[k + 1] = chunk[2 * i + 1];
        }
        ring.written.store(w + got, std::memory_order_release);
        if (got == 0) ring.finished.store(true, std::memory_order_release);
        return got > 0;
    }

    // Songs and disk.
    std::vector<Song> songs_;
    StemRing rings_[kStemStrips];
    std::thread disk_;
    std::atomic<bool> quit_{false};
    std::atomic<int> loadGen_{0}, readyGen_{-1}, requestedSong_{0};
    std::atomic<long long> songFrames_{0};
    std::atomic<double> bpm_{0.0};

    // Effects and mix.
    DubEffect *delay_ = nullptr, *reverb_ = nullptr, *bus3_ = nullptr;
    DubEffect *siren_ = nullptr, *syndrum_ = nullptr, *limiter_ = nullptr;
    float applied_[fx::Count];
    Glide dry_[kStemStrips], post_[kStemStrips][3], pre_[kStemStrips][3], return_[3], busSend_[3][3], masterGain_;
    float stripGain_[kStemStrips] = {};
    float glide_ = 0.005f;
    float stripL_[kMaxChunk], stripR_[kMaxChunk];
    float busL_[3][kMaxChunk], busR_[3][kMaxChunk];
    float lastRetL_[3][kMaxChunk] = {}, lastRetR_[3][kMaxChunk] = {};
    int lastN_ = 0;

    // Console.
    float seen_[kNumParams];
    Physical knobs_[kSurfaceStrips][3], faders_[kSurfaceStrips], master_;
    int page_ = kMix, pageBeforeBank_ = -1;
    long long bankDownLeft_ = -1, bankDownRight_ = -1, clock_ = 0;
    bool gestures_[kGestureCount] = {};
    bool throwing_[kStemStrips] = {};
    bool hitLamp_ = false;
    bool instrumentStrip_[2] = {true, true};

    // Transport and displays.
    double sampleRate_ = 44100.0;
    bool playing_ = false, ended_ = false, lastPpqValid_ = false;
    double lastPpq_ = 0.0, lastBlockBeats_ = 0.0;
    int current_ = 0;
    long long framesPlayed_ = 0;
    int underruns_ = 0, displayCounter_ = 0, slowCounter_ = 0;
    float cpu_ = 0.0f;
    float meterPeak_[kSurfaceStrips] = {}, meterShown_[kSurfaceStrips] = {};
};

MPC_PLUGIN_ENTRY(DubStemMix)
