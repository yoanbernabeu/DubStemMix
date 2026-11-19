// Split.h - a full song into four stems (PRD § 12): drums, bass, instruments, vocals, with htdemucs_ft run by
// ONNX Runtime on the processor. A port of the Mac app's Sources/StemSplit: same model files, same folders,
// same manifest, so a song split by one app is not computed again by the other.
//
// The model files are never shipped: they are downloaded once, after the user agrees (PRD § 12.2).
// ONNX Runtime is a library placed beside the program and loaded when a song is split; without it the app
// runs and says so.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <juce_audio_formats/juce_audio_formats.h>
#include <juce_cryptography/juce_cryptography.h>

#include <onnxruntime_c_api.h>

#include <atomic>
#include <cmath>
#include <functional>
#include <memory>
#include <vector>

namespace dsm {
namespace split {

// The four stems, in the order they land on the strips (PRD § 12.1).
enum Stem { Drums = 0, Bass, Instruments, Vocals, StemCount };

inline const char* stemName(int stem)
{
    static const char* names[StemCount] = {"drums", "bass", "instruments", "vocals"};
    return names[stem];
}
// The htdemucs_ft network that makes this stem.
inline const char* modelName(int stem) { return stem == Instruments ? "other" : stemName(stem); }
inline juce::String stemFile(int stem) { return juce::String(stemName(stem)) + ".wav"; }
inline juce::String stemLabel(int stem) { return juce::String(stemName(stem)).toUpperCase(); }

constexpr double kModelRate = 44100.0;

struct Stereo
{
    std::vector<float> left, right;
    long long size() const { return (long long)left.size(); }
    void resize(long long frames) { left.assign((size_t)frames, 0.0f); right.assign((size_t)frames, 0.0f); }
};

// "ARTIST - TITLE" from a file name, as the Mac app cleans it.
inline juce::String songTitle(const juce::File& source)
{
    return source.getFileNameWithoutExtension().trimCharactersAtStart(" ()[]_-.").trimCharactersAtEnd(" ()[]_-.").toUpperCase();
}

// "Artist - Title": the name of a prepared project's file.
inline juce::String capitalised(const juce::String& text)
{
    juce::String out;
    bool inWord = false;
    for (int i = 0; i < text.length(); ++i)
    {
        const juce::juce_wchar c = text[i];
        const bool wordCharacter = juce::CharacterFunctions::isLetterOrDigit(c) || c == '\'' || c == 0x2019;
        out << (juce::juce_wchar)(wordCharacter && !inWord ? juce::CharacterFunctions::toUpperCase(c) : juce::CharacterFunctions::toLowerCase(c));
        inWord = wordCharacter;
    }
    return out;
}

// ----------------------------------------------------------------------------------------------------
// Chunks and overlap-add: the model takes 7.8 s at a time
// ----------------------------------------------------------------------------------------------------

constexpr int kChunk = 343980;            // samples per model input, imposed by the model
constexpr int kOverlap = kChunk / 4;
constexpr int kStride = kChunk - kOverlap;

inline int chunkCount(long long total)
{
    return juce::jmax(1, (int)std::ceil((double)total / (double)kStride));
}

// Linear ramps over the overlap at both ends, 1 in between. As in Demucs the ramp starts at 1/overlap, never
// at 0: every sample of the song gets a positive weight.
inline std::vector<float> window()
{
    std::vector<float> w((size_t)kChunk, 1.0f);
    for (int i = 0; i < kOverlap; ++i)
    {
        const float ramp = (float)(i + 1) / (float)kOverlap;
        w[(size_t)i] = ramp;
        w[(size_t)(kChunk - 1 - i)] = ramp;
    }
    return w;
}

// Sums the windowed chunks and divides by the summed window.
class Accumulator
{
public:
    explicit Accumulator(long long total) : weights_((size_t)total, 0.0f), window_(window()) { out_.resize(total); }

    // One chunk's output: `length` valid samples per channel, starting at `start` in the song.
    void add(const float* left, const float* right, long long start, int length)
    {
        const long long n = juce::jmin((long long)length, out_.size() - start);
        for (long long i = 0; i < n; ++i)
        {
            const float w = window_[(size_t)i];
            out_.left[(size_t)(start + i)] += left[i] * w;
            out_.right[(size_t)(start + i)] += right[i] * w;
            weights_[(size_t)(start + i)] += w;
        }
    }

