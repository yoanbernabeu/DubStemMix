// main.cpp - DubStemMix desktop mock-up (PRD § 17.2).
//
// A small host around the MPC plugin's engine (mpc/DubStemMix/src, compiled into this program unchanged):
// it gives the engine a sound card, the MIDImix (in, and out for the LEDs) and a plain window. It plays the
// songs of an "Export to MPC" folder. Keyboard: Space = play / pause, N = next song.
//
// What it is for: checking, before the real port, that the engine and the console hold outside the MPC
// (sound, MIDImix, latency, stems read from disk, a window) on macOS and Linux. Not meant to be released.
//
//   dubstemmix-desktop [folder]     folder: an export folder, a card, or the plugin's own folder
//   dubstemmix-desktop --selftest   no window, no sound card: plays test songs and checks the levels
//
// SPDX-License-Identifier: MIT

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#include "miniaudio.h"

#include "RtMidi.h"

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include <GLFW/glfw3.h>

#include "mpc_vst2_abi.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

// The MPC plugin's entry point (mpc/DubStemMix/src/DubStemMix.cpp).
extern "C" AEffect* VSTPluginMain(audioMasterCallback host);

namespace {

constexpr double kRate = 44100.0;   // the engine's only rate, like the MPC: the sound card is opened at it
constexpr int kChunk = 512;         // the engine is fed at most this many frames at a time
constexpr int kStrips = 8;

// MIDImix factory mapping (Sources/DubStemMixCore/MidiMix.swift): LEDs are lit by a Note On on the button's note.
constexpr int kBankLeftNote = 25, kBankRightNote = 26;
inline int muteNote(int strip) { return 1 + 3 * strip; }
inline int recArmNote(int strip) { return 3 + 3 * strip; }
// The plugin's GO gesture (pad 15: play the next song now), with its default "Pad 1 note" of 24.
constexpr int kGoNote = 48;

// Single-producer, single-consumer queue of 3-byte MIDI messages towards the audio thread.
struct MidiQueue
{
    std::array<uint32_t, 1024> items{};
    std::atomic<size_t> read{0}, written{0};

    void push(uint8_t status, uint8_t a, uint8_t b)
    {
        const size_t w = written.load(std::memory_order_relaxed);
        if (w - read.load(std::memory_order_acquire) >= items.size()) return;   // full: drop
        items[w % items.size()] = (uint32_t)status | ((uint32_t)a << 8) | ((uint32_t)b << 16);
        written.store(w + 1, std::memory_order_release);
    }
    bool pop(uint8_t out[3])
    {
        const size_t r = read.load(std::memory_order_relaxed);
        if (r == written.load(std::memory_order_acquire)) return false;
        const uint32_t m = items[r % items.size()];
        out[0] = (uint8_t)m; out[1] = (uint8_t)(m >> 8); out[2] = (uint8_t)(m >> 16);
        read.store(r + 1, std::memory_order_release);
        return true;
    }
};

// The plugin's engine, driven the way the MPC drives it: a transport, MIDI in, audio out.
struct Engine
{
    AEffect* fx = nullptr;
    std::atomic<bool> playing{false};
    double ppq = 0.0;                     // audio thread only: moves while playing, never goes back
    MidiQueue fromConsole, fromKeys;      // one producer each: the MIDI thread, the window's thread
    std::atomic<float> load{0.0f};        // % of the buffer's duration spent computing it
    std::atomic<int> overruns{0};         // buffers that took longer to compute than they last
    std::atomic<float> lastLevel{0.0f};   // last output sample (left), for the self-test
    VstTimeInfo timeInfo{};
    float left[kChunk] = {}, right[kChunk] = {};

    void open()
    {
        fx = VSTPluginMain(&Engine::host);
        fx->dispatcher(fx, effOpen, 0, 0, nullptr, 0.0f);
        fx->dispatcher(fx, effSetSampleRate, 0, 0, nullptr, (float)kRate);
        fx->dispatcher(fx, effSetBlockSize, 0, kChunk, nullptr, 0.0f);
        fx->dispatcher(fx, effMainsChanged, 0, 1, nullptr, 0.0f);
    }

