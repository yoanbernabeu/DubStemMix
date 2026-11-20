---
title: On Linux (alpha)
seoTitle: DubStemMix on Linux (alpha) · Akai MIDImix dub console
description: "An early Linux version of DubStemMix: download one archive, unpack and run. What is in it, what is different from the Mac app, and what nobody has tried yet."
nav: On Linux (alpha)
order: 11
---

DubStemMix is being ported to Linux. A first version is out as an **alpha**: it is complete on paper, its automatic tests pass, but **nobody has played it on a real Linux PC yet**. Sound, the MIDImix and its LEDs are the parts that still need ears and hands. Try it at home before you take it anywhere near a stage, and [tell us how it went](https://github.com/yoanbernabeu/DubStemMix/issues).

**[Download the Linux alpha (.tar.gz)](https://github.com/yoanbernabeu/DubStemMix/releases/latest/download/Linux-DubStemMix-x86_64.tar.gz)**, free and open source.

## What you need

- A **64-bit PC (x86_64)** with a Linux from 2022 or later: Ubuntu 22.04 and newer, and their equivalents.
- The **Akai MIDImix**, on its factory mapping. Optional: everything also works with the mouse and the keyboard.

## Install and run

Unpack the archive and start the program, in a terminal:

```sh
tar -xzf Linux-DubStemMix-x86_64.tar.gz
cd DubStemMix-*-linux-x86_64
./DubStemMix
```

To find it in your applications menu afterwards:

```sh
./install.sh
```

It copies the folder to `~/.local/share/DubStemMix` and adds a menu entry, for your user only, without `sudo`. `./install.sh --remove` undoes it.

If the program does not start, a library is probably missing. On Ubuntu or Debian:

```sh
sudo apt install libasound2 libfreetype6 libfontconfig1 libcurl4 libx11-6 libxext6 libxinerama1 \
  libxrandr2 libxcursor1 libxcomposite1 libxrender1
```

Keep the files of the folder together: the program loads `libonnxruntime.so`, beside it, to split songs.

## Sound and the console

- Click the **AUDIO** line at the bottom left to pick the sound card and the buffer size. Sound goes through ALSA; PipeWire and PulseAudio show up there as devices.
- Plug the MIDImix in USB, before or after opening the app: the status line says **MIDIMIX connected**.

## What is in it

The same console as the Mac app, with the same look, effects and gestures:

- stems on six strips, the two effect strips, the siren and the Syndrum, the four pages (MIX, FX, MASTER, INSERTS);
- projects and setlists: **the Mac app's own files**, a project made on one opens on the other;
- the setlist workshop (**EDIT** in the sidebar);
- recording the master, the recorded sessions and their MP3 export;
- splitting a full song into drums, bass, instruments and vocals (**SPLIT A SONG**), and a whole set at once (**PREPARE SONGS**). The first time, the app asks before downloading the model (662 MB);
- your own effect plugins, in **VST3** and **LV2**, on the buses and on each strip.

The other pages of these docs describe the Mac app; almost all of it applies as is.

## What is different from the Mac app

- **SOLO**: click the SOLO button in the right column, then MUTE on the strips (on the Mac: ⌥-click on MUTE).
- **No menu bar and no settings window**: `OPEN…`, `SAVE` and `NEW` are at the top; the stem separation's model and folder are on the **PREPARE SONGS** screen; the recordings' folder is on the **RECORDED SESSIONS** screen.
- **Plugins**: 5 macros per bus instead of 6, and a plugin that crashes takes the app down with it. Plugins are not shared between a project's Mac and Linux lives: each app keeps its own.
- **Not there yet**: exporting a set to an Akai MPC or to a folder, controllers other than the MIDImix, updates from inside the app (download the new archive instead).
- **M4A** files are not read on Linux; WAV, AIFF, FLAC, MP3 and OGG are.

## Where your files go

- Projects, setlists, split stems and recordings: `~/Music/DubStemMix`.
- Settings, and the stem separation model if you downloaded it: `~/.config/DubStemMix`.

## Updates and removal

Download the new archive from the [releases page](https://github.com/yoanbernabeu/DubStemMix/releases) and unpack it in place of the old one (run `./install.sh` again if you used it). To remove the app: `./install.sh --remove`, or delete its folder. Your files in `~/Music/DubStemMix` are yours: nothing deletes them.

## License

The Linux app is built with JUCE and is distributed under the **GNU AGPL version 3**; its source is the `desktop/` folder of the [repository](https://github.com/yoanbernabeu/DubStemMix). The Mac app and the MPC plugin stay under the MIT license.
