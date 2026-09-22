#ifndef DUB_INTERNAL_H
#define DUB_INTERNAL_H

#include "DubDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define DUB_MAX_SAMPLE_RATE 96000.0
#define DUB_PI 3.14159265358979323846

struct DubEffect {
    DubEffectKind kind;
    _Atomic float params[DUB_EFFECT_MAX_PARAMS];
    double sampleRate;
    void *state;
    void (*prepare)(DubEffect *);
    void (*process)(DubEffect *, const float *, const float *, float *, float *, int);
    void (*destroy)(DubEffect *);
};

static inline float dub_param(const DubEffect *e, int index) { return atomic_load_explicit(&e->params[index], memory_order_relaxed); }
static inline float dub_clamp(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
/// Coefficient d'un passe-bas un pôle : y += a * (x - y).
static inline float dub_onepole(double cutoffHz, double sampleRate) { return (float)(1.0 - exp(-2.0 * DUB_PI * cutoffHz / sampleRate)); }

/// Ligne à retard circulaire (taille en puissance de deux).
typedef struct { float *data; int mask; int write; } DubLine;

static inline int dub_line_init(DubLine *line, int minLength) {
    int size = 1;
    while (size < minLength + 8) size <<= 1;
    line->data = (float *)calloc((size_t)size, sizeof(float));
    line->mask = size - 1;
    line->write = 0;
    return line->data != NULL;
}
static inline void dub_line_clear(DubLine *line) { memset(line->data, 0, (size_t)(line->mask + 1) * sizeof(float)); line->write = 0; }
static inline void dub_line_free(DubLine *line) { free(line->data); line->data = NULL; }
static inline void dub_line_push(DubLine *line, float x) { line->data[line->write] = x; line->write = (line->write + 1) & line->mask; }
/// Échantillon écrit il y a `delay` pas (lecture avant l'écriture du pas courant).
static inline float dub_line_tap(const DubLine *line, int delay) { return line->data[(line->write - delay) & line->mask]; }
/// Lecture fractionnaire, interpolation cubique d'Hermite (propre quand le retard glisse).
static inline float dub_line_tap_frac(const DubLine *line, float delay) {
    int i = (int)delay;
    float f = delay - (float)i;
    float xm1 = dub_line_tap(line, i - 1), x0 = dub_line_tap(line, i), x1 = dub_line_tap(line, i + 1), x2 = dub_line_tap(line, i + 2);
    float c = (x1 - xm1) * 0.5f, v = x0 - x1, w = c + v, a = w + v + (x2 - x0) * 0.5f, b = w + a;
    return (((a * f) - b) * f + c) * f + x0;
}

void dub_delay_install(DubEffect *effect);
void dub_plate_install(DubEffect *effect);
void dub_phaser_install(DubEffect *effect);
void dub_master_install(DubEffect *effect);
void dub_spring_install(DubEffect *effect);
void dub_sub_install(DubEffect *effect);
void dub_wah_install(DubEffect *effect);
void dub_flanger_install(DubEffect *effect);

#endif
