# DubStemMix for the desktop (Linux, then Windows)

The third DubStemMix app, next to the Mac app and the MPC plugin. Product framing: `PRD.md` § 17. **Work in progress, not released.** Where each feature stands: `FEATURES.md`.

Built with [JUCE](https://juce.com). **This folder is distributed under the AGPLv3** (`desktop/LICENSE`); the rest of the repository (Mac app, MPC plugin, effects) stays under MIT.

## Where it stands

Milestones L1 (the JUCE base), L3 (the console's look) and L2 (the app's own engine, projects) of PRD § 17.5.

- **Projects as on the Mac**: `.dubstem` files open and save both ways (what this app does not handle yet, such as Audio Unit slots, is kept untouched). Drop stems (WAV, AIFF, FLAC, MP3, OGG; M4A on macOS; any sample rate) or a folder: on a strip they are placed there, elsewhere they go to **Stems to place**. Drag a stem onto a strip, or right-click it (place, move, back to the stems to place, remove). Several stems on a strip are summed. `OPEN…`, `SAVE`, `NEW`; once a session has a place, changes save on their own.
- **Each song has its settings** (effects, models, bus sends, KEEP, inserts, tempo, loop), loaded with it. A song is loaded stopped at its start; the effects' tails ring on.
- **Setlists** (`.dubset`): the list in the sidebar, touch a song or N / P to load it; colours, tags, total time, songs heard 30 s marked as played.
- **Transport**: play / pause, back to the start, loop (to the sample), the song's waveform (click or drag to move, the last 30 s in ochre), position and time left.
- **Tempo**: worked out from the stems when they are placed (never when one is already known; `AUTO` asks again), then drag the value (Shift for fine steps), TAP (or T), ÷2, ×2, SYNC for the delay.
- **Names**: double-click the song's title or a strip's name to change it. **Missing stems** are said in the sidebar; `LOCATE…` looks for them by name in a folder. `OPEN…` lists the 10 last projects and setlists.
- **Master**: output meter, the limiter's switch (click `LIMITER ON`), what it takes off (`GR`, and the most since the last click), or by how much the output clips when it is off. **PRE** bar beside each strip's meter (the stems before the fader and MUTE). `POST` / `PRE` on each bus card: sends taken after or before the fader. Limiter and pre / post are kept for this computer, not in the project.
- **The console's screen, as on the Mac** (palette, Archivo and JetBrains Mono, knobs, faders, meters): strips 1-6 (stems, or the siren and the Syndrum), the effect strips 7-8, the master column, the three bus cards with their cables. The four pages (MIX, FX, MASTER, INSERTS).
- **Everything is playable with the mouse**: knobs (drag up and down), faders, MUTE, THROW (held), KEEP, SOLO (the SOLO button, then MUTE), the pages, DROP / REWIND / HOLD / CRASH, the insert of each strip, the reverb and bus 3 models, the throw target, where each bus is sent, the siren's wave and the Syndrum's roll.
- **MIDImix**, factory mapping. Plugged or unplugged while running. Its LEDs are lit (MUTE, REC ARM, BANK).
- **Keyboard**: Space play / pause, N / P next / previous song, T tap, D drop (held), H hold (held), C crash, R rewind, Esc panic; Ctrl/Cmd + O, S, Shift + S, N.
- Click the AUDIO line of the sidebar to pick the sound card and the buffer size. The engine runs at 44.1 kHz; a sound card at another rate is resampled to.

The engine (`src/DubEngine.cpp`) is a fork of the MPC plugin's, with the Mac's way of handling songs; the effects are `Sources/DubDSP`, shared with the Mac app and the MPC plugin.

Not there yet: the setlist workshop, recording, third-party plugins, stem separation.

## Build and run

```sh
desktop/build.sh                                        # -> desktop/build/dubstemmix-desktop
desktop/build/dubstemmix-desktop                        # an empty session
desktop/build/dubstemmix-desktop song.dubstem           # a project, or a setlist (.dubset)
desktop/build/dubstemmix-desktop --selftest             # no display, no sound card: makes test songs and checks
desktop/build/dubstemmix-desktop --snapshot out.png fx  # draws a page (mix, fx, master, inserts) to a picture
```

- **macOS**: Xcode command line tools and CMake (`brew install cmake`).
- **Linux** (Ubuntu): `sudo apt install build-essential cmake git pkg-config libasound2-dev libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev`

The first build downloads JUCE and Akai's MPC Plugin SDK headers (the engine is written against them), both pinned. It takes a few minutes.

## Tested, not tested

- `--selftest` makes test songs, then checks the stems (placing, several per strip, another sample rate), the console's gestures with the levels of the MPC plugin's own test, moving in the song, the loop and its seamless loop point, the end, saving and reopening a project, names, the recent files, tempo detection, a Mac-only setting surviving a save, a missing stem and locating it. It runs in CI on Linux.
- Not tried on Linux yet: the MIDImix and its LEDs, and sound on a real PC.
- Windows: not built yet.