    Stereo finish()
    {
        for (size_t i = 0; i < weights_.size(); ++i)
        {
            const float w = juce::jmax(weights_[i], 1.0e-8f);
            out_.left[i] /= w;
            out_.right[i] /= w;
        }
        return std::move(out_);
    }

private:
    Stereo out_;
    std::vector<float> weights_, window_;
};

// One network's separation of a whole song; the job calls it once per stem. Tests pass a fake.
struct Separator
{
    virtual ~Separator() = default;
    // `progress(chunk, chunkCount)` after each chunk; `cancelled()` is asked between chunks.
    virtual bool separate(int stem, const Stereo& mix, Stereo& out, const std::function<void(int, int)>& progress,
                          const std::function<bool()>& cancelled, juce::String& error) = 0;
};

// ----------------------------------------------------------------------------------------------------
// The model files: pinned revision, sizes and hashes. Never bundled.
// ----------------------------------------------------------------------------------------------------

struct ModelFile
{
    int stem;
    juce::String name;
    juce::int64 bytes;
    juce::String sha256;
    juce::String url;
};

struct Catalog
{
    juce::String name, revision, repository;
    std::vector<ModelFile> files;

    juce::String shortRevision() const { return revision.substring(0, 8); }
    // Names the model in the stems' manifests: another model, and every song is split again.
    juce::String id() const { return name + "@" + shortRevision(); }
    juce::int64 totalBytes() const
    {
        juce::int64 total = 0;
        for (const ModelFile& f : files) total += f.bytes;
        return total;
    }
    int megabytes() const { return (int)((double)totalBytes() / 1.0e6); }

    // Shown before any download (PRD § 12.2).
    juce::String licenseNotice() const
    {
        return "Weights: htdemucs_ft by Meta (Demucs), ONNX export by StemSplitio (Hugging Face, revision " + shortRevision() + "). "
               "The export is published under MIT, but Meta's original weights carry no explicit license and were trained on "
               "MUSDB18-HQ (\"educational purposes only\"). DubStemMix downloads them on your request and never redistributes them.";
    }

    static const Catalog& htdemucs()
    {
        static const Catalog catalog = []
        {
            Catalog c;
            c.name = "htdemucs_ft";
            c.revision = "8616370ed541bc183dbe15fb0d54d5f49918f47e";
            c.repository = "StemSplitio/htdemucs-ft-onnx";
            const char* hashes[StemCount] = {"047764dff888cfb87da917013377d4ec7a134f7419cbe486d9c339aa17975ddd",
                                             "b533037176b14b2df31c92a5d5b3d5660d0811b9b360d3db761964768b079961",
                                             "b739171a7057b3107bb0711c6222d4a619b41b13a8f04026431d30f32ad2bd71",
                                             "0cbe651f535415c9d26a7bb614f7d322dd5a080fa0298f2e50f478030a994dce"};
            for (int s = 0; s < StemCount; ++s)
            {
                const juce::String file = "htdemucs_ft_" + juce::String(modelName(s)) + "_fp16weights.onnx";
                c.files.push_back({s, file, 165612636, hashes[s], "https://huggingface.co/" + c.repository + "/resolve/" + c.revision + "/" + file});
            }
            return c;
        }();
        return catalog;
    }
};

inline juce::String sha256(const juce::File& file)
{
    return juce::SHA256(file).toHexString().removeCharacters(" ").toLowerCase();
}

// Where the model files live and how they get there: asked-for download, resumed after a cut, size and
// SHA-256 checked, moved in place only when right. A file present with the right size counts as checked.
class ModelStore
{
public:
    enum Status { Missing, Partial, Ready };

    ModelStore(const juce::File& directory, const Catalog& catalog) : directory_(directory), catalog_(catalog) {}

    const Catalog& catalog() const { return catalog_; }
    const juce::File& directory() const { return directory_; }
    juce::File file(int stem) const { return directory_.getChildFile(catalog_.files[(size_t)stem].name); }

    int readyCount() const
    {
        int ready = 0;
        for (const ModelFile& f : catalog_.files) ready += present(f) ? 1 : 0;
        return ready;
    }
    Status status() const
    {
        const int ready = readyCount();
        return ready == 0 ? Missing : ready == (int)catalog_.files.size() ? Ready : Partial;
    }
    bool isReady() const { return status() == Ready; }

    bool remove() const { return !directory_.exists() || directory_.deleteRecursively(); }

