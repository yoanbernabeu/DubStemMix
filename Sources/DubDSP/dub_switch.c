// Switches: two kernels in one effect, so that changing the effect of a bus or of a strip insert never touches
// the audio graph (AVAudioEngine can only rewire with the engine stopped, which cuts every tail).
//
// On a send bus (plate / spring, phaser / flanger) the kernels sit side by side: at a change the input moves to
// the new one over 10 ms, and the old one keeps ringing out its tail with nothing more coming in. Once silent it
// goes to sleep and costs nothing. In an insert (straight / sub / auto-wah) the path is crossfaded over 10 ms.
// The kernel in use and nothing else runs the rest of the time: the output is then exactly that kernel's.

#include "dub_internal.h"

#define SWITCH_CHUNK 512
#define SWITCH_FADE_SECONDS 0.01
#define SWITCH_SILENCE 0.000001f       // −120 dB: below this, a kernel left alone is asleep
#define SWITCH_SLEEP_SECONDS 0.1       // …after this long

typedef struct {
    DubEffect *child[2];
    int offset[2], count[2];   // switch parameters forwarded to each kernel (from its index 0)
    int parallel;              // send bus: side by side, tails ring out; otherwise an inline insert
    int trigger;               // one-shot parameter (the spring's CRASH), −1 if none
    int selected;              // kernel in use; −1 = straight through (insert only)
    float gain[2], dry;        // current weights, ramped towards the selection
    int awake[2];
    int silent[2];             // samples in a row a kernel left alone stayed below the silence
    float input[2][SWITCH_CHUNK];
    float work[2][2][SWITCH_CHUNK];
    float ramp[3][SWITCH_CHUNK];
} SwitchState;

static int switch_target(const DubEffect *e, const SwitchState *s) {
    const int select = (int)(dub_param(e, DUB_SWITCH_SELECT) + 0.5f);
    if (s->parallel) return select >= 1 ? 1 : 0;
    return select <= 0 ? -1 : (select >= 2 ? 1 : 0);
}

static void switch_forward(DubEffect *e, SwitchState *s) {
    for (int c = 0; c < 2; c++) {
        for (int i = 0; i < s->count[c]; i++) {
            const int index = s->offset[c] + i;
            if (index == s->trigger) continue;
            atomic_store_explicit(&s->child[c]->params[i], dub_param(e, index), memory_order_relaxed);
        }
    }
    if (s->trigger >= 0 && dub_param(e, s->trigger) >= 0.5f) {
        atomic_store_explicit(&e->params[s->trigger], 0.0f, memory_order_relaxed);
        for (int c = 0; c < 2; c++) atomic_store_explicit(&s->child[c]->params[s->trigger - s->offset[c]], 1.0f, memory_order_relaxed);
    }
}

static void switch_prepare(DubEffect *e) {
    SwitchState *s = (SwitchState *)e->state;
    switch_forward(e, s); // the kernels start from the current settings, as they would on their own
    s->selected = switch_target(e, s);
    for (int c = 0; c < 2; c++) {
        dub_effect_prepare(s->child[c], e->sampleRate);
        s->awake[c] = c == s->selected;
        s->gain[c] = c == s->selected ? 1.0f : 0.0f;
        s->silent[c] = 0;
    }
    s->dry = s->selected < 0 ? 1.0f : 0.0f;
}

static inline float switch_step(float value, float target, float step) {
    if (value < target) return value + step >= target ? target : value + step;
    return value - step <= target ? target : value - step;
}

