# Reproducible image fixtures

`TextRecognition/mixed.png` and `TextRecognition/blank.png` are small PNG fixtures for #687's real Vision tests. The mixed image has `中文测试` and `SIDE` on the first row and `Hello Mado` on the second, drawn in a macOS system font on white; the blank image is white at the same 1000×340 size. `mixed-orientation-6.jpg` stores the mixed image sideways with EXIF orientation 6; `mixed-oversize.jpg` places it on a 5000 px canvas; `dense-40.png` has 40 numbered rows with row 19 indented; `mixed-tall-narrow.jpg` is 1170×12000 for the thumbnail width check. Regenerate these derived fixtures with `scripts/heavy-lock.sh swift scripts/testassets/generate-text-recognition.swift` on macOS. They contain no personal images and are separate from the P0 tier-① manifest.

These are test data, not App resources. P0-07 has no user-visible ledger row. Nothing here is wired into a
Swift/App target. For the P0-07 manifest corpus, Python ≥3.9 and its standard library generate all synthetic files; no Pillow, host fonts,
platform image encoder, network or clock is involved. PNG compression uses the host zlib; its runtime
version and the Python version are recorded in the manifest. The fixed 5×7 glyphs are authored in the generator.
Generated fixtures are dedicated to CC0-1.0. No Git LFS is used in this repository.

## Three tiers

| Tier | Location | Content |
|---|---|---|
| ① | committed `TestAssets/synthetic/` | 20 small self-verifying files; byte sizes and SHA-256 in manifest |
| ② | `~/.picsee/testassets/generated/` | S2: 5,000 mixed PNG/TIFF files, 50 groups, nested directories and repeated basenames; S3: valid 8,000×6,000 (48MP) and 10,000×10,000 (100MP) noise PNGs |
| ③ | `~/.picsee/testassets/photos/` | CC0 real-scene Nikon Z8 SDR JPEG and HEIC, both with EXIF; immutable source URLs, bytes, SHA-256 and licence evidence in manifest |

The checkerboard path and bytes, and the coordinate-grid path and bytes, were landed first for #7. They are
1024×768 and 1280×960 respectively. Each grid cell is labelled by its top-left **image-pixel** coordinates,
with major lines/labels every 128 pixels and minor lines every 32 pixels. Labels remain readable at 1:1.
Do not rescale these images before an actual-pixels check.

P1 adds labelled 3:2 landscape and 2:3 portrait frames with centre marks for VIEW-01, plus a labelled
4096×3072 coordinate grid for VIEW-04. The pan grid is 117,185 bytes; every other new fixture is below
3 KiB. `not-an-image.jpg` is plain text behind a misleading image extension. `unsupported-container.zip`
is a valid ZIP archive with one stored text member: ZIP was chosen because it is a genuine, deterministic
non-image container and ImageIO has no image representation to decode from it. Both are expected to be
rejected without replacing the current image. `gradient-16bit.png` is 16-bit-per-channel grayscale for
bit-depth-aware decode-cost checks. These are correctness fixtures, not performance inputs.

The eight orientation files are TIFF with the EXIF/TIFF Orientation tag (0x0112), ExifVersion and an Exif
IFD. The stored pixel data is inversely rotated/mirrored for each tag so a reader honoring orientation
shows the same upright arrow, `TOP`, left `L` and right `R`. Stored sizes are 128×96 for 1–4, 96×128 for
5–8; displayed size is always 128×96. This explicitly covers mirrored cases too. These are not JPEG files.
The PNG alpha ramp has x=0 transparent and x=255 opaque; RGB stays constant. Bad fixtures are intentionally
invalid: one truncated PNG, one non-image payload and a header claiming 2147483647² pixels with no image
payload. The header fixture must never be allocated at its declared size. Corrupt dimensions are unknown
(`null`), not invented; truncated/oversize dimensions describe header claims, not decoded buffers.
The 48-byte truncation may yield a partial image in ImageIO: the native check accepts partial or failed
bounded decode, never a crash or timeout. This is not an unconditional decode-failure fixture.

**Flat synthetic images must never be used for performance numbers.** All generated assets here (including
white-noise S3 and tiny S2 files) are correctness, sorting/cancellation or allocation stress data, **not** a
representative photo performance baseline. Use tier-③ real photographs, or a separately justified
photo-noise corpus, for measurements; label the content and cache state. There are no performance results
in P0-07. In particular, the tiny S2 corpus proves enumeration topology, not real-photo decode throughput.

## Commands

