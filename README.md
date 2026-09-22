<p align="center"><img src="Design/AppIcon-1024.png" width="128" alt="DubStemMix icon"></p>

# DubStemMix

**A dub mixing console for the Akai MIDImix.** Load the stems of a song, and mix it live like a dub engineer: faders, mutes, sends to a tape delay, a reverb and a phaser, dub throws, a stepped high-pass, sound-system kills, drops and rewinds. No DAW, no configuration. Plug the console, drop a folder of stems, play.

Free and open source (MIT), macOS 26, Apple Silicon.

## Install

One line, from the latest release. It installs (or updates) `DubStemMix.app` in `/Applications`, clears the Gatekeeper quarantine flag and opens the app:

```sh
curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/dubstemmix/main/install.sh | sh
```

Or by hand: download `DubStemMix-<version>.zip` from the [releases](https://github.com/yoanbernabeu/dubstemmix/releases), unzip, move `DubStemMix.app` to `/Applications`.

**Gatekeeper.** The app is signed ad hoc, not notarized (there is no Apple Developer account behind it). On first launch macOS may say the app "cannot be opened". Two ways through:

- System Settings ▸ Privacy & Security, scroll down, **Open Anyway**;
- or, in a terminal: `xattr -dr com.apple.quarantine /Applications/DubStemMix.app` (this is what the install script does).

## First minute

1. **Plug in the MIDImix**, on its factory mapping. If you changed it with the Akai MIDImix Editor: File ▸ New, then Send to Hardware. The status line at the bottom left says "connected"; it also tells you when the console sends something the factory mapping does not know.
2. **Press SEND ALL** on the console. The app then knows where every knob and fader is. Knobs are not motorized: after a page change, a knob acts once it reaches the value it now drives, shown as a cream "ghost" mark until then.
3. **Drop a folder of stems** anywhere in the window, then drag each stem onto the strip you want (or right-click it). Nothing is placed for you: you decide what goes where. A file that is really the full mix stays in the pool.
4. **Play.** Space plays and pauses, Return goes back to the start, L toggles the loop.

## The console

Eight strips, mirrored on screen. Per strip: three knobs, MUTE, REC ARM, a fader. BANK LEFT / BANK RIGHT change what the knobs do; the faders stay strip volumes on every page.

| Page | Reach it | Knobs |
|---|---|---|
| **MIX** | BANK LEFT (always comes back here) | sends to DELAY, REVERB, BUS 3 |
| **FX** | BANK RIGHT | the built-in effects: delay time, feedback, wow, filters, reverb decay, damping, phaser rate, depth… and the three returns |
| **MASTER** | BANK RIGHT again | big knob (stepped high-pass), kills BASS / MID / TOP, dubplate colour, delay heads and ping-pong |
| **INSERTS** | BANK RIGHT again | each strip's insert (sub, auto-wah, or a plugin's macros) |

