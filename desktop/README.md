# DubStemMix for the desktop (Linux, then Windows)

The third DubStemMix app, next to the Mac app and the MPC plugin. Product framing: `PRD.md` § 17. **Work in progress, not released.** Where each feature stands: `FEATURES.md`.

Built with [JUCE](https://juce.com). **This folder is distributed under the AGPLv3** (`desktop/LICENSE`); the rest of the repository (Mac app, MPC plugin, effects) stays under MIT.

## Where it stands

Milestones L1 (the JUCE base), L3 (the console's look) and L2 (the app's own engine, projects) of PRD § 17.5.

- **Projects as on the Mac**: `.dubstem` files open and save both ways (what this app does not handle yet, such as Audio Unit slots, is kept untouched). Drop stems (WAV, AIFF, FLAC, MP3, OGG; M4A on macOS; any sample rate) or a folder: on a strip they are placed there, elsewhere they go to **Stems to place**. Drag a stem onto a strip, or right-click it (place, move, back to the stems to place, remove). Several stems on a strip are summed. `OPEN…`, `SAVE`, `NEW`; once a session has a place, changes save on their own.
- **Each song has its settings** (effects, models, bus sends, KEEP, inserts, tempo, loop), loaded with it. A song is loaded stopped at its start; the effects' tails ring on.
- **Setlists** (`.dubset`): the list in the sidebar, touch a song or N / P to load it; colours, tags, total time, songs heard 30 s marked as played. Right-click a song to move it up or down; `+` adds a song of the library right after the one open, without cutting the music.
- **The setlist workshop** (`EDIT` in the sidebar), a screen of its own to build sets: my setlists (new, duplicate, rename, delete), the library (every project of `~/Music/DubStemMix`, plus projects dropped in, with a search), and the setlist (drag songs in, drag to reorder, a colour and a tag per line, no song twice, Backspace or right-click to remove, a missing song in red with Locate…). Every change is written at once. The play mark of a song previews its raw mix, with a waveform to jump in. `LOAD IN THE CONSOLE` gives the setlist to the console.
- **Transport**: play / pause, back to the start, loop (to the sample), the song's waveform (click or drag to move, the last 30 s in ochre), position and time left.
- **Tempo**: worked out from the stems when they are placed (never when one is already known; `AUTO` asks again), then drag the value (Shift for fine steps), TAP (or T), ÷2, ×2, SYNC for the delay.
- **Names**: double-click the song's title or a strip's name to change it. **Missing stems** are said in the sidebar; `LOCATE…` looks for them by name in a folder. `OPEN…` lists the 10 last projects and setlists.
- **Recording**: `REC` (or Ctrl/Cmd + R) records the master, after the limiter, as a 32-bit float WAV in a new session folder of the recordings folder (`~/Music/DubStemMix` unless another is chosen), with `session.txt` (date, duration, setlist, sound card, limiter, and the songs played with their time: paste it as YouTube chapters) and `session.json`. `RECORDED SESSIONS` in the sidebar (Shift + Ctrl/Cmd + R) lists them: the sheet of the one chosen, `EXPORT MP3` (320 kb/s, brought to -14 LUFS, peaks at -1.5 dB at most), `SHOW IN FILES`, `MOVE TO TRASH`. Same folders and files as the Mac app.
- **Third-party plugins**: VST3 and LV2 (and Audio Units on macOS). The name of the effect on a bus card is a menu: the built-in effect, or any effect plugin installed, by maker; `Open plugin window`; `Scan for plugins…` (in the background; a plugin that crashed a scan is skipped the next time). On the FX page, the bus's knobs become **macros**: click one to give it a parameter of the plugin (right-click to change it); the MIDImix drives them with its usual soft takeover, and a setting changed in the plugin's window comes back to the knob. Five macros per bus. The same on a strip's **insert** (INSERTS page, three macros). A plugin's macros are remembered for that plugin in every song. The project keeps the plugin, its full state and its macros; a plugin not installed is said, the built-in effect stays, and the plugin stays written in the project. Plugins run inside the app: one that crashes takes the app down.
- **Stem separation**: drop a full song on `SPLIT A SONG` in the sidebar (or click it): its drums, bass, instruments and vocals land on strips 1 to 4 of a new session, the song itself in the stems to place. Progress, time left and CANCEL in the sidebar. `PREPARE SONGS` opens a screen of its own for a whole set: drop songs or a folder, they are split one after the other, each into its stems and a ready project beside them (time left for the whole list, remove or reorder the waiting songs, `CANCEL ALL`; playback is off meanwhile). Stems go to `~/Music/DubStemMix/Stems/<file name> [fingerprint]/` (`FOLDER…` on that screen); a song already split is never computed again, by this app or the Mac app. The model (htdemucs_ft, four files, 662 MB) is **never shipped**: the app asks before downloading it, and the same screen shows its state, downloads or deletes it. On a Mac the files are the Mac app's own.
- **Master**: output meter, the limiter's switch (click `LIMITER ON`), what it takes off (`GR`, and the most since the last click), or by how much the output clips when it is off. **PRE** bar beside each strip's meter (the stems before the fader and MUTE). `POST` / `PRE` on each bus card: sends taken after or before the fader. Limiter and pre / post are kept for this computer, not in the project.
- **The console's screen, as on the Mac** (palette, Archivo and JetBrains Mono, knobs, faders, meters): strips 1-6 (stems, or the siren and the Syndrum), the effect strips 7-8, the master column, the three bus cards with their cables. The four pages (MIX, FX, MASTER, INSERTS).
- **Everything is playable with the mouse**: knobs (drag up and down), faders, MUTE, THROW (held), KEEP, SOLO (the SOLO button, then MUTE), the pages, DROP / REWIND / HOLD / CRASH, the insert of each strip, the reverb and bus 3 models, the throw target, where each bus is sent, the siren's wave and the Syndrum's roll.
- **MIDImix**, factory mapping. Plugged or unplugged while running. Its LEDs are lit (MUTE, REC ARM, BANK).
- **Keyboard**: Space play / pause, N / P next / previous song, T tap, D drop (held), H hold (held), C crash, R rewind, Esc panic; Ctrl/Cmd + O, S, Shift + S, N.
- Click the AUDIO line of the sidebar to pick the sound card and the buffer size. The engine runs at 44.1 kHz; a sound card at another rate is resampled to.

The engine (`src/DubEngine.cpp`) is a fork of the MPC plugin's, with the Mac's way of handling songs; the effects are `Sources/DubDSP`, shared with the Mac app and the MPC plugin.

Not there yet: Windows.

## Build and run

```sh
desktop/build.sh                                        # -> desktop/build/dubstemmix-desktop
desktop/build/dubstemmix-desktop                        # an empty session
desktop/build/dubstemmix-desktop song.dubstem           # a project, or a setlist (.dubset)
desktop/build/dubstemmix-desktop --selftest             # no display, no sound card: makes test songs and checks
desktop/build/dubstemmix-desktop --screentest pictures/  # no display: plays the screen like a user, checks, saves pictures
desktop/build/dubstemmix-desktop --check-plugins TAL    # looks for the plugins installed, lists them, tries those named
desktop/build/dubstemmix-desktop --split song.mp3 out/  # splits a song with the real models (once downloaded) and checks the stems
desktop/build/dubstemmix-desktop --fetch-models out/    # downloads the model's files into a folder, as the app does, and checks them
desktop/build/dubstemmix-desktop --snapshot out.png fx  # draws a page (mix, fx, master, inserts) to a picture
```

- **macOS**: Xcode command line tools and CMake (`brew install cmake`).
- **Linux** (Ubuntu): `sudo apt install build-essential cmake git pkg-config libasound2-dev libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev libcurl4-openssl-dev`

The first build downloads JUCE, Akai's MPC Plugin SDK headers (the engine is written against them) and ONNX Runtime 1.24.2 (its library from Microsoft's Maven Central package, its C header from the archive the Mac app's Swift package uses), all pinned. It takes a few minutes. The ONNX Runtime library is copied beside the program and loaded when a song is split; it must travel with it.

## The Linux archive

```sh
desktop/package.sh 0.16.0     # -> desktop/dist/Linux-DubStemMix-0.16.0-linux-x86_64.tar.gz
```

One archive to unpack and run: the program, `libonnxruntime.so` beside it, the licenses, a notice (`linux/README.txt`) and `install.sh`, which adds the app to the applications menu of the current user (no sudo; `--remove` undoes it). CI builds it on Ubuntu 22.04, so that it runs on Linux systems from 2022 on, unpacks it elsewhere and runs its self-test; a published release gets it attached (`.github/workflows/release.yml`). The version is the release's tag.

## Tested, not tested

- `--selftest` makes test songs, then checks the stems (placing, several per strip, another sample rate), the console's gestures with the levels of the MPC plugin's own test, moving in the song, the loop and its seamless loop point, the end, saving and reopening a project, names, the recent files, tempo detection, a Mac-only setting surviving a save, a missing stem and locating it, a recording (the WAV, its sheet and tracklist) and its MP3 export, and plugins with a small plugin of the tests' own (a slot, macros both ways, the project, a plugin not installed). It runs in CI on Linux.
- `--screentest` builds the real console and plays it like a user, with no window: files dropped, stems carried, right-click menus, the play, back and loop buttons, a click in the waveform, faders and knobs dragged, MUTE, THROW held, KEEP, SOLO, the pages, the bus cards, the tempo controls, double-clicks to rename, the limiter, a setlist, then the whole setlist workshop, the sidebar's live setlist gestures, REC and the recorded sessions screen. It checks the result of each gesture and saves pictures. It runs in CI on Linux too. It cannot reach the system's file dialogs, nor judge the sound.
- Stem separation is checked without the models (they are not downloaded in CI): the chunks and their overlap, decoding (mono 22.05 kHz, stereo 48 kHz, in time), the job with a separator of the tests' own (files, manifest, no second computation, cancelling leaves nothing), the model files' download from a local folder (resume, checksum, a wrong file thrown away), the preparation list, and the app's steps (the question before any download, the split, the preparation mode and its projects). With the real models, `--split` says how well the four stems add up to the song.
- On Linux (Ubuntu 22.04 in a container): the archive builds, unpacks on a bare system and passes its self-test; the model's files download (cut and resumed) and match the Mac app's; a real song is split into the same stems as the Mac app's, to the sample.
- Not tried on Linux yet: the MIDImix and its LEDs, sound, and the window's own dialogs, on a real PC.
- Windows: not built yet.
