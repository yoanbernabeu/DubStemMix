---
name: feature
description: Add or change a DubStemMix feature on every app at once (Mac app, MPC plugin, later the Linux / Windows app) without letting them drift apart. Frames the change with the user, writes it in PRD.md, updates the platform table FEATURES.md, codes it in each app that gets it, tests, and hands the user a list of trials per machine. Use when the user asks to add, change or remove a feature, a gesture, an effect, a control or a screen, or runs /feature [what].
---

# Add or change a DubStemMix feature

Answer the user in French, short and concrete, with usage examples and no engine jargon. Code comments are in English.

DubStemMix exists as several apps that share the product, not the code:

| App | Where | Language |
|---|---|---|
| Mac app | `Sources/DubStemMix` (screens), `Sources/DubStemMixCore` (engine, console logic) | Swift |
| MPC plugin | `mpc/DubStemMix/src` (engine, console logic), `make_skin.py` + `skin_art.py` (screen) | C++, Python |
| Linux / Windows app | not started (column `·` in `FEATURES.md`) | — |

Only the effect kernels are shared: `Sources/DubDSP` (C), compiled unchanged by the MPC plugin. Everything else is written once per app, so the only things keeping the apps in step are `PRD.md`, `FEATURES.md` and this skill.

## Rules

- `PRD.md` is the single product reference. `FEATURES.md` says where each feature exists. Both change in the same PR as the code.
- Nothing is coded before the user has validated the PRD text. No behaviour the user did not ask for or agree to.
- **The MPC evolves like the other apps**: a new feature or a change is offered for it at step 1, like for the Mac. Only the gaps already written as wanted in `FEATURES.md` (`🟡`, `❌`) are settled: do not reopen them or "fix" them on your own, the user will ask if one should change.
- Existing gestures never change without the user's explicit agreement.
- A feature left out of an app is written down as such (`❌` with its reason), never silently skipped.
- One commit per delivered point, tests green before each commit. No push, PR, merge or release without the user's OK.

## Steps

### 1. Frame it with the user

Read the PRD sections the change touches and the matching rows of `FEATURES.md` first. Then ask, in one go, only what is not already decided:

- what the user sees and does (the gesture, the control, the screen);
- **which apps get it**. Propose a default per app with its reason (for example "not on the MPC: no room on the screen"), and let the user decide;
- anything that cannot be the same on an app (no keyboard on the MPC, no LEDs, touch instead of mouse): say how it would be done there.

### 2. Write it down

- `PRD.md`: the change in its section (or a new one), dated, marked "(à valider)" until step 3. If an app does it differently, say so there.
- `FEATURES.md`: add or update the row. Every app column gets a sign: `⏳` for an app that will get it, `❌` or `🟡` with the reason for a wanted gap, `·` for Linux / Windows as long as that port is not framed. Never leave a `❔` you can settle by asking.

### 3. Get the user's OK

Show the PRD text and the table row. Wait for an explicit yes before any code. Then remove "(à valider)".

### 4. Code it, app by app

On a branch, the Mac first (the user judges the sound there), then the others.

- **Effect kernel** (`Sources/DubDSP`): one change, both apps get it. New kernel file → add its wrapper `mpc/DubStemMix/src/dsp_<name>.cpp`.
- **Effect parameter**: `Sources/DubStemMixCore/FXParameter.swift` and `mpc/DubStemMix/src/FX.h` hold the same list (defaults, laws, labels, page layouts) and must stay in step. On the MPC, **only append** parameters, never reorder: saved MPC projects depend on the order. `make_skin.py` checks parameter indices; update them when it complains.
- **Console logic** (pages, soft takeover, gestures, mute / solo): `Sources/DubStemMixCore/MixController.swift` on the Mac, `mpc/DubStemMix/src/DubStemMix.cpp` on the MPC.
- **Signal path**: `Sources/DubStemMixCore/AudioEngine.swift` on the Mac; the block at the top of `DubStemMix.cpp` describes the MPC's and must stay true.
- **Screens**: SwiftUI views on the Mac; `make_skin.py` / `skin_art.py` on the MPC (the MPC must restart after a skin change).
- **Export to MPC** (`Sources/DubStemMixCore/MPCExport.swift`, `song.json`): if the feature needs something from the project on the MPC, it goes through the export.

### 5. Test

- Mac: `swift test`.
- MPC: `mpc/test.sh`, then `mpc/build.sh` (always after the test: the test build must never go on the MPC).
- **Same gesture, same result**: when a gesture or a sound behaviour lands on more than one app, write the same scenario with the same expected values on each side (`Tests/DubStemMixCoreTests` and `mpc/tests`), so a later change to one app alone fails a test.
- Bound long commands (`perl -e 'alarm N; exec @ARGV' …`).

Commit each delivered point once its tests pass.

### 6. Update the table and the docs

- `FEATURES.md`: `⏳` becomes `✅` (or `🟡` with the difference) for each app actually done. Whatever is not done stays `⏳` and is reported.
- Docs where the feature shows: `README.md`, `mpc/README.md`, the site (`web/src`), screenshots if a screen changed.

### 7. Hand over the trials

Give the user one short list per machine, with what to do and what to expect:

- **Mac**: the gestures to try on the MIDImix and in the window.
- **MPC One+**: how to get the new plugin on the card (File ▸ Export Setlist to MPC…, or `mpc/build.sh` and copy), then the gestures to try.
- **Linux / Windows**: once that app exists.

Say plainly what was tested by the test suites only and what still needs the user's ears. Nothing is "validated" before the user says so; then note it in the PRD with the date.
