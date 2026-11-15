// Stems.h - reading a song's stems from the plugin's Content/Songs folder: listing, WAV streaming,
// the ring buffer between the disk thread and the audio thread, and the strip names.

#pragma once

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <dirent.h>
#include <time.h>

namespace stems {

// ~1.5 s of stereo audio per stem at 44.1 kHz. Power of two so the ring index is a mask.
constexpr size_t kRingFrames = 65536;
// The disk thread reads this many frames at a time.
constexpr size_t kChunkFrames = 4096;

inline bool hasWavExtension(const std::string& name)
{
    if (name.size() < 4) return false;
    std::string ext = name.substr(name.size() - 4);
    for (char& c : ext) c = (char)std::tolower((unsigned char)c);
    return ext == ".wav";
}

inline std::vector<std::string> listDir(const std::string& path, bool wantDirs)
{
    std::vector<std::string> out;
    DIR* dir = opendir(path.c_str());
    if (dir == nullptr) return out;
    while (dirent* e = readdir(dir))
    {
        std::string name = e->d_name;
        if (name.empty() || name[0] == '.') continue;
        bool isDir = e->d_type == DT_DIR;
        if (e->d_type == DT_UNKNOWN || e->d_type == DT_LNK)
        {
            DIR* probe = opendir((path + "/" + name).c_str());
            isDir = probe != nullptr;
            if (probe) closedir(probe);
        }
        if (wantDirs ? isDir : (!isDir && hasWavExtension(name))) out.push_back(name);
    }
    closedir(dir);
    std::sort(out.begin(), out.end());
    return out;
}

inline double nowSeconds()
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// A WAV file read in chunks, converted to stereo float. Used only by the disk thread.
class WavReader
{
public:
    ~WavReader() { close(); }

    bool open(const std::string& path)
    {
        close();
        file_ = std::fopen(path.c_str(), "rb");
        if (file_ == nullptr) return false;
        uint8_t head[12];
        if (std::fread(head, 1, 12, file_) != 12 || std::memcmp(head, "RIFF", 4) != 0 || std::memcmp(head + 8, "WAVE", 4) != 0)
            return fail();
        uint32_t format = 0;
        for (;;)
        {
            uint8_t ch[8];
            if (std::fread(ch, 1, 8, file_) != 8) return fail();
            const uint32_t len = u32(ch + 4);
            if (std::memcmp(ch, "fmt ", 4) == 0 && len >= 16)
            {
                std::vector<uint8_t> fmt(len);
                if (std::fread(fmt.data(), 1, len, file_) != len) return fail();
                format = u16(&fmt[0]);
                channels_ = (int)u16(&fmt[2]);
                rate_ = u32(&fmt[4]);
                bits_ = (int)u16(&fmt[14]);
                if (format == 0xFFFE && len >= 26) format = u16(&fmt[24]);
                if (len & 1u) std::fseek(file_, 1, SEEK_CUR);
            }
            else if (std::memcmp(ch, "data", 4) == 0)
            {
                bytesLeft_ = len;
                break;
            }
            else if (std::fseek(file_, (long)(len + (len & 1u)), SEEK_CUR) != 0)
                return fail();
        }
        isFloat_ = format == 3 && bits_ == 32;
        const bool pcm = format == 1 && (bits_ == 16 || bits_ == 24 || bits_ == 32);
        if (channels_ < 1 || channels_ > 16 || (!isFloat_ && !pcm)) return fail();
        frameBytes_ = (size_t)channels_ * (size_t)(bits_ / 8);
        scratch_.resize(kChunkFrames * frameBytes_);
        return true;
    }

    // Reads up to `frames` frames into interleaved stereo `out`. Returns the number read; 0 at the end.
    size_t read(float* out, size_t frames)
    {
        if (file_ == nullptr) return 0;
        frames = std::min(frames, std::min(kChunkFrames, (size_t)(bytesLeft_ / frameBytes_)));
        if (frames == 0) return 0;
        const size_t got = std::fread(scratch_.data(), frameBytes_, frames, file_);
        bytesLeft_ -= (uint32_t)(got * frameBytes_);
        const size_t bytes = (size_t)(bits_ / 8);
        for (size_t i = 0; i < got; ++i)
        {
            const uint8_t* s = scratch_.data() + i * frameBytes_;
            const float l = sample(s);
            const float r = channels_ > 1 ? sample(s + bytes) : l;
            out[2 * i] = l;
            out[2 * i + 1] = r;
        }
        return got;
    }

