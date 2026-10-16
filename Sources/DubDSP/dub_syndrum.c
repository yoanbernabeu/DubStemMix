// Syndrum (PRD § 15), the electronic drum of late-seventies dub: a sine whose pitch falls as it dies away ("piou"),
// with a short noise click on the attack. One hit per trigger; ROLL retriggers it at a set interval while held.
// Added to the input, an exact passthrough once silent: the strip's stems, if any, go through untouched.

#include "dub_internal.h"

#define SYNDRUM_LEVEL 0.6f
#define SYNDRUM_FLOOR 0.35f  // the pitch falls to this fraction of the start
#define SYNDRUM_CLICK 0.25f
#define SYNDRUM_ATTACK 0.001 // seconds: a retrigger ramps from where the last hit was, no click

typedef struct {
    double phase;
    int since;          // samples since the hit
    int active;
    float start;        // amplitude when the hit came (a retrigger rises from it)
    float amp;          // last amplitude
    float pitch, decay; // smoothed knobs
    int rolling, rollLeft;
    unsigned noise;
} SyndrumState;

static void syndrum_prepare(DubEffect *e) {
    SyndrumState *s = (SyndrumState *)e->state;
    memset(s, 0, sizeof *s);
    s->pitch = dub_param(e, DUB_SYNDRUM_PITCH);
    s->decay = dub_param(e, DUB_SYNDRUM_DECAY);
    s->noise = 22222u;
}

static void syndrum_hit(SyndrumState *s) {
    s->start = s->active ? s->amp : 0.0f;
    s->since = 0;
    s->active = 1;
}

static void syndrum_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    SyndrumState *s = (SyndrumState *)e->state;
    const float sr = (float)e->sampleRate;
    if (dub_param(e, DUB_SYNDRUM_HIT) >= 0.5f) {
        dub_effect_set(e, DUB_SYNDRUM_HIT, 0.0f); // consumed
        syndrum_hit(s);
    }
    const int rolling = dub_param(e, DUB_SYNDRUM_ROLLING) >= 0.5f;
    const int interval = (int)(dub_clamp(dub_param(e, DUB_SYNDRUM_ROLL), 0.03f, 2.0f) * sr);
    if (rolling && !s->rolling) { // the roll starts on a hit
        syndrum_hit(s);
        s->rollLeft = interval;
    }
    s->rolling = rolling;
    if (!s->active && !rolling) {
        if (outL != inL) memcpy(outL, inL, (size_t)frames * sizeof(float));
        if (outR != inR) memcpy(outR, inR, (size_t)frames * sizeof(float));
        return;
    }
    const float pitch = dub_clamp(dub_param(e, DUB_SYNDRUM_PITCH), 30.0f, 3000.0f);
    const float decay = dub_clamp(dub_param(e, DUB_SYNDRUM_DECAY), 0.02f, 4.0f);
    const float knob = dub_onepole(1.0 / (2.0 * DUB_PI * 0.03), sr);
    const float attackSamples = (float)(SYNDRUM_ATTACK * sr);

    for (int n = 0; n < frames; n++) {
        if (rolling && --s->rollLeft <= 0) {
            syndrum_hit(s);
            s->rollLeft = interval;
        }
        s->pitch += (pitch - s->pitch) * knob;
        s->decay += (decay - s->decay) * knob;
        float y = 0.0f;
        if (s->active) {
            const float t = (float)s->since / sr;
            float amp = expf(-6.9f * t / s->decay); // −60 dB at the decay time
            if (s->since < attackSamples) amp = s->start + (amp - s->start) * ((float)s->since / attackSamples);
            s->amp = amp;
            const float freq = s->pitch * (SYNDRUM_FLOOR + (1.0f - SYNDRUM_FLOOR) * expf(-t / (0.3f * s->decay)));
            s->phase += freq / sr;
            if (s->phase >= 1.0) s->phase -= 1.0;
            s->noise = s->noise * 1664525u + 1013904223u;
            const float white = (float)(s->noise >> 8) / 8388608.0f - 1.0f;
            const float click = SYNDRUM_CLICK * white * expf(-t / 0.003f);
            y = SYNDRUM_LEVEL * amp * (sinf(2.0f * (float)DUB_PI * (float)s->phase) + click);
            s->since++;
            if (amp < 1e-4f && s->since > attackSamples) s->active = 0;
        }
        outL[n] = inL[n] + y;
        outR[n] = inR[n] + y;
    }
}

static void syndrum_destroy(DubEffect *e) { free(e->state); }

void dub_syndrum_install(DubEffect *e) {
    SyndrumState *s = (SyndrumState *)calloc(1, sizeof(SyndrumState));
    if (!s) return;
    e->state = s;
    e->prepare = syndrum_prepare;
    e->process = syndrum_process;
    e->destroy = syndrum_destroy;
    dub_effect_set(e, DUB_SYNDRUM_PITCH, 310.0f);
    dub_effect_set(e, DUB_SYNDRUM_DECAY, 0.35f);
    dub_effect_set(e, DUB_SYNDRUM_ROLL, 0.125f);
}
