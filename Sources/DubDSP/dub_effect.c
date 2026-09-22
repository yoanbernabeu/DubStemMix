#include "dub_internal.h"

DubEffect *dub_effect_create(DubEffectKind kind) {
    DubEffect *effect = (DubEffect *)calloc(1, sizeof(DubEffect));
    if (!effect) return NULL;
    effect->kind = kind;
    effect->sampleRate = 48000.0;
    switch (kind) {
        case DUB_EFFECT_DELAY: dub_delay_install(effect); break;
        case DUB_EFFECT_PLATE: dub_plate_install(effect); break;
        case DUB_EFFECT_PHASER: dub_phaser_install(effect); break;
        case DUB_EFFECT_MASTER: dub_master_install(effect); break;
    }
    if (!effect->state) { free(effect); return NULL; }
    effect->prepare(effect);
    return effect;
}

void dub_effect_destroy(DubEffect *effect) {
    if (!effect) return;
    effect->destroy(effect);
    free(effect);
}

void dub_effect_prepare(DubEffect *effect, double sampleRate) {
    effect->sampleRate = sampleRate > DUB_MAX_SAMPLE_RATE ? DUB_MAX_SAMPLE_RATE : sampleRate;
    effect->prepare(effect);
}

void dub_effect_set(DubEffect *effect, int param, float value) {
    if (param >= 0 && param < DUB_EFFECT_MAX_PARAMS) atomic_store_explicit(&effect->params[param], value, memory_order_relaxed);
}

float dub_effect_get(const DubEffect *effect, int param) {
    return (param >= 0 && param < DUB_EFFECT_MAX_PARAMS) ? dub_param(effect, param) : 0.0f;
}

void dub_effect_process(DubEffect *effect, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    effect->process(effect, inL, inR, outL, outR, frames);
}
