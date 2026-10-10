// The two reading sections of the site, both made of Markdown pages:
// the docs (src/content/docs) and the comparisons (src/content/compare).
import { getCollection } from "astro:content";

export const sections = {
  docs: {
    label: "Docs",
    root: "/docs/",
    start: "Start here",
    numbered: true,
    title: "DubStemMix docs",
    seoTitle: "DubStemMix docs · Learn to cut a dub live",
    description:
      "Step-by-step guides for DubStemMix: load your stems, play the console, throw into the echo, crash the spring and record your own dub version.",
    intro: "From the first plug to your first recorded version. Read the pages in order, or jump straight to the one you need.",
  },
  compare: {
    label: "Compare",
    root: "/compare/",
    start: "Overview",
    numbered: false,
    title: "DubStemMix compared",
    seoTitle: "DubStemMix vs DAWs and DJ software",
    description:
      "How DubStemMix compares with Amp FreQQ, Ableton Live, Logic Pro, Serato, rekordbox, Traktor, djay, VirtualDJ and Mixxx for a live dub mix of stems.",
    intro:
      "DubStemMix does one thing: a live dub mix of one tune's stems, on a console. Here is how it compares with the software people already use, and when the other one is the better pick.",
  },
} as const;
export type SectionKey = keyof typeof sections;

// Every page of a section, in reading order.
export async function pagesOf(key: SectionKey) {
  const all = await getCollection(key);
  return all.sort((a, b) => a.data.order - b.data.order);
}
