// Écho à bande pour le dub.
//
//   entrée ──(+)──▶ coupe-bas ──▶ coupe-haut ──▶ saturation ──▶ ligne à retard ──┬──▶ sortie (100 % wet)
//            ▲                                                                   │
//            └──────────────────── feedback ◀────────────────────────────────────┘
//
// Chaque passage — y compris le premier — traverse filtres et saturation : les répétitions
// s'assombrissent et s'arrondissent comme sur une bande. Le temps de retard glisse doucement
// vers sa cible (la hauteur des échos « plonge » quand on tourne le potard) et la saturation
// borne l'auto-oscillation quand le feedback dépasse 1.

#include "dub_internal.h"

#define DELAY_MAX_SECONDS 4.0

typedef struct {
    DubLine line[2];
    float delaySamples; // retard courant, lissé
    float feedback;     // feedback courant, lissé
    float lowCut[2][2]; // [canal][étage]
    float highCut[2][2];
    double wowPhase, flutterPhase;
} DelayState;

static void delay_prepare(DubEffect *e) {
    DelayState *s = (DelayState *)e->state;
    for (int c = 0; c < 2; c++) dub_line_clear(&s->line[c]);
    memset(s->lowCut, 0, sizeof s->lowCut);
    memset(s->highCut, 0, sizeof s->highCut);
    s->delaySamples = dub_param(e, DUB_DELAY_TIME) * (float)e->sampleRate;
    s->feedback = dub_param(e, DUB_DELAY_FEEDBACK);
    s->wowPhase = s->flutterPhase = 0.0;
}

static void delay_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    DelayState *s = (DelayState *)e->state;
    const float sr = (float)e->sampleRate;
    const float *in[2] = { inL, inR };
    float *out[2] = { outL, outR };

    const float targetDelay = dub_clamp(dub_param(e, DUB_DELAY_TIME), 0.02f, 3.5f) * sr;
    const float targetFeedback = dub_clamp(dub_param(e, DUB_DELAY_FEEDBACK), 0.0f, 1.15f);
    const float wow = dub_clamp(dub_param(e, DUB_DELAY_WOW), 0.0f, 1.0f);
    const float lowCutA = dub_onepole(dub_clamp(dub_param(e, DUB_DELAY_LOW_CUT), 10.0f, 4000.0f), sr);
    const float highCutA = dub_onepole(dub_clamp(dub_param(e, DUB_DELAY_HIGH_CUT), 200.0f, 20000.0f), sr);

    const float glide = dub_onepole(1.0 / (2.0 * DUB_PI * 0.12), sr); // constante de temps ≈ 120 ms
    const float smooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.02), sr);
    const float wowDepth = wow * wow * 0.004f * sr;                   // jusqu'à ± 4 ms
    const float flutterDepth = wow * wow * 0.0004f * sr;
    const double wowInc = 2.0 * DUB_PI * 0.43 / sr, flutterInc = 2.0 * DUB_PI * 5.7 / sr;
    const float maxDelay = (float)(s->line[0].mask - 8);

    for (int n = 0; n < frames; n++) {
        s->delaySamples += (targetDelay - s->delaySamples) * glide;
        s->feedback += (targetFeedback - s->feedback) * smooth;
        s->wowPhase += wowInc;
        s->flutterPhase += flutterInc;
        if (s->wowPhase > 2.0 * DUB_PI) s->wowPhase -= 2.0 * DUB_PI;
        if (s->flutterPhase > 2.0 * DUB_PI) s->flutterPhase -= 2.0 * DUB_PI;
        const float flutter = flutterDepth * (float)sin(s->flutterPhase);

        for (int c = 0; c < 2; c++) {
            // Le wow est décalé d'un quart de période entre gauche et droite : léger mouvement stéréo.
            const float wobble = wowDepth * (float)sin(s->wowPhase + c * DUB_PI * 0.5) + flutter;
            const float delay = dub_clamp(s->delaySamples + wobble, 4.0f, maxDelay);
            const float delayed = dub_line_tap_frac(&s->line[c], delay);

            float x = in[c][n] + s->feedback * delayed;
            for (int stage = 0; stage < 2; stage++) { // coupe-bas 12 dB/oct
                s->lowCut[c][stage] += lowCutA * (x - s->lowCut[c][stage]);
                x -= s->lowCut[c][stage];
            }
            for (int stage = 0; stage < 2; stage++) { // coupe-haut 12 dB/oct
                s->highCut[c][stage] += highCutA * (x - s->highCut[c][stage]);
                x = s->highCut[c][stage];
            }
            dub_line_push(&s->line[c], tanhf(x));
            out[c][n] = delayed;
        }
    }
}

static void delay_destroy(DubEffect *e) {
    DelayState *s = (DelayState *)e->state;
    for (int c = 0; c < 2; c++) dub_line_free(&s->line[c]);
    free(s);
}

void dub_delay_install(DubEffect *e) {
    DelayState *s = (DelayState *)calloc(1, sizeof(DelayState));
    if (!s) return;
    const int length = (int)(DELAY_MAX_SECONDS * DUB_MAX_SAMPLE_RATE);
    if (!dub_line_init(&s->line[0], length) || !dub_line_init(&s->line[1], length)) {
        dub_line_free(&s->line[0]);
        free(s);
        return;
    }
    dub_effect_set(e, DUB_DELAY_TIME, 0.45f);
    dub_effect_set(e, DUB_DELAY_FEEDBACK, 0.5f);
    dub_effect_set(e, DUB_DELAY_WOW, 0.2f);
    dub_effect_set(e, DUB_DELAY_LOW_CUT, 120.0f);
    dub_effect_set(e, DUB_DELAY_HIGH_CUT, 3500.0f);
    e->state = s;
    e->prepare = delay_prepare;
    e->process = delay_process;
    e->destroy = delay_destroy;
}