static void switch_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    SwitchState *s = (SwitchState *)e->state;
    switch_forward(e, s);
    const int target = switch_target(e, s);
    if (target != s->selected) {
        // A kernel coming back from sleep starts clean, as a freshly created one would.
        if (target >= 0 && !s->awake[target]) {
            dub_effect_prepare(s->child[target], e->sampleRate);
            s->awake[target] = 1;
        }
        s->selected = target;
    }
    const float step = (float)(1.0 / (SWITCH_FADE_SECONDS * e->sampleRate));
    const int sleepAfter = (int)(SWITCH_SLEEP_SECONDS * e->sampleRate);

    for (int done = 0; done < frames; done += SWITCH_CHUNK) {
        const int n = frames - done < SWITCH_CHUNK ? frames - done : SWITCH_CHUNK;
        // Weights, sample by sample, and a copy of the input (the output may be the input's buffer).
        for (int k = 0; k < n; k++) {
            for (int c = 0; c < 2; c++) {
                s->gain[c] = switch_step(s->gain[c], c == s->selected ? 1.0f : 0.0f, step);
                s->ramp[c][k] = s->gain[c];
            }
            s->dry = switch_step(s->dry, s->selected < 0 ? 1.0f : 0.0f, step);
            s->ramp[2][k] = s->dry;
        }
        memcpy(s->input[0], inL + done, (size_t)n * sizeof(float));
        memcpy(s->input[1], inR + done, (size_t)n * sizeof(float));

        int processed[2] = { 0, 0 };
        for (int c = 0; c < 2; c++) {
            if (!s->awake[c]) continue;
            processed[c] = 1;
            float *left = s->work[c][0], *right = s->work[c][1];
            if (s->parallel) {
                // Side by side: the weight is on the kernel's input, its tail is left alone.
                for (int k = 0; k < n; k++) {
                    left[k] = s->input[0][k] * s->ramp[c][k];
                    right[k] = s->input[1][k] * s->ramp[c][k];
                }
            } else {
                memcpy(left, s->input[0], (size_t)n * sizeof(float));
                memcpy(right, s->input[1], (size_t)n * sizeof(float));
            }
            dub_effect_process(s->child[c], left, right, left, right, n);
            if (!s->parallel) {
                for (int k = 0; k < n; k++) { left[k] *= s->ramp[c][k]; right[k] *= s->ramp[c][k]; }
            }
            // A kernel no longer in use sleeps once faded out (insert) or silent (bus: its tail has died).
            if (c != s->selected && s->gain[c] == 0.0f) {
                float peak = 0.0f;
                for (int k = 0; k < n; k++) {
                    const float a = fabsf(left[k]), b = fabsf(right[k]);
                    peak = a > peak ? a : peak;
                    peak = b > peak ? b : peak;
                }
                s->silent[c] = peak < SWITCH_SILENCE ? s->silent[c] + n : 0;
                if (!s->parallel || s->silent[c] >= sleepAfter) {
                    s->awake[c] = 0;
                    s->silent[c] = 0;
                }
            } else {
                s->silent[c] = 0;
            }
        }

        // Sum. The kernel in use alone, at full weight, gives its output untouched; an insert with no kernel
        // awake is straight through (its last kernel only sleeps once fully faded out).
        float *out[2] = { outL + done, outR + done };
        for (int ch = 0; ch < 2; ch++) {
            if (!processed[0] && !processed[1]) {
                if (s->parallel) memset(out[ch], 0, (size_t)n * sizeof(float));
                else memcpy(out[ch], s->input[ch], (size_t)n * sizeof(float));
                continue;
            }
            for (int k = 0; k < n; k++) {
                float sum = s->parallel ? 0.0f : s->input[ch][k] * s->ramp[2][k];
                if (processed[0]) sum += s->work[0][ch][k];
                if (processed[1]) sum += s->work[1][ch][k];
                out[ch][k] = sum;
            }
        }
    }
}

static void switch_destroy(DubEffect *e) {
    SwitchState *s = (SwitchState *)e->state;
    for (int c = 0; c < 2; c++) dub_effect_destroy(s->child[c]);
    free(s);
}

void dub_switch_install(DubEffect *e) {
    SwitchState *s = (SwitchState *)calloc(1, sizeof(SwitchState));
    if (!s) return;
    DubEffectKind kinds[2];
    s->trigger = -1;
    switch (e->kind) {
        case DUB_EFFECT_REVERB_BUS:
            kinds[0] = DUB_EFFECT_PLATE; kinds[1] = DUB_EFFECT_SPRING;
            s->parallel = 1;
            s->count[0] = s->count[1] = DUB_SPRING_CRASH + 1;
            s->trigger = DUB_SPRING_CRASH;
            break;
        case DUB_EFFECT_BUS3:
            kinds[0] = DUB_EFFECT_PHASER; kinds[1] = DUB_EFFECT_FLANGER;
            s->parallel = 1;
            s->count[0] = s->count[1] = DUB_PHASER_STEREO + 1;
            break;
        default: // DUB_EFFECT_INSERT
            kinds[0] = DUB_EFFECT_SUB; kinds[1] = DUB_EFFECT_WAH;
            s->offset[0] = DUB_INSERT_SUB; s->count[0] = DUB_SUB_CUTOFF + 1;
            s->offset[1] = DUB_INSERT_WAH; s->count[1] = DUB_WAH_DIRECTION + 1;
            break;
    }
    for (int c = 0; c < 2; c++) {
        s->child[c] = dub_effect_create(kinds[c]);
        if (!s->child[c]) {
            dub_effect_destroy(s->child[0]);
            free(s);
            return;
        }
    }
    e->state = s;
    e->prepare = switch_prepare;
    e->process = switch_process;
    e->destroy = switch_destroy;
}
