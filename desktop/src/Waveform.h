// Waveform.h - the overall waveform of each song, for the transport (PRD § 5.6).
//
// The engine does not give one: the screen reads the song's stems itself, on a background thread, and keeps
// the result. Songs are listed with the engine's own code (Stems.h), so they come in the same order.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <juce_audio_formats/juce_audio_formats.h>

#include "Stems.h"

#include <map>
#include <memory>
#include <mutex>
#include <vector>

namespace dsm {

struct Waveform
{
    std::vector<float> peaks;   // 0..1, one per bar
    double seconds = 0.0;       // the longest stem
};

class Waveforms
{
public:
    static constexpr int kBars = 390;

    Waveforms() : pool_(1) {}
    ~Waveforms() { pool_.removeAllJobs(true, 4000); }

    // The plugin's folder (the one holding Content/Songs).
    void setFolder(const juce::String& folder)
    {
        songs_.clear();
        const std::string root = (folder + "/Content/Songs").toStdString();
        for (const std::string& dir : stems::listDir(root, true))
        {
            const stems::Song song = stems::readSong(root + "/" + dir, dir);
            std::vector<std::string> files;
            for (const std::string& f : song.stems) if (!f.empty()) files.push_back(f);
            if (!files.empty()) songs_.push_back(std::move(files));
        }
    }

    int songCount() const { return (int)songs_.size(); }

    // The song's waveform when it is ready; else nullptr, and its computation starts.
    std::shared_ptr<const Waveform> get(int song)
    {
        if (song < 0 || song >= songCount()) return nullptr;
        {
            const std::lock_guard<std::mutex> lock(mutex_);
            const auto it = ready_.find(song);
            if (it != ready_.end()) return it->second;
            if (asked_[song]) return nullptr;
            asked_[song] = true;
        }
        const std::vector<std::string> files = songs_[(size_t)song];
        pool_.addJob([this, song, files]
        {
            auto result = std::make_shared<Waveform>(compute(files));
            const std::lock_guard<std::mutex> lock(mutex_);
            ready_[song] = std::move(result);
        });
        return nullptr;
    }

private:
    static Waveform compute(const std::vector<std::string>& files)
    {
        Waveform wave;
        wave.peaks.assign((size_t)kBars, 0.0f);
        juce::WavAudioFormat wav;
        std::vector<std::unique_ptr<juce::AudioFormatReader>> readers;
        for (const std::string& f : files)
        {
            std::unique_ptr<juce::AudioFormatReader> reader(wav.createReaderFor(new juce::FileInputStream(juce::File(juce::String::fromUTF8(f.c_str()))), true));
            if (reader == nullptr || reader->sampleRate <= 0) continue;
            wave.seconds = juce::jmax(wave.seconds, (double)reader->lengthInSamples / reader->sampleRate);
            readers.push_back(std::move(reader));
        }
        if (wave.seconds <= 0.0) return wave;
        for (const auto& reader : readers)
        {
            const double perBar = wave.seconds / kBars * reader->sampleRate;
            for (int bar = 0; bar < kBars; ++bar)
            {
                const juce::int64 start = (juce::int64)(bar * perBar);
                if (start >= reader->lengthInSamples) break;
                float lowL = 0, highL = 0, lowR = 0, highR = 0;
                reader->readMaxLevels(start, juce::jmax((juce::int64)1, (juce::int64)perBar), lowL, highL, lowR, highR);
                wave.peaks[(size_t)bar] += juce::jmax(std::fabs(lowL), std::fabs(highL), std::fabs(lowR), std::fabs(highR));
            }
        }
        const float top = *std::max_element(wave.peaks.begin(), wave.peaks.end());
        if (top > 0.0f) for (float& p : wave.peaks) p /= top;
        return wave;
    }

    std::vector<std::vector<std::string>> songs_;
    std::mutex mutex_;
    std::map<int, std::shared_ptr<const Waveform>> ready_;
    std::map<int, bool> asked_;
    juce::ThreadPool pool_;
};

} // namespace dsm
