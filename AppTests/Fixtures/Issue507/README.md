# #507: folders reached through symlinks

## Historical RED

Phase 1 (`7a21930a`, rebased first to `ede4b792`, then to `528600fa`) reproduced an admission failure, not an enumeration deadlock. `SystemSecurityScope.start` succeeded for the raw symlink URL, but bookmark creation threw Cocoa error 256 before a scanner existed. Direct paths and chooser-resolved Finder aliases completed. `red-output.txt` preserves that original evidence.

The native input route had two additional problems: classification relied on `hasDirectoryPath`, and a classified folder always requested another panel. A raw dropped directory link could therefore produce the unsupported-image sheet; Open With could request access that its event had already delivered.

## Current behavior

Owner decision, 2026-11-07, verbatim choice 「Same as a plain folder (Recommended)」: a folder reached through a symlink is handled exactly like a plain folder. Only the system open panel creates an Access Root (ADR-006, ADR-008, GLOSSARY).

- **Drop / Open With / `open -a`:** a single input is classified on `FileAccess` (off the MainActor) by its real directory metadata, not by `hasDirectoryPath`. A directory, plain or linked, becomes its canonical target and goes through `ViewerSession.openInput` to the existing folder prompt: "Browsing Needs Folder Access", then NSOpenPanel opened on that target. Nothing is granted, bookmarked or remembered before the panel answers; cancelling leaves nothing. When the selection can't be read, the input keeps its original URL and classification.
- **Panel:** `FileAccess.grant` bookmarks the canonical target while the selection's scope is held, which fixes the Cocoa error 256 for a raw symlink URL. Recents record the canonical target name (amendment 1). The first window title is the name the panel returned.

Round 1's delivered-folder admission (a root saved straight from a drop or open event) was removed in round 2.

The existing coordinator lease owns scan admission and failure handling. Real FolderBrowser resolves the enumeration directory within it; both supplementary one-batch fixtures do the same.

## Tests

- `Issue507AliasFolderScanTests.swift`:
  - The panel entry (`openGrantedFolder`) with a direct path, a raw or hinted symlink, and a chooser-resolved alias, through real and legacy scanners: the exact three-image set, no sheet, the title and the canonical recent name, each within its own two-second deadline.
  - Drop and `open -a` of a link or a plain folder: one prompt with the canonical target, and nothing persisted before the answer. After the simulated grant, the grid completes within two seconds with no second sheet.
  - Also covered: cancel, an unreadable hinted folder, a lone image, a link plus an image, and a stale link drop replaced by an image.
  - Real bookmark tests cover both grant orders and missing targets.
- Package `Issue507DeliveredFolderClassificationTests.swift`: `FileAccess.deliveredFolder` for a raw link, an unhinted plain folder, files, file links, dangling links, non-file URLs, and unstartable selections (readable or not). Scope starts and stops balance, and no record is created.
- `Issue507FooterBookmarkRoundTripTests.swift`: directory URL hints survive whether the directory is present or absent, and the original symlink-parent spelling passes real FileAccess verification and leased reads. The directory-only #506 double now reconstructs with `isDirectory: true`.

The prompt seam `folderGrantPromptOverride` replaces only the alert and panel. The selection closure it receives is the production one.

## Run

```sh
scripts/heavy-lock.sh xcodegen generate
scripts/heavy-lock.sh xcodebuild build-for-testing -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci -only-testing:PicseeAppTests
node AppTests/Fixtures/Issue507/target-lane.mjs
node scripts/tdd/app-lane.mjs
```

The targeted runner selects the #507 functions, takes heavy-lock only for xctest, validates the exact completed execution set with the repository parser, and writes `.build/i507/target-result.json`.

Raw historical receipt verdicts remain unchanged. The handoff documents accepted source/specification corrections rather than replacing RED evidence. The temporary two-second recovery/sidebar diagnostic wrappers were moved to `.build`; the permanent original tests remain in the full App lane.

Final gates and commit SHAs: `~/.picsee/herdr/gpt-imple-1/i507-fix-handoff.md` (`Report-Task: i507-fix-b`). These unsigned tests do not prove genuine Finder/Open With sandbox delivery, nor the real NSOpenPanel's preselection. No entitlement change, ancestor grant, path-only bookmark fallback or signed-device acceptance is claimed. Round 2 handoff: `~/.picsee/herdr/opus-imple-1/i507-fix2-handoff.md`.