- **MUTE** cuts a strip; the LED shows the state. **SOLO held + MUTE** solos it (solo in place: the effect returns keep playing).
- **REC ARM held** is the **dub throw**: the strip goes at full into the delay (or the reverb, or both, from the delay card's menu), taken before the fader and the mute, so you can throw a cut strip.
- Effects sit on shared buses: cutting a strip never interrupts an echo or a reverb tail already on its way.
- Sends are post-fader by default; Settings (⌘,) switch any bus to pre-fader.

## Gestures

Keyboard or the buttons in the master column. They never touch your mutes: release, and the mix is exactly as it was.

| Key | Gesture |
|---|---|
| **D** (hold) | **DROP**: cuts every strip not marked KEEP (mark the bass and the drums) |
| **H** (hold) | **HOLD**: the delay loops on itself, input closed, feedback at unity |
| **C** | **CRASH**: hits the spring reverb (select Built-in · Spring on the REVERB card) |
| **R** | **Pull-up**: tape brake on the whole master, back to the top, play |
| **T** | tap tempo · **N / P** next and previous song of the setlist · **⌘R** record the master |

## Effects

Built in, no plugin needed: a tape **dub delay** (feedback up to self-oscillation, filters in the loop, wow and flutter, tempo sync, Space Echo head patterns, ping-pong), a Dattorro **plate** and a **spring** reverb, a Bi-Phase style **phaser** and a tape **flanger**, a **master chain** (King Tubby's stepped high-pass, a three-band isolator, dubplate colour), and two strip inserts (**sub-octave** generator, **auto-wah**).

Any **Audio Unit** effect can replace a built-in effect on a bus, or sit in a strip's insert. Plugins load out of process: one that crashes falls back to the built-in effect and stays in the project to be reloaded. On the FX page the bus's six knobs become macros you assign to the plugin's parameters, remembered per plugin.

Set a plugin on a **bus** 100 % wet: the dry signal already goes to the master through the strip. A plugin in an **insert** is in the direct path, set its mix as you like.

## Splitting a song into stems

Drop a full song (WAV, MP3, AIFF, FLAC, M4A…) in **SPLIT A SONG** in the sidebar, or File ▸ Split a Song…. Drums, bass, instruments and vocals land on strips 1 to 4, the original goes to the pool for A/B listening. Stems are written as Float32 WAV in `~/Music/DubStemMix/Stems/` (changeable in Settings); a song already split reopens without recomputing.

The separation runs on the CPU with [htdemucs_ft](https://github.com/facebookresearch/demucs) through ONNX Runtime. Count roughly 1.2× the song's length on an M3 Pro (a 5-minute song takes about 6 minutes) and up to 9 GB of memory. The four model files (663 MB) are **not** in this repository, the releases or the app: they are downloaded from Hugging Face on first use, after asking you, into `~/Library/Application Support/DubStemMix/Models`. Their license status is described in [NOTICE](NOTICE).

## Projects, setlists, recording

- **Save** (⌘S) writes a `.dubstem` project: which stems on which strips, effect settings, plugins and their state, inserts, KEEP marks, tempo. Fader and knob positions are not restored: the console is the truth. Once saved, changes are saved automatically. Files are referenced by absolute and relative path, so a moved folder still opens.
- **Setlist** (`.dubset`): the sidebar lists the songs of the set; N / P load the next or previous one, stopped at the start, while the effect tails of the previous song keep going. Drag rows to reorder, double-click the title to rename.
- **REC** (⌘R) records the master, after the limiter, as 24-bit WAV in `~/Music/DubStemMix` (changeable in Settings).

## Settings (⌘,)

Output device and buffer size (128 or 256 for live), recordings folder, pre/post-fader per bus, Audio Unit rescan, separation engine (download, delete) and stems folder. The status bar shows the device, the audio-thread load and the dropouts reported by the device.

## Known limits

- Plugin latency is not compensated. Fine on send buses (100 % wet), audible in an insert with a plugin that adds latency.
- Changing the effect of a bus or an insert stops the engine for a fraction of a second (effect tails are cut), then playback resumes where it was: AVAudioEngine cannot rewire while running.
- Dropping or removing a stem during playback causes a short gap; MUTE takes about 25 ms to close (the mixer's own ramp).
- macOS 26 only for now: the engine uses the `Synchronization` module and macOS 26 SDK APIs.
- The MIDImix is the only controller in this version; the mapping lives in one file, other controllers can follow.

## Build from source

```sh
git clone https://github.com/yoanbernabeu/dubstemmix.git
cd dubstemmix
swift run DubStemMix          # runs the app from the package
tools/make-app.sh 0.1.0 dist  # builds dist/DubStemMix.app and the zip
swift test                    # 65 tests, no model or audio device needed
```

Needs Xcode 26 (Swift 6.2). Useful self-checks without the UI: `--check-documents`, `--check-audio`, `--check-plugins`, `--check-plugin-crash`, `--download-models`, `--split <file>`.

`PRD.md` is the product reference (in French): every decision, the console mapping, the milestones. `TODO.md` is what remains.

## License

MIT, see [LICENSE](LICENSE). Third-party notices, including the separation model's, in [NOTICE](NOTICE).
