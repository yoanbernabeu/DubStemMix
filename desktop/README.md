# DubStemMix desktop mock-up

A feasibility mock-up for a Linux (then Windows) DubStemMix, framed in `PRD.md` § 17.2. **Not a release**: it only checks that the engine and the console hold outside the MPC.

It is the MPC plugin's engine (`mpc/DubStemMix/src`, compiled in unchanged, with the effects of `Sources/DubDSP`) inside a small host that gives it a sound card, the MIDImix and a plain window.

## What it does

- Plays the songs of an **Export to MPC** folder (File ▸ Export Setlist to MPC… in the Mac app, to a folder), or the repository's test songs (`mpc/DubStemMix/Content/Songs`) when started from the repository with no argument.
- **MIDImix**, factory mapping, exactly as on the MPC: pages, effects and gestures come with the engine. Plugged or unplugged while running. Its LEDs are lit (MUTE, REC ARM, BANK).
- **Keyboard**: Space = play / pause, N = next song.
- **Window**: 8 strips (name, fader, meter, MUTE and REC ARM lamps) and the master, the song and time left, the sound card and buffer size, the MIDImix's state, the load, late buffers and disk dropouts.

## Build and run

```sh
desktop/build.sh                                        # -> desktop/build/dubstemmix-desktop
desktop/build/dubstemmix-desktop                        # the repository's test songs
desktop/build/dubstemmix-desktop "/path/to/an export"   # an Export to MPC folder, or a card
desktop/build/dubstemmix-desktop --selftest             # no window, no sound card: checks the levels
```

- **macOS**: Xcode command line tools and CMake (`brew install cmake`).
- **Linux** (Ubuntu): `sudo apt install build-essential cmake git libasound2-dev xorg-dev libgl1-mesa-dev`.

The first build downloads Akai's MPC Plugin SDK headers (the plugin is written against them) and four small libraries, all pinned: miniaudio (sound), RtMidi (MIDI), Dear ImGui and GLFW (window). All are MIT-compatible.

## Known limits

- The sound card is opened at 44.1 kHz, the engine's only rate.
- `--selftest` plays the same gestures, and expects the same levels, as the MPC plugin's own test (`mpc/tests/transport_test.cpp`).
- Windows: not built yet (the plugin's file listing and the effects' C atomics need work there).
