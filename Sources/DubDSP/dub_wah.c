// Auto-wah (PRD § 11.5), Mu-Tron III style: an envelope follower drives the cutoff of a resonant
// state-variable low-pass. Louder opens the filter (or closes it, in "down" mode). Insert effect: the
// output is the filtered signal only.

#include "dub_internal.h"

#define BASE_HZ 180.0f

typedef struct {
    float envelope;
    float cutoff;          // smoothed, Hz
    float low[2], band[2]; // state-variable filter per channel
} WahState;

static void wah_prepare(DubEffect *e) {
    WahState *s = (WahState *)e->state;
    memset(s, 0, sizeof *s);
    s->cutoff = BASE_HZ;
}

static void wah_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    WahState *s = (WahState *)e->state;
    const float sr = (float)e->sampleRate;
    const float *in[2] = { inL, inR };
    float *out[2] = { outL, outR };
    const float sensitivity = dub_clamp(dub_param(e, DUB_WAH_SENSITIVITY), 0.0f, 1.0f);
    const float range = dub_clamp(dub_param(e, DUB_WAH_RANGE), 0.0f, 1.0f) * 3.0f; // octaves
    const float resonance = dub_clamp(dub_param(e, DUB_WAH_RESONANCE), 0.0f, 1.0f);
    const int down = dub_param(e, DUB_WAH_DIRECTION) >= 0.5f;
    const float attack = dub_onepole(1.0 / (2.0 * DUB_PI * 0.006), sr), release = dub_onepole(1.0 / (2.0 * DUB_PI * 0.09), sr);
    const float glide = dub_onepole(1.0 / (2.0 * DUB_PI * 0.004), sr);
    // Q from 0.7 (gentle) to 10 (the honk). Damping term of the SVF = 1/Q.
    const float damping = 1.0f / (0.7f + 9.3f * resonance);
    const float top = BASE_HZ * powf(2.0f, range);

    for (int n = 0; n < frames; n++) {
        const float mag = fabsf(0.5f * (inL[n] + inR[n]));
        s->envelope += (mag > s->envelope ? attack : release) * (mag - s->envelope);
        // Envelope 0 … ~0.5 → position 0 … 1 across the sweep, scaled by sensitivity.
        float position = dub_clamp(s->envelope * 4.0f * (0.2f + 1.8f * sensitivity), 0.0f, 1.0f);
        if (down) position = 1.0f - position;
        const float target = BASE_HZ * powf(top / BASE_HZ, position);
        s->cutoff += (target - s->cutoff) * glide;
        const float f = 2.0f * sinf((float)DUB_PI * dub_clamp(s->cutoff, 40.0f, sr * 0.2f) / sr);
        for (int c = 0; c < 2; c++) {
            // Chamberlin state-variable filter, low-pass output, soft-bounded band state.
            const float high = in[c][n] - s->low[c] - damping * s->band[c];
            s->band[c] += f * high;
            s->low[c] += f * s->band[c];
            s->band[c] = tanhf(s->band[c]);
            out[c][n] = s->low[c];
        }
    }
}

static void wah_destroy(DubEffect *e) { free(e->state); }

void dub_wah_install(DubEffect *e) {
    WahState *s = (WahState *)calloc(1, sizeof(WahState));
    if (!s) return;
    e->state = s;
    e->prepare = wah_prepare;
    e->process = wah_process;
    e->destroy = wah_destroy;
    dub_effect_set(e, DUB_WAH_SENSITIVITY, 0.6f);
    dub_effect_set(e, DUB_WAH_RANGE, 0.7f);
    dub_effect_set(e, DUB_WAH_RESONANCE, 0.5f);
    dub_effect_set(e, DUB_WAH_DIRECTION, 0.0f);
}
