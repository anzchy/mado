# #507: folders reached through symlinks

## Historical RED

Phase 1 (`7a21930a`, rebased first to `ede4b792`, then to `528600fa`) reproduced an admission failure, not an enumeration deadlock. `SystemSecurityScope.start` succeeded for the raw symlink URL, but bookmark creation threw Cocoa error 256 before a scanner existed. Direct paths and chooser-resolved Finder aliases completed. `red-output.txt` preserves that original evidence.

The native input route had two additional problems: classification relied on `hasDirectoryPath`, and a classified folder always requested another panel. A raw dropped directory link could therefore produce the unsupported-image sheet; Open With could request access that its event had already delivered.

## Current behavior

A single native input checks actual directory metadata while holding the selected URL's authority. FileAccess bookmarks the canonical target under that authority. Delivered folder grants separately prove directory access, actual bookmark creation/resolution, target identity and a scoped read before persistence. They retain the exact verified bookmark URL, including its opaque capability. Strict panel admission and subsequent root containment checks remain intact.

The existing coordinator lease owns scan admission and failure handling. Real FolderBrowser resolves the enumeration directory within it; both supplementary one-batch fixtures now do the same. Canvas adds no separate pre-scan lease. That avoids changing recovery/Undo and sidebar watch sequencing merely to accommodate a fixture.

Amendment 1 approves canonical target names in recents. The added recent-name assertion, originally line 132 and now line 135, now expects `path.1.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent`. The initial title retains the selected name. Chooser-resolved input, return to grid and recent reopen can display the target name. No original phase-1 scan assertion or two-second bound changed.

## Tests

- `Issue507AliasFolderScanTests.swift`: direct, raw/hinted symlink, chooser-resolved alias and shared drop/Open With entry; real and legacy scanners; exact three-image sets, no sheet, title and canonical recent name. Every opening retains its independent two-second deadline. Real bookmark tests also cover both grant orders and missing targets.
- Package `Issue507DeliveredFolderGrantTests.swift`: delivered access without a startable selected scope, persisted reopen, explicit verification, sibling rejection, transactional failures and retention of the bookmark-resolved URL. Its synthetic capability marker models an opaque scope boundary; it is not an OS security token. Real bookmark operations, identities and file I/O remain in use.
- `Issue507FooterBookmarkRoundTripTests.swift`: directory URL hints survive both present and absent directories, and the original symlink-parent spelling passes real FileAccess verification and leased reads. The directory-only #506 double now reconstructs with `isDirectory: true`.

All seven original #507 and 27 original #506 expectation lines remain unchanged. The two new opaque-scope path comparisons were corrected to compare both sides' canonical full path components: `/var` and `/private/var` can name the same target. Their byte and reload assertions are unchanged.

## Run

```sh
scripts/heavy-lock.sh xcodegen generate
scripts/heavy-lock.sh xcodebuild build-for-testing -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci -only-testing:PicseeAppTests
node AppTests/Fixtures/Issue507/target-lane.mjs
node scripts/tdd/app-lane.mjs
```

The targeted runner selects five #507 functions, takes heavy-lock only for xctest, validates the exact completed execution set with the repository parser, and writes `.build/i507/target-result.json`.

Raw historical receipt verdicts remain unchanged. The handoff documents accepted source/specification corrections rather than replacing RED evidence. The temporary two-second recovery/sidebar diagnostic wrappers were moved to `.build`; the permanent original tests remain in the full App lane.

Final gates and commit SHAs: `~/.picsee/herdr/gpt-imple-1/i507-fix-handoff.md` (`Report-Task: i507-fix-b`). These unsigned tests do not prove genuine Finder/Open With sandbox-extension delivery. No entitlement change, ancestor grant, path-only bookmark fallback or signed-device acceptance is claimed.
