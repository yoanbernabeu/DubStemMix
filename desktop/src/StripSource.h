// StripSource.h - what the app's engine (DubEngine.cpp) and the rest of the app share: where a strip's audio
// comes from, and the transport. No JUCE here: the engine stays plain C++.
//
// A song is given to the engine as lists of files, one list per stem strip (several stems on a strip are
// summed, PRD § 5.1). The app opens them (any format, any rate) and hands the engine 44.1 kHz stereo.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace dsm {

constexpr int kStemStrips = 6;

// The audio of one strip, read in order by the engine's disk thread.
struct StripSource
{
    virtual ~StripSource() = default;
    // Reads up to `frames` frames of interleaved stereo at 44.1 kHz. Returns the number read; 0 at the end.
    virtual size_t read(float* out, size_t frames) = 0;
};

// Opens the files of a strip, summed, from `startFrame` (44.1 kHz frames). `frames` receives the strip's whole
// length. nullptr when the strip has no readable file. Implemented in Sources.cpp.
std::unique_ptr<StripSource> openStrip(const std::vector<std::string>& files, long long startFrame, long long& frames);

struct SongFiles
{
    std::vector<std::string> strips[kStemStrips];
};

// The transport, shared by the window's thread (which asks) and the engine's audio thread (which does).
struct Transport
{
    // Asked by the app.
    std::atomic<bool> playing{false};
    std::atomic<bool> loop{false};
    std::atomic<long long> seekTo{-1};   // a frame to jump to, taken once by the engine
    std::atomic<double> bpm{0.0};        // the song's tempo, 0 when unknown
    std::mutex mutex;                    // guards `pending`
    SongFiles pending;                   // the song to load next...
    std::atomic<int> loadGen{0};         // ...once this has moved

    // Told by the engine.
    std::atomic<long long> position{0}, length{0};   // 44.1 kHz frames
    std::atomic<bool> ready{false};      // the current song's stems are open
    std::atomic<bool> ended{false};      // played to its end (and not looping)
    std::atomic<int> songGen{0};         // moves each time a loaded song becomes the current one

    // Loads a song: it becomes current, stopped at its start, while the effects' tails ring on (PRD § 5.8).
    void load(const SongFiles& song)
    {
        playing.store(false);
        {
            const std::lock_guard<std::mutex> lock(mutex);
            pending = song;
        }
        loadGen.fetch_add(1, std::memory_order_release);
    }
};

Transport& transport();

} // namespace dsm
