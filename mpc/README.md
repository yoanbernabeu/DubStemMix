# DubStemMix for MPC — feasibility mock-up

A plugin for Akai MPC standalones (MPC OS 3.10.1+) that mixes up to 6 stems with an Akai MIDImix plugged into the MPC's USB port. Built with Akai's [MPC Plugin SDK](https://github.com/inmusic-software/mpc-plugin-builder-sdk). Product framing: `PRD.md` § 16.

This is a mock-up: it answers "can it work on an MPC One+?" before the real port. No effects yet.

## What it does

- Plays the songs found in the plugin's `Content/Songs/` folder, one sub-folder per song, in name order. Up to 6 WAV stems per song, in name order: strip 1, strip 2, …
- MIDImix (factory mapping): faders 1–6 set the strip levels, MUTE 1–6 toggle the strip mutes.
- MPC transport: **STOP** pauses, **PLAY** resumes, **PLAY START** jumps to the next song. At the end of a song, the next one starts on its own.
- Screen pages: **MIX** (faders, mutes, volume), **SET** (song playing, next song — pick it from the list, state, time), **TEST** (last CC and note received, last start seen, CPU, underruns).

## Build and test on the Mac

```sh
mpc/prepare-song.sh "1 My Song" bass.wav drums.wav voice.wav other.wav   # -> Content/Songs, 44.1 kHz WAV
mpc/test.sh     # SDK host simulator + transport test (STOP / PLAY / PLAY START, chaining, faders, mutes)
mpc/build.sh    # MPC build -> mpc/DubStemMix/build/Yoan Bernabeu - VST - DubStemMix/
```

The SDK is fetched (pinned) into `mpc/.sdk` on first run; it needs Python 3.9+ and downloads the Zig compiler once. Run `mpc/build.sh` after `mpc/test.sh`: the test build waits for the disk and must not go on the MPC.

## Try it on the MPC One+

1. Copy the folder `Yoan Bernabeu - VST - DubStemMix` into a folder named exactly `VST2 Plugins` at the root of the SD card or USB drive.
2. On the MPC: **Preferences → Enhancements (Beta)**: turn on **Enable Enhancements** and **External Plugin Support**.
3. Create a plugin track and load **DubStemMix** from **External Plugins**.
4. Plug the MIDImix into the MPC's USB port and set the track's MIDI input to the MIDImix.

Then check, and note the result of each:

| # | Check | Where to look |
|---|---|---|
| 1 | Moving fader 1 → "Last CC" shows 19; MUTE 1 → "Last note" shows 1 | TEST page |
| 2 | Every fader and MUTE moves its control on the MIX page, and the sound follows | MIX page |
| 3 | The MPC's own screen or tracks do not react to the MIDImix as well | — |
| 4 | PLAY → the song plays; STOP; PLAY → it resumes ("Last start" = PLAY) | TEST page |
| 5 | PLAY START → next song ("Last start" = PLAY START, "Playing" changes) | SET, TEST |
| 6 | Let a song end → the next one starts on its own | SET page |
| 7 | "Underruns" stays at 0 with 4 to 6 stems over a whole song | TEST page |
| 8 | "CPU" value, and the MPC's own CPU meter | TEST page |

## Known limits

- A short silence between two chained songs while the next one's stems are opened (gapless comes later).
- Stems must be 44.1 kHz WAV (the MPC's only rate): `prepare-song.sh` converts them.
- The MIDImix LEDs stay off: a plugin cannot send MIDI on the MPC.
- No stem names on screen yet; strips are numbered.