    static VstIntPtr host(AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float);

    void deliver(MidiQueue& queue)
    {
        uint8_t m[3];
        while (queue.pop(m))
        {
            VstMidiEvent e{};
            e.type = kVstMidiType;
            e.byteSize = sizeof e;
            e.midiData[0] = (char)m[0]; e.midiData[1] = (char)m[1]; e.midiData[2] = (char)m[2];
            VstEvents events{};
            events.numEvents = 1;
            events.events[0] = reinterpret_cast<VstEvent*>(&e);
            fx->dispatcher(fx, effProcessEvents, 0, 0, &events, 0.0f);
        }
    }

    // Audio thread: fills `frames` interleaved stereo frames.
    void render(float* out, int frames)
    {
        const auto t0 = std::chrono::steady_clock::now();
        deliver(fromConsole);
        deliver(fromKeys);
        for (int done = 0; done < frames;)
        {
            const int n = std::min(kChunk, frames - done);
            float* outs[2] = {left, right};
            fx->processReplacing(fx, nullptr, outs, n);
            for (int i = 0; i < n; ++i)
            {
                out[(done + i) * 2] = left[i];
                out[(done + i) * 2 + 1] = right[i];
            }
            if (playing.load(std::memory_order_relaxed)) ppq += n / kRate * 2.0;   // 120 BPM
            done += n;
        }
        if (frames > 0) lastLevel.store(out[(frames - 1) * 2], std::memory_order_relaxed);
        const double spent = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        const double budget = frames / kRate;
        if (spent > budget) overruns.fetch_add(1, std::memory_order_relaxed);
        const float now = (float)(spent / budget * 100.0);
        const float smoothed = load.load(std::memory_order_relaxed);
        load.store(smoothed + (now - smoothed) * 0.05f, std::memory_order_relaxed);
    }

