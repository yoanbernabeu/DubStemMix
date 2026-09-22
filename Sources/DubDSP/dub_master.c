// Master chain (PRD § 11.3), in signal order: big knob → kills → dubplate.
//
// Big knob: King Tubby's stepped high-pass (MCI console). 12 dB/oct Butterworth, no resonance; the cutoff
// glides between steps (no click) but each step stays audible as a plateau. At or below 20 Hz the stage is
// bypassed exactly.
// Kills: sound-system isolator, three bands split by Linkwitz-Riley 24 dB/oct crossovers (the bands sum
// flat when all three are open). Each band goes from silence to unity, never above.
// Dubplate: an acetate played a hundred times. Bandwidth shrinks, tape-style soft saturation, a slow wobble
// (wow) — all scaled by one intensity, exact passthrough at zero. Crackle is a separate amount, added
// whatever the intensity.
//
// Every stage is neutral by default: the chain changes nothing until touched.

#include "dub_internal.h"

typedef struct { float b0, b1, b2, a1, a2; } Biquad;
typedef struct { float z1, z2; } BiquadState;

static inline float biquad_run(const Biquad *c, BiquadState *s, float x) {
    // Transposed direct form II.
    float y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return y;
}

static void biquad_lowpass(Biquad *c, float cutoff, float sr, float q) {
    float w = 2.0f * (float)DUB_PI * cutoff / sr, cw = cosf(w), sw = sinf(w), alpha = sw / (2.0f * q);
    float a0 = 1.0f + alpha;
    c->b0 = (1.0f - cw) * 0.5f / a0; c->b1 = (1.0f - cw) / a0; c->b2 = c->b0;
    c->a1 = -2.0f * cw / a0; c->a2 = (1.0f - alpha) / a0;
}

static void biquad_highpass(Biquad *c, float cutoff, float sr, float q) {
    float w = 2.0f * (float)DUB_PI * cutoff / sr, cw = cosf(w), sw = sinf(w), alpha = sw / (2.0f * q);
    float a0 = 1.0f + alpha;
    c->b0 = (1.0f + cw) * 0.5f / a0; c->b1 = -(1.0f + cw) / a0; c->b2 = c->b0;
    c->a1 = -2.0f * cw / a0; c->a2 = (1.0f - alpha) / a0;
}

#define BUTTERWORTH_Q 0.70710678f
#define KILL_LOW_HZ 200.0f
#define KILL_HIGH_HZ 2500.0f
#define WOW_MAX_SAMPLES 72.0f  // 1.5 ms at 48 kHz: base delay reached at full intensity

typedef struct {
    // Big knob
    float hpfCutoff;               // smoothed, Hz
    Biquad hpf;
    BiquadState hpfState[2];
    int hpfCounter;
    // Kills: LR4 = two cascaded Butterworth biquads per crossover
    Biquad lowLP, lowHP, highLP, highHP;
    BiquadState lowLPState[2][2], lowHPState[2][2], highLPState[2][2], highHPState[2][2];
    float bass, mid, top;          // smoothed gains
    // Dubplate
    float intensity, crackle;      // smoothed
    Biquad plateHP, plateLP;
    BiquadState plateHPState[2], plateLPState[2];
    int plateCounter;
    DubLine wowLine[2];
    double wowPhase;
    unsigned int noise;            // LCG state
    float crackleEnv[2];
    float crackleLP[2];
} MasterState;