    void close()
    {
        if (file_) std::fclose(file_);
        file_ = nullptr;
        bytesLeft_ = 0;
    }

    uint32_t rate() const { return rate_; }
    // Frames left to read (the whole file right after open()).
    size_t framesLeft() const { return frameBytes_ ? bytesLeft_ / frameBytes_ : 0; }

private:
    static uint32_t u16(const uint8_t* p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
    static uint32_t u32(const uint8_t* p) { return u16(p) | (u16(p + 2) << 16); }
    bool fail() { close(); return false; }

    float sample(const uint8_t* s) const
    {
        if (isFloat_) { float v; std::memcpy(&v, s, 4); return v; }
        if (bits_ == 16) return (float)(int16_t)(s[0] | (s[1] << 8)) / 32768.0f;
        if (bits_ == 24) return (float)((int32_t)(((uint32_t)s[0] << 8) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 24)) >> 8) / 8388608.0f;
        return (float)(int32_t)u32(s) / 2147483648.0f;
    }

    std::FILE* file_ = nullptr;
    int channels_ = 0, bits_ = 0;
    uint32_t rate_ = 0, bytesLeft_ = 0;
    bool isFloat_ = false;
    size_t frameBytes_ = 0;
    std::vector<uint8_t> scratch_;
};

// Single producer (disk thread) / single consumer (audio thread) ring of stereo frames.
struct StemRing
{
    std::vector<float> data = std::vector<float>(kRingFrames * 2);
    std::atomic<size_t> written{0}, read{0};
    std::atomic<bool> present{false};   // this strip has a stem in the current song
    std::atomic<bool> finished{false};  // the file has been read to the end
};

struct Song
{
    std::string name;
    std::vector<std::string> stems;   // full paths, strip order
    std::vector<std::string> labels;  // strip names shown on screen (BASSE, DRUMS...)
};

// Strip names from the stem file names, as on the Mac: the part that differs between the files, upper case.
// "1 - Artist - Title (Bass)_1.wav" and "2 - Artist - Title (Drums)_1.wav" give "BASS" and "DRUMS". The common
// prefix and suffix are cut only at a word boundary ("drums" and "bass" keep their final "s").
inline std::vector<std::string> stripLabels(const std::vector<std::string>& files)
{
    std::vector<std::string> names;
    for (std::string f : files)
    {
        f = f.substr(f.find_last_of('/') + 1);
        if (f.size() > 4) f.resize(f.size() - 4);   // .wav
        size_t i = 0;                              // "1 - " added by prepare-song.sh
        while (i < f.size() && std::isdigit((unsigned char)f[i])) ++i;
        if (i > 0 && f.compare(i, 3, " - ") == 0) f = f.substr(i + 3);
        names.push_back(f);
    }
    auto boundary = [](char c) { return !std::isalnum((unsigned char)c); };
    size_t pre = 0, suf = 0;
    if (names.size() > 1)
    {
        pre = names[0].size();
        suf = names[0].size();
        for (const std::string& n : names)
        {
            size_t p = 0;
            while (p < pre && p < n.size() && n[p] == names[0][p]) ++p;
            pre = p;
            size_t q = 0;
            while (q < suf && q < n.size() && n[n.size() - 1 - q] == names[0][names[0].size() - 1 - q]) ++q;
            suf = q;
        }
        while (pre > 0 && !boundary(names[0][pre - 1])) --pre;
        while (suf > 0 && !boundary(names[0][names[0].size() - suf])) --suf;
    }
    std::vector<std::string> out;
    for (const std::string& n : names)
    {
        std::string core = n.size() > pre + suf ? n.substr(pre, n.size() - pre - suf) : n;
        std::string clean;
        for (char c : core)
            if (std::isalnum((unsigned char)c) || (c == ' ' && !clean.empty() && clean.back() != ' ')) clean += (char)std::toupper((unsigned char)c);
        while (!clean.empty() && clean.back() == ' ') clean.pop_back();
        out.push_back(clean.empty() ? n : clean);
    }
    return out;
}

} // namespace stems
