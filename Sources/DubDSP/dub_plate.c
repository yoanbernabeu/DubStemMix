// Reverb plate de Dattorro (« Effect Design, Part 1 », JAES 1997). Entrée sommée en mono, sortie stéréo, 100 % wet.
// Les longueurs de l'article sont données pour 29 761 Hz et mises à l'échelle de la fréquence courante.

#include "dub_internal.h"

#define REF_RATE 29761.0
#define SCALE(n, sr) ((int)((n) * (sr) / REF_RATE + 0.5))

typedef struct {
    DubLine modAllpass, delay1, allpass2, delay2;
    int modAllpassLen, delay1Len, allpass2Len, delay2Len;
    float damp;
} TankHalf;

typedef struct {
    DubLine predelay;
    DubLine inAllpass[4];
    int inAllpassLen[4];
    TankHalf half[2];
    int tapsL[7], tapsR[7];
    float bandwidthState, lowCutState, toneState[2];
    float decay, damping; // lissés
    float excursion;
    double lfoPhase;
} PlateState;

static const int kInAllpass[4] = { 142, 107, 379, 277 };
static const float kInAllpassGain[4] = { 0.75f, 0.75f, 0.625f, 0.625f };
static const int kHalf[2][4] = { { 672, 4453, 1800, 3720 }, { 908, 4217, 2656, 3163 } };
static const int kTapsL[7] = { 266, 2974, 1913, 1996, 1990, 187, 1066 };
static const int kTapsR[7] = { 353, 3627, 1228, 2673, 2111, 335, 121 };

static void plate_prepare(DubEffect *e) {
    PlateState *s = (PlateState *)e->state;
    const double sr = e->sampleRate;
    dub_line_clear(&s->predelay);
    for (int i = 0; i < 4; i++) {
        dub_line_clear(&s->inAllpass[i]);
        s->inAllpassLen[i] = SCALE(kInAllpass[i], sr);
    }
    for (int h = 0; h < 2; h++) {
        TankHalf *t = &s->half[h];
        dub_line_clear(&t->modAllpass); dub_line_clear(&t->delay1); dub_line_clear(&t->allpass2); dub_line_clear(&t->delay2);
        t->modAllpassLen = SCALE(kHalf[h][0], sr);
        t->delay1Len = SCALE(kHalf[h][1], sr);
        t->allpass2Len = SCALE(kHalf[h][2], sr);
        t->delay2Len = SCALE(kHalf[h][3], sr);
        t->damp = 0.0f;
    }
    for (int i = 0; i < 7; i++) {
        s->tapsL[i] = SCALE(kTapsL[i], sr);
        s->tapsR[i] = SCALE(kTapsR[i], sr);
    }
    s->excursion = (float)SCALE(16, sr);
    s->bandwidthState = s->lowCutState = s->toneState[0] = s->toneState[1] = 0.0f;
    s->decay = dub_param(e, DUB_PLATE_DECAY);
    s->damping = dub_param(e, DUB_PLATE_DAMPING);
    s->lfoPhase = 0.0;
}

static inline void tank_half(TankHalf *t, float x, float decay, float damping, float diffusion2, float mod) {
    // Allpass modulé (decay diffusion 1, signe inversé)
    const float d = dub_line_tap_frac(&t->modAllpass, (float)t->modAllpassLen + mod);
    const float v = x + 0.7f * d;
    dub_line_push(&t->modAllpass, v);
    const float y = d - 0.7f * v;

    const float out1 = dub_line_tap(&t->delay1, t->delay1Len);
    dub_line_push(&t->delay1, y);

    t->damp = out1 * (1.0f - damping) + t->damp * damping;

    const float d2 = dub_line_tap(&t->allpass2, t->allpass2Len);
    const float v2 = t->damp * decay - diffusion2 * d2;
    dub_line_push(&t->allpass2, v2);
    dub_line_push(&t->delay2, d2 + diffusion2 * v2);
}

