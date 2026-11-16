// Tempo.h - the tempo of a song, estimated from its stems (PRD § 5.7). The Mac app's method
// (Sources/DubStemMixCore/TempoDetector.swift), with the same numbers, so both apps answer alike.
//
// Onset envelope (rise of energy per ~5 ms slice, summed over the stems), autocorrelation, then the tempo
// whose period AND its multiples fall on peaks. Half and double tempo explain the signal as well: the answer
// is always in the range reggae is counted in, and the user has x2 / ÷2 for the other reading.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <juce_audio_formats/juce_audio_formats.h>

#include <cmath>
#include <string>
#include <vector>

namespace dsm {
namespace tempo {

constexpr int kHop = 256;
constexpr double kAnalysisSeconds = 60.0, kLowest = 58.0, kHighest = 125.0;

// 0 when no tempo can be told.
inline double estimate(std::vector<float> envelope, double framesPerSecond)
{
    const int maxLag = (int)(4 * 60 / kLowest * framesPerSecond) + 2;   // up to 4 periods of the slowest tempo
    bool any = false;
    for (float v : envelope) any |= v > 0;
    if ((int)envelope.size() <= maxLag * 2 || !any) return 0.0;

    // Onsets widened to ~25 ms: else a period that is not a whole number of slices loses to a wrong but "round" one.
    for (int pass = 0; pass < 2; ++pass)
    {
        std::vector<float> smoothed = envelope;
        for (size_t i = 1; i + 1 < envelope.size(); ++i) smoothed[i] = 0.25f * envelope[i - 1] + 0.5f * envelope[i] + 0.25f * envelope[i + 1];
        envelope = smoothed;
    }

    std::vector<float> autocorrelation((size_t)maxLag + 1, 0.0f);
    for (int lag = 1; lag <= maxLag; ++lag)
    {
        float sum = 0;
        for (size_t i = 0; i + (size_t)lag < envelope.size(); ++i) sum += envelope[i] * envelope[i + (size_t)lag];
        autocorrelation[(size_t)lag] = sum / (float)(envelope.size() - (size_t)lag);
    }
    auto valueAt = [&autocorrelation](double lag)
    {
        const size_t i = (size_t)lag;
        if (i + 1 >= autocorrelation.size()) return 0.0f;
        const float fraction = (float)(lag - (double)i);
        return autocorrelation[i] * (1 - fraction) + autocorrelation[i + 1] * fraction;
    };

    double best = 0.0;
    float bestScore = -1e30f;
    for (int step = 0; step <= (int)((kHighest - kLowest) * 10); ++step)
    {
        const double bpm = kLowest + step / 10.0;
        const double period = 60 / bpm * framesPerSecond;
        float score = 0;
        for (int multiple = 1; multiple <= 4; ++multiple) score += valueAt(period * multiple) / (float)multiple;
        if (score > bestScore) { best = bpm; bestScore = score; }
    }
    if (bestScore <= 0) return 0.0;
    const double rounded = std::round(best);
    return std::fabs(best - rounded) <= 0.15 ? rounded : best;   // most songs have a whole tempo
}

// 60 s taken from the song's first quarter on (intros without a beat are skipped).
inline double detect(const std::vector<std::string>& files)
{
    juce::AudioFormatManager formats;
    formats.registerBasicFormats();
    std::vector<float> envelope;
    double rate = 0.0;
    for (const std::string& path : files)
    {
        std::unique_ptr<juce::AudioFormatReader> reader(formats.createReaderFor(juce::File(juce::String::fromUTF8(path.c_str()))));
        if (reader == nullptr || reader->sampleRate <= 0) continue;
        if (rate == 0.0) rate = reader->sampleRate;
        if (reader->sampleRate != rate) continue;
        const juce::int64 wanted = (juce::int64)(kAnalysisSeconds * rate);
        const juce::int64 start = reader->lengthInSamples > wanted * 2 ? reader->lengthInSamples / 4 : 0;
        const int count = (int)juce::jmin(wanted, reader->lengthInSamples - start);
        if (count <= 0) continue;
        const int channels = juce::jmin(2, (int)reader->numChannels);
        juce::AudioBuffer<float> buffer(channels, count);
        reader->read(&buffer, 0, count, start, true, channels > 1);

        float previous = 0;
        size_t slice = 0;
        for (int frame = 0; frame + kHop <= count; frame += kHop, ++slice)
        {
            float energy = 0;
            for (int c = 0; c < channels; ++c)
            {
                const float* data = buffer.getReadPointer(c, frame);
                for (int i = 0; i < kHop; ++i) energy += data[i] * data[i];
            }
            const float level = std::log(1 + 1000 * energy / (float)(kHop * channels));
            if (envelope.size() <= slice) envelope.resize(slice + 1, 0.0f);
            envelope[slice] += std::fmax(0.0f, level - previous);
            previous = level;
        }
    }
    return rate > 0 ? estimate(std::move(envelope), rate / kHop) : 0.0;
}

} // namespace tempo
} // namespace dsm