```sh
python3 scripts/testassets/generate.py --output TestAssets
python3 scripts/testassets/check.py
scripts/heavy-lock.sh python3 scripts/testassets/determinism.py --tier all
scripts/heavy-lock.sh python3 scripts/testassets/generate.py --tier bulk --output ~/.picsee/testassets/generated
scripts/heavy-lock.sh python3 scripts/testassets/generate.py --tier large --output ~/.picsee/testassets/generated
python3 scripts/testassets/download.py
python3 scripts/testassets/check.py --external --native
python3 scripts/testassets/check_lock.py
```

`determinism.py` defaults to the small tier for a cheap CI-ready check; `--tier all` independently creates
all 5,022 synthetic fixtures twice under the external root (`--output <dir>` overrides it). It uses system `shasum -a 256`, compares sorted
inventories, verifies regenerated tier ① against the committed manifest, prints the 20 committed hashes plus an inventory digest, and retains both inventories and
outputs outside the repo. Bulk/large generation refuses any output inside the repository.

`check.py` validates the individual records and S2 recipe/count/inventory SHA-256. S2 uses the digest of
the sorted `shasum -a 256` list, with paths relative to the generated root, rather than 5,000 records. By default it hashes
the 20 committed files. `--external` also requires/hashes all external files. `--native` independently
checks small valid assets and, with `--external`, real-photo metadata with macOS ImageIO (JXA), including identical upright
rendered pixels for all eight EXIF orientations; all platforms can run the
stdlib header/hash check. Only the known tiny truncated fixture receives a bounded negative decode; the corrupt/oversize files
are never decoded by this check. Without `--external`, photo EXIF is explicitly reported as skipped.
`--small-root`, `--generated-root` and `--external-root` allow scratch copies for checks. Unexpected tier-①
files (except Finder `.DS_Store`, which is ignored), missing entries, recipe drift, wrong dimensions, wrong sizes and wrong hashes fail closed.

`download.py` uses pinned HTTPS media URLs and checks size/SHA-256 **before** atomic publication. Non-HTTPS redirects are refused before a follow-up request. It never
accepts a Git LFS pointer as the photo. Its sources happen to be stored with LFS upstream; downloading
verified raw media bytes requires no LFS tooling or LFS tracking here. Existing correct files are cached;
a mismatched existing file causes refusal. `--output` must be outside the repo. No personal photos are used.

`catalog.py` is an explicit maintenance tool, not a verification step: after reviewing a generator/source
change, generate the external assets and download the approved source bytes, then rebuild the manifest.
It records each synthetic recipe and the generator source hash; do not run it merely to bless a failed
check. Byte identity is proven by the independent regeneration check, not by the catalog authoring pass.

## Provenance and remaining coverage

Both real-photo files come from aaron-rust's hdr-sample-images at commit
`df0d5df406ad0dbe2124d6f2a3700fe73dd3ead7`, with per-file pinned URLs in `manifest.json`.
The author's [README](https://github.com/aaron-rust/hdr-sample-images/blob/df0d5df406ad0dbe2124d6f2a3700fe73dd3ead7/README.md)
identifies Nikon Z8 capture and states: “All image files in this repository are licensed under the Creative Commons Zero (CC0) license”. No photographer identity is inferred; the repository's
[licence](https://github.com/aaron-rust/hdr-sample-images/blob/df0d5df406ad0dbe2124d6f2a3700fe73dd3ead7/LICENSE)
contains CC0-1.0. They are 8256×5504 (45.4MP), not part of a completed 50-photo, 1–12MP S1 baseline.

The plan's S1–S6 table is a coverage roadmap, not a claim that this asset pack completes every scenario.
Manifest `gaps` records the incomplete S1 corpus and deferred S4 RAW/GIF/PDF sources. S5 filesystem
replacement/symlink/permissions/unmount and S6 multiwindow/pin topology must be constructed by future
runtime recipes. P0-07 does not measure performance, implement those behaviors or create XCUITest targets.

## Verification environments and reports

Byte identity is checked against the manifest, not promised across arbitrary zlib releases. A Python or
zlib version mismatch prints both manifest and runtime versions; hashes remain decisive. Fix round 1
was verified on the local MacBook Pro (Apple M4, macOS 27.0.1): Python 3.14.3 for the full corpus,
and system Python 3.9.6 for the small tier and regression suite; both use zlib 1.2.12. The Python 3.9.6
run prints the manifest=3.14.3 / runtime=3.9.6 warning and still matches all small hashes.
The prior blind audit also reported identical small fixtures with CPython 3.9.6/3.13/3.14.3 on zlib 1.2.12;
that is auditor evidence, not a second host run by this implementer. Mac mini remains unverified.

`check.py --output <dir>` optionally saves `check.txt`; the default check writes nothing.
`check_lock.py --output <dir>` selects its disposable probe parent. Run committed fail-closed regressions
with `python3 -m unittest discover -s scripts/testassets -p 'test_*.py'`. No added runtime dependency is required.
