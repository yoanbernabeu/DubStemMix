// Tape flanger (PRD § 11.5), the seventies "jet" on a send bus: a short modulated delay with feedback.
// Like the phaser, the output is the delayed signal only — summed with the strip's dry signal it carves the
// comb. Uses the phaser's parameter indices: rate (Hz), depth (0 … 1), feedback (0 … 0.95), center (Hz →
// base delay = 1 / center: 200 Hz → 5 ms, 2 kHz → 0.5 ms), stereo (LFO phase offset).

#include "dub_internal.h"

#define FLANGER_MAX_SECONDS 0.03

typedef struct {
    DubLine line[2];
    float last[2];
    float delay, depth, feedback; // smoothed
    double phase;
} FlangerState;

static void flanger_prepare(DubEffect *e) {
    FlangerState *s = (FlangerState *)e->state;
    for (int c = 0; c < 2; c++) { dub_line_clear(&s->line[c]); s->last[c] = 0.0f; }
    s->delay = (float)e->sampleRate / dub_clamp(dub_param(e, DUB_PHASER_CENTER), 100.0f, 4000.0f);
    s->depth = dub_param(e, DUB_PHASER_DEPTH);
    s->feedback = dub_param(e, DUB_PHASER_FEEDBACK);
    s->phase = 0.0;
}

static void flanger_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    FlangerState *s = (FlangerState *)e->state;
    const float sr = (float)e->sampleRate;
    const float *in[2] = { inL, inR };
    float *out[2] = { outL, outR };
    const float rate = dub_clamp(dub_param(e, DUB_PHASER_RATE), 0.02f, 10.0f);
    const float targetDepth = dub_clamp(dub_param(e, DUB_PHASER_DEPTH), 0.0f, 1.0f);
    const float targetFeedback = dub_clamp(dub_param(e, DUB_PHASER_FEEDBACK), 0.0f, 0.95f);
    const float targetDelay = sr / dub_clamp(dub_param(e, DUB_PHASER_CENTER), 100.0f, 4000.0f);
    const double stereoOffset = dub_clamp(dub_param(e, DUB_PHASER_STEREO), 0.0f, 1.0f) * DUB_PI;
    const float smooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.03), sr);
    const double inc = 2.0 * DUB_PI * rate / sr;
    const float maxDelay = (float)(s->line[0].mask - 8);

    for (int n = 0; n < frames; n++) {
        s->depth += (targetDepth - s->depth) * smooth;
        s->feedback += (targetFeedback - s->feedback) * smooth;
        s->delay += (targetDelay - s->delay) * smooth;
        s->phase += inc;
        if (s->phase > 2.0 * DUB_PI) s->phase -= 2.0 * DUB_PI;
        for (int c = 0; c < 2; c++) {
            // The delay sweeps around its base, down to a fraction of it: the classic jet.
            const float lfo = 0.5f * (1.0f + (float)sin(s->phase + c * stereoOffset));
            const float delay = dub_clamp(s->delay * (1.0f - 0.9f * s->depth * lfo), 2.0f, maxDelay);
            const float delayed = dub_line_tap_frac(&s->line[c], delay);
            dub_line_push(&s->line[c], tanhf(in[c][n] + s->feedback * delayed));
            out[c][n] = delayed;
        }
    }
}

static void flanger_destroy(DubEffect *e) {
    FlangerState *s = (FlangerState *)e->state;
    for (int c = 0; c < 2; c++) dub_line_free(&s->line[c]);
    free(s);
}

void dub_flanger_install(DubEffect *e) {
    FlangerState *s = (FlangerState *)calloc(1, sizeof(FlangerState));
    if (!s) return;
    const int length = (int)(FLANGER_MAX_SECONDS * DUB_MAX_SAMPLE_RATE);
    if (!dub_line_init(&s->line[0], length) || !dub_line_init(&s->line[1], length)) {
        dub_line_free(&s->line[0]);
        free(s);
        return;
    }
    e->state = s;
    e->prepare = flanger_prepare;
    e->process = flanger_process;
    e->destroy = flanger_destroy;
    dub_effect_set(e, DUB_PHASER_RATE, 0.3f);
    dub_effect_set(e, DUB_PHASER_DEPTH, 0.75f);
    dub_effect_set(e, DUB_PHASER_FEEDBACK, 0.6f);
    dub_effect_set(e, DUB_PHASER_CENTER, 400.0f);
    dub_effect_set(e, DUB_PHASER_STEREO, 0.5f);
}
