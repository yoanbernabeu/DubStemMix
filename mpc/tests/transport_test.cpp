// transport_test.cpp - drives the plugin like the MPC would: STOP, PLAY, PLAY START, end of song, and the
// MIDImix (faders, mutes, throw, pages with soft takeover, the siren, PANIC). Each test song is one stem
// holding a constant level, so the output level tells which song is playing.
//
// Built and run by mpc/test.sh against a native build made with -DDSM_OFFLINE=1
// (the plugin then waits for its disk thread, since this host runs faster than real time).

#include "mpc_vst2_abi.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <sys/stat.h>

namespace {

constexpr int kBlock = 128;
constexpr double kRate = 44100.0;

bool playing = false;
double ppq = 0.0;
double loopBeats = 0.0;   // > 0: the MPC's sequence loops back to 0 after this many beats
VstTimeInfo timeInfo{};
int failures = 0;

VstIntPtr host(AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
{
    if (opcode == audioMasterVersion) return 2400;
    if (opcode == audioMasterGetSampleRate) return (VstIntPtr)kRate;
    if (opcode == audioMasterGetBlockSize) return kBlock;
    if (opcode == audioMasterGetTime)
    {
        std::memset(&timeInfo, 0, sizeof timeInfo);
        timeInfo.sampleRate = kRate;
        timeInfo.tempo = 120.0;
        timeInfo.ppqPos = ppq;
        timeInfo.flags = kVstTempoValid | kVstPpqPosValid | (playing ? kVstTransportPlaying : 0);
        return (VstIntPtr)&timeInfo;
    }
    return 0;
}

void writeSong(const std::string& root, const char* name, float level, double seconds)
{
    const std::string dir = root + "/Content/Songs/" + name;
    mkdir((root + "/Content").c_str(), 0755);
    mkdir((root + "/Content/Songs").c_str(), 0755);
    mkdir(dir.c_str(), 0755);
    std::FILE* f = std::fopen((dir + "/1 - stem.wav").c_str(), "wb");
    const uint32_t frames = (uint32_t)(seconds * kRate), data = frames * 4;
    auto u32 = [f](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [f](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); u32(36 + data); std::fwrite("WAVEfmt ", 1, 8, f);
    u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16);
    std::fwrite("data", 1, 4, f); u32(data);
    const int16_t s = (int16_t)(level * 32767.0f);
    for (uint32_t i = 0; i < frames * 2; ++i) std::fwrite(&s, 2, 1, f);
    std::fclose(f);
}

struct Runner
{
    AEffect* fx;
    float left[kBlock], right[kBlock];
    float peak = 0;   // largest output level of the last run
    float floor = 0;  // smallest output level of the last run

    // Runs `blocks` blocks and returns the level of the last sample.
    float run(int blocks)
    {
        float* outs[2] = {left, right};
        peak = 0;
        floor = 1e9f;
        for (int b = 0; b < blocks; ++b)
        {
            std::memset(left, 0, sizeof left);
            std::memset(right, 0, sizeof right);
            fx->processReplacing(fx, nullptr, outs, kBlock);
            for (float v : left) { peak = std::fmax(peak, std::fabs(v)); floor = std::fmin(floor, std::fabs(v)); }
            if (playing) ppq += kBlock / kRate * 2.0;   // 120 BPM
            if (loopBeats > 0.0 && ppq >= loopBeats) ppq -= loopBeats;
        }
        return left[kBlock - 1];
    }

    void midi(uint8_t status, uint8_t a, uint8_t b)
    {
        VstMidiEvent e{};
        e.type = kVstMidiType;
        e.byteSize = sizeof e;
        e.midiData[0] = (char)status; e.midiData[1] = (char)a; e.midiData[2] = (char)b;
        VstEvents events{};
        events.numEvents = 1;
        events.events[0] = reinterpret_cast<VstEvent*>(&e);
        fx->dispatcher(fx, effProcessEvents, 0, 0, &events, 0.0f);
        run(1);
    }
    void cc(int number, int value) { midi(0xB0, (uint8_t)number, (uint8_t)value); }
    void press(int note) { midi(0x90, (uint8_t)note, 127); }
    void lift(int note) { midi(0x80, (uint8_t)note, 0); }

    // Parameter index by its on-screen name.
    int param(const char* name)
    {
        for (int i = 0; i < fx->numParams; ++i)
        {
            char buf[64] = {};
            fx->dispatcher(fx, effGetParamName, i, 0, buf, 0.0f);
            if (std::strcmp(buf, name) == 0) return i;
        }
        std::fprintf(stderr, "no parameter named %s\n", name);
        std::exit(1);
    }
    float value(const char* name) { return fx->getParameter(fx, param(name)); }
    int choice(const char* name, int count) { return (int)std::lround(value(name) * (count - 1)); }
};

void expect(const char* what, float got, float want)
{
    const bool ok = std::fabs(got - want) < 0.002f;
    if (!ok) failures++;
    std::printf("%s  %-52s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, got, want);
}

void expectInt(const char* what, int got, int want)
{
    if (got != want) failures++;
    std::printf("%s  %-52s got %d want %d\n", got == want ? "PASS" : "FAIL", what, got, want);
}

void expectTrue(const char* what, bool ok, float got)
{
    if (!ok) failures++;
    std::printf("%s  %-52s got %.4f\n", ok ? "PASS" : "FAIL", what, got);
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: %s <plugin.dylib> <scratch folder>\n", argv[0]); return 1; }
    const std::string root = argv[2];
    mkdir(root.c_str(), 0755);
    // Song A lasts 6 s (long enough to loop the sequence), B 1 s, C half a second. Levels identify them.
    writeSong(root, "A", 0.25f, 6.0);
    writeSong(root, "B", 0.50f, 1.0);
    writeSong(root, "C", 0.75f, 0.5);
    setenv("MPC_PLUGIN_FOLDER", root.c_str(), 1);

    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
    auto entry = (AEffect * (*)(audioMasterCallback)) dlsym(lib, "VSTPluginMain");
    AEffect* fx = entry(host);
    fx->dispatcher(fx, effOpen, 0, 0, nullptr, 0.0f);
    fx->dispatcher(fx, effSetSampleRate, 0, 0, nullptr, (float)kRate);
    fx->dispatcher(fx, effSetBlockSize, 0, kBlock, nullptr, 0.0f);
    fx->dispatcher(fx, effMainsChanged, 0, 1, nullptr, 0.0f);
    Runner r{fx, {}, {}};

    // Mac gain structure: fader^2.5 x 0.5 on the strip, master^2.5 x 0.5 x 2 (make-up). Faders default to 0.8.
    const float masterGain = std::pow(0.8f, 2.5f);
    const float unity = std::pow(0.8f, 2.5f) * 0.5f * masterGain;
    const float a = 0.25f * unity, b = 0.50f * unity, c = 0.75f * unity;
    const float faderUp = 0.25f * 0.5f * masterGain;   // song A with fader 1 at the top

    expect("stopped: silence", r.run(20), 0.0f);

    playing = true; ppq = 0.0;
    expect("PLAY at the start: song A", r.run(40), a);
    expectInt("Last start = PLAY START (position 0)", r.choice("Last start", 3), 2);
    expectInt("Playing = A", r.choice("Playing", 3), 0);
    expectInt("Next = B", r.choice("Next", 3), 1);

    playing = false;
    expect("STOP: silence", r.run(20), 0.0f);
    playing = true;   // PLAY resumes: the MPC's position is not back at 0
    expect("PLAY: song A resumes", r.run(20), a);
    expectInt("Last start = PLAY", r.choice("Last start", 3), 1);

    // MIX page: fader, mute, soft takeover after a change on the screen.
    r.cc(19, 0);
    expect("fader 1 down (CC 19 = 0): silence", r.run(20), 0.0f);
    r.cc(19, 127);
    expect("fader 1 up (CC 19 = 127)", r.run(20), faderUp);
    r.press(1);
    expect("MUTE 1 (note 1): silence", r.run(20), 0.0f);
    expectInt("Mute 1 on, lamp lit", r.choice("Mute 1", 2) + r.choice("Lamp M1", 2), 2);
    r.lift(1);
    r.press(1); r.lift(1);
    expect("MUTE 1 again: back", r.run(20), faderUp);
    fx->setParameter(fx, r.param("Fader 1"), 0.8f);   // from the screen
    expect("fader 1 set on screen: default level", r.run(20), a);
    r.cc(19, 120);
    expect("fader 1 moved, still above the screen value: no jump", r.run(20), a);
    r.cc(19, 102);
    expect("fader 1 reaches the screen value: takes over", r.run(20),
           0.25f * 0.5f * std::pow(102 / 127.0f, 2.5f) * masterGain);
    fx->setParameter(fx, r.param("Fader 1"), 0.8f);
    r.run(5);

    // Dub throw: REC ARM 1 held sends strip 1 to the delay; the echoes ring on after STOP.
    r.press(3);
    r.run(100);
    expectInt("REC ARM 1 held: throw lamp lit", r.choice("Lamp R1", 2), 1);
    r.lift(3);
    playing = false;
    r.run(10);
    r.run(200);
    expectTrue("STOP after a throw: the delay keeps echoing", r.peak > 0.001f, r.peak);

    // PANIC (BANK LEFT + BANK RIGHT) empties the delay.
    r.press(25); r.press(26); r.lift(26); r.lift(25);
    r.run(100);
    r.run(200);
    expect("PANIC: the echoes are gone", r.peak, 0.0f);
    expectInt("PANIC stays on the MIX page", r.choice("Page", 4), 0);

    // The siren on empty strip 5: MUTE 5 (note 13) held sounds it, even while stopped.
    expectInt("strip 5 is the siren (song A has one stem)", r.choice("Strip 5", 2), 1);
    r.press(13);
    r.run(100);
    expectTrue("MUTE 5 held: the siren sounds", r.peak > 0.01f, r.peak);
    expectInt("siren lamp lit", r.choice("Lamp M5", 2), 1);
    r.lift(13);
    r.run(200);   // the siren fades out, still feeding the delay
    r.press(25); r.press(26); r.lift(26); r.lift(25);   // PANIC: its echoes too
    r.run(100);
    r.run(200);
    expect("siren released + PANIC: silence", r.peak, 0.0f);

    // FX page: knob 1 of strip 1 (CC 16) drives the delay time, catching up before it acts.
    const float time0 = r.value("Dly Time");
    r.press(26); r.lift(26);
    expectInt("BANK RIGHT: FX page", r.choice("Page", 4), 1);
    r.cc(16, 0);
    expect("FX page, knob far below TIME: no jump", r.value("Dly Time"), time0);
    r.cc(16, 127);
    expect("knob crosses TIME: takes over", r.value("Dly Time"), 1.0f);
    r.press(25); r.lift(25);
    expectInt("BANK LEFT: MIX page", r.choice("Page", 4), 0);
    r.cc(16, 64);
    expect("MIX page, knob at 64 while DLY 1 is 0: no jump", r.value("DLY 1"), 0.0f);
    r.cc(16, 0);
    expect("knob back on DLY 1's value: takes over", r.value("DLY 1"), 0.0f);
    r.cc(16, 32);
    expect("then it drives DLY 1", r.value("DLY 1"), 32 / 127.0f);
    r.cc(16, 0);
    fx->setParameter(fx, r.param("Dly Time"), time0);
    r.run(100);

    // MASTER page (BANK RIGHT twice): knob 1 of strip 1 is the big knob.
    r.press(26); r.lift(26);
    r.press(26); r.lift(26);
    expectInt("BANK RIGHT twice: MASTER page", r.choice("Page", 4), 2);
    r.cc(16, 0);   // the knob sits at 0, like the big knob: it holds it
    r.cc(16, 20);
    expectTrue("MASTER page: knob 1 drives the big knob", r.value("Big Knob") > 0.1f, r.value("Big Knob"));
    r.cc(16, 0);
    // INSERTS page: a sub on strip 1, its knobs drive its amount.
    r.press(26); r.lift(26);
    expectInt("BANK RIGHT again: INSERTS page", r.choice("Page", 4), 3);
    fx->setParameter(fx, r.param("Insert 1"), 0.5f);   // Sub, picked on screen
    r.run(5);
    expect("a new insert starts from its defaults", r.value("Insert 1A"), 0.6f);
    r.cc(16, 76);   // near 0.6: takes over
    r.cc(16, 100);
    expect("INSERTS page: knob 1 drives the sub's amount", r.value("Insert 1A"), 100 / 127.0f);
    fx->setParameter(fx, r.param("Insert 1"), 0.0f);
    r.press(25); r.lift(25);
    expectInt("BANK LEFT: back to MIX", r.choice("Page", 4), 0);

    // SOLO (SOLO held + MUTE sends note 2 + 3 (strip - 1)) and DROP (pad 1) with KEEP.
    playing = true; ppq = 1.0;
    r.run(20);
    r.press(5); r.lift(5);   // solo strip 2: strip 1 goes silent
    expect("SOLO strip 2: strip 1 is out", r.run(20), 0.0f);
    r.press(5); r.lift(5);
    expect("SOLO off: strip 1 back", r.run(20), a);
    r.press(37);   // pad 1: DROP held
    expect("DROP held: strip 1 (not KEEP) is cut", r.run(20), 0.0f);
    r.lift(37);
    expect("DROP released: back", r.run(20), a);
    fx->setParameter(fx, r.param("Keep 1"), 1.0f);
    r.press(37);
    expect("DROP held, strip 1 KEEP: still there", r.run(20), a);
    r.lift(37);
    fx->setParameter(fx, r.param("Keep 1"), 0.0f);
    playing = false; r.run(5);

    // Songs and transport.
    playing = true; ppq = 1.0;   // PLAY resumes A
    r.run(5);
    playing = false; r.run(5);
    playing = true; ppq = 0.0;   // PLAY START
    expect("PLAY START: song B", r.run(40), b);
    expectInt("Playing = B", r.choice("Playing", 3), 1);
    expectInt("Next = C", r.choice("Next", 3), 2);

    fx->setParameter(fx, r.param("Next"), 0.0f);   // pick A on screen, then STOP + PLAY START
    playing = false; r.run(5);
    playing = true; ppq = 0.0;
    expect("Next picked on screen (A) + PLAY START: song A", r.run(40), a);

    loopBeats = 4.0;   // a 1-bar sequence looping (2 s at 120 BPM), as the MPC does
    fx->setParameter(fx, r.param("Next"), 0.5f);   // B
    expect("sequence loops (twice): still song A", r.run(1400), a);
    expectInt("Playing = A after the loops", r.choice("Playing", 3), 0);
    ppq = 0.0;   // PLAY START while playing: the position jumps back mid-bar
    expect("PLAY START while playing: song B", r.run(40), b);
    expectInt("Last start = PLAY START", r.choice("Last start", 3), 2);
    loopBeats = 0.0;

    r.run(290);   // most of B (1 s)
    expect("end of B: C follows on its own", r.run(110), c);
    expectTrue("no gap between B and C", r.floor > 0.5f * b, r.floor);
    expectInt("Playing = C", r.choice("Playing", 3), 2);

    expect("end of C (last song): silence", r.run(300), 0.0f);
    expectInt("State = Ended", r.choice("State", 4), 3);

    // The live setlist: touch a song (its cue) to play it next, pads GO, RESTART, PREV, NEXT.
    expectInt("SONG list: A was played (>= 30 s? no: 6 s) shows as a song", r.choice("Slot 1", 7), 1);
    fx->setParameter(fx, r.param("B"), 1.0f);   // touch B in the list
    r.run(80);   // the list refreshes 5 times a second
    expectInt("touching B makes it next", r.choice("Next", 3), 1);
    expectInt("B's slot shows NEXT", r.choice("Slot 2", 7), 4);
    r.press(43); r.lift(43);   // pad 7: GO
    expect("pad GO: B plays now", r.run(40), b);
    r.press(42); r.lift(42);   // pad 6: NEXT moves the next song on
    expectInt("pad NEXT: C stays next (last song)", r.choice("Next", 3), 2);
    r.press(41); r.lift(41);   // pad 5: PREV
    expectInt("pad PREV: B is next (replay)", r.choice("Next", 3), 1);
    r.run(200);
    r.press(44); r.lift(44);   // pad 8: RESTART
    r.run(20);
    expect("pad RESTART: B again from the top", r.run(20), b);
    expectInt("RESTART leaves the next song alone", r.choice("Next", 3), 1);

    fx->dispatcher(fx, effMainsChanged, 0, 0, nullptr, 0.0f);
    fx->dispatcher(fx, effClose, 0, 0, nullptr, 0.0f);
    std::printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}
