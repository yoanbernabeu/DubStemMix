// FX.h - the effect parameters of the Mac app (Sources/DubStemMixCore/FXParameter.swift), ported as data:
// normalized 0..1 on the console and screen, converted here to the kernels' real units, with the same
// defaults, laws, labels and page layouts. Keep the two in step.

#pragma once

#include "DubDSP.h"

#include <cmath>
#include <cstdio>
#include <string>

namespace fx {

// The order is the plugin's parameter order: never reorder, only append.
enum Param
{
    DelayTime, DelayFeedback, DelayWow, DelayLowCut, DelayHighCut, DelayToReverb,
    ReverbDecay, ReverbDamping, ReverbPredelay, ReverbLowCut, ReverbTone,
    PhaserRate, PhaserDepth, PhaserFeedback, PhaserCenter, PhaserStereo,
    DelayReturn, ReverbReturn, PhaserReturn,
    ReverbSend, Bus3Send,
    SirenPitch, SirenRate, SirenWave, SirenDelay, SirenReverb, SirenBus3,
    SyndrumPitch, SyndrumDecay, SyndrumRoll, SyndrumDelay, SyndrumReverb, SyndrumBus3,
    Count,
    None = -1
};

enum Bus { Delay, Reverb, Bus3, BusCount };

// Which kernel a parameter drives (a return, a bus send or an instrument send is a mix level instead).
enum Kernel { NoKernel, DelayKernel, ReverbKernel, Bus3Kernel, SirenKernel, SyndrumKernel };

struct Info
{
    const char* id;      // saved in MPC projects: never rename
    const char* name;    // parameter name in the MPC's lists (unique, ~12 characters)
    const char* label;   // screen caption, as on the Mac
    float def;
    Kernel kernel;
    int index;           // kernel parameter
};

inline const Info& info(int p)
{
    static const Info table[Count] = {
        {"delayTime", "Dly Time", "TIME", 0.62f, DelayKernel, DUB_DELAY_TIME},
        {"delayFeedback", "Dly Feedback", "FEEDBACK", 0.5f, DelayKernel, DUB_DELAY_FEEDBACK},
        {"delayWow", "Dly Wow", "WOW", 0.25f, DelayKernel, DUB_DELAY_WOW},
        {"delayLowCut", "Dly Low Cut", "LOW CUT", 0.45f, DelayKernel, DUB_DELAY_LOW_CUT},
        {"delayHighCut", "Dly High Cut", "HIGH CUT", 0.55f, DelayKernel, DUB_DELAY_HIGH_CUT},
        {"delayToReverb", "DLY>", "DLY>", 0.0f, NoKernel, 0},
        {"reverbDecay", "Rev Decay", "DECAY", 0.7f, ReverbKernel, DUB_PLATE_DECAY},
        {"reverbDamping", "Rev Damping", "DAMPING", 0.4f, ReverbKernel, DUB_PLATE_DAMPING},
        {"reverbPredelay", "Rev Predelay", "PREDELAY", 0.1f, ReverbKernel, DUB_PLATE_PREDELAY},
        {"reverbLowCut", "Rev Low Cut", "LOW CUT", 0.55f, ReverbKernel, DUB_PLATE_LOW_CUT},
        {"reverbTone", "Rev Tone", "TONE", 0.65f, ReverbKernel, DUB_PLATE_TONE},
        {"phaserRate", "Phs Rate", "RATE", 0.35f, Bus3Kernel, DUB_PHASER_RATE},
        {"phaserDepth", "Phs Depth", "DEPTH", 0.75f, Bus3Kernel, DUB_PHASER_DEPTH},
        {"phaserFeedback", "Phs Reso", "RESONANCE", 0.74f, Bus3Kernel, DUB_PHASER_FEEDBACK},
        {"phaserCenter", "Phs Center", "CENTER", 0.5f, Bus3Kernel, DUB_PHASER_CENTER},
        {"phaserStereo", "Phs Stereo", "STEREO", 0.5f, Bus3Kernel, DUB_PHASER_STEREO},
        {"delayReturn", "DLY Return", "DLY RTN", 0.9f, NoKernel, 0},
        {"reverbReturn", "REV Return", "REV RTN", 0.9f, NoKernel, 0},
        {"phaserReturn", "PHS Return", "PHS RTN", 1.0f, NoKernel, 0},
        {"reverbSend", "REV>", "REV>", 0.0f, NoKernel, 0},
        {"bus3Send", "PHS>", "PHS>", 0.0f, NoKernel, 0},
        {"sirenPitch", "Siren Pitch", "PITCH", 0.5f, SirenKernel, DUB_SIREN_PITCH},
        {"sirenRate", "Siren Rate", "RATE", 0.45f, SirenKernel, DUB_SIREN_RATE},
        {"sirenWave", "Siren Wave", "WAVE", 0.0f, SirenKernel, DUB_SIREN_WAVE},
        {"sirenDelay", "Siren DLY", "DLY", 0.5f, NoKernel, 0},
        {"sirenReverb", "Siren REV", "REV", 0.0f, NoKernel, 0},
        {"sirenBus3", "Siren PHS", "PHS", 0.0f, NoKernel, 0},
        {"syndrumPitch", "Syn Pitch", "PITCH", 0.5f, SyndrumKernel, DUB_SYNDRUM_PITCH},
        {"syndrumDecay", "Syn Decay", "DECAY", 0.5f, SyndrumKernel, DUB_SYNDRUM_DECAY},
        {"syndrumRoll", "Syn Roll", "ROLL", (2 + 0.5f) / 3, SyndrumKernel, DUB_SYNDRUM_ROLL},   // sixteenths
        {"syndrumDelay", "Syn DLY", "DLY", 0.5f, NoKernel, 0},
        {"syndrumReverb", "Syn REV", "REV", 0.0f, NoKernel, 0},
        {"syndrumBus3", "Syn PHS", "PHS", 0.0f, NoKernel, 0},
    };
    return table[p];
}

// FX page (BANK RIGHT): knobs of strips 1 to 8, top to bottom.
constexpr int kFxLayout[8][3] = {
    {DelayTime, DelayFeedback, DelayWow},
    {DelayLowCut, DelayHighCut, None},
    {ReverbDecay, ReverbDamping, ReverbPredelay},
    {ReverbLowCut, ReverbTone, None},
    {PhaserRate, PhaserDepth, PhaserFeedback},
    {PhaserCenter, PhaserStereo, None},
    {DelayReturn, ReverbReturn, PhaserReturn},
    {DelayToReverb, ReverbSend, Bus3Send},
};
// Effect strips 7 and 8 on the MIX page, and their faders (the same on every page).
constexpr int kEffectStripLayout[2][3] = {{DelayTime, DelayFeedback, ReverbDecay}, {PhaserRate, DelayToReverb, ReverbSend}};
constexpr int kEffectStripFader[2] = {DelayReturn, ReverbReturn};
// Instrument strips 5 (siren) and 6 (Syndrum) on the MIX page, and their sends to the three buses.
constexpr int kInstrumentLayout[2][3] = {{SirenPitch, SirenRate, SirenDelay}, {SyndrumPitch, SyndrumDecay, SyndrumDelay}};
constexpr int kInstrumentSends[2][3] = {{SirenDelay, SirenReverb, SirenBus3}, {SyndrumDelay, SyndrumReverb, SyndrumBus3}};
// Each bus's send knob into another bus.
constexpr int kBusSend[BusCount] = {DelayToReverb, ReverbSend, Bus3Send};

// Delay divisions when TIME follows the tempo (in quarter notes), and the Syndrum's roll values.
constexpr int kSyncCount = 6;
constexpr const char* kSyncLabels[kSyncCount] = {"1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2"};
constexpr double kSyncBeats[kSyncCount] = {0.25, 0.5, 0.75, 1, 1.5, 2};
constexpr int kRollCount = 3;
constexpr const char* kRollLabels[kRollCount] = {"1/8", "1/8T", "1/16"};
constexpr double kRollBeats[kRollCount] = {0.5, 1.0 / 3, 0.25};

inline int step(double n, int count) { int i = (int)(std::fmin(1.0, std::fmax(0.0, n)) * count); return i < count ? i : count - 1; }

// Real value, as `FXParameter.value`: seconds, Hz, coefficient or linear gain.
inline double value(int p, double n)
{
    n = std::fmin(1.0, std::fmax(0.0, n));
    auto ex = [n](double lo, double hi) { return lo * std::pow(hi / lo, n); };
    switch (p)
    {
        case DelayTime: return ex(0.04, 1.5);
        case DelayFeedback: return n * 1.15;
        case DelayLowCut: return ex(20, 1500);
        case DelayHighCut: return ex(400, 14000);
        case ReverbDecay: return 0.2 + 0.77 * n;
        case ReverbDamping: return 0.9 * n;
        case ReverbPredelay: return 0.2 * n;
        case ReverbLowCut: return ex(20, 800);
        case ReverbTone: return ex(800, 16000);
        case PhaserRate: return ex(0.05, 8);
        case PhaserFeedback: return 0.95 * n;
        case PhaserCenter: return ex(200, 2000);
        case SirenPitch: return ex(150, 1500);
        case SirenRate: return ex(0.3, 12);
        case SirenWave: return n >= 0.5 ? 1 : 0;
        case SyndrumPitch: return ex(80, 1200);
        case SyndrumDecay: return ex(0.08, 1.5);
        case SyndrumRoll: return step(n, kRollCount);
        case DelayToReverb: case ReverbSend: case Bus3Send:
        case DelayReturn: case ReverbReturn: case PhaserReturn:
        case SirenDelay: case SirenReverb: case SirenBus3:
        case SyndrumDelay: case SyndrumReverb: case SyndrumBus3:
            return n * n;   // gain, 100 % = unity
        default: return n;   // wow, depth, stereo
    }
}

// The delay's division when TIME follows the tempo (sync on and a tempo known), else -1.
inline int syncDivision(double n, bool sync, double bpm) { return sync && bpm > 0 ? step(n, kSyncCount) : -1; }

// What the kernel gets: `value`, except a synced delay time and the roll, worked out from the tempo.
inline float engineValue(int p, double n, bool sync, double bpm)
{
    if (p == DelayTime)
    {
        const int d = syncDivision(n, sync, bpm);
        if (d >= 0) return (float)(60.0 / bpm * kSyncBeats[d]);
    }
    if (p == SyndrumRoll) return (float)(60.0 / (bpm > 0 ? bpm : 120.0) * kRollBeats[step(n, kRollCount)]);
    return (float)value(p, n);
}

// Screen text, as `FXParameter.display` / `MixController.fxDisplay`.
inline std::string display(int p, double n, bool sync, double bpm)
{
    char b[48];
    const double v = value(p, n);
    auto hz = [&](double x) {
        if (x >= 1000) std::snprintf(b, sizeof b, "%.1f kHz", x / 1000); else std::snprintf(b, sizeof b, "%d Hz", (int)std::lround(x));
        return std::string(b);
    };
    switch (p)
    {
        case DelayTime:
        {
            const int d = syncDivision(n, sync, bpm);
            if (d >= 0) return kSyncLabels[d];
            std::snprintf(b, sizeof b, "%d ms", (int)std::lround(v * 1000));
            return b;
        }
        case ReverbPredelay: case SyndrumDecay:
            std::snprintf(b, sizeof b, "%d ms", (int)std::lround(v * 1000)); return b;
        case DelayLowCut: case DelayHighCut: case ReverbLowCut: case ReverbTone: case PhaserCenter:
            return hz(v);
        case SirenPitch: case SyndrumPitch:
            std::snprintf(b, sizeof b, "%d Hz", (int)std::lround(v)); return b;
        case PhaserRate: case SirenRate:
            std::snprintf(b, sizeof b, "%.2f Hz", v); return b;
        case DelayFeedback:
            std::snprintf(b, sizeof b, "%d %%", (int)std::lround(v * 100)); return b;
        case SirenWave: return v < 0.5 ? "SQUARE" : "TRIANGLE";
        case SyndrumRoll: return kRollLabels[(int)v];
        case DelayToReverb: case ReverbSend: case Bus3Send:
        case DelayReturn: case ReverbReturn: case PhaserReturn:
            if (v < 0.001) return "-inf dB";
            std::snprintf(b, sizeof b, "%+.0f dB", 20 * std::log10(v)); return b;
        default:
            std::snprintf(b, sizeof b, "%d %%", (int)std::lround(n * 100)); return b;
    }
}

} // namespace fx
