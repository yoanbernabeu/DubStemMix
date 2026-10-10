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
//
// M7 additions (PRD § 11.4):
// - Heads: like the Space Echo, three playback heads at 1×, 2× and 3× the time; a pattern picks which ones
//   sound. The feedback takes the mean of the active heads (stable whatever the pattern), the output their
//   sum scaled by 1/√count. Pattern 0 (head 1 alone) is the delay as it was.
// - Ping-pong: the width blends from plain stereo (each channel its own loop) to a mono input entering
//   the left loop whose repeats cross over to the right and back.
// - HOLD: input closed and feedback at unity, filters and saturation out of the loop: the echo holds itself.
//
// Effect strip gestures (PRD § 14):
// - ×2: the time target is halved; the usual glide makes the repeats slide an octave up, and back on release.
// - Tape stop: the playback side of the tape slows down to a standstill (every head reads further and further
//   behind, so the pitch falls) and its output fades with the speed. On release the tape speeds up again and
//   the heads glide back to their place. Recording goes on all along; the feedback fades with the speed, so
//   what comes back after the stop is the music played meanwhile.

#include "dub_internal.h"

#define DELAY_MAX_SECONDS 11.0  // three heads at up to 3.5 s

typedef struct {
    DubLine line[2];
    float delaySamples; // retard courant, lissé
    float feedback;     // feedback courant, lissé
    float inputGain;    // smoothed: 1, or 0 while holding
    float pingPong;     // smoothed
    float lowCut[2][2]; // [canal][étage]
    float highCut[2][2];
    double wowPhase, flutterPhase;
    float tapeSpeed;    // tape stop: 1 = normal, 0 = standstill
    float stopLag;      // samples the heads have fallen behind while the tape braked
} DelayState;

#define TAPE_STOP_SECONDS 0.9f  // from full speed to standstill
#define TAPE_START_SECONDS 0.35f

// Head patterns: which of the three heads sound (PRD § 11.4).
static const int kHeadPatterns[7][3] = {
    { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 1, 0 }, { 0, 1, 1 }, { 1, 0, 1 }, { 1, 1, 1 },
};

static void delay_prepare(DubEffect *e) {
    DelayState *s = (DelayState *)e->state;
    for (int c = 0; c < 2; c++) dub_line_clear(&s->line[c]);
    memset(s->lowCut, 0, sizeof s->lowCut);
    memset(s->highCut, 0, sizeof s->highCut);
    s->delaySamples = dub_param(e, DUB_DELAY_TIME) * (float)e->sampleRate;
    s->feedback = dub_param(e, DUB_DELAY_FEEDBACK);
    s->inputGain = 1.0f;
    s->pingPong = dub_param(e, DUB_DELAY_PINGPONG);
    s->wowPhase = s->flutterPhase = 0.0;
    s->tapeSpeed = 1.0f;
    s->stopLag = 0.0f;
}

