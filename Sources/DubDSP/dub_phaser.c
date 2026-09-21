// Phaser façon Mu-Tron Bi-Phase, le « gros » phaser du reggae des années 70 : deux phaseurs 6 étages en série,
// balayés ensemble, chacun avec sa réinjection (résonance). Une saturation douce dans chaque boucle permet
// de pousser la résonance très haut sans que ça explose.
//
// La sortie ne contient QUE le signal déphasé : l'effet vit sur un bus d'envoi, et c'est sa somme avec le
// signal direct de la tranche qui creuse les encoches (à fond quand l'envoi est à fond et le retour à 0 dB).
// Y remettre du direct ici reboucherait les encoches.

#include "dub_internal.h"

#define SECTIONS 2
#define STAGES 6

typedef struct {
    float x1[2][SECTIONS][STAGES], y1[2][SECTIONS][STAGES];
    float last[2][SECTIONS]; // sortie de chaque phaseur, pour sa réinjection
    float depth, feedback, center; // lissés
    double phase;
} PhaserState;

static void phaser_prepare(DubEffect *e) {
    PhaserState *s = (PhaserState *)e->state;
    memset(s, 0, sizeof *s);
    s->depth = dub_param(e, DUB_PHASER_DEPTH);
    s->feedback = dub_param(e, DUB_PHASER_FEEDBACK);
    s->center = dub_param(e, DUB_PHASER_CENTER);
}

static void phaser_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    PhaserState *s = (PhaserState *)e->state;
    const float sr = (float)e->sampleRate;
    const float *in[2] = { inL, inR };
    float *out[2] = { outL, outR };

    const float rate = dub_clamp(dub_param(e, DUB_PHASER_RATE), 0.02f, 10.0f);
    const float targetDepth = dub_clamp(dub_param(e, DUB_PHASER_DEPTH), 0.0f, 1.0f);
    const float targetFeedback = dub_clamp(dub_param(e, DUB_PHASER_FEEDBACK), 0.0f, 0.95f);
    const float targetCenter = dub_clamp(dub_param(e, DUB_PHASER_CENTER), 100.0f, 4000.0f);
    const double stereoOffset = dub_clamp(dub_param(e, DUB_PHASER_STEREO), 0.0f, 1.0f) * DUB_PI;
    const float smooth = dub_onepole(1.0 / (2.0 * DUB_PI * 0.03), sr);
    const double inc = 2.0 * DUB_PI * rate / sr;

    for (int n = 0; n < frames; n++) {
        s->depth += (targetDepth - s->depth) * smooth;
        s->feedback += (targetFeedback - s->feedback) * smooth;
        s->center += (targetCenter - s->center) * smooth;
        s->phase += inc;
        if (s->phase > 2.0 * DUB_PI) s->phase -= 2.0 * DUB_PI;

        for (int c = 0; c < 2; c++) {
            // Balayage exponentiel, jusqu'à ± 2,5 octaves autour de la fréquence centrale.
            const float lfo = (float)sin(s->phase + c * stereoOffset);
            const float freq = dub_clamp(s->center * powf(2.0f, 2.5f * s->depth * lfo), 40.0f, sr * 0.45f);
            const float t = tanf((float)DUB_PI * freq / sr);
            const float a = (t - 1.0f) / (t + 1.0f);

            float x = in[c][n];
            for (int section = 0; section < SECTIONS; section++) {
                x += s->feedback * tanhf(s->last[c][section]);
                for (int stage = 0; stage < STAGES; stage++) {
                    const float y = a * x + s->x1[c][section][stage] - a * s->y1[c][section][stage];
                    s->x1[c][section][stage] = x;
                    s->y1[c][section][stage] = y;
                    x = y;
                }
                s->last[c][section] = x;
            }
            out[c][n] = x;
        }
    }
}

static void phaser_destroy(DubEffect *e) { free(e->state); }

void dub_phaser_install(DubEffect *e) {
    PhaserState *s = (PhaserState *)calloc(1, sizeof(PhaserState));
    if (!s) return;
    dub_effect_set(e, DUB_PHASER_RATE, 0.3f);
    dub_effect_set(e, DUB_PHASER_DEPTH, 0.75f);
    dub_effect_set(e, DUB_PHASER_FEEDBACK, 0.7f);
    dub_effect_set(e, DUB_PHASER_CENTER, 650.0f);
    dub_effect_set(e, DUB_PHASER_STEREO, 0.5f);
    e->state = s;
    e->prepare = phaser_prepare;
    e->process = phaser_process;
    e->destroy = phaser_destroy;
}
