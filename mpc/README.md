# DubStemMix for MPC

A plugin for Akai MPC standalones (MPC OS 3.10.1+) that turns an Akai MIDImix plugged into the MPC's USB port into the DubStemMix dub console, on up to 6 stems per song. Built with Akai's [MPC Plugin SDK](https://github.com/inmusic-software/mpc-plugin-builder-sdk). Product framing: `PRD.md` § 16. Validated on an MPC One+ for the stem player (PRD § 16.4); the effects and the screen are waiting for their first try.

## What it does

- **Songs**: the plugin plays the songs in its `Content/Songs/` folder, one sub-folder per song, in name order. Up to 6 WAV stems at 44.1 kHz per song, in name order: strip 1, strip 2, … (drums, bass, instruments, vocals for a split song).
- **The MIDImix works as on the Mac** (factory mapping), with the same effects engine (`Sources/DubDSP`, compiled unchanged) and the same gain structure:
  - MIX page: knobs = DLY / REV / PHS sends; REC ARM held = dub throw; MUTE = mute.
  - Empty strips 5 and 6: the siren (MUTE held sounds, REC ARM held rises) and the Syndrum (MUTE hits, REC ARM held rolls).
  - Strip 7 = delay (speed, feedback, reverb length; MUTE = HOLD, REC ARM = ×2), strip 8 = space (phaser rate, DLY>, REV>; MUTE = FX ONLY, REC ARM = TAPE STOP). Faders 7-8 = delay and reverb returns.
  - BANK RIGHT = next page (MIX → FX → MASTER → INSERTS), BANK LEFT = MIX, both together = PANIC. Knobs catch up with the value before acting.
  - SOLO held + MUTE = solo. KEEP (touch, on each strip) keeps a strip through DROP.
- **Pads** of the DubStemMix track (pad 1's note set in SETUP, 37 by default): 1 DROP (held), 2 CRASH (spring reverb), 3 REWIND (pull-up), 5 PREV and 6 NEXT (move the next song), 7 GO (play the next song now), 8 RESTART (this song from the top).
- **MPC transport**: STOP pauses, PLAY resumes, PLAY START jumps to the next song (stopped or playing). At the end of a song, the next one starts on its own, with no gap (it waits, opened, in a second deck). Effects and instruments keep sounding while stopped.
- **Screen**:
  - **CONSOLE**: a mirror of the MIDImix in the Mac app's look (names, knobs for the current page, faders, meters, the buttons' lamps, SOLO / KEEP, insert choice on INSERTS). The header (logo, song, time left, next song, console page) is on every tab.
  - **SETUP**: delay sync (to the MPC's tempo), reverb plate / spring, bus 3 phaser / flanger, throw target, where DLY> / REV> / PHS> send, master, pad 1's note and the pad map.
  - **SONG**: the setlist. Touch a song to play it next (a played one, or the one playing, to replay it); played songs are dimmed with a check mark after 30 s.
  - **TEST**: last CC and note received, last start, CPU, underruns.
- Everything set is saved with the MPC project.

## Build and test on the Mac

```sh
mpc/prepare-song.sh "1 My Song" drums.wav bass.wav instruments.wav vocals.wav   # -> Content/Songs, 44.1 kHz WAV
mpc/test.sh     # SDK host simulator + transport and console test
mpc/build.sh    # MPC build -> mpc/DubStemMix/build/YoanDev - VST - DubStemMix/
```

The SDK is fetched (pinned) into `mpc/.sdk` on first run; it needs Python 3.9+ and downloads the Zig compiler once. `build.sh` writes the screen (`DubStemMix/make_skin.py` → `DubStemMix/skins/`) from the parameter list. Run `mpc/build.sh` after `mpc/test.sh`: the test build waits for the disk and must not go on the MPC.

## Install on the MPC

1. Copy the folder `YoanDev - VST - DubStemMix` into a folder named exactly `VST2 Plugins` at the root of the SD card or USB drive.
2. On the MPC: **Preferences → Enhancements (Beta)**: turn on **Enable Enhancements** and **External Plugin Support**.
3. Create a plugin track and load **DubStemMix** from **External Plugins**.
4. Plug the MIDImix into the MPC's USB port and set the track's MIDI input to the MIDImix.

The plugin reads the song list when it loads: after adding songs, load it again (or restart the MPC).

## Known limits

- The MIDImix LEDs stay off (a plugin cannot send MIDI on the MPC): the screen shows them.
- Not yet on the MPC: pre / post-fader sends (all sends are post-fader), the auto-wah's direction (always up), the song's own tempo (delay sync and the Syndrum roll follow the MPC's tempo), more than 24 songs on the SONG tab.
- RESTART and REWIND reopen the song: a very short silence before it starts again.
