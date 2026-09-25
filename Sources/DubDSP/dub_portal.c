// Bus-to-bus sends through memory (issue #1, patched while playing).
//
// AVAudioEngine only renders a graph without cycles, and can only rewire with the engine stopped (which cuts
// every tail). So the buses are never wired to one another: each bus return writes itself into a ring
// (dub_portal_write, from a pass-through unit), and each bus input reads what the others send it
// (dub_portal_read, from a source node), one render slice later. Every source → target pair exists at all times;
// patching is only a gain, glided over 10 ms: no rewiring, no cut, whatever the order the engine renders them in.
// The slice of delay (3 to 11 ms with the usual buffers) disappears in an echo or a reverb.

#include "dub_internal.h"

#define PORTAL_BUSES 3
#define PORTAL_SIZE 16384            // power of two, far more than a render slice
#define PORTAL_MASK (PORTAL_SIZE - 1)
#define PORTAL_STEP (1.0f / 480.0f)  // gain glide: 10 ms at 48 kHz

struct DubPortal {
    float ring[PORTAL_BUSES][2][PORTAL_SIZE];
    // Written span of each source, in the engine's sample time: from `start` (the current unbroken run) to `end`.
    _Atomic long long start[PORTAL_BUSES], end[PORTAL_BUSES];
    _Atomic float gain[PORTAL_BUSES][PORTAL_BUSES];   // [source][target], set from any thread
    float current[PORTAL_BUSES][PORTAL_BUSES];        // glided, owned by the target's reader
};

DubPortal *dub_portal_create(void) {
    DubPortal *portal = (DubPortal *)calloc(1, sizeof(DubPortal));
    if (portal) {
        for (int s = 0; s < PORTAL_BUSES; s++) {
            atomic_store(&portal->start[s], 0);
            atomic_store(&portal->end[s], 0);
        }
    }
    return portal;
}

void dub_portal_destroy(DubPortal *portal) { free(portal); }

void dub_portal_set_gain(DubPortal *portal, int source, int target, float gain) {
    if (source < 0 || source >= PORTAL_BUSES || target < 0 || target >= PORTAL_BUSES) return;
    atomic_store_explicit(&portal->gain[source][target], source == target ? 0.0f : gain, memory_order_relaxed);
}

void dub_portal_write(DubPortal *portal, int source, double sampleTime, const float *left, const float *right, int frames) {
    if (source < 0 || source >= PORTAL_BUSES || frames <= 0) return;
    const long long t = (long long)sampleTime;
    // A jump in time (engine restarted, first slice) starts a new run: nothing before it is ever read.
    if (t != atomic_load_explicit(&portal->end[source], memory_order_relaxed)) {
        atomic_store_explicit(&portal->start[source], t, memory_order_relaxed);
    }
    for (int n = 0; n < frames; n++) {
        const int index = (int)((t + n) & PORTAL_MASK);
        portal->ring[source][0][index] = left[n];
        portal->ring[source][1][index] = right[n];
    }
    atomic_store_explicit(&portal->end[source], t + frames, memory_order_release);
}

void dub_portal_read(DubPortal *portal, int target, double sampleTime, float *left, float *right, int frames) {
    memset(left, 0, (size_t)frames * sizeof(float));
    memset(right, 0, (size_t)frames * sizeof(float));
    if (target < 0 || target >= PORTAL_BUSES || frames <= 0) return;
    const long long t = (long long)sampleTime;
    const long long from = t - frames; // the previous slice: written whichever of the two ran first
    for (int s = 0; s < PORTAL_BUSES; s++) {
        if (s == target) continue;
        const float wanted = atomic_load_explicit(&portal->gain[s][target], memory_order_relaxed);
        float gain = portal->current[s][target];
        if (wanted == 0.0f && gain == 0.0f) continue;
        const long long end = atomic_load_explicit(&portal->end[s], memory_order_acquire);
        const long long start = atomic_load_explicit(&portal->start[s], memory_order_relaxed);
        // The source must be at most a slice ahead of us (else it belongs to another run of the engine).
        const int valid = end >= t && end - t <= PORTAL_SIZE / 4;
        for (int n = 0; n < frames; n++) {
            gain = gain < wanted ? (gain + PORTAL_STEP > wanted ? wanted : gain + PORTAL_STEP)
                                 : (gain - PORTAL_STEP < wanted ? wanted : gain - PORTAL_STEP);
            const long long p = from + n;
            if (!valid || p < start) continue;
            const int index = (int)(p & PORTAL_MASK);
            left[n] += gain * portal->ring[s][0][index];
            right[n] += gain * portal->ring[s][1][index];
        }
        portal->current[s][target] = gain;
    }
}
