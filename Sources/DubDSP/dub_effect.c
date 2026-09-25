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
        case DUB_EFFECT_SPRING: dub_spring_install(effect); break;
        case DUB_EFFECT_SUB: dub_sub_install(effect); break;
        case DUB_EFFECT_WAH: dub_wah_install(effect); break;
        case DUB_EFFECT_FLANGER: dub_flanger_install(effect); break;
        case DUB_EFFECT_REVERB_BUS:
        case DUB_EFFECT_BUS3:
        case DUB_EFFECT_INSERT: dub_switch_install(effect); break;
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

#define DUB_CLEAR_SECONDS 0.06

void dub_effect_process(DubEffect *effect, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    if (effect->clearLeft == 0 && dub_param(effect, DUB_EFFECT_CLEAR) >= 0.5f) {
        atomic_store_explicit(&effect->params[DUB_EFFECT_CLEAR], 0.0f, memory_order_relaxed);
        effect->clearLength = effect->clearLeft = (int)(DUB_CLEAR_SECONDS * effect->sampleRate);
    }
    effect->process(effect, inL, inR, outL, outR, frames);
    if (effect->clearLeft == 0) return;
    // PANIC: fade the output out (no click), empty the effect, and stay silent for the rest of the block.
    for (int n = 0; n < frames; n++) {
        if (effect->clearLeft > 0) {
            float gain = (float)effect->clearLeft / (float)effect->clearLength;
            gain *= gain;
            outL[n] *= gain;
            outR[n] *= gain;
            if (--effect->clearLeft == 0) effect->prepare(effect);
        } else {
            outL[n] = outR[n] = 0.0f;
        }
    }
}