static void master_prepare(DubEffect *e) {
    MasterState *s = (MasterState *)e->state;
    const float sr = (float)e->sampleRate;
    DubLine lines[2] = { s->wowLine[0], s->wowLine[1] };
    memset(s, 0, sizeof *s);
    s->wowLine[0] = lines[0];
    s->wowLine[1] = lines[1];
    dub_line_clear(&s->wowLine[0]);
    dub_line_clear(&s->wowLine[1]);
    s->hpfCutoff = dub_param(e, DUB_MASTER_HIGH_PASS);
    s->bass = dub_param(e, DUB_MASTER_BASS);
    s->mid = dub_param(e, DUB_MASTER_MID);
    s->top = dub_param(e, DUB_MASTER_TOP);
    s->intensity = dub_param(e, DUB_MASTER_DUBPLATE);
    s->crackle = dub_param(e, DUB_MASTER_CRACKLE);
    s->noise = 22222;
    biquad_lowpass(&s->lowLP, KILL_LOW_HZ, sr, BUTTERWORTH_Q);
    biquad_highpass(&s->lowHP, KILL_LOW_HZ, sr, BUTTERWORTH_Q);
    biquad_lowpass(&s->highLP, KILL_HIGH_HZ, sr, BUTTERWORTH_Q);
    biquad_highpass(&s->highHP, KILL_HIGH_HZ, sr, BUTTERWORTH_Q);
    biquad_highpass(&s->hpf, dub_clamp(s->hpfCutoff, 20.0f, sr * 0.45f), sr, BUTTERWORTH_Q);
}

static inline float lr4(const Biquad *c, BiquadState st[2], float x) { return biquad_run(c, &st[1], biquad_run(c, &st[0], x)); }

static inline float lcg(unsigned int *state) {
    *state = *state * 1664525u + 1013904223u;
    return (float)(*state >> 8) / 16777216.0f; // 0 … 1
}

