# #507: folders reached through symlinks

## Historical RED

Phase 1 (`7a21930a`, rebased first to `ede4b792`, then to `528600fa`) reproduced an admission failure, not an enumeration deadlock. `SystemSecurityScope.start` succeeded for the raw symlink URL, but bookmark creation threw Cocoa error 256 before a scanner existed. Direct paths and chooser-resolved Finder aliases completed. `red-output.txt` preserves that original evidence.

The native input route had two additional problems: classification relied on `hasDirectoryPath`, and a classified folder always requested another panel. A raw dropped directory link could therefore produce the unsupported-image sheet; Open With could request access that its event had already delivered.

## Current behavior

A single native input checks actual directory metadata while holding the selected URL's authority. FileAccess bookmarks the canonical target under that authority. Delivered folder grants separately prove directory access, actual bookmark creation/resolution, target identity and a scoped read before persistence. They retain the exact verified bookmark URL, including its opaque capability. Strict panel admission and subsequent root containment checks remain intact.

The existing coordinator lease owns scan admission and failure handling. Real FolderBrowser resolves the enumeration directory within it; both supplementary one-batch fixtures now do the same. Canvas adds no separate pre-scan lease. That avoids changing recovery/Undo and sidebar watch sequencing merely to accommodate a fixture.

Amendment 1 approves canonical target names in recents. The added recent-name assertion, originally line 132 and now line 135, now expects `path.1.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent`. The initial title retains the selected name. Chooser-resolved input, return to grid and recent reopen can display the target name. No original phase-1 scan assertion or two-second bound changed.

## WI-1 tests

The App alias test covers direct, raw/hinted symlink, chooser-resolved alias and shared drop/Open With paths with real and supplementary scanners. Each opening has its own two-second bound. Package tests cover delivered admission, persistence, root containment, transaction preservation and retention of the bookmark-resolved URL object. The capability marker is a deterministic scope-boundary model, not a genuine OS token.

```sh
scripts/heavy-lock.sh xcodegen generate
scripts/heavy-lock.sh xcodebuild build-for-testing -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci -only-testing:PicseeAppTests
node AppTests/Fixtures/Issue507/target-lane.mjs
```

This commit's targeted runner selects three App functions. Historical receipt differences, final series gates and commit SHAs are recorded in ~/.picsee/herdr/gpt-imple-1/i507-fix-handoff.md. No signed-device acceptance or ledger status promotion is claimed.
