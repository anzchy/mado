# Gate — PASS (#553 amendment 1)

The fresh configured unit run is shared by taskCompleted, coverage audit and commit freshness: all select the same sole unit lane, and no native source changed after that run. Commands were wrapped individually in heavy-lock by the lane runner, with no threshold/config bypass. Mutation is disabled; no push-bound lanes configured.

- unit: PASS, actual Swift terminal summary 1,779 tests / 43 suites, 2 existing known issues. Plugin testCounts is null for Swift, so count is attributed to the actual terminal output, not invented by the parser. Fresh coverage produced and parsed successfully.
- docs-node: PASS, 10 tests. Receipts i553-WI-1/2/3: SEPARATION-HELD. Existing hash reproducer contamination documented in review.
- Combined name/ledger gate: PASS (106 tests), node-gates-final.log.
- npm ci --ignore-scripts: PASS, npm-ci.log.
- ledger:html-check: PASS, ledger-html-final.log.
- design:check: PASS, design-final.log (116 Node tests; 22 states, 22 hashes, 30 sub-cases, 20 branch plays).
- git diff --check: PASS.
- Exact AGENTS native commands, foreground and sequential through heavy-lock: xcodegen PASS (xcodegen.log), swift test PASS (swift-copy-retry.log), unsigned xcodebuild PASS (xcodebuild.log). No signed build or launch.

The first native Swift copy gate rejected changed DESIGN.md bytes against its pinned digest. Before correcting the digest, targeted existing designRegistryPinsSources RED was recorded. Only that documentation hash was refreshed in JSON and Swift; targeted verification and full retry passed. No existing assertion changed.

Evidence directory: ~/.picsee/herdr/gpt-imple-2/i553-logs/. Unit result: unit-result.json and unit-coverage-gate.log. Parsed coverage: coverage-parsed.json. Raw LCOV: coverage/lcov.info (local ignored output).