static void master_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    MasterState *s = (MasterState *)e->state;
    const float sr = (float)e->sampleRate;
    const float *in[2] = { inL, inR };
    float *out[2] = { outL, outR };

    const float targetCutoff = dub_clamp(dub_param(e, DUB_MASTER_HIGH_PASS), 20.0f, sr * 0.45f);
    const int hpfBypass = dub_param(e, DUB_MASTER_HIGH_PASS) <= 20.0f && s->hpfCutoff <= 20.5f;
    const float targetBass = dub_clamp(dub_param(e, DUB_MASTER_BASS), 0.0f, 1.0f);
    const float targetMid = dub_clamp(dub_param(e, DUB_MASTER_MID), 0.0f, 1.0f);
    const float targetTop = dub_clamp(dub_param(e, DUB_MASTER_TOP), 0.0f, 1.0f);
    const float targetIntensity = dub_clamp(dub_param(e, DUB_MASTER_DUBPLATE), 0.0f, 1.0f);
    const float targetCrackle = dub_clamp(dub_param(e, DUB_MASTER_CRACKLE), 0.0f, 1.0f);
    const int killsOpen = targetBass >= 1.0f && targetMid >= 1.0f && targetTop >= 1.0f
                          && s->bass >= 0.9999f && s->mid >= 0.9999f && s->top >= 0.9999f;
    const int plateOff = targetIntensity <= 0.0f && s->intensity <= 0.0001f && targetCrackle <= 0.0f && s->crackle <= 0.0001f;

    const float gainSmooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.02), sr); // ~20 ms
    const float cutoffSmooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.03), sr); // ~30 ms glide between steps

    for (int n = 0; n < frames; n++) {
        float x[2] = { in[0][n], in[1][n] };

        // Big knob
        if (!hpfBypass) {
            s->hpfCutoff += (targetCutoff - s->hpfCutoff) * cutoffSmooth;
            if (s->hpfCounter-- <= 0) {
                s->hpfCounter = 15;
                biquad_highpass(&s->hpf, s->hpfCutoff, sr, BUTTERWORTH_Q);
            }
            for (int c = 0; c < 2; c++) x[c] = biquad_run(&s->hpf, &s->hpfState[c], x[c]);
        } else {
            s->hpfCutoff = 20.0f;
        }

        // Kills
        if (!killsOpen) {
            s->bass += (targetBass - s->bass) * gainSmooth;
            s->mid += (targetMid - s->mid) * gainSmooth;
            s->top += (targetTop - s->top) * gainSmooth;
            for (int c = 0; c < 2; c++) {
                float low = lr4(&s->lowLP, s->lowLPState[c], x[c]);
                float rest = lr4(&s->lowHP, s->lowHPState[c], x[c]);
                float mid = lr4(&s->highLP, s->highLPState[c], rest);
                float high = lr4(&s->highHP, s->highHPState[c], rest);
                x[c] = low * s->bass + mid * s->mid + high * s->top;
            }
        } else {
            s->bass = s->mid = s->top = 1.0f;
        }

        // Dubplate
        if (!plateOff) {
            s->intensity += (targetIntensity - s->intensity) * gainSmooth;
            s->crackle += (targetCrackle - s->crackle) * gainSmooth;
            const float i = s->intensity;
            if (s->plateCounter-- <= 0) {
                s->plateCounter = 31;
                // Bandwidth: 20 Hz → 80 Hz below, 18 kHz → 5 kHz above.
                biquad_highpass(&s->plateHP, 20.0f * powf(4.0f, i), sr, BUTTERWORTH_Q);
                biquad_lowpass(&s->plateLP, dub_clamp(18000.0f * powf(5000.0f / 18000.0f, i), 1000.0f, sr * 0.45f), sr, BUTTERWORTH_Q);
            }
            // Tape-style soft knee: unity below the knee, squashed towards 1.0 above it.
            const float knee = 1.0f - 0.7f * i;
            s->wowPhase += 2.0 * DUB_PI * 0.55 / sr;
            if (s->wowPhase > 2.0 * DUB_PI) s->wowPhase -= 2.0 * DUB_PI;
            // Base delay grows with intensity (so engaging the stage slides instead of clicking),
            // the wobble rides on top of it.
            const float base = WOW_MAX_SAMPLES * dub_clamp(i * 10.0f, 0.0f, 1.0f) * (sr / 48000.0f);
            const float wobble = base * 0.6f * i * (float)(0.7 * sin(s->wowPhase) + 0.3 * sin(3.1 * s->wowPhase + 1.0));
            for (int c = 0; c < 2; c++) {
                float y = biquad_run(&s->plateHP, &s->plateHPState[c], x[c]);
                float mag = fabsf(y);
                if (mag > knee) {
                    float squashed = knee + (1.0f - knee) * tanhf((mag - knee) / (1.0f - knee + 1e-6f));
                    y = copysignf(squashed, y);
                }
                y = biquad_run(&s->plateLP, &s->plateLPState[c], y);
                dub_line_push(&s->wowLine[c], y);
                y = dub_line_tap_frac(&s->wowLine[c], 1.0f + base + wobble);
                // Crackle: sparse random ticks, low-passed so they sound like dust, not digital clicks.
                float tick = 0.0f;
                if (s->crackle > 0.0001f) {
                    float r = lcg(&s->noise);
                    if (r < 0.00012f * s->crackle * s->crackle * 50.0f) s->crackleEnv[c] = (lcg(&s->noise) - 0.5f) * 0.6f * s->crackle;
                    s->crackleLP[c] += (s->crackleEnv[c] - s->crackleLP[c]) * 0.35f;
                    s->crackleEnv[c] *= 0.7f;
                    tick = s->crackleLP[c];
                }
                x[c] = y + tick;
            }
        } else {
            s->intensity = 0.0f;
            s->crackle = 0.0f;
        }

        out[0][n] = x[0];
        out[1][n] = x[1];
    }
}

static void master_destroy(DubEffect *e) {
    MasterState *s = (MasterState *)e->state;
    dub_line_free(&s->wowLine[0]);
    dub_line_free(&s->wowLine[1]);
    free(s);
}

void dub_master_install(DubEffect *e) {
    MasterState *s = (MasterState *)calloc(1, sizeof(MasterState));
    if (!s) return;
    if (!dub_line_init(&s->wowLine[0], 512) || !dub_line_init(&s->wowLine[1], 512)) {
        dub_line_free(&s->wowLine[0]);
        free(s);
        return;
    }
    e->state = s;
    e->prepare = master_prepare;
    e->process = master_process;
    e->destroy = master_destroy;
    // Neutral defaults.
    dub_effect_set(e, DUB_MASTER_HIGH_PASS, 20.0f);
    dub_effect_set(e, DUB_MASTER_BASS, 1.0f);
    dub_effect_set(e, DUB_MASTER_MID, 1.0f);
    dub_effect_set(e, DUB_MASTER_TOP, 1.0f);
    dub_effect_set(e, DUB_MASTER_DUBPLATE, 0.0f);
    dub_effect_set(e, DUB_MASTER_CRACKLE, 0.0f);
}
