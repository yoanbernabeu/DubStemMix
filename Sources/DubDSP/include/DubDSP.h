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
    DUB_EFFECT_MASTER = 3, // master chain: stepped high-pass (big knob) → 3-band kills → dubplate colour
    DUB_EFFECT_SPRING = 4, // spring reverb (dispersive allpass chain in a loop) with a CRASH trigger
    DUB_EFFECT_SUB = 5,    // strip insert: sub-octave generator (dbx "boom box" style), dry + sub
    DUB_EFFECT_WAH = 6,    // strip insert: envelope-following filter (Mu-Tron III style), wet only
    DUB_EFFECT_FLANGER = 7,// tape flanger, output 100 % wet (for a send bus, like the phaser); phaser parameter indices
} DubEffectKind;

// Paramètres, en unités réelles.
enum {
    DUB_DELAY_TIME = 0,     // secondes (0,02 … 3,5)
    DUB_DELAY_FEEDBACK = 1, // gain de réinjection (0 … 1,15 ; > 1 = auto-oscillation bornée par la saturation)
    DUB_DELAY_WOW = 2,      // 0 … 1
    DUB_DELAY_LOW_CUT = 3,  // Hz
    DUB_DELAY_HIGH_CUT = 4, // Hz
    DUB_DELAY_HEADS = 5,    // Space Echo head pattern, 0 … 6: 1, 2, 3, 1+2, 2+3, 1+3, 1+2+3 (heads at 1×, 2×, 3× the time)
    DUB_DELAY_PINGPONG = 6, // 0 … 1: repeats alternate left / right (0 = plain stereo, as before)
    DUB_DELAY_HOLD = 7,     // ≥ 0.5: input closed, feedback at unity — the loop holds itself
};
enum {
    DUB_PLATE_DECAY = 0,    // coefficient de décroissance (0 … 0,98)
    DUB_PLATE_DAMPING = 1,  // 0 … 0,95
    DUB_PLATE_PREDELAY = 2, // secondes (0 … 0,25)
    DUB_PLATE_LOW_CUT = 3,  // Hz, avant la reverb
    DUB_PLATE_TONE = 4,     // Hz, passe-bas en sortie
};
// The spring shares the plate's five parameters (same indices, same units), plus:
enum {
    DUB_SPRING_CRASH = 5,   // set to 1 to hit the spring; the kernel resets it to 0 once the crash has fired
};
enum {
    DUB_SUB_AMOUNT = 0,     // 0 … 1 (0 = exact passthrough)
    DUB_SUB_CUTOFF = 1,     // Hz, low-pass on the generated sub (40 … 160)
};
enum {
    DUB_WAH_SENSITIVITY = 0, // 0 … 1: how far the envelope opens the filter
    DUB_WAH_RANGE = 1,       // 0 … 1: sweep span, up to 3 octaves above the base
    DUB_WAH_RESONANCE = 2,   // 0 … 1
    DUB_WAH_DIRECTION = 3,   // 0 = louder opens the filter (up), 1 = louder closes it (down)
};
enum {
    DUB_PHASER_RATE = 0,     // Hz
    DUB_PHASER_DEPTH = 1,    // 0 … 1 (± 2,5 octaves)
    DUB_PHASER_FEEDBACK = 2, // résonance, 0 … 0,95
    DUB_PHASER_CENTER = 3,   // Hz
    DUB_PHASER_STEREO = 4,   // 0 … 1 (déphasage du LFO entre gauche et droite, jusqu'à 180°)
};

enum {
    DUB_MASTER_HIGH_PASS = 0, // Hz; at or below 20 = bypassed. Stepped by the caller, glided here.
    DUB_MASTER_BASS = 1,      // linear gain 0 … 1 of the band below 200 Hz
    DUB_MASTER_MID = 2,       // 200 Hz … 2.5 kHz
    DUB_MASTER_TOP = 3,       // above 2.5 kHz
    DUB_MASTER_DUBPLATE = 4,  // 0 … 1 intensity (0 = exact passthrough)
    DUB_MASTER_CRACKLE = 5,   // 0 … 1
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
