DubStemMix @VERSION@ for Linux
==============================

A dub mixing console for your stems, played with an Akai MIDImix (or the mouse and the keyboard).
Website and guides: https://github.com/yoanbernabeu/DubStemMix

Run it
------
  ./DubStemMix                    from this folder, or
  ./install.sh                    to add DubStemMix to the applications menu (in your home folder, no sudo)

Keep the files of this folder together: the program loads libonnxruntime.so, beside it, to split songs.

What it needs
-------------
A 64-bit Linux from 2022 or later (Ubuntu 22.04 and newer, and their equivalents). The libraries it uses
are on most desktops already; on Ubuntu or Debian, if it does not start:

  sudo apt install libasound2 libfreetype6 libfontconfig1 libcurl4 libx11-6 libxext6 libxinerama1 \
    libxrandr2 libxcursor1 libxcomposite1 libxrender1

Sound goes through ALSA (PipeWire and PulseAudio show up as ALSA devices). Click the AUDIO line of the
sidebar to pick the sound card and the buffer size. The MIDImix is found when plugged, on its factory mapping.

Splitting songs
---------------
SPLIT A SONG and PREPARE SONGS need the htdemucs_ft model: four files, 662 MB, downloaded once from
Hugging Face after you agree, into ~/.config/DubStemMix/Models. They are never part of this archive
(see licenses/NOTICE.txt for the weights' license status).

Your files
----------
Projects, setlists, stems and recordings live in ~/Music/DubStemMix; settings in ~/.config/DubStemMix.
Projects (.dubstem) and setlists (.dubset) are the Mac app's: they open on both.

Licenses
--------
This program is free software under the GNU Affero General Public License version 3
(licenses/LICENSE-AGPL-3.0.txt). Its source, for this exact version, is the tag v@VERSION@ of
https://github.com/yoanbernabeu/DubStemMix (folder desktop/). Third-party notices are in licenses/.
