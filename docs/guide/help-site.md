# Mado help site

Static pages published to GitHub Pages (https://anzchy.github.io/mado/). Source of truth for the long how-to and privacy text that Settings links to with 「了解更多 ↗」 (Settings keeps one short line per row).

- Only `site/` is published (workflow `.github/workflows/pages.yml`); nothing under `docs/` is.
- GitHub Pages is enabled at https://anzchy.github.io/mado/. The owner publishes manually with the `workflow_dispatch` action in `.github/workflows/pages.yml`; search indexing is allowed from 2026-11-27.
- Plain HTML, no scripts, no remote fonts or images.
- The articles are in Chinese; product names and the macOS permission name follow the shipped Settings copy.
