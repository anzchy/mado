# Real Swift output fixtures

Captured on 2026-10-22 with Swift 6.3.3 (Xcode 26.6, 17F113), using a scratch SwiftPM package. These are real merged stdout/stderr. The generator replaces only scratch/home filesystem prefixes with `/SCRATCH/LaneFixtures` and `/HOME`; result and diagnostic lines retain their captured content.

To reproduce, create a scratch directory outside the repo containing `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LaneFixtures", targets: [.testTarget(name: "LaneTests")])
```

Create `Tests/LaneTests/`, then run from the worktree root:

```sh
scripts/heavy-lock.sh python3 scripts/tdd/fixtures/capture.py /absolute/path/to/scratch
```

The generator writes each exact test source alongside scratch, runs `swift test --package-path <scratch>` for each source, and writes `fixture-capture.txt` with commands, exit codes and full output in scratch's parent. It refreshes the twelve tracked output fixtures here. Append fixture names after the scratch path to capture only those variants and keep earlier captures unchanged.

| Fixture | Exit | Expected completed results |
|---|---|---|
| swift-pass | 0 | 3 total, 2 passed, 0 failed, 1 disabled |
| swift-fail | 1 | 3 total, 1 passed, 1 failed with **two issues**, 1 disabled |
| compile-fail | 1 | undefined symbol, no completed run |
| xctest-pass | 0 | 12 total, 11 passed, 0 failed, 1 skipped |
| xctest-fail | 1 | 12 total, 10 passed, 1 failed, 1 skipped |
| swift-duplicate | 1 | 4 total, 2 failed and 2 skipped, all displayed as “same” |
| xctest-partial-crash | 1 | first class assertion fails, second class traps; no XCTest root completion |
| xctest-two-assertions | 1 | 1 executed case, 2 failure events, 1 failed case |
| swift-known-pass | 0 | 3 total, 3 passed, one of them with a known issue (`withKnownIssue`) |
| swift-known-fail | 1 | 3 total, 2 passed (one with a known issue), 1 failed; summary counts the known issue |
| swift-crash-name-pass | 0 | 1 passed test named “does not crash” |
| swift-crash-name-fail | 1 | 1 failed test named “does not crash”; crash-related assertion prose |

Swift Testing fixtures include XCTest's empty companion summary; XCTest fixtures include Swift Testing's empty companion summary and three repeated XCTest suite summaries. The adapter requires every started framework's root completion and cross-checks terminal results against the framework totals. A class subtotal cannot establish completion. XCTest root failure events must be at least the number of failed terminal case identities; they are not equal when one case has multiple failed assertions. Crash detection uses anchored diagnostic records, excluding words inside test names and assertion messages. XCTest failure output contains both the `error: -[... ] : XCTAssertEqual failed` diagnostic and the failed case result.

Run `node --test scripts/tdd/*.test.mjs`. Tests use tdd-guardian `0.10.2` under `~/.claude/plugins/cache/xiaolai/tdd-guardian/`, or `PICSEE_TDD_PLUGIN_ROOT`, to check actual plugin classification. They replace only the external `swift` executable with a fixture playback process; the real wrapper and lock still execute. Temporary test directories use `os.tmpdir()` and are removed in `after()`. Split-stream tests replay captured bytes on both streams, including a crash diagnostic on the other stream and a started-but-incomplete framework. Derived truncations remove captured lines to test completion checks; they do not fabricate fixture output.