    // Downloads what is missing, one file after the other. `progress(received, total)` counts the files
    // already there as received.
    bool download(const std::function<void(juce::int64, juce::int64)>& progress, const std::function<bool()>& cancelled, juce::String& error) const
    {
        if (!directory_.createDirectory()) { error = "cannot write in " + directory_.getFullPathName(); return false; }
        juce::int64 done = 0;
        for (const ModelFile& f : catalog_.files) if (present(f)) done += f.bytes;
        progress(done, catalog_.totalBytes());
        for (const ModelFile& f : catalog_.files)
        {
            if (present(f)) continue;
            const juce::File part = directory_.getChildFile(f.name + ".part");
            const juce::int64 base = done;
            if (!fetch(f, part, [&](juce::int64 received) { progress(base + received, catalog_.totalBytes()); }, cancelled, error)) return false;
            if (cancelled()) { error = "cancelled"; return false; }
            if (sha256(part) != f.sha256)
            {
                part.deleteFile();
                error = f.name + " did not match its checksum and was discarded";
                return false;
            }
            const juce::File target = directory_.getChildFile(f.name);
            target.deleteFile();
            if (!part.moveFileTo(target)) { error = "cannot write " + target.getFullPathName(); return false; }
            done += f.bytes;
            progress(done, catalog_.totalBytes());
        }
        return true;
    }

private:
    bool present(const ModelFile& f) const
    {
        const juce::File file = directory_.getChildFile(f.name);
        return file.existsAsFile() && file.getSize() == f.bytes;
    }

    // Streams a file, going on from what is already there when the server allows it.
    static bool fetch(const ModelFile& f, const juce::File& part, const std::function<void(juce::int64)>& progress,
                      const std::function<bool()>& cancelled, juce::String& error)
    {
        juce::int64 existing = part.existsAsFile() ? part.getSize() : 0;
        if (existing > f.bytes) { part.deleteFile(); existing = 0; }
        if (existing == f.bytes) { progress(existing); return true; }

        const juce::URL url(f.url);
        int status = 0;
        const juce::URL::InputStreamOptions options = juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inAddress)
                                                          .withConnectionTimeoutMs(20000).withNumRedirectsToFollow(8).withStatusCode(&status)
                                                          .withExtraHeaders(existing > 0 ? "Range: bytes=" + juce::String(existing) + "-" : juce::String());
        std::unique_ptr<juce::InputStream> in = url.createInputStream(options);
        if (in == nullptr) { error = "no answer from " + url.getDomain(); return false; }
        if (!url.isLocalFile() && status != 200 && status != 206) { error = "the server answered " + juce::String(status); return false; }
        // The range was not honoured: start over.
        if (status != 206 && existing > 0) { part.deleteFile(); existing = 0; }

        juce::FileOutputStream out(part);   // opens at the end of what is there
        if (!out.openedOk()) { error = "cannot write " + part.getFullPathName(); return false; }
        juce::HeapBlock<char> buffer(1 << 16);
        juce::int64 received = existing;
        for (;;)
        {
            const int n = in->read(buffer.get(), 1 << 16);
            if (n <= 0) break;
            if (!out.write(buffer.get(), (size_t)n)) { error = "cannot write " + part.getFullPathName(); return false; }
            received += n;
            progress(received);
            if (cancelled()) { error = "cancelled"; return false; }
        }
        out.flush();
        if (received != f.bytes) { error = f.name + " came back incomplete"; return false; }
        return true;
    }

    juce::File directory_;
    Catalog catalog_;
};

// ----------------------------------------------------------------------------------------------------
// ONNX Runtime: its library beside the program, loaded on first use
// ----------------------------------------------------------------------------------------------------

class OnnxRuntime
{
public:
    static OnnxRuntime& get()
    {
        static OnnxRuntime instance;
        return instance;
    }

    static juce::File libraryFile()
    {
       #if JUCE_WINDOWS
        const char* name = "onnxruntime.dll";
       #elif JUCE_MAC
        const char* name = "libonnxruntime.dylib";
       #else
        const char* name = "libonnxruntime.so";
       #endif
        return juce::File::getSpecialLocation(juce::File::currentExecutableFile).getSiblingFile(name);
    }

    const OrtApi* api = nullptr;
    OrtEnv* env = nullptr;      // one per app
    juce::String error;

    bool ok() const { return api != nullptr && env != nullptr; }

