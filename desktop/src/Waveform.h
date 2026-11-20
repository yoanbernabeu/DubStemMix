// Waveform.h - the overall waveform of each song, for the transport (PRD § 5.6).
//
// The screen reads the song's stems itself, on a background thread, and keeps the result for as long as the
// same stems are placed.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <juce_audio_formats/juce_audio_formats.h>

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

    // The waveform of these stems when it is ready; else nullptr, and its computation starts.
    std::shared_ptr<const Waveform> get(const std::vector<std::string>& files)
    {
        if (files.empty()) return nullptr;
        std::string key;
        for (const std::string& f : files) key += f + "\n";
        {
            const std::lock_guard<std::mutex> lock(mutex_);
            const auto it = ready_.find(key);
            if (it != ready_.end()) return it->second;
            if (asked_[key]) return nullptr;
            asked_[key] = true;
        }
        pool_.addJob([this, key, files]
        {
            auto result = std::make_shared<Waveform>(compute(files));
            const std::lock_guard<std::mutex> lock(mutex_);
            ready_[key] = std::move(result);
        });
        return nullptr;
    }

private:
    static Waveform compute(const std::vector<std::string>& files)
    {
        Waveform wave;
        wave.peaks.assign((size_t)kBars, 0.0f);
        juce::AudioFormatManager formats;
        formats.registerBasicFormats();
        std::vector<std::unique_ptr<juce::AudioFormatReader>> readers;
        for (const std::string& f : files)
        {
            std::unique_ptr<juce::AudioFormatReader> reader(formats.createReaderFor(juce::File(juce::String::fromUTF8(f.c_str()))));
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

    std::mutex mutex_;
    std::map<std::string, std::shared_ptr<const Waveform>> ready_;
    std::map<std::string, bool> asked_;
    juce::ThreadPool pool_;
};

} // namespace dsm
