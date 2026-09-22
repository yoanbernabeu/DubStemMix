// Spring reverb (PRD § 11.4): the tank of a Fisher Space Expander or a guitar amp, the sound of King Tubby's
// and Lee Perry's thunder.
//
//   input ──▶ low cut ──▶ predelay ──(+)──▶ delay ──▶ dispersive allpass chain ──┬──▶ damping ──▶ tone ──▶ out
//                                    ▲                                          │
//                                    └──────────── decay × damped ◀─────────────┘
//
// A spring is a dispersive line: low frequencies travel slower than high ones, so a transient comes out as
// a downward chirp ("boing"). A chain of first-order allpass sections gives that dispersion; the loop delay
// sets the flutter rate of the chirps. Two slightly different springs give the stereo pair. The same five
// parameters as the plate apply (same indices, same units). CRASH injects a hard burst into the loop —
// the tank being kicked.

#include "dub_internal.h"

#define STAGES 72
#define CRASH_SAMPLES 900

typedef struct {
    DubLine loop;
    int loopLen;
    float allpass[STAGES];   // one state per first-order section
    float damp;
} Spring;

typedef struct {
    DubLine predelay;
    Spring spring[2];
    float lowCutState, toneState[2];
    float decay;             // smoothed loop gain
    int crashLeft;           // samples of burst still to inject
    unsigned int noise;
} SpringState;

static const double kLoopSeconds[2] = { 0.047, 0.053 };
static const float kAllpassCoeff[2] = { 0.62f, 0.60f };

static void spring_prepare(DubEffect *e) {
    SpringState *s = (SpringState *)e->state;
    const double sr = e->sampleRate;
    dub_line_clear(&s->predelay);
    for (int i = 0; i < 2; i++) {
        Spring *sp = &s->spring[i];
        dub_line_clear(&sp->loop);
        sp->loopLen = (int)(kLoopSeconds[i] * sr);
        memset(sp->allpass, 0, sizeof sp->allpass);
        sp->damp = 0.0f;
    }
    s->lowCutState = s->toneState[0] = s->toneState[1] = 0.0f;
    s->decay = dub_param(e, DUB_PLATE_DECAY);
    s->crashLeft = 0;
    s->noise = 7777;
}

static inline float lcg(unsigned int *state) {
    *state = *state * 1664525u + 1013904223u;
    return (float)(*state >> 8) / 16777216.0f * 2.0f - 1.0f; // −1 … 1
}

static void spring_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    SpringState *s = (SpringState *)e->state;
    const float sr = (float)e->sampleRate;
    // Decay 0.2 … 0.97 (the plate's range) → loop gain 0.63 … 0.96.
    const float targetDecay = 0.55f + 0.42f * dub_clamp(dub_param(e, DUB_PLATE_DECAY), 0.0f, 0.98f);
    const float damping = dub_clamp(dub_param(e, DUB_PLATE_DAMPING), 0.0f, 0.95f);
    const int predelay = (int)(dub_clamp(dub_param(e, DUB_PLATE_PREDELAY), 0.0f, 0.25f) * sr) + 1;
    const float lowCutA = dub_onepole(dub_clamp(dub_param(e, DUB_PLATE_LOW_CUT), 10.0f, 2000.0f), sr);
    const float toneA = dub_onepole(dub_clamp(dub_param(e, DUB_PLATE_TONE), 500.0f, 20000.0f), sr);
    const float smooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.05), sr);
    if (dub_param(e, DUB_SPRING_CRASH) >= 0.5f) {
        s->crashLeft = (int)(CRASH_SAMPLES * sr / 48000.0f);
        dub_effect_set(e, DUB_SPRING_CRASH, 0.0f); // consumed
    }

    for (int n = 0; n < frames; n++) {
        s->decay += (targetDecay - s->decay) * smooth;

        float x = 0.5f * (inL[n] + inR[n]);
        s->lowCutState += lowCutA * (x - s->lowCutState);
        x -= s->lowCutState;
        const float delayed = dub_line_tap(&s->predelay, predelay);
        dub_line_push(&s->predelay, x);

        // The crash: a dense, loud burst kicked straight into both tanks.
        float kick = 0.0f;
        if (s->crashLeft > 0) {
            const float env = (float)s->crashLeft / (CRASH_SAMPLES * sr / 48000.0f);
            kick = 2.5f * env * env * lcg(&s->noise);
            s->crashLeft--;
        }

        for (int i = 0; i < 2; i++) {
            Spring *sp = &s->spring[i];
            const float a = kAllpassCoeff[i];
            float y = dub_line_tap(&sp->loop, sp->loopLen);
            // Dispersive chain: first-order allpass sections, y = -a·x + z, z = x + a·y.
            for (int k = 0; k < STAGES; k++) {
                const float out = -a * y + sp->allpass[k];
                sp->allpass[k] = y + a * out;
                y = out;
            }
            sp->damp = y * (1.0f - damping) + sp->damp * damping;
            const float back = tanhf(delayed + kick + s->decay * sp->damp);
            dub_line_push(&sp->loop, back);
            s->toneState[i] += toneA * (y - s->toneState[i]);
        }
        outL[n] = s->toneState[0];
        outR[n] = s->toneState[1];
    }
}

static void spring_destroy(DubEffect *e) {
    SpringState *s = (SpringState *)e->state;
    dub_line_free(&s->predelay);
    for (int i = 0; i < 2; i++) dub_line_free(&s->spring[i].loop);
    free(s);
}

void dub_spring_install(DubEffect *e) {
    SpringState *s = (SpringState *)calloc(1, sizeof(SpringState));
    if (!s) return;
    int ok = dub_line_init(&s->predelay, (int)(0.25 * DUB_MAX_SAMPLE_RATE) + 2);
    for (int i = 0; i < 2; i++) ok &= dub_line_init(&s->spring[i].loop, (int)(kLoopSeconds[i] * DUB_MAX_SAMPLE_RATE) + 2);
    e->state = s;
    e->destroy = spring_destroy;
    if (!ok) { spring_destroy(e); e->state = NULL; return; }
    dub_effect_set(e, DUB_PLATE_DECAY, 0.75f);
    dub_effect_set(e, DUB_PLATE_DAMPING, 0.35f);
    dub_effect_set(e, DUB_PLATE_PREDELAY, 0.0f);
    dub_effect_set(e, DUB_PLATE_LOW_CUT, 180.0f);
    dub_effect_set(e, DUB_PLATE_TONE, 6000.0f);
    dub_effect_set(e, DUB_SPRING_CRASH, 0.0f);
    e->prepare = spring_prepare;
    e->process = spring_process;
}
