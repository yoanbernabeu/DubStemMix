// Sources.cpp - opens the stems of a strip for the engine: any format JUCE reads (WAV, AIFF, FLAC, OGG, MP3;
// M4A on macOS), any sample rate (converted to the engine's 44.1 kHz), several files summed.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "StripSource.h"

#include <juce_audio_formats/juce_audio_formats.h>

namespace dsm {

Transport& transport()
{
    static Transport instance;
    return instance;
}

Hooks& hooks()
{
    static Hooks instance;
    return instance;
}

namespace {

constexpr double kEngineRate = 44100.0;

juce::AudioFormatManager& formats()
{
    static juce::AudioFormatManager manager;
    static const bool registered = (manager.registerBasicFormats(), true);
    juce::ignoreUnused(registered);
    return manager;
}

// One file, resampled to 44.1 kHz stereo.
struct StemFile
{
    std::unique_ptr<juce::AudioFormatReaderSource> source;
    std::unique_ptr<juce::ResamplingAudioSource> resampled;
    long long frames = 0;   // length at 44.1 kHz

    void rewind()
    {
        source->setNextReadPosition(0);
        resampled->flushBuffers();
    }

    bool open(const std::string& path, long long startFrame)
    {
        juce::AudioFormatReader* reader = formats().createReaderFor(juce::File(juce::String::fromUTF8(path.c_str())));
        if (reader == nullptr || reader->sampleRate <= 0 || reader->lengthInSamples <= 0) { delete reader; return false; }
        const double ratio = reader->sampleRate / kEngineRate;
        frames = (long long)std::ceil((double)reader->lengthInSamples / ratio);
        source = std::make_unique<juce::AudioFormatReaderSource>(reader, true);
        source->setNextReadPosition((juce::int64)((double)startFrame * ratio));
        resampled = std::make_unique<juce::ResamplingAudioSource>(source.get(), false, 2);
        resampled->setResamplingRatio(ratio);
        resampled->prepareToPlay(4096, kEngineRate);
        return true;
    }
};

class MixedStrip : public StripSource
{
public:
    std::vector<std::unique_ptr<StemFile>> files;
    long long frames = 0, position = 0;

    void setLoopLength(long long length) override { loopLength_ = length; }

    size_t read(float* out, size_t wanted) override
    {
        const long long end = loopLength_ > 0 ? loopLength_ : frames;
        if (position >= end)
        {
            if (loopLength_ <= 0) return 0;
            // The loop point: every stem of the strip goes back to its top, to the sample.
            position = 0;
            for (const std::unique_ptr<StemFile>& file : files) file->rewind();
        }
        const long long left = end - position;
        const int n = (int)std::min<long long>((long long)wanted, left);
        if (sum_.getNumSamples() < n) { sum_.setSize(2, n, false, false, true); one_.setSize(2, n, false, false, true); }
        sum_.clear(0, n);
        for (const std::unique_ptr<StemFile>& file : files)
        {
            if (position >= file->frames) continue;   // a shorter stem: silence after its end
            one_.clear(0, n);
            juce::AudioSourceChannelInfo block(&one_, 0, n);
            file->resampled->getNextAudioBlock(block);
            sum_.addFrom(0, 0, one_, 0, 0, n);
            sum_.addFrom(1, 0, one_, 1, 0, n);
        }
        const float* left44 = sum_.getReadPointer(0);
        const float* right44 = sum_.getReadPointer(1);
        for (int i = 0; i < n; ++i) { out[2 * i] = left44[i]; out[2 * i + 1] = right44[i]; }
        position += n;
        return (size_t)n;
    }

private:
    juce::AudioBuffer<float> sum_, one_;
    long long loopLength_ = 0;
};

} // namespace

std::unique_ptr<StripSource> openStrip(const std::vector<std::string>& files, long long startFrame, long long& frames)
{
    frames = 0;
    auto strip = std::make_unique<MixedStrip>();
    for (const std::string& path : files)
    {
        auto file = std::make_unique<StemFile>();
        if (!file->open(path, startFrame)) continue;
        strip->frames = std::max(strip->frames, file->frames);
        strip->files.push_back(std::move(file));
    }
    if (strip->files.empty()) return nullptr;
    strip->position = startFrame;   // may be past this strip's own end: it then waits for the loop point, or ends
    frames = strip->frames;
    return strip;
}

} // namespace dsm
