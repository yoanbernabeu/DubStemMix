// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";

// Published as a GitHub Pages project site: https://yoanbernabeu.github.io/DubStemMix/
export default defineConfig({
  site: "https://yoanbernabeu.github.io",
  base: "/DubStemMix",
  trailingSlash: "ignore",
  // One page, one canonical URL: keep only the trailing-slash form in the sitemap.
  integrations: [sitemap({ filter: (page) => page.endsWith("/") })],
  vite: {
    plugins: [tailwindcss()],
  },
});
