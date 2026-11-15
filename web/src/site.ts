// Single place for the facts the page repeats. Bump `version` with each release.
export const site = {
  name: "DubStemMix",
  version: "0.14.0",
  repo: "https://github.com/yoanbernabeu/DubStemMix",
  releases: "https://github.com/yoanbernabeu/DubStemMix/releases",
  latest: "https://github.com/yoanbernabeu/DubStemMix/releases/latest",
  // The MPC plugin alone, from the latest release (fixed name, see mpc/package.sh).
  mpcDownload: "https://github.com/yoanbernabeu/DubStemMix/releases/latest/download/DubStemMix-MPC.zip",
  videoId: "bo1voaD_10Q",
  brewCommand: "brew install --cask yoanbernabeu/tap/dubstemmix",
  installCommand:
    "curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/DubStemMix/main/install.sh | sh",
  author: { name: "YoanDev", url: "https://yoandev.co" },
  requirements: "A macOS app · or a plugin for the Akai MPC · free and open source",
  macRequirements: "macOS 15 or later · Apple Silicon · Akai MIDImix optional",
  mpcRequirements: "Akai MPC with MPC OS 3.10.1 or later · Akai MIDImix",
  // <title>: under 60 characters. Description: under 160, for search snippets and link previews.
  title: "DubStemMix · Live dub mixing for the Akai MIDImix",
  description:
    "Free dub mixing console for the Akai MIDImix, as a macOS app or an Akai MPC plugin. Stems on six faders, cut a dub live: tape delay, spring reverb, throws.",
  keywords: [
    "dub mixing", "dub", "reggae", "stems", "Akai MIDImix", "live mixing", "tape delay", "spring reverb",
    "sound system", "stem separation", "demucs", "macOS", "MIDI controller", "version", "riddim", "open source",
    "Akai MPC", "MPC plugin", "MPC One",
  ],
};