    // An ONNX Runtime call's status as text ("" when it went well); the status is released.
    juce::String failure(OrtStatus* status) const
    {
        if (status == nullptr) return {};
        const juce::String text = juce::String::fromUTF8(api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return text.isEmpty() ? juce::String("ONNX Runtime failed") : text;
    }

private:
    OnnxRuntime()
    {
        const juce::File file = libraryFile();
        if (!file.existsAsFile() || !library_.open(file.getFullPathName()))
        {
            error = "the separation engine's library is missing (" + file.getFileName() + ")";
            return;
        }
        using GetApiBase = const OrtApiBase* (ORT_API_CALL*)(void);
        const GetApiBase getBase = (GetApiBase)library_.getFunction("OrtGetApiBase");
        const OrtApiBase* base = getBase != nullptr ? getBase() : nullptr;
        const OrtApi* found = base != nullptr ? base->GetApi(ORT_API_VERSION) : nullptr;
        if (found == nullptr) { error = "the separation engine's library is not the expected version"; return; }
        api = found;
        error = failure(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "dubstemmix", &env));
    }

    juce::DynamicLibrary library_;
};

// htdemucs_ft on the processor: one network in memory at a time, the whole song through it chunk by chunk.
class OnnxSeparator : public Separator
{
public:
    explicit OnnxSeparator(const ModelStore& store) : store_(store) {}