    // Parameters, by the name the plugin gives them (they are its screen's values).
    int param(const char* name) const
    {
        for (int i = 0; i < fx->numParams; ++i)
        {
            char buf[64] = {};
            fx->dispatcher(fx, effGetParamName, i, 0, buf, 0.0f);
            if (std::strcmp(buf, name) == 0) return i;
        }
        return -1;
    }
    float value(int index) const { return index < 0 ? 0.0f : fx->getParameter(fx, index); }
    std::string text(int index) const
    {
        if (index < 0) return "";
        char buf[64] = {};
        fx->dispatcher(fx, effGetParamDisplay, index, 0, buf, 0.0f);
        return buf;
    }
};

Engine engine;

VstIntPtr Engine::host(AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
{
    if (opcode == audioMasterVersion) return 2400;
    if (opcode == audioMasterGetSampleRate) return (VstIntPtr)kRate;
    if (opcode == audioMasterGetBlockSize) return kChunk;
    if (opcode == audioMasterGetTime)
    {
        VstTimeInfo& t = engine.timeInfo;
        std::memset(&t, 0, sizeof t);
        t.sampleRate = kRate;
        t.tempo = 120.0;
        t.ppqPos = engine.ppq;
        t.flags = kVstTempoValid | kVstPpqPosValid | (engine.playing.load(std::memory_order_relaxed) ? kVstTransportPlaying : 0);
        return (VstIntPtr)&t;
    }
    return 0;
}

// The two keyboard gestures of the mock-up.
void togglePlay() { engine.playing.store(!engine.playing.load()); }
void nextSong()
{
    engine.fromKeys.push(0x90, kGoNote, 127);
    engine.fromKeys.push(0x80, kGoNote, 0);
}

// ----------------------------------------------------------------------------------------------------
// Sound card
// ----------------------------------------------------------------------------------------------------

struct Audio
{
    ma_context context{};
    ma_device device{};
    bool hasContext = false, running = false;
    std::vector<ma_device_info> outputs;
    int selected = -1;   // -1: the system's default output
    int buffer = 256;
    std::string error;

    static void callback(ma_device*, void* output, const void*, ma_uint32 frames)
    {
        engine.render(static_cast<float*>(output), (int)frames);
    }

    bool init(bool noSoundCard)
    {
        const ma_backend null[] = {ma_backend_null};
        if (ma_context_init(noSoundCard ? null : nullptr, noSoundCard ? 1 : 0, nullptr, &context) != MA_SUCCESS)
        {
            error = "no audio system found";
            return false;
        }
        hasContext = true;
        listOutputs();
        return true;
    }

    void listOutputs()
    {
        ma_device_info* infos = nullptr;
        ma_uint32 count = 0;
        outputs.clear();
        if (ma_context_get_devices(&context, &infos, &count, nullptr, nullptr) == MA_SUCCESS)
            outputs.assign(infos, infos + count);
        if (selected >= (int)outputs.size()) selected = -1;
    }

    bool start()
    {
        stop();
        ma_device_config config = ma_device_config_init(ma_device_type_playback);
        config.playback.format = ma_format_f32;
        config.playback.channels = 2;
        config.sampleRate = (ma_uint32)kRate;
        config.periodSizeInFrames = (ma_uint32)buffer;
        config.performanceProfile = ma_performance_profile_low_latency;
        config.dataCallback = &Audio::callback;
        if (selected >= 0) config.playback.pDeviceID = &outputs[(size_t)selected].id;
        if (ma_device_init(&context, &config, &device) != MA_SUCCESS) { error = "cannot open the sound card"; return false; }
        if (ma_device_start(&device) != MA_SUCCESS) { ma_device_uninit(&device); error = "cannot start the sound card"; return false; }
        running = true;
        error.clear();
        engine.overruns.store(0);
        return true;
    }

    void stop()
    {
        if (!running) return;
        ma_device_uninit(&device);
        running = false;
    }

    // What the sound card really runs at (it may not grant the buffer asked for).
    int cardBuffer() const { return running ? (int)device.playback.internalPeriodSizeInFrames : 0; }
    int cardRate() const { return running ? (int)device.playback.internalSampleRate : 0; }
    const char* cardName() const { return running ? device.playback.name : ""; }
    const char* backend() const { return hasContext ? ma_get_backend_name(context.backend) : ""; }

    void shutdown()
    {
        stop();
        if (hasContext) ma_context_uninit(&context);
        hasContext = false;
    }
};

// ----------------------------------------------------------------------------------------------------
// MIDImix: in (knobs, faders, buttons) and out (LEDs)
// ----------------------------------------------------------------------------------------------------

struct Console
{
    std::unique_ptr<RtMidiIn> in;
    std::unique_ptr<RtMidiOut> out;
    bool available = false, connected = false, ledsOpen = false;
    std::string name;
    int leds[128];

    static bool isMidiMix(std::string portName)
    {
        for (char& c : portName) c = (char)std::tolower((unsigned char)c);
        return portName.find("midi mix") != std::string::npos || portName.find("midimix") != std::string::npos;
    }

    static void received(double, std::vector<unsigned char>* message, void*)
    {
        if (message == nullptr || message->size() < 3) return;
        engine.fromConsole.push((*message)[0], (*message)[1], (*message)[2]);
    }

    void init()
    {
        forgetLeds();
        try
        {
            in = std::make_unique<RtMidiIn>(RtMidi::UNSPECIFIED, "DubStemMix");
            out = std::make_unique<RtMidiOut>(RtMidi::UNSPECIFIED, "DubStemMix");
            in->setCallback(&Console::received);
            available = true;
        }
        catch (RtMidiError& e)
        {
            std::fprintf(stderr, "MIDI unavailable: %s\n", e.getMessage().c_str());
        }
    }

    void forgetLeds() { for (int& v : leds) v = -1; }

    // Called about once a second: plugs the console in when it appears, lets it go when it leaves.
    void poll()
    {
        if (!available) return;
        try
        {
            int found = -1;
            const unsigned int count = in->getPortCount();
            for (unsigned int i = 0; i < count && found < 0; ++i)
                if (isMidiMix(in->getPortName(i))) found = (int)i;
            if (found >= 0 && !connected)
            {
                name = in->getPortName((unsigned int)found);
                in->openPort((unsigned int)found, "in");
                connected = true;
                const unsigned int outs = out->getPortCount();
                for (unsigned int i = 0; i < outs && !ledsOpen; ++i)
                    if (isMidiMix(out->getPortName(i))) { out->openPort(i, "leds"); ledsOpen = true; }
                forgetLeds();   // light them all again
            }
            else if (found < 0 && connected)
            {
                in->closePort();
                if (ledsOpen) out->closePort();
                connected = ledsOpen = false;
            }
        }
        catch (RtMidiError& e)
        {
            std::fprintf(stderr, "MIDI: %s\n", e.getMessage().c_str());
        }
    }

    void led(int note, bool on)
    {
        if (!ledsOpen || leds[note] == (int)on) return;
        leds[note] = (int)on;
        const unsigned char message[3] = {0x90, (unsigned char)note, (unsigned char)(on ? 127 : 0)};
        try { out->sendMessage(message, 3); } catch (RtMidiError&) {}
    }

    void shutdown()
    {
        if (ledsOpen) for (int n = 0; n < 128; ++n) if (leds[n] == 1) led(n, false);
        in.reset();
        out.reset();
    }
};

// ----------------------------------------------------------------------------------------------------
// Songs folder
// ----------------------------------------------------------------------------------------------------

bool isDir(const std::string& path)
{
    struct stat st{};
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// The folder holding Content/Songs, from what the user gave: an export folder or a card
// ("VST2 Plugins/YoanDev - VST - DubStemMix" inside), or the plugin's folder itself. Empty when not found.
std::string pluginFolder(const std::string& given)
{
    const std::string inExport = given + "/VST2 Plugins/YoanDev - VST - DubStemMix";
    if (isDir(inExport + "/Content/Songs")) return inExport;
    if (isDir(given + "/Content/Songs")) return given;
    return "";
}

// ----------------------------------------------------------------------------------------------------
// Window
// ----------------------------------------------------------------------------------------------------

struct Screen
{
    int master, playing, next, state, timeLeft, page, underruns;
    int fader[kStrips], name[kStrips], lampMute[kStrips], lampRec[kStrips], meter[kStrips];

    void bind()
    {
        master = engine.param("Master");
        playing = engine.param("Playing");
        next = engine.param("Next");
        state = engine.param("State");
        timeLeft = engine.param("Time left");
        page = engine.param("Page");
        underruns = engine.param("Underruns");
        for (int s = 0; s < kStrips; ++s)
        {
            const std::string n = std::to_string(s + 1);
            // Faders 7 and 8 are the delay and reverb returns (PRD § 14).
            fader[s] = engine.param(s == 6 ? "DLY Return" : s == 7 ? "REV Return" : ("Fader " + n).c_str());
            name[s] = engine.param(("Name " + n).c_str());
            lampMute[s] = engine.param(("Lamp M" + n).c_str());
            lampRec[s] = engine.param(("Lamp R" + n).c_str());
            meter[s] = engine.param(("Meter " + n).c_str());
        }
    }

    int pageIndex() const { return (int)std::lround(engine.value(page) * 3.0f); }

    // The plugin's lamps, sent to the console's LEDs (the MPC cannot do this, a computer can).
    void lightLeds(Console& console) const
    {
        for (int s = 0; s < kStrips; ++s)
        {
            console.led(muteNote(s), engine.value(lampMute[s]) > 0.5f);
            console.led(recArmNote(s), engine.value(lampRec[s]) > 0.5f);
        }
        // BANK LEDs as on the Mac (PRD § 11.1): MIX = left, FX = right, MASTER and INSERTS = both.
        const int p = pageIndex();
        console.led(kBankLeftNote, p == 0 || p >= 2);
        console.led(kBankRightNote, p >= 1);
    }

    static void bar(const char* id, float value, ImVec2 size, ImU32 colour)
    {
        const ImVec2 at = ImGui::GetCursorScreenPos();
        ImDrawList* draw = ImGui::GetWindowDrawList();
        draw->AddRectFilled(at, ImVec2(at.x + size.x, at.y + size.y), IM_COL32(40, 36, 32, 255));
        const float h = size.y * std::fmin(std::fmax(value, 0.0f), 1.0f);
        draw->AddRectFilled(ImVec2(at.x, at.y + size.y - h), ImVec2(at.x + size.x, at.y + size.y), colour);
        ImGui::InvisibleButton(id, size);
    }

    void draw(Audio& audio, Console& console, const std::string& folder)
    {
        const ImGuiViewport* viewport = ImGui::GetMainViewport();
        ImGui::SetNextWindowPos(viewport->WorkPos);
        ImGui::SetNextWindowSize(viewport->WorkSize);
        ImGui::Begin("DubStemMix", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);

        // Song
        const std::string title = engine.text(playing);
        if (folder.empty())
            ImGui::TextColored(ImVec4(1, 0.5f, 0.3f, 1), "No songs folder. Start with: dubstemmix-desktop <export folder>");
        else if (title.empty())
            ImGui::TextColored(ImVec4(1, 0.5f, 0.3f, 1), "No song found in %s", folder.c_str());
        else
            ImGui::Text("%s   |   %s   |   time left %s   |   next: %s   |   page %s", title.c_str(),
                        engine.text(state).c_str(), engine.text(timeLeft).c_str(), engine.text(next).c_str(), engine.text(page).c_str());
        ImGui::TextDisabled("Space = play / pause    N = next song");
        ImGui::Separator();

        // Sound card
        ImGui::SetNextItemWidth(320);
        const char* current = audio.selected < 0 ? "System default" : audio.outputs[(size_t)audio.selected].name;
        if (ImGui::BeginCombo("Sound card", current))
        {
            if (ImGui::Selectable("System default", audio.selected < 0)) { audio.selected = -1; audio.start(); }
            for (int i = 0; i < (int)audio.outputs.size(); ++i)
                if (ImGui::Selectable(audio.outputs[(size_t)i].name, audio.selected == i)) { audio.selected = i; audio.start(); }
            ImGui::EndCombo();
        }
        ImGui::SameLine();
        ImGui::SetNextItemWidth(90);
        static const int sizes[] = {64, 128, 256, 512, 1024};
        if (ImGui::BeginCombo("Buffer", std::to_string(audio.buffer).c_str()))
        {
            for (int size : sizes)
                if (ImGui::Selectable(std::to_string(size).c_str(), audio.buffer == size)) { audio.buffer = size; audio.start(); }
            ImGui::EndCombo();
        }
        ImGui::SameLine();
        if (ImGui::Button("Refresh")) audio.listOutputs();
        if (audio.running)
            ImGui::Text("%s (%s)   %d frames at %d Hz = %.1f ms   |   load %.1f %%   |   late buffers %d   |   disk dropouts %s",
                        audio.cardName(), audio.backend(), audio.cardBuffer(), audio.cardRate(),
                        audio.cardRate() > 0 ? audio.cardBuffer() * 1000.0 / audio.cardRate() : 0.0,
                        engine.load.load(), engine.overruns.load(), engine.text(underruns).c_str());
        else
            ImGui::TextColored(ImVec4(1, 0.4f, 0.3f, 1), "No sound: %s", audio.error.c_str());
        if (!console.available) ImGui::TextColored(ImVec4(1, 0.4f, 0.3f, 1), "MIDI unavailable on this system");
        else if (console.connected) ImGui::TextColored(ImVec4(0.6f, 0.8f, 0.45f, 1), "MIDImix connected: %s%s", console.name.c_str(), console.ledsOpen ? " (LEDs on)" : " (no LED port)");
        else ImGui::TextColored(ImVec4(1, 0.7f, 0.3f, 1), "MIDImix not connected");
        ImGui::Separator();

        // Console mirror: name, fader, meter, MUTE and REC ARM lamps.
        const float height = std::fmax(120.0f, ImGui::GetContentRegionAvail().y - 90.0f);
        ImGui::Columns(kStrips + 1, "strips", false);
        for (int s = 0; s <= kStrips; ++s)
        {
            const bool isMaster = s == kStrips;
            std::string label = isMaster ? "MASTER" : s == 6 ? "7 DELAY" : s == 7 ? "8 SPACE" : std::to_string(s + 1) + " " + engine.text(name[s]);
            ImGui::TextUnformatted(label.c_str());
            ImGui::PushID(s);
            bar("fader", engine.value(isMaster ? master : fader[s]), ImVec2(28, height), IM_COL32(237, 227, 207, 255));
            if (!isMaster)
            {
                ImGui::SameLine();
                bar("meter", engine.value(meter[s]), ImVec2(10, height), IM_COL32(126, 155, 90, 255));
                const bool m = engine.value(lampMute[s]) > 0.5f, r = engine.value(lampRec[s]) > 0.5f;
                ImGui::TextColored(m ? ImVec4(0.93f, 0.89f, 0.81f, 1) : ImVec4(0.35f, 0.33f, 0.3f, 1), "MUTE");
                ImGui::TextColored(r ? ImVec4(0.85f, 0.64f, 0.25f, 1) : ImVec4(0.35f, 0.33f, 0.3f, 1), "REC ARM");
            }
            ImGui::PopID();
            ImGui::NextColumn();
        }
        ImGui::Columns(1);
        ImGui::End();
    }
};

int runWindow(const std::string& folder)
{
    if (!glfwInit()) { std::fprintf(stderr, "cannot open a window\n"); return 1; }
#ifdef __APPLE__
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
    const char* glsl = "#version 150";
#else
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
    const char* glsl = "#version 130";
#endif
    GLFWwindow* window = glfwCreateWindow(1100, 620, "DubStemMix (desktop mock-up)", nullptr, nullptr);
    if (window == nullptr) { std::fprintf(stderr, "cannot open a window\n"); glfwTerminate(); return 1; }
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;
    ImGui::StyleColorsDark();
    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init(glsl);

    engine.open();
    Screen screen;
    screen.bind();
    Audio audio;
    if (audio.init(false)) audio.start();
    Console console;
    console.init();

    double lastPoll = -10.0;
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();
        if (glfwGetTime() - lastPoll > 1.0) { console.poll(); lastPoll = glfwGetTime(); }
        screen.lightLeds(console);

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();
        if (ImGui::IsKeyPressed(ImGuiKey_Space, false)) togglePlay();
        if (ImGui::IsKeyPressed(ImGuiKey_N, false)) nextSong();
        screen.draw(audio, console, folder);
        ImGui::Render();
        int w = 0, h = 0;
        glfwGetFramebufferSize(window, &w, &h);
        glViewport(0, 0, w, h);
        glClearColor(0.08f, 0.07f, 0.06f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        glfwSwapBuffers(window);
    }

    console.shutdown();
    audio.shutdown();
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}

// ----------------------------------------------------------------------------------------------------
// Self-test: no window, no sound card (miniaudio's null device, in real time). Same gestures and same
// expected levels as the MPC plugin's own test (mpc/tests/transport_test.cpp).
// ----------------------------------------------------------------------------------------------------

void writeSong(const std::string& root, const char* name, float level, double seconds)
{
    const std::string dir = root + "/Content/Songs/" + name;
    mkdir((root + "/Content").c_str(), 0755);
    mkdir((root + "/Content/Songs").c_str(), 0755);
    mkdir(dir.c_str(), 0755);
    std::FILE* f = std::fopen((dir + "/1 - stem.wav").c_str(), "wb");
    if (f == nullptr) { std::fprintf(stderr, "cannot write %s\n", dir.c_str()); std::exit(1); }
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

int runSelfTest()
{
    char scratch[] = "/tmp/dubstemmix-desktop-XXXXXX";
    if (mkdtemp(scratch) == nullptr) { std::fprintf(stderr, "cannot create a scratch folder\n"); return 1; }
    const std::string root = scratch;
    writeSong(root, "A", 0.25f, 20.0);
    writeSong(root, "B", 0.50f, 20.0);
    setenv("MPC_PLUGIN_FOLDER", root.c_str(), 1);

    engine.open();
    Audio audio;
    if (!audio.init(true) || !audio.start()) { std::fprintf(stderr, "self-test: %s\n", audio.error.c_str()); return 1; }

    int failures = 0;
    auto wait = [](double seconds) { std::this_thread::sleep_for(std::chrono::duration<double>(seconds)); };
    auto expect = [&failures](const char* what, float got, float want)
    {
        const bool ok = std::fabs(got - want) < 0.003f;
        if (!ok) failures++;
        std::printf("%s  %-46s got %.4f want %.4f\n", ok ? "PASS" : "FAIL", what, got, want);
    };
    auto level = [] { return engine.lastLevel.load(); };
    auto cc = [](int number, int value) { engine.fromConsole.push(0xB0, (uint8_t)number, (uint8_t)value); };

    // Mac gain structure: fader^2.5 x 0.5 on the strip, master^2.5 x 0.5 x 2 (make-up). Faders default to 0.8.
    const float masterGain = std::pow(0.8f, 2.5f);
    const float unity = std::pow(0.8f, 2.5f) * 0.5f * masterGain;

    wait(0.5);
    expect("stopped: silence", level(), 0.0f);
    togglePlay();
    wait(1.0);
    expect("Space: song A plays", level(), 0.25f * unity);
    nextSong();
    wait(1.0);
    expect("N: song B plays", level(), 0.50f * unity);
    cc(19, 0);
    wait(0.6);
    expect("fader 1 down (CC 19 = 0): silence", level(), 0.0f);
    cc(19, 127);
    wait(0.6);
    expect("fader 1 up (CC 19 = 127)", level(), 0.50f * 0.5f * masterGain);
    engine.fromConsole.push(0x90, 1, 127);
    wait(0.6);
    expect("MUTE 1 (note 1): silence", level(), 0.0f);
    expect("MUTE 1 lamp lit (the console's LED)", engine.value(engine.param("Lamp M1")), 1.0f);
    engine.fromConsole.push(0x80, 1, 0);
    engine.fromConsole.push(0x90, 1, 127);
    engine.fromConsole.push(0x80, 1, 0);
    wait(0.6);
    expect("MUTE 1 again: back", level(), 0.50f * 0.5f * masterGain);
    togglePlay();
    wait(0.6);
    expect("Space: pause, silence", level(), 0.0f);

    std::printf("late buffers: %d, disk dropouts: %s, load: %.1f %%\n", engine.overruns.load(),
                engine.text(engine.param("Underruns")).c_str(), engine.load.load());
    audio.shutdown();
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    std::printf("Result: %s\n", failures == 0 ? "all passed" : "FAILED");
    return failures == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc > 1 && std::strcmp(argv[1], "--selftest") == 0) return runSelfTest();

    // Songs: the folder given, else the repository's own test songs when started from it.
    std::string folder;
    if (argc > 1) folder = pluginFolder(argv[1]);
    else
        for (const char* guess : {"mpc/DubStemMix", "../mpc/DubStemMix", "../../mpc/DubStemMix"})
            if (folder.empty()) folder = pluginFolder(guess);
    if (argc > 1 && folder.empty())
    {
        std::fprintf(stderr, "No Content/Songs folder in %s\n(expected an Export to MPC folder, a card, or the plugin's folder)\n", argv[1]);
        return 1;
    }
    if (!folder.empty()) setenv("MPC_PLUGIN_FOLDER", folder.c_str(), 1);
    return runWindow(folder);
}
