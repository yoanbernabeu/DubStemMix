# DubStemMix landing page

One page, built with [Astro](https://astro.build) and Tailwind CSS, published on GitHub Pages at
https://yoanbernabeu.github.io/DubStemMix/ by `.github/workflows/pages.yml` on every push to `main` that touches `web/`.

```sh
cd web
npm install
npm run dev       # http://localhost:4321/DubStemMix/
npm run build     # static site in web/dist
```

- `src/site.ts` holds the facts the page repeats (version, install command, links): bump `version` with each release.
- `src/styles/global.css` carries the app's design tokens (same hex values as `Sources/DubStemMix/Theme.swift`) and the
  two typefaces, copied from `Sources/DubStemMix/Resources/Fonts` and self-hosted (OFL). No third-party request, no analytics.
- `src/assets/screenshots` are copies of `docs/screenshots`, optimised to WebP at build time. `public/og.png` is the
  MIX screenshot letterboxed to 1200×630 for link previews.
- `astro.config.mjs` sets `base: "/DubStemMix"` because it is a project site; `import.meta.env.BASE_URL` is used for
  anything under `public/`.

## SEO, link previews, LLMs

- `src/layouts/Base.astro` writes the whole head: title and description from `src/site.ts`, canonical, robots, Open Graph
  and Twitter cards, icons, and JSON-LD (`SoftwareApplication`, `Person`, `WebSite`). `src/components/Faq.astro` adds a
  `FAQPage` JSON-LD from the same list it renders.
- `public/og.png` is the 1200×630 link preview (WhatsApp, iMessage, Slack, LinkedIn, X…). Its source is `og-card.html`;
  re-render it with `tools/og.sh` after changing the headline.
- `public/robots.txt` allows everything and points to the sitemap; `@astrojs/sitemap` generates `sitemap-index.xml`.
- `public/llms.txt` is a plain-text summary of the product for language models and answer engines. Keep it in sync with
  the README when a feature changes.