    bool separate(int stem, const Stereo& mix, Stereo& out, const std::function<void(int, int)>& progress,
                  const std::function<bool()>& cancelled, juce::String& error) override
    {
        OnnxRuntime& ort = OnnxRuntime::get();
        if (!ort.ok()) { error = ort.error; return false; }
        const OrtApi* api = ort.api;
        OrtSessionOptions* options = nullptr;
        OrtSession* session = nullptr;
        OrtMemoryInfo* memory = nullptr;
        const juce::File model = store_.file(stem);

        error = ort.failure(api->CreateSessionOptions(&options));
        if (error.isEmpty()) error = ort.failure(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
       #if JUCE_WINDOWS
        if (error.isEmpty()) error = ort.failure(api->CreateSession(ort.env, model.getFullPathName().toWideCharPointer(), options, &session));
       #else
        if (error.isEmpty()) error = ort.failure(api->CreateSession(ort.env, model.getFullPathName().toRawUTF8(), options, &session));
       #endif
        if (error.isEmpty()) error = ort.failure(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));

        const int count = chunkCount(mix.size());
        Accumulator accumulator(mix.size());
        std::vector<float> input((size_t)(2 * kChunk));
        const int64_t shape[3] = {1, 2, kChunk};
        const char* inputNames[1] = {"mix"};
        const char* outputNames[1] = {"stems"};
        bool stopped = false;
        for (int chunk = 0; chunk < count && error.isEmpty(); ++chunk)
        {
            if (cancelled()) { stopped = true; break; }
            const long long start = (long long)chunk * kStride;
            const int length = (int)juce::jmin((long long)kChunk, mix.size() - start);
            // The chunk, padded with silence to the model's size.
            std::fill(input.begin(), input.end(), 0.0f);
            std::copy(mix.left.begin() + start, mix.left.begin() + start + length, input.begin());
            std::copy(mix.right.begin() + start, mix.right.begin() + start + length, input.begin() + kChunk);

            OrtValue* in = nullptr;
            OrtValue* result = nullptr;
            error = ort.failure(api->CreateTensorWithDataAsOrtValue(memory, input.data(), input.size() * sizeof(float), shape, 3,
                                                                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in));
            if (error.isEmpty())
            {
                const OrtValue* inputs[1] = {in};
                error = ort.failure(api->Run(session, nullptr, inputNames, inputs, 1, outputNames, 1, &result));
            }
            // The answer is [1, 4, 2, N]: four stems, of which this network's own row is kept.
            if (error.isEmpty())
            {
                OrtTensorTypeAndShapeInfo* info = nullptr;
                size_t elements = 0;
                error = ort.failure(api->GetTensorTypeAndShape(result, &info));
                if (error.isEmpty()) error = ort.failure(api->GetTensorShapeElementCount(info, &elements));
                if (info != nullptr) api->ReleaseTensorTypeAndShapeInfo(info);
                if (error.isEmpty() && elements != (size_t)(StemCount * 2) * (size_t)kChunk) error = "the model returned an unexpected output";
            }
            if (error.isEmpty())
            {
                float* data = nullptr;
                error = ort.failure(api->GetTensorMutableData(result, (void**)&data));
                if (error.isEmpty())
                    accumulator.add(data + (size_t)(stem * 2) * (size_t)kChunk, data + (size_t)(stem * 2 + 1) * (size_t)kChunk, start, length);
            }
            if (result != nullptr) api->ReleaseValue(result);
            if (in != nullptr) api->ReleaseValue(in);
            if (error.isEmpty()) progress(chunk + 1, count);
        }
        if (memory != nullptr) api->ReleaseMemoryInfo(memory);
        if (session != nullptr) api->ReleaseSession(session);
        if (options != nullptr) api->ReleaseSessionOptions(options);
        if (stopped) { error = "cancelled"; return false; }
        if (error.isNotEmpty()) return false;
        out = accumulator.finish();
        return true;
    }

private:
    const ModelStore& store_;
};

// ----------------------------------------------------------------------------------------------------
// Files in, files out
// ----------------------------------------------------------------------------------------------------

inline juce::AudioFormatManager& audioFormats()
{
    static juce::AudioFormatManager manager;
    static const bool registered = (manager.registerBasicFormats(), true);
    juce::ignoreUnused(registered);
    return manager;
}

// Length in seconds, or -1 when the file cannot be read.
inline double audioSeconds(const juce::File& file)
{
    std::unique_ptr<juce::AudioFormatReader> reader(audioFormats().createReaderFor(file));
    return reader != nullptr && reader->sampleRate > 0 ? (double)reader->lengthInSamples / reader->sampleRate : -1.0;
}

// Any file JUCE reads -> stereo at 44.1 kHz, the model's rate. Mono is doubled; more than two channels: the first two.
inline bool loadAudio(const juce::File& file, Stereo& out, juce::String& error)
{
    std::unique_ptr<juce::AudioFormatReader> reader(audioFormats().createReaderFor(file));
    if (reader == nullptr || reader->sampleRate <= 0) { error = "can't read this audio file"; return false; }
    if (reader->lengthInSamples <= 0) { error = "the file has no audio"; return false; }
    const int frames = (int)reader->lengthInSamples;
    juce::AudioBuffer<float> buffer(2, frames);
    if (!reader->read(&buffer, 0, frames, 0, true, true)) { error = "can't read this audio file"; return false; }
    if (std::fabs(reader->sampleRate - kModelRate) < 0.5)
    {
        out.left.assign(buffer.getReadPointer(0), buffer.getReadPointer(0) + frames);
        out.right.assign(buffer.getReadPointer(1), buffer.getReadPointer(1) + frames);
        return true;
    }
    const double ratio = reader->sampleRate / kModelRate;
    const int wanted = (int)std::ceil((double)frames / ratio);   // as the engine counts a stem's length
    if (wanted <= 0) { error = "the file has no audio"; return false; }
    out.resize(wanted);
    // The interpolator answers a little late: silence is fed after the end and its delay is cut from the start,
    // so the stems stay in time with the original.
    const int delay = (int)std::lround((double)juce::WindowedSincInterpolator().getBaseLatency() / ratio);
    const int tail = (int)std::ceil((double)(delay + 8) * ratio) + 256;
    juce::AudioBuffer<float> padded(2, frames + tail);
    padded.clear();
    std::vector<float> converted((size_t)(wanted + delay));
    for (int c = 0; c < 2; ++c)
    {
        padded.copyFrom(c, 0, buffer, c, 0, frames);
        juce::WindowedSincInterpolator resampler;
        resampler.process(ratio, padded.getReadPointer(c), converted.data(), wanted + delay, frames + tail, 0);
        std::copy(converted.begin() + delay, converted.end(), (c == 0 ? out.left : out.right).begin());
    }
    return true;
}

// WAV, 32-bit float, 44.1 kHz, stereo.
inline bool writeStem(const Stereo& audio, const juce::File& file)
{
    file.deleteFile();
    std::unique_ptr<juce::FileOutputStream> stream(file.createOutputStream());
    if (stream == nullptr) return false;
    juce::WavAudioFormat wav;
    std::unique_ptr<juce::AudioFormatWriter> writer(wav.createWriterFor(stream.get(), kModelRate, 2, 32, {}, 0));   // 32 bits: float
    if (writer == nullptr) return false;
    stream.release();   // the writer owns it now
    const float* channels[2] = {audio.left.data(), audio.right.data()};
    return writer->writeFromFloatArrays(channels, 2, (int)audio.size()) && writer->flush();
}

// ----------------------------------------------------------------------------------------------------
// One song from file to four stems
// ----------------------------------------------------------------------------------------------------

constexpr const char* kManifest = "stems.json";

struct Result
{
    bool ok = false, reused = false, cancelled = false;
    juce::File folder, stems[StemCount];
    juce::String error;
};

// "<file name> [fingerprint]": the same file split again lands in the same place.
inline juce::File folderFor(const juce::File& source, const juce::String& fingerprint, const juce::File& root)
{
    return root.getChildFile(source.getFileNameWithoutExtension().replaceCharacter('/', '-') + " [" + fingerprint.substring(0, 8) + "]");
}

// Stems already made for this file with this model: the manifest says so and the four files are there.
inline bool existing(const juce::File& source, const juce::String& fingerprint, const juce::File& root, const juce::String& modelId, Result& out)
{
    const juce::File folder = folderFor(source, fingerprint, root);
    const juce::var manifest = juce::JSON::parse(folder.getChildFile(kManifest).loadFileAsString());
    if (manifest["fingerprint"].toString() != fingerprint || manifest["model"].toString() != modelId) return false;
    Result found;
    found.folder = folder;
    for (int s = 0; s < StemCount; ++s)
    {
        found.stems[s] = folder.getChildFile(stemFile(s));
        if (!found.stems[s].existsAsFile()) return false;
    }
    found.ok = found.reused = true;
    out = found;
    return true;
}

struct Progress
{
    int stem = 0, chunk = 0, chunkCount = 1;
    // Over the whole song: 4 networks x chunkCount chunks.
    double fraction() const { return (double)(stem * chunkCount + chunk) / (double)(StemCount * chunkCount); }
};

// Decodes, runs one network at a time, writes each stem as soon as its network is done, the manifest last.
// Meant for a background thread. A cancelled or failed job leaves nothing behind.
inline Result run(const juce::File& source, const juce::File& root, const juce::String& modelId,
                  const std::function<std::unique_ptr<Separator>()>& makeSeparator,
                  const std::function<void(const Progress&)>& progress, const std::function<bool()>& cancelled)
{
    Result result;
    if (!source.existsAsFile()) { result.error = "can't read this audio file"; return result; }
    const juce::String fingerprint = sha256(source);
    if (existing(source, fingerprint, root, modelId, result)) return result;
    if (!root.createDirectory()) { result.error = "cannot write in " + root.getFullPathName(); return result; }

    Stereo mix;
    if (!loadAudio(source, mix, result.error)) return result;
    const juce::File folder = folderFor(source, fingerprint, root);
    const juce::File temporary = root.getChildFile("." + folder.getFileName() + ".tmp");
    temporary.deleteRecursively();
    if (!temporary.createDirectory()) { result.error = "cannot write in " + root.getFullPathName(); return result; }

    const std::unique_ptr<Separator> separator = makeSeparator();
    bool ok = separator != nullptr;
    if (!ok) result.error = "the separation engine is not available";
    for (int stem = 0; ok && stem < StemCount; ++stem)
    {
        if (cancelled()) { result.cancelled = true; ok = false; break; }
        Stereo separated;
        ok = separator->separate(stem, mix, separated, [&](int chunk, int count) { progress({stem, chunk, count}); }, cancelled, result.error);
        if (!ok) { result.cancelled = cancelled(); break; }
        ok = writeStem(separated, temporary.getChildFile(stemFile(stem)));
        if (!ok) result.error = "cannot write " + stemFile(stem);
    }
    if (ok)
    {
        // Same manifest as the Mac app: its dates count seconds from 2001.
        auto* manifest = new juce::DynamicObject();
        manifest->setProperty("created", (double)juce::Time::currentTimeMillis() / 1000.0 - 978307200.0);
        manifest->setProperty("fingerprint", fingerprint);
        manifest->setProperty("model", modelId);
        manifest->setProperty("source", source.getFullPathName());
        ok = temporary.getChildFile(kManifest).replaceWithText(juce::JSON::toString(juce::var(manifest)));
        if (!ok) result.error = "cannot write the stems' manifest";
    }
    // Into place. A folder already there keeps whatever else it holds (a project saved beside older stems).
    if (ok) ok = folder.createDirectory().wasOk();
    for (int s = 0; ok && s <= StemCount; ++s)
    {
        const juce::String name = s < StemCount ? stemFile(s) : juce::String(kManifest);
        folder.getChildFile(name).deleteFile();
        ok = temporary.getChildFile(name).moveFileTo(folder.getChildFile(name));
        if (!ok) result.error = "cannot write in " + folder.getFullPathName();
    }
    temporary.deleteRecursively();
    if (!ok) return result;
    result.ok = true;
    result.folder = folder;
    for (int s = 0; s < StemCount; ++s) result.stems[s] = folder.getChildFile(stemFile(s));
    return result;
}

// ----------------------------------------------------------------------------------------------------
// The preparation mode's list (PRD § 12.6): songs split one at a time, in the list's order
// ----------------------------------------------------------------------------------------------------

class Queue
{
public:
    enum Status { Waiting, Running, Done, Failed };

