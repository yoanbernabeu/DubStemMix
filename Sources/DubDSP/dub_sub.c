// Sub-octave generator (PRD § 11.5), the dbx "boom box" idea: follow the bass fundamental, produce a
// square wave an octave below it (a flip-flop toggling on the fundamental's rising zero crossings), shape
// it with the fundamental's envelope, low-pass it into a sine-ish sub, and add it under the dry signal.
// Amount 0 is an exact passthrough. Sums the input to mono for the detector; the sub is added to both sides.

#include "dub_internal.h"

typedef struct {
    float bandLP[2], bandHP;      // detector band-pass: 2-pole LP at 200 Hz, 1-pole HP at 35 Hz
    float lastBand;
    float flip;                   // ±1
    float envelope;
    float subLP[4];               // 4-pole low-pass on the square wave (kills the square's harmonics)
    float amount;                 // smoothed
} SubState;

static void sub_prepare(DubEffect *e) {
    SubState *s = (SubState *)e->state;
    memset(s, 0, sizeof *s);
    s->flip = 1.0f;
    s->amount = dub_param(e, DUB_SUB_AMOUNT);
}

static void sub_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    SubState *s = (SubState *)e->state;
    const float sr = (float)e->sampleRate;
    const float targetAmount = dub_clamp(dub_param(e, DUB_SUB_AMOUNT), 0.0f, 1.0f);
    if (targetAmount <= 0.0f && s->amount <= 0.0001f) {
        s->amount = 0.0f;
        if (outL != inL) memcpy(outL, inL, (size_t)frames * sizeof(float));
        if (outR != inR) memcpy(outR, inR, (size_t)frames * sizeof(float));
        return;
    }
    const float bandLPA = dub_onepole(200.0, sr), bandHPA = dub_onepole(35.0, sr);
    const float subA = dub_onepole(dub_clamp(dub_param(e, DUB_SUB_CUTOFF), 40.0f, 160.0f), sr);
    const float attack = dub_onepole(1.0 / (2.0 * DUB_PI * 0.004), sr), release = dub_onepole(1.0 / (2.0 * DUB_PI * 0.08), sr);
    const float smooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.02), sr);

    for (int n = 0; n < frames; n++) {
        s->amount += (targetAmount - s->amount) * smooth;
        float x = 0.5f * (inL[n] + inR[n]);
        // Detector band: what the flip-flop and the envelope listen to.
        s->bandLP[0] += bandLPA * (x - s->bandLP[0]);
        s->bandLP[1] += bandLPA * (s->bandLP[0] - s->bandLP[1]);
        s->bandHP += bandHPA * (s->bandLP[1] - s->bandHP);
        const float band = s->bandLP[1] - s->bandHP;
        if (s->lastBand <= 0.0f && band > 0.0f) s->flip = -s->flip; // rising zero crossing: toggle
        s->lastBand = band;
        const float mag = fabsf(band);
        s->envelope += (mag > s->envelope ? attack : release) * (mag - s->envelope);
        // Square wave an octave down, at the fundamental's level, smoothed into a round sub.
        const float square = s->flip * s->envelope * 2.2f;
        s->subLP[0] += subA * (square - s->subLP[0]);
        for (int k = 1; k < 4; k++) s->subLP[k] += subA * (s->subLP[k - 1] - s->subLP[k]);
        const float sub = s->amount * s->subLP[3];
        outL[n] = inL[n] + sub;
        outR[n] = inR[n] + sub;
    }
}

static void sub_destroy(DubEffect *e) { free(e->state); }

void dub_sub_install(DubEffect *e) {
    SubState *s = (SubState *)calloc(1, sizeof(SubState));
    if (!s) return;
    e->state = s;
    e->prepare = sub_prepare;
    e->process = sub_process;
    e->destroy = sub_destroy;
    dub_effect_set(e, DUB_SUB_AMOUNT, 0.0f);
    dub_effect_set(e, DUB_SUB_CUTOFF, 90.0f);
}
