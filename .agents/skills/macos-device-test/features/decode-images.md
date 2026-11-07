# Decode real images

Mado shows ordinary formats with correct colour, orientation and transparency, keeps the window responsive
while a large image decodes, and shows a recoverable error for a broken file instead of the previous image.

## Sub-features

- `FMT-01` JPEG, PNG, HEIC and TIFF from S1 show correct colour, orientation and transparency.
- `VIEW-06` all eight EXIF orientations show upright.
- `VIEW-07` transparent areas follow the background setting and are never black.
- `VIEW-08` a 48MP image loads without freezing the window; a preview appears, then sharpens.

## How to get to it (user POV)

- Open each fixture from Finder (or by `open -a` with the file).
- While the 48MP image loads, drag the window and open a menu.

## Driving it with computer use

Preconditions:

- Fixtures: S1's four-format set, the eight orientation images, the alpha-gradient PNG, and S3's 48MP image
  (real photo content, not a flat synthetic image).
- For VIEW-08 timing on the baseline, the Mac mini.

- **Formats.** Open the JPEG, PNG, HEIC and TIFF fixtures in turn. Each shows its known colours and upright
  orientation; the PNG's transparent area isn't black.
- **Orientation.** Open orientation images 1 to 8. Every one shows its arrow pointing up and `TOP` readable.
- **Transparency.** Open the alpha-gradient PNG. The gradient blends into the background setting, with no black
  band.
- **Large image.** Open the 48MP image and, at once, drag the window and open a menu. Both respond while the
  image is loading. A lower-resolution preview appears first, then the image sharpens.
- **Proof.** `FMT-01-<format>.png`, `VIEW-06-orientation-<n>.png`, `VIEW-07-alpha.png`,
  `VIEW-08-during-load.png`, plus the decode timing lines from `app.log`.

## Gotchas

- Flat synthetic images decode far faster than photos; never use them for VIEW-08 or timing numbers.
- "Responsive" here is observed behaviour, not a measurement. Plan §10 timings come from signposts with ≥30
  samples, recorded separately.
- A broken file is covered by `OPEN-05`, which is P1; P0 only checks that it fails cleanly in the unit seam.

## Native P0 handles and fixtures (P0-05/06)

- Window: title `Mado`; use the PID/birth/window handle recorded by `scripts/device/launch.sh` in
  `RUN_DIR/process.json`, never another running Mado. The canvas accessibility role is `AXImage`
  with localized label `Image` / `图片`; loading/failure text is localized.
- Tier ① paths: `TestAssets/synthetic/orientation-1.tiff` through `orientation-8.tiff`,
  `alpha-gradient.png`, `corrupt.png`, `truncated.png`, `oversize-header.png` in the same directory.
- Real photo paths: `~/.picsee/testassets/photos/5B_JPEG_SDR.jpg` and `3B_HEIC_SDR.heic`.
  Both are 8256×5504 (45.4MP), substituting for 48MP; provenance/hashes are in `TestAssets/manifest.json`.
  The 50-photo S1 corpus is incomplete. The noise PNG is allocation stress, never a timing source.
- P0-05 pipeline default: N=3 including the reserved current opportunity, visible≤2, heavy≤1 (>12MP),
  source RGBA8 reservation ≤min(512MiB, 8% RAM). Initial preview≤512px, then viewport detail.
  Logs use subsystem `io.github.anzchy.mado`, category `decode`, private filenames and actual pixel bytes.

For implementor smoke, set the brief's Xcode environment and use a new absolute run directory under
`~/.picsee/device-runs/`. Build with `scripts/heavy-lock.sh scripts/device/build.sh "$RUN_DIR"`;
if codesigning fails, retain `build.log` and skip launch. If another Mado is running, its owner must exit it.
Then run `scripts/device/launch.sh "$RUN_DIR"` and `scripts/device/doctor.sh "$RUN_DIR" --expected-sha <SHA>`.
Open fixtures with `open -a "$(cat "$RUN_DIR/bundle.path")" <absolute-fixture-path>`.
Immediately capture `scripts/device/shot.sh "$RUN_DIR" VIEW-08-during-load`, resize with
`scripts/device/size.sh "$RUN_DIR" 1100 740`, and capture a separate ready image.
Capture orientation-6 and alpha with the same shot helper. Finish with doctor and
`scripts/device/cleanup.sh "$RUN_DIR"`. These helpers only address the owned run.

The implementor smoke is not independent feature validation. Record whether a screenshot actually caught
loading or preview; do not infer it from its filename. This branch has no main menu, so menu responsiveness
must be checked after #10 lands. Background settings, physical drag, @2x and the remaining S1 corpus still
need their full acceptance runs. Do not upgrade the ledger from this smoke alone.