    struct Item
    {
        int id = 0;
        juce::File source;
        double seconds = -1.0;    // the song's length, for the time left; -1: the file cannot be read
        Status status = Waiting;
        juce::File project;       // Done: the project written beside the stems
        bool reused = false;      // Done: the project was already there, left untouched
        juce::String error;       // Failed
    };

    const std::vector<Item>& items() const { return items_; }

    const Item* running() const
    {
        for (const Item& item : items_) if (item.status == Running) return &item;
        return nullptr;
    }
    int count(Status status) const
    {
        int n = 0;
        for (const Item& item : items_) n += item.status == status ? 1 : 0;
        return n;
    }
    // Something waits or runs: the mode cannot be left.
    bool hasWork() const { return count(Waiting) + count(Running) > 0; }

    // At the end of the list; a file already waiting or running is not added twice. Returns how many were added.
    int add(const juce::File& source, double seconds)
    {
        for (const Item& item : items_)
            if (item.source == source && (item.status == Waiting || item.status == Running)) return 0;
        Item item;
        item.id = ++lastId_;
        item.source = source;
        item.seconds = seconds;
        items_.push_back(item);
        return 1;
    }

    // Only a waiting song can be removed or moved.
    void remove(int id)
    {
        for (size_t i = 0; i < items_.size(); ++i)
            if (items_[i].id == id && items_[i].status == Waiting) { items_.erase(items_.begin() + (long)i); return; }
    }

