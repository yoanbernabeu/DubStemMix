// Noyaux DSP temps réel des effets intégrés de DubStemMix.
// Règles : aucune allocation, aucun verrou, aucun appel système dans dub_effect_process().
// Les paramètres sont écrits depuis n'importe quel thread (atomiques) et lissés dans le noyau.

#ifndef DUB_DSP_H
#define DUB_DSP_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DubEffect DubEffect;

typedef enum {
    DUB_EFFECT_DELAY = 0,  // écho à bande : filtres et saturation dans la boucle, wow/flutter
    DUB_EFFECT_PLATE = 1,  // reverb plate (Dattorro), entrée mono, sortie stéréo
    DUB_EFFECT_PHASER = 2, // phaser façon Bi-Phase : 2 × 6 étages en série, sortie 100 % déphasée (pour bus d'envoi)
} DubEffectKind;

// Paramètres, en unités réelles.
enum {
    DUB_DELAY_TIME = 0,     // secondes (0,02 … 3,5)
    DUB_DELAY_FEEDBACK = 1, // gain de réinjection (0 … 1,15 ; > 1 = auto-oscillation bornée par la saturation)
    DUB_DELAY_WOW = 2,      // 0 … 1
    DUB_DELAY_LOW_CUT = 3,  // Hz
    DUB_DELAY_HIGH_CUT = 4, // Hz
};
enum {
    DUB_PLATE_DECAY = 0,    // coefficient de décroissance (0 … 0,98)
    DUB_PLATE_DAMPING = 1,  // 0 … 0,95
    DUB_PLATE_PREDELAY = 2, // secondes (0 … 0,25)
    DUB_PLATE_LOW_CUT = 3,  // Hz, avant la reverb
    DUB_PLATE_TONE = 4,     // Hz, passe-bas en sortie
};
enum {
    DUB_PHASER_RATE = 0,     // Hz
    DUB_PHASER_DEPTH = 1,    // 0 … 1 (± 2,5 octaves)
    DUB_PHASER_FEEDBACK = 2, // résonance, 0 … 0,95
    DUB_PHASER_CENTER = 3,   // Hz
    DUB_PHASER_STEREO = 4,   // 0 … 1 (déphasage du LFO entre gauche et droite, jusqu'à 180°)
};

#define DUB_EFFECT_MAX_PARAMS 8

DubEffect *dub_effect_create(DubEffectKind kind);
void dub_effect_destroy(DubEffect *effect);
/// Fixe la fréquence d'échantillonnage et remet l'effet à zéro. Hors thread audio.
void dub_effect_prepare(DubEffect *effect, double sampleRate);
void dub_effect_set(DubEffect *effect, int param, float value);
float dub_effect_get(const DubEffect *effect, int param);
/// Traite `frames` échantillons stéréo. L'entrée et la sortie peuvent être les mêmes tampons.
void dub_effect_process(DubEffect *effect, const float *inL, const float *inR, float *outL, float *outR, int frames);

#ifdef __cplusplus
}
#endif

#endif