static void delay_process(DubEffect *e, const float *inL, const float *inR, float *outL, float *outR, int frames) {
    DelayState *s = (DelayState *)e->state;
    const float sr = (float)e->sampleRate;
    const float *in[2] = { inL, inR };
    float *out[2] = { outL, outR };

    const float doubled = dub_param(e, DUB_DELAY_DOUBLE) >= 0.5f ? 0.5f : 1.0f;
    const float targetDelay = dub_clamp(dub_param(e, DUB_DELAY_TIME), 0.02f, 3.5f) * doubled * sr;
    const int hold = dub_param(e, DUB_DELAY_HOLD) >= 0.5f;
    const int stopping = dub_param(e, DUB_DELAY_STOP) >= 0.5f;
    const float brake = 1.0f / (TAPE_STOP_SECONDS * sr), restart = 1.0f / (TAPE_START_SECONDS * sr);
    const float targetFeedback = hold ? 1.0f : dub_clamp(dub_param(e, DUB_DELAY_FEEDBACK), 0.0f, 1.15f);
    const float targetInput = hold ? 0.0f : 1.0f;
    const float targetPingPong = dub_clamp(dub_param(e, DUB_DELAY_PINGPONG), 0.0f, 1.0f);
    int pattern = (int)(dub_param(e, DUB_DELAY_HEADS) + 0.5f);
    if (pattern < 0) pattern = 0;
    if (pattern > 6) pattern = 6;
    const int *heads = kHeadPatterns[pattern];
    const int headCount = heads[0] + heads[1] + heads[2];
    const float outScale = 1.0f / sqrtf((float)headCount);
    const float fbScale = 1.0f / (float)headCount;
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
        s->inputGain += (targetInput - s->inputGain) * smooth;
        s->pingPong += (targetPingPong - s->pingPong) * smooth;
        if (stopping) {
            // Braking like a motor losing power: slow at first, then faster. The heads fall behind by what the
            // tape no longer moves.
            s->tapeSpeed = dub_clamp(s->tapeSpeed - brake * (0.35f + 1.3f * (1.0f - s->tapeSpeed)), 0.0f, 1.0f);
            s->stopLag = fminf(s->stopLag + 1.0f - s->tapeSpeed, maxDelay);
        } else if (s->tapeSpeed < 1.0f || s->stopLag > 0.0f) {
            s->tapeSpeed = fminf(1.0f, s->tapeSpeed + restart);
            s->stopLag += (0.0f - s->stopLag) * glide;
            if (s->stopLag < 0.5f) s->stopLag = 0.0f;
        }
        // The output follows the speed (squared: the last stretch is heard as stopping, as with the pull-up).
        const float tapeGain = s->tapeSpeed * s->tapeSpeed;
        const float pp = s->pingPong;
        const float mono = 0.5f * (in[0][n] + in[1][n]);
        s->wowPhase += wowInc;
        s->flutterPhase += flutterInc;
        if (s->wowPhase > 2.0 * DUB_PI) s->wowPhase -= 2.0 * DUB_PI;
        if (s->flutterPhase > 2.0 * DUB_PI) s->flutterPhase -= 2.0 * DUB_PI;
        const float flutter = flutterDepth * (float)sin(s->flutterPhase);

        float headSum[2], headMean[2];
        for (int c = 0; c < 2; c++) {
            // Le wow est décalé d'un quart de période entre gauche et droite : léger mouvement stéréo.
            const float wobble = wowDepth * (float)sin(s->wowPhase + c * DUB_PI * 0.5) + flutter;
            const float base = s->delaySamples + wobble;
            float sum = 0.0f;
            for (int h = 0; h < 3; h++) {
                if (!heads[h]) continue;
                sum += dub_line_tap_frac(&s->line[c], dub_clamp(base * (float)(h + 1) + s->stopLag, 4.0f, maxDelay));
            }
            headSum[c] = sum * outScale;
            headMean[c] = sum * fbScale;
        }
        for (int c = 0; c < 2; c++) {
            // Ping-pong: the input enters the left loop only, each loop feeds the other.
            const float input = (1.0f - pp) * in[c][n] + pp * (c == 0 ? mono : 0.0f);
            const float returned = (1.0f - pp) * headMean[c] + pp * headMean[1 - c];
            // A tape at a standstill recirculates nothing: the loop fades with the speed, it never sticks on one sample.
            float x = s->inputGain * input + s->feedback * tapeGain * returned;
            if (!hold) {
                for (int stage = 0; stage < 2; stage++) { // coupe-bas 12 dB/oct
                    s->lowCut[c][stage] += lowCutA * (x - s->lowCut[c][stage]);
                    x -= s->lowCut[c][stage];
                }
                for (int stage = 0; stage < 2; stage++) { // coupe-haut 12 dB/oct
                    s->highCut[c][stage] += highCutA * (x - s->highCut[c][stage]);
                    x = s->highCut[c][stage];
                }
                x = tanhf(x);
            } else {
                x = dub_clamp(x, -1.0f, 1.0f); // held loop: no colouring, just a hard ceiling
            }
            dub_line_push(&s->line[c], x);
            out[c][n] = headSum[c] * tapeGain;
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
    dub_effect_set(e, DUB_DELAY_HEADS, 0.0f);
    dub_effect_set(e, DUB_DELAY_PINGPONG, 0.0f);
    dub_effect_set(e, DUB_DELAY_HOLD, 0.0f);
    dub_effect_set(e, DUB_DELAY_DOUBLE, 0.0f);
    dub_effect_set(e, DUB_DELAY_STOP, 0.0f);
    e->state = s;
    e->prepare = delay_prepare;
    e->process = delay_process;
    e->destroy = delay_destroy;
}