    // Up (-1) or down (+1) among the waiting songs.
    void move(int id, int by)
    {
        std::vector<size_t> waiting;
        for (size_t i = 0; i < items_.size(); ++i) if (items_[i].status == Waiting) waiting.push_back(i);
        for (size_t w = 0; w < waiting.size(); ++w)
        {
            if (items_[waiting[w]].id != id) continue;
            const long to = (long)w + by;
            if (to >= 0 && to < (long)waiting.size()) std::swap(items_[waiting[w]], items_[waiting[(size_t)to]]);
            return;
        }
    }

    // The first waiting song, now running; null when nothing waits or one already runs.
    const Item* startNext()
    {
        if (running() != nullptr) return nullptr;
        for (Item& item : items_)
            if (item.status == Waiting) { item.status = Running; return &item; }
        return nullptr;
    }

    void finish(int id, const juce::File& project, bool reused)
    {
        for (Item& item : items_) if (item.id == id) { item.status = Done; item.project = project; item.reused = reused; }
    }
    void fail(int id, const juce::String& error)
    {
        for (Item& item : items_) if (item.id == id) { item.status = Failed; item.error = error; }
    }

    // The running and waiting songs leave the list; the finished ones stay.
    void cancelAll()
    {
        items_.erase(std::remove_if(items_.begin(), items_.end(), [](const Item& i) { return i.status == Waiting || i.status == Running; }), items_.end());
    }
    void clear() { items_.clear(); }

    // Seconds left for the whole list at the measured speed (seconds of work per second of song), or -1 while
    // the speed is not known. `runningLeft` < 0: not known yet for the song under way.
    double timeLeft(double speed, double runningLeft) const
    {
        if (speed <= 0) return -1.0;
        double total = 0.0;
        if (const Item* now = running()) total += runningLeft >= 0 ? runningLeft : juce::jmax(0.0, now->seconds) * speed;
        for (const Item& item : items_) if (item.status == Waiting) total += juce::jmax(0.0, item.seconds) * speed;
        return total;
    }

private:
    std::vector<Item> items_;
    int lastId_ = 0;
};

} // namespace split
} // namespace dsm
