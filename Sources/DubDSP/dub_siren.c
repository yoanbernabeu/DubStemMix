// Dub siren (PRD § 15): an oscillator whose pitch a triangle LFO sweeps up and down (the "wou-wou"), played by
// holding a gate. Square wave (band-limited) by default, triangle on demand. RISE glides the pitch two octaves up
// while held and back down on release. The siren is added to the input, so with the gate closed and the sound
// gone it is an exact passthrough: the strip's stems, if any, go through untouched.

#include "dub_internal.h"

#define SIREN_DEPTH 0.5f   // LFO swing, in octaves either side of the pitch
#define SIREN_RISE 2.0f    // octaves climbed by RISE
#define SIREN_SQUARE 0.30f // output peaks: the triangle sounds softer, it gets more level
#define SIREN_TRIANGLE 0.45f

typedef struct {
    double phase, lfo;     // 0 … 1
    float env;             // amplitude, glided towards the gate
    float rise;            // octaves above the pitch, glided
    float pitch, rate;     // smoothed knobs
    float wave;            // 0 = square, 1 = triangle, crossfaded
    float tone;            // one-pole low-pass state, takes the edge off the square
    int sounding;
} SirenState;

static void siren_prepare(DubEffect *e) {
    SirenState *s = (SirenState *)e->state;
    memset(s, 0, sizeof *s);
    s->pitch = dub_param(e, DUB_SIREN_PITCH);
    s->rate = dub_param(e, DUB_SIREN_RATE);
    s->wave = dub_param(e, DUB_SIREN_WAVE) >= 0.5f ? 1.0f : 0.0f;
    s->lfo = 0.5;
}

/// PolyBLEP correction around a discontinuity at phase 0 (t in 0 … 1, dt = phase step).
static inline float siren_blep(double t, double dt) {
    if (t < dt) { t /= dt; return (float)(t + t - t * t - 1.0); }
    if (t > 1.0 - dt) { t = (t - 1.0) / dt; return (float)(t * t + t + t + 1.0); }
    return 0.0f;
}

static void siren_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    SirenState *s = (SirenState *)e->state;
    const int gate = dub_param(e, DUB_SIREN_GATE) >= 0.5f;
    if (!gate && !s->sounding) {
        if (outL != inL) memcpy(outL, inL, (size_t)frames * sizeof(float));
        if (outR != inR) memcpy(outR, inR, (size_t)frames * sizeof(float));
        return;
    }
    if (gate && !s->sounding) { // a new blow starts low in the sweep, rising
        s->sounding = 1;
        s->lfo = 0.5;
    }
    const float sr = (float)e->sampleRate;
    const float pitch = dub_clamp(dub_param(e, DUB_SIREN_PITCH), 50.0f, 4000.0f);
    const float rate = dub_clamp(dub_param(e, DUB_SIREN_RATE), 0.05f, 30.0f);
    const float wave = dub_param(e, DUB_SIREN_WAVE) >= 0.5f ? 1.0f : 0.0f;
    const float riseTarget = dub_param(e, DUB_SIREN_RISE) >= 0.5f ? SIREN_RISE : 0.0f;
    const float knob = dub_onepole(1.0 / (2.0 * DUB_PI * 0.03), sr);
    const float riseUp = dub_onepole(1.0 / (2.0 * DUB_PI * 0.6), sr), riseDown = dub_onepole(1.0 / (2.0 * DUB_PI * 0.3), sr);
    const float attack = dub_onepole(1.0 / (2.0 * DUB_PI * 0.004), sr), release = dub_onepole(1.0 / (2.0 * DUB_PI * 0.05), sr);
    const float toneA = dub_onepole(7000.0, sr);
    const float nyquistGuard = 0.45f * sr;

    for (int n = 0; n < frames; n++) {
        s->pitch += (pitch - s->pitch) * knob;
        s->rate += (rate - s->rate) * knob;
        s->wave += (wave - s->wave) * knob;
        s->rise += (riseTarget - s->rise) * (riseTarget > s->rise ? riseUp : riseDown);
        s->env += ((gate ? 1.0f : 0.0f) - s->env) * (gate ? attack : release);

        s->lfo += s->rate / sr;
        if (s->lfo >= 1.0) s->lfo -= 1.0;
        const float tri = 4.0f * fabsf((float)s->lfo - 0.5f) - 1.0f; // 1 at 0, −1 at 0.5
        float freq = s->pitch * exp2f(SIREN_DEPTH * tri + s->rise);
        if (freq > nyquistGuard) freq = nyquistGuard;
        const double dt = freq / sr;
        s->phase += dt;
        if (s->phase >= 1.0) s->phase -= 1.0;

        double half = s->phase + 0.5;
        if (half >= 1.0) half -= 1.0;
        const float square = (s->phase < 0.5 ? 1.0f : -1.0f) + siren_blep(s->phase, dt) - siren_blep(half, dt);
        const float triangle = 4.0f * fabsf((float)s->phase - 0.5f) - 1.0f;
        const float x = (1.0f - s->wave) * SIREN_SQUARE * square + s->wave * SIREN_TRIANGLE * triangle;
        s->tone += toneA * (x - s->tone);
        const float y = s->env * s->tone;
        outL[n] = inL[n] + y;
        outR[n] = inR[n] + y;
    }
    if (!gate && s->env < 1e-5f) { // gone: back to an exact passthrough, the next blow starts clean
        s->sounding = 0;
        s->env = 0.0f;
        s->tone = 0.0f;
        s->rise = 0.0f;
    }
}

static void siren_destroy(DubEffect *e) { free(e->state); }

void dub_siren_install(DubEffect *e) {
    SirenState *s = (SirenState *)calloc(1, sizeof(SirenState));
    if (!s) return;
    e->state = s;
    e->prepare = siren_prepare;
    e->process = siren_process;
    e->destroy = siren_destroy;
    dub_effect_set(e, DUB_SIREN_PITCH, 470.0f);
    dub_effect_set(e, DUB_SIREN_RATE, 1.5f);
}