static void plate_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    PlateState *s = (PlateState *)e->state;
    const float sr = (float)e->sampleRate;
    const float targetDecay = dub_clamp(dub_param(e, DUB_PLATE_DECAY), 0.0f, 0.98f);
    const float targetDamping = dub_clamp(dub_param(e, DUB_PLATE_DAMPING), 0.0f, 0.95f);
    const int predelay = (int)(dub_clamp(dub_param(e, DUB_PLATE_PREDELAY), 0.0f, 0.25f) * sr) + 1;
    const float lowCutA = dub_onepole(dub_clamp(dub_param(e, DUB_PLATE_LOW_CUT), 10.0f, 2000.0f), sr);
    const float toneA = dub_onepole(dub_clamp(dub_param(e, DUB_PLATE_TONE), 500.0f, 20000.0f), sr);
    const float smooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.05), sr);
    const double lfoInc = 2.0 * DUB_PI * 0.7 / sr;
    TankHalf *L = &s->half[0], *R = &s->half[1];

    for (int n = 0; n < frames; n++) {
        s->decay += (targetDecay - s->decay) * smooth;
        s->damping += (targetDamping - s->damping) * smooth;
        const float diffusion2 = dub_clamp(s->decay + 0.15f, 0.25f, 0.5f);

        float x = 0.5f * (inL[n] + inR[n]);
        s->lowCutState += lowCutA * (x - s->lowCutState); // coupe-bas : pas de boue dans la reverb
        x -= s->lowCutState;

        const float delayed = dub_line_tap(&s->predelay, predelay);
        dub_line_push(&s->predelay, x);
        s->bandwidthState += 0.9995f * (delayed - s->bandwidthState);
        x = s->bandwidthState;

        for (int i = 0; i < 4; i++) {
            const float d = dub_line_tap(&s->inAllpass[i], s->inAllpassLen[i]);
            const float v = x - kInAllpassGain[i] * d;
            dub_line_push(&s->inAllpass[i], v);
            x = d + kInAllpassGain[i] * v;
        }

        s->lfoPhase += lfoInc;
        if (s->lfoPhase > 2.0 * DUB_PI) s->lfoPhase -= 2.0 * DUB_PI;
        const float modL = s->excursion * 0.5f * (1.0f + (float)sin(s->lfoPhase));
        const float modR = s->excursion * 0.5f * (1.0f + (float)cos(s->lfoPhase));

        // Couplage croisé : chaque moitié du réservoir reçoit la sortie de l'autre.
        const float fromL = dub_line_tap(&L->delay2, L->delay2Len);
        const float fromR = dub_line_tap(&R->delay2, R->delay2Len);
        tank_half(L, x + s->decay * fromR, s->decay, s->damping, diffusion2, modL);
        tank_half(R, x + s->decay * fromL, s->decay, s->damping, diffusion2, modR);

        const int *a = s->tapsL, *b = s->tapsR;
        float wetL = 0.6f * (dub_line_tap(&R->delay1, a[0]) + dub_line_tap(&R->delay1, a[1]) - dub_line_tap(&R->allpass2, a[2])
                           + dub_line_tap(&R->delay2, a[3]) - dub_line_tap(&L->delay1, a[4]) - dub_line_tap(&L->allpass2, a[5])
                           - dub_line_tap(&L->delay2, a[6]));
        float wetR = 0.6f * (dub_line_tap(&L->delay1, b[0]) + dub_line_tap(&L->delay1, b[1]) - dub_line_tap(&L->allpass2, b[2])
                           + dub_line_tap(&L->delay2, b[3]) - dub_line_tap(&R->delay1, b[4]) - dub_line_tap(&R->allpass2, b[5])
                           - dub_line_tap(&R->delay2, b[6]));

        s->toneState[0] += toneA * (wetL - s->toneState[0]);
        s->toneState[1] += toneA * (wetR - s->toneState[1]);
        outL[n] = s->toneState[0];
        outR[n] = s->toneState[1];
    }
}

static void plate_destroy(DubEffect *e) {
    PlateState *s = (PlateState *)e->state;
    dub_line_free(&s->predelay);
    for (int i = 0; i < 4; i++) dub_line_free(&s->inAllpass[i]);
    for (int h = 0; h < 2; h++) {
        TankHalf *t = &s->half[h];
        dub_line_free(&t->modAllpass); dub_line_free(&t->delay1); dub_line_free(&t->allpass2); dub_line_free(&t->delay2);
    }
    free(s);
}

void dub_plate_install(DubEffect *e) {
    PlateState *s = (PlateState *)calloc(1, sizeof(PlateState));
    if (!s) return;
    const double maxRate = DUB_MAX_SAMPLE_RATE;
    int ok = dub_line_init(&s->predelay, (int)(0.25 * maxRate) + 2);
    for (int i = 0; i < 4; i++) ok &= dub_line_init(&s->inAllpass[i], SCALE(kInAllpass[i], maxRate));
    for (int h = 0; h < 2; h++) {
        TankHalf *t = &s->half[h];
        ok &= dub_line_init(&t->modAllpass, SCALE(kHalf[h][0] + 32, maxRate));
        ok &= dub_line_init(&t->delay1, SCALE(kHalf[h][1], maxRate));
        ok &= dub_line_init(&t->allpass2, SCALE(kHalf[h][2], maxRate));
        ok &= dub_line_init(&t->delay2, SCALE(kHalf[h][3], maxRate));
    }
    e->state = s;
    e->destroy = plate_destroy;
    if (!ok) { plate_destroy(e); e->state = NULL; return; }
    dub_effect_set(e, DUB_PLATE_DECAY, 0.75f);
    dub_effect_set(e, DUB_PLATE_DAMPING, 0.35f);
    dub_effect_set(e, DUB_PLATE_PREDELAY, 0.02f);
    dub_effect_set(e, DUB_PLATE_LOW_CUT, 180.0f);
    dub_effect_set(e, DUB_PLATE_TONE, 6000.0f);
    e->prepare = plate_prepare;
    e->process = plate_process;
}
