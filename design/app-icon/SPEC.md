# Mado app icon — shared brief for the three option designers

Historical design brief: option 2 “Lens” was chosen on 2026-10-23.

Review artefacts only: nothing here goes into the App bundle or a commit until the user picks an option.

## The product
Mado is a native macOS image viewer (Swift + SwiftUI + AppKit, macOS 14+, sandboxed). Design direction
"C · Quiet Image Canvas": the photo is the content; the app is calm, neutral, with one blue accent, thin dividers,
flat rows, restrained shadows. No marketing gloss, no decorative gradients for their own sake, no glass side bars.
Name is always **Mado**, with this capitalization in English and Chinese (#547, ADR-0017). Read `design/DESIGN.md` §2–4 for tone; do not read other repo files.

## Palette (use these; derive tints with oklch from them, don't invent new hues)
| role | light | dark |
|---|---|---|
| canvas | #ffffff | #0f1115 |
| quiet surface | #f6f7fb | #161a22 |
| panel | #ffffff | #141821 |
| text | #1a1a1a | #e5e7eb |
| muted | #6b7280 | #9aa4b2 |
| accent | #2563eb | #60a5fa |
| accent fill | #2563eb | #1d4ed8 |
Blue is an accent, not a flood: neutrals dominate; at most one blue element/region in the icon.

## macOS icon best practices to honour (state in your notes which you applied)
- **Canvas 1024×1024.** Draw the classic macOS rounded-square body: 824×824 centred (100 px margin), continuous
  ("squircle") corners ≈ 185 px radius — approximate the superellipse with a smooth path, not a plain `rx`. Keep the
  drop shadow subtle (the classic macOS icon shadow: soft, offset ~ y+12, ~ 28 px blur, ~ 30% black) and separable.
- **macOS 26 (Tahoe) / Icon Composer readiness:** design in **layers** — one background layer plus 1–3 foreground
  layers, flat fills, no baked-in lighting/glare (the system adds Liquid Glass specular and shadow). Mark each layer in
  the SVG as `<g id="layer-background">`, `<g id="layer-fg-1">`, ... so they can be exported separately.
- **Appearances:** provide **Default (light)**, **Dark**, **Tinted** (monochrome: the system tints a greyscale icon —
  supply a luminance-only version on a dark background) and **Clear** (translucent: foreground as white/semi-opaque
  shapes over a frosted-looking background). Same geometry in all four.
- **One idea, recognisable at 16 px.** A single bold silhouette; no text, no letters, no tiny detail; check it at
  1024 / 512 / 256 / 128 / 64 / 32 / 16 px. Thin strokes vanish below 32 px — use fills or ≥ 48 px strokes at 1024.
- **Front-facing, centred optical weight**, consistent with the system icon family (Preview, Photos, Image Capture are
  the neighbours it will sit next to in the Dock — be distinct from Preview's photo-and-loupe and Photos' pinwheel).
- **No photos of people, no stock imagery, no screenshots** inside the icon.

## Deliverables (write only inside your folder `design/app-icon/option-<N>-<slug>/`)
1. `icon-default.svg`, `icon-dark.svg`, `icon-tinted.svg`, `icon-clear.svg` — each a standalone 1024×1024 SVG,
   layered as above, no external refs, no fonts.
2. `index.html` — one self-contained page (inline CSS, the SVGs inlined or referenced relatively) showing:
   - hero: the default icon large, the option name and a one-line idea;
   - the four appearances side by side, each on a fitting backdrop (light desktop, dark desktop, tinted on dark, clear
     over a colourful blurred wallpaper made with CSS gradients);
   - the size ladder 1024 → 16 px rendered at true pixel size (use `<img width>` of the SVG), on light and dark;
   - a Dock mock (rounded translucent bar, ~6 neighbour icons drawn as simple neutral rounded squares labelled by a
     tooltip-like caption — do NOT reproduce Apple's real icons) and a Finder-list row mock at 16/32 px;
   - design notes (≤ 150 words): metaphor, grid/keylines, layers, which best practices you applied, risks.
   Respect light/dark: the page itself uses `prefers-color-scheme`. Use "Mado" everywhere.
3. Verify before you finish: render screenshots with headless Chrome
   (`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1400,2400 --screenshot=<your folder>/preview.png "file://<abs path>/index.html"`)
   and also rasterise the default SVG at 32 and 16 px the same way (a tiny HTML wrapper is fine). Look at the PNGs
   (Read them) and fix anything muddy at small sizes, misaligned, or off-palette. Keep the PNGs in your folder.

Return: the folder path, the option name, a 2-sentence pitch, and any caveat. Do not touch any file outside your folder.
