# #507 phase 1 — admission failure, not a running scan

Base: `900b23f5993f3b01461eff89e46cbcdab6a6d7c4`. Ledger FOLDER-01; P2-02 / P3-17b. No production change.

The committed test uses the real `SystemSecurityScope` for scope and bookmark operations. Its wrapper only records calls/results. It opens three-image folders directly, through a raw symlink (with and without a directory URL hint), and through a real Finder alias resolved as the native chooser does. Both the real FolderBrowser and #506's simple one-batch scanner are exercised. Each path has its own two-second deadline; no ConditionWait helper or 180-second test limit is involved. Finder alias creation succeeded in this run.

Result: **App admission failure for raw symlink URLs**. Direct and chooser-resolved Finder alias paths complete with three items in both scanner modes. Both raw symlink spellings fail before a scan coordinator exists. System scope starts successfully, but bookmark creation throws `NSCocoaErrorDomain 256: Could not open() the item`; the App shows its access-error sheet. Neither scanner is entered. The selected test completes in 10.008 seconds with assertion failures, not an environment timeout. See `red-output.txt`.

Exact boundary:

- `App/CanvasWindowController.swift:1445` awaits `services.grant(folder)`; its catch at line 1449 shows the error, so `openFolder` is never called.
- `App/Access/AccessServices.swift:51` calls FileAccess.grant.
- `Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/FileAccess.swift:827` passes the uncanonicalized selected URL to `bookmarks.create(for:)`.
- `Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/SystemSecurityScope.swift:11` calls `URL.bookmarkData(options: [.withSecurityScope], ...)`, which throws for the symlink here.

The original #506 harness has an additional, distinct failure. Its bookmark double saves `url.path` and reconstructs `URL(fileURLWithPath:)`. On this fixture, a symlink's canonical original URL ends in `actual/`, while its reconstructed URL ends in `actual`; URL equality is false. `FileAccess.swift:422` rejects this in verifyExplicitSelection, and `App/Access/AccessMonitor.swift:204–205` records unknown loss. No scan starts. `AppTests/ConditionWait.swift:23` disables its helper deadline for a test with a time-limit trait, so the original waits for completion that cannot happen until its owning test is cancelled. Instrumented direct/symlink/Finder-alias runs reproduced this with both real and legacy scanners. This explains the old 180-second symptom; it is not evidence of an enumeration deadlock.

Proposed next-phase fix: establish the granted directory's canonical target under the selected URL's security scope before creating its persistent bookmark, and consistently use that target for grant identity and subsequent admission. Keep sandbox and root-boundary checks. Separately, folder-only test bookmark doubles must preserve directory URL semantics, and completion waits must also terminate on admission failure. **No fix was implemented.** The exact native chooser delivery of symlinks and signed sandbox access are not established by this unsigned App test; chooser-resolved Finder aliases are covered, raw Finder alias injection is not.

Run from the repository root:

```sh
xcodegen generate
scripts/heavy-lock.sh xcodebuild build-for-testing -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci -only-testing:PicseeAppTests
node AppTests/Fixtures/Issue507/target-lane.mjs
```

The runner selects only `PicseeAppTests.issue507FolderPathsComplete(legacyScanner:)`, runs xctest under heavy-lock, and uses the repository App lane's complete-result parser, including exact selected-test execution verification. It exits 1 for this RED and writes `.build/i507/target-result.json`.

Receipt: tdd-guardian 0.10.2 `app-red`, ID `507-WI-1`, valid assertion-failure RED, base SHA above. A local isolated receipt workspace at `.build/i507/receipt-workspace` holds a byte-identical copy of the test and an app-red configuration pointing at this targeted runner; the tracked shared config is unchanged. The receipt fingerprint was checked against the committed test source. Its implementation-present note refers only to the new test runner `.mjs`, not production code. The test is intentionally RED pending the separately authorized fix phase.
