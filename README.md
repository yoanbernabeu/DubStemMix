<p align="center"><img src="Design/AppIcon-1024.png" width="128" alt="DubStemMix icon"></p>

# DubStemMix

**Version excursion for the Akai MIDImix.** Take the stems of a tune, put them on six faders, keep two more to play the effects, and cut your own version the way it was done at King Tubby's: pull the vocal, throw the snare into the echo, drop everything but bass and drums, let the spring crash. No DAW, no session to prepare, nothing to map.

Free and open source (MIT). macOS 15 or later, Apple Silicon. Native Swift and C, no Electron.

**[Website](https://yoanbernabeu.github.io/DubStemMix/) · [Docs](https://yoanbernabeu.github.io/DubStemMix/docs/) · [Video](https://www.youtube.com/watch?v=bo1voaD_10Q) · [Releases](https://github.com/yoanbernabeu/DubStemMix/releases)**

<p align="center"><img src="docs/screenshots/mix.png" width="100%" alt="DubStemMix, MIX page: six stem strips with sends to delay, reverb and phaser, then the two effect strips"></p>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/DubStemMix/main/install.sh | sh
```

It installs (or updates) `DubStemMix.app` in `/Applications`, clears the Gatekeeper quarantine flag and opens the app. The app is signed ad hoc, not notarized. Details, manual install and first steps: [Install and plug in](https://yoanbernabeu.github.io/DubStemMix/docs/install/).

## Using it

The user documentation lives on the website:

1. [Install and plug in](https://yoanbernabeu.github.io/DubStemMix/docs/install/)
2. [Your first dub, step by step](https://yoanbernabeu.github.io/DubStemMix/docs/first-dub/)
3. [Stems and splitting](https://yoanbernabeu.github.io/DubStemMix/docs/stems/)
4. [The board](https://yoanbernabeu.github.io/DubStemMix/docs/the-board/)
5. [Gestures](https://yoanbernabeu.github.io/DubStemMix/docs/gestures/)
6. [The effects](https://yoanbernabeu.github.io/DubStemMix/docs/effects/)
7. [Projects and sets](https://yoanbernabeu.github.io/DubStemMix/docs/sets/)
8. [Playing live](https://yoanbernabeu.github.io/DubStemMix/docs/live/)
9. [Settings and help](https://yoanbernabeu.github.io/DubStemMix/docs/settings/)

The rest of this README is for people who want to build, change or extend the app.

## Build from source

Needs Xcode 26 (Swift 6.2) on an Apple Silicon Mac.

```sh
git clone https://github.com/yoanbernabeu/DubStemMix.git
cd DubStemMix
swift run DubStemMix          # runs the app from the package
swift test                    # unit tests, no model or audio device needed
tools/make-app.sh 0.11.0 dist  # builds dist/DubStemMix.app and the zip
```

Command-line modes of the app binary (`swift run DubStemMix --check-audio`…):

| Flag | Does |
|---|---|
| `<folder, .dubstem or .dubset>` | launches the app and opens it |
| `--check-documents` | saves and reopens projects and a setlist, no UI, no sound |
| `--check-audio` | sound card, buffer, DSP load and dropouts on the real engine |
| `--check-plugins [--all]` | loads each third-party Audio Unit effect (or all of them), silently, and reports |
| `--check-plugin-crash` | kills an out-of-process plugin and checks the fallback |
| `--check-update [version]` | asks GitHub, downloads and verifies the latest release, replaces nothing |
| `--detect-tempo <folder> [text to exclude]` | estimates the BPM of a folder of stems |
| `--download-models` | downloads the four htdemucs_ft networks (663 MB) |
| `--split <file> [--out dir] [--provider cpu\|coreml-…] [--threads n] [--project]` | splits a song with the real models and reports the sum of the stems against the mix; `--project` also writes its ready project |
| `--check-prepare <out dir> <files…>` | runs the preparation queue on the real model, then a second queue cancelled after 5 s |
| `--snapshot <file.png> [--fx \| --master \| --inserts \| --settings \| --prepare \| --setlists]` | renders the interface with demo data; the screenshots come from here |

## Code map

A Swift package, four targets:

| Target | What it holds |
|---|---|
| `Sources/DubDSP` | the real-time DSP kernels of the built-in effects, in C: tape delay, plate and spring reverb, phaser, flanger, master chain, sub, auto-wah. No allocation and no lock on the audio thread. |
| `Sources/DubStemMixCore` | everything without UI, and tested: the audio engine (AVAudioEngine), the bus routing, the MIDI controller and the mix logic (`MixController`), projects and setlists, plugins hosting, recording, tempo detection, the update check. |
| `Sources/StemSplit` | stem separation: audio decoding, overlap-add, htdemucs_ft inference through ONNX Runtime, model download and verification. |
| `Sources/DubStemMix` | the SwiftUI app: `AppModel` (split by topic in `AppModel+*.swift`), the console, the preparation screen, the setlist workshop, the settings, the self-checks. |

Tests are in `Tests/DubStemMixCoreTests` and `Tests/StemSplitTests`. CI (`.github/workflows/ci.yml`) builds and runs them on every push and pull request.

Other folders:

- `tools/`: `make-app.sh` (packaging), `midi-monitor.swift` (prints what a MIDI controller sends), `make-icon.swift`.
- `Packaging/Info.plist`, `Design/` (icon), `install.sh`.
- `web/`: the website and the docs (Astro), see below.

## Design notes

- **The console is the truth.** Knobs are not motorized: after a page change, a knob acts only once it reaches the current value (soft takeover). The stem faders, the sends and the master fader are never restored from a project.
- **Effects live on shared buses**, like the sends of a real board, so cutting a strip never kills a tail. Buses can feed one another, but are never wired together in the audio graph: each return is handed to the other buses through memory, one buffer later (`BusPortal`), which also makes loops impossible to create.
- **Nothing cuts the sound while playing.** Any change that would stop or rewire AVAudioEngine (loading a plugin, placing a stem) is refused while playing, with a notice (`refusedWhilePlaying`).
- **Plugins load out of process** when possible: a crashing plugin falls back to the built-in effect.
- **The separation model is never shipped**: not in the repository, the releases or the app. It is downloaded on first use, after asking. Its license status is in [NOTICE](NOTICE).

`PRD.md` is the product reference (in French): every decision, the console mapping, the milestones. `TODO.md` is what remains, `IDEAS.md` what might come.

## Adding a controller

The mix logic never sees the MIDImix. It receives abstract events (knob on strip 3, row 2; MUTE on strip 5; BANK RIGHT) and sends abstract LED states back. The MIDImix itself is a **profile**, plain data: which control change is which knob, which note is which button, which notes light the LEDs. See `ControllerProfile` in `Sources/DubStemMixCore/MidiMix.swift`.

- **Same geometry** (8 strips with 3 knobs, a fader and MUTE / SOLO / REC ARM buttons, two bank buttons, a master fader): write a profile with its CC and note tables, the fragment of its MIDI name and whether it has LEDs, add it to `ControllerProfile.all`, check the numbers with `tools/midi-monitor.swift`, and open a pull request. The Novation Launch Control XL is the obvious candidate.
- **Different shape** (one knob per strip, no per-strip buttons): it needs changes in the interface and the mix logic, not just a profile. Open an issue first so we can talk about it.

## The website and the docs

`web/` is an [Astro](https://astro.build) site, published to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that touches `web/`.

```sh
cd web
npm install
npm run dev      # http://localhost:4321/DubStemMix/
```

- The landing page is `web/src/pages/index.astro` and its sections in `web/src/components/`.
- **Each docs page is a Markdown file** in `web/src/content/docs/`. The front matter sets its title, its SEO title and description, its label in the sidebar and its position (`order`). Add a file and it appears in the sidebar, the previous / next links and the sitemap.
- Screenshots used by the site are in `web/src/assets/screenshots/`.
- Facts the pages repeat (version, links) are in `web/src/site.ts`.

## Releasing

The version comes from the git tag. Publishing the GitHub release `vX.Y.Z` runs `.github/workflows/release.yml`: tests, `tools/make-app.sh X.Y.Z`, and `DubStemMix-X.Y.Z.zip` attached to the release. The in-app updater looks for that zip. The version is also written by hand in `web/src/site.ts` and in the build example above.

## Contributing

Bugs and ideas: [issues](https://github.com/yoanbernabeu/DubStemMix/issues). Pull requests welcome; for anything bigger than a fix or a controller profile, open an issue first.

## License

MIT, see [LICENSE](LICENSE). Third-party notices, including the separation model's, in [NOTICE](NOTICE).

Made for the sound system, in the spirit of King Tubby, Lee "Scratch" Perry, Scientist and everyone who ever versioned a riddim on a four-track with a spring and a tape echo.
