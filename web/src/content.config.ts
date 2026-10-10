import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

// One Markdown file per page: src/content/<section>/<slug>.md.
const page = z.object({
    // The page's h1.
    title: z.string(),
    // <title>, under 60 characters with the " · DubStemMix" suffix.
    seoTitle: z.string(),
    // Meta description, under 160 characters.
    description: z.string(),
    // Short label in the sidebar.
    nav: z.string(),
    // Position in the reading order (sidebar, previous / next).
    order: z.number(),
});

const docs = defineCollection({ loader: glob({ pattern: "*.md", base: "./src/content/docs" }), schema: page });
const compare = defineCollection({ loader: glob({ pattern: "*.md", base: "./src/content/compare" }), schema: page });

export const collections = { docs, compare };
