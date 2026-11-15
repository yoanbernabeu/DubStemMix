// transport_test.cpp - drives the plugin like the MPC would: STOP, PLAY, PLAY START, end of song,
// MIDImix faders and mutes. Each test song is one stem holding a constant level, so the output
// level tells which song is playing.
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
// Parameter indices, as declared in DubStemMix.cpp.
constexpr int kFader1 = 1, kMute1 = 7, kNext = 13, kPlaying = 14, kState = 15, kStart = 16;

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
    std::FILE* f = std::fopen((dir + "/1 stem.wav").c_str(), "wb");
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

    // Runs `blocks` blocks and returns the level of the last one.
    float run(int blocks)
    {
        float* outs[2] = {left, right};
        for (int b = 0; b < blocks; ++b)
        {
            std::memset(left, 0, sizeof left);
            std::memset(right, 0, sizeof right);
            fx->processReplacing(fx, nullptr, outs, kBlock);
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
    }

    int choice(int index, int count) { return (int)std::lround(fx->getParameter(fx, index) * (count - 1)); }
};

void expect(const char* what, float got, float want)
{
    const bool ok = std::fabs(got - want) < 0.002f;
    if (!ok) failures++;
    std::printf("%s  %-46s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, got, want);
}

void expectInt(const char* what, int got, int want)
{
    if (got != want) failures++;
    std::printf("%s  %-46s got %d want %d\n", got == want ? "PASS" : "FAIL", what, got, want);
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

    const float unity = std::pow(0.8f, 2.5f);   // default fader position, same law as the Mac app
    const float a = 0.25f * unity, b = 0.50f * unity, c = 0.75f * unity;

    expect("stopped: silence", r.run(20), 0.0f);

    playing = true; ppq = 0.0;
    expect("PLAY at the start: song A", r.run(40), a);
    expectInt("Last start = PLAY START (position 0)", r.choice(kStart, 3), 2);
    expectInt("Playing = A", r.choice(kPlaying, 3), 0);
    expectInt("Next = B", r.choice(kNext, 3), 1);

    playing = false;
    expect("STOP: silence", r.run(20), 0.0f);
    playing = true;   // PLAY resumes: the MPC's position is not back at 0
    expect("PLAY: song A resumes", r.run(20), a);
    expectInt("Last start = PLAY", r.choice(kStart, 3), 1);

    r.midi(0xB0, 19, 0);   // fader 1 down
    expect("fader 1 down (CC 19 = 0): silence", r.run(20), 0.0f);
    r.midi(0xB0, 19, 127);
    expect("fader 1 up (CC 19 = 127): full level", r.run(20), 0.25f);
    r.midi(0x90, 1, 127);  // MUTE 1
    expect("MUTE 1 (note 1): silence", r.run(20), 0.0f);
    expectInt("Mute 1 on", r.choice(kMute1, 2), 1);
    r.midi(0x80, 1, 0);
    r.midi(0x90, 1, 127);  // MUTE 1 again
    expect("MUTE 1 again: back", r.run(20), 0.25f);
    r.midi(0xB0, 19, 102); // back near the default position
    r.run(20);
    fx->setParameter(fx, kFader1, 0.8f);

    playing = false; r.run(5);
    playing = true; ppq = 0.0;   // PLAY START
    expect("PLAY START: song B", r.run(40), b);
    expectInt("Playing = B", r.choice(kPlaying, 3), 1);
    expectInt("Next = C", r.choice(kNext, 3), 2);

    fx->setParameter(fx, kNext, 0.0f);   // pick A on screen, then STOP + PLAY START
    playing = false; r.run(5);
    playing = true; ppq = 0.0;
    expect("Next picked on screen (A) + PLAY START: song A", r.run(40), a);

    loopBeats = 4.0;   // a 1-bar sequence looping (2 s at 120 BPM), as the MPC does
    fx->setParameter(fx, kNext, 0.5f);   // B
    expect("sequence loops (twice): still song A", r.run(1400), a);
    expectInt("Playing = A after the loops", r.choice(kPlaying, 3), 0);
    ppq = 0.0;   // PLAY START while playing: the position jumps back mid-bar
    expect("PLAY START while playing: song B", r.run(40), b);
    expectInt("Last start = PLAY START", r.choice(kStart, 3), 2);
    loopBeats = 0.0;

    expect("end of B: C follows on its own", r.run(400), c);
    expectInt("Playing = C", r.choice(kPlaying, 3), 2);

    expect("end of C (last song): silence", r.run(300), 0.0f);
    expectInt("State = Ended", r.choice(kState, 4), 3);

    fx->dispatcher(fx, effMainsChanged, 0, 0, nullptr, 0.0f);
    fx->dispatcher(fx, effClose, 0, 0, nullptr, 0.0f);
    std::printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}
