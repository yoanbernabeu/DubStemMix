# DubStemMix for MPC

A plugin for Akai MPC standalones (MPC OS 3.10.1+) that turns an Akai MIDImix plugged into the MPC's USB port into the DubStemMix dub console, on up to 6 stems per song. Built with Akai's [MPC Plugin SDK](https://github.com/inmusic-software/mpc-plugin-builder-sdk). Product framing: `PRD.md` § 16. Validated on an MPC One+ for the stem player (PRD § 16.4); the effects and the screen are waiting for their first try.

## What it does

- **Songs**: the plugin plays the songs in its `Content/Songs/` folder, one sub-folder per song, in name order. Up to 6 WAV files at 44.1 kHz per song: `N - NAME.wav` goes on strip N, other files fill the free strips in name order. An optional `song.json` gives the title, BPM and strip names.
- **The MIDImix works as on the Mac** (factory mapping), with the same effects engine (`Sources/DubDSP`, compiled unchanged) and the same gain structure:
  - MIX page: knobs = DLY / REV / PHS sends; REC ARM held = dub throw; MUTE = mute.
  - Empty strips 5 and 6: the siren (MUTE held sounds, REC ARM held rises) and the Syndrum (MUTE hits, REC ARM held rolls).
  - Strip 7 = delay (speed, feedback, reverb length; MUTE = HOLD, REC ARM = ×2), strip 8 = space (phaser rate, DLY>, REV>; MUTE = FX ONLY, REC ARM = TAPE STOP). Faders 7-8 = delay and reverb returns.
  - BANK RIGHT = next page (MIX → FX → MASTER → INSERTS), BANK LEFT = MIX, both together = PANIC. Knobs catch up with the value before acting.
  - SOLO held + MUTE = solo. KEEP (touch, on each strip) keeps a strip through DROP.
- **Pads** of the DubStemMix track, on the two top rows (pad 1's note set in SETUP, 24 by default as on the One+; pads 1-4 send notes the MIDImix already uses, so they do nothing): 9 DROP (held), 10 CRASH (spring reverb), 11 REWIND (pull-up), 13 PREV and 14 NEXT (move the next song), 15 GO (play the next song now), 16 RESTART (this song from the top).
- **MPC transport**: STOP pauses, PLAY resumes, PLAY START jumps to the next song (stopped or playing). At the end of a song, the next one starts on its own, with no gap (it waits, opened, in a second deck). Effects and instruments keep sounding while stopped.
- **Screen**:
  - **CONSOLE**: a mirror of the MIDImix in the Mac app's look (names, knobs for the current page, faders, meters, the buttons' lamps, SOLO / KEEP, insert choice on INSERTS). The header (logo, song, time left, next song, console page) is on every tab.
  - **SETUP**: delay sync (to the MPC's tempo), reverb plate / spring, bus 3 phaser / flanger, throw target, where DLY> / REV> / PHS> send, master, pad 1's note and the pad map.
  - **SONG**: the setlist. Touch a song to play it next (a played one, or the one playing, to replay it); played songs are dimmed with a check mark after 30 s.
  - **TEST**: last CC, note and channel received, last start, CPU, underruns.
- Everything set is saved with the MPC project.

## Songs from the Mac app

In DubStemMix on the Mac: **File ▸ Export Setlist to MPC…** (or the setlist's right-click menu). Pick the card (or a folder), and the app writes the plugin and the setlist's songs: one 44.1 kHz WAV per strip, made from the stems the songs already use (several stems on a strip are mixed), with `song.json` (title, BPM, strip names). The card becomes the setlist; songs already there and unchanged are not copied again. It offers to back up the card's DubStemMix folder to `~/Music/DubStemMix/MPC Backups` first, and to eject the card at the end. Without the window: `DubStemMix --export-mpc <setlist.dubset> <card or folder>`.

## Build and test on the Mac

```sh
mpc/prepare-song.sh "1 My Song" drums.wav bass.wav instruments.wav vocals.wav   # -> Content/Songs, 44.1 kHz WAV
mpc/test.sh     # SDK host simulator + transport and console test
mpc/build.sh    # MPC build -> mpc/DubStemMix/build/YoanDev - VST - DubStemMix/
mpc/package.sh 1.2.3 dist   # release: dist/mpc/<plugin, no songs> + dist/MPC-DubStemMix-1.2.3.zip
```

`tools/make-app.sh` runs `mpc/package.sh` and puts the plugin inside the app; the release workflow attaches the plugin's zip next to the app's.

`python3 mpc/DubStemMix/preview_skin.py web/src/assets/screenshots/mpc` redraws the screen pictures of the docs from the screen files.

**One engine for two apps.** `DubStemMix/src/DubStemMix.cpp` is also the engine of the Linux app (`desktop/`), which builds it with `DSM_DESKTOP` defined. Everything between `#ifdef DSM_DESKTOP` and `#endif` is the desktop's and is not in the plugin; the rest is shared, so a change to the console, the gestures or the mix reaches both. Before changing that file for the desktop only, note the checksum of `build/YoanDev - VST - DubStemMix/VST/dubstemmix-arm64.so`: builds are reproducible, and a desktop-only change must leave it the same. `mpc/test.sh` runs in CI.

The SDK is fetched (pinned) into `mpc/.sdk` on first run; it needs Python 3.9+ and downloads the Zig compiler once. `build.sh` writes the screen (`DubStemMix/make_skin.py` → `DubStemMix/skins/`) from the parameter list. Run `mpc/build.sh` after `mpc/test.sh`: the test build waits for the disk and must not go on the MPC.

## Install on the MPC

1. Copy the folder `YoanDev - VST - DubStemMix` into a folder named exactly `VST2 Plugins` at the root of the SD card or USB drive.
2. On the MPC: **Preferences → Enhancements (Beta)**: turn on **Enable Enhancements** and **External Plugin Support**.
3. Create a plugin track and load **DubStemMix** from **External Plugins**.
4. Plug the MIDImix into the MPC's USB port and set the track's MIDI input to the MIDImix.

The plugin reads the song list when it loads: after adding songs, load it again (or restart the MPC).

## Known limits

- The MIDImix LEDs stay off (a plugin cannot send MIDI on the MPC): the screen shows them.
- Not yet on the MPC: pre / post-fader sends (all sends are post-fader), the auto-wah's direction (always up).
- RESTART and REWIND reopen the song: a very short silence before it starts again.
