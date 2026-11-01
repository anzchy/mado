# I344-WI-1 — DONE

Scope: default-off `DisplayPreferences.loopThroughImages`, additive Codable persistence under existing supported schema1. False is omitted, preserving old exact encodings. No store adapter change needed: its existing serialization persists the added model field.

Tests: `Packages/PicseeKit/Tests/PicseeInfrastructureTests/Issue344LoopPreferencesTests.swift`, four test functions: supported legacy payload preservation; exhaustive Bool Codable and prefilled session restoration; true-to-false real defaults relaunch; unsupported schema versions 0/99 byte preservation. Existing assertions unchanged.

## RED

Tests were written first, then only the default-false stored property was added to compile the new API. No persistence implementation existed at recording. Receipt `I344-WI-1`, lane `swift-red`, filter `issue344LoopPreference` recorded a genuine assertion failure: 2 of 3 selected tests failed. Legacy test name is outside that filter and ran in the full package green lane. Receipt fingerprint includes the entire new test file. The expected `implementation-already-present` note refers solely to this compiling property stub.

Command: `PICSEE_SWIFT_FILTER=issue344LoopPreference /Users/jack/.picsee/device/ram/with-ram.sh i344-wi1-red scripts/heavy-lock.sh node /Users/jack/.codex/plugins/cache/xiaolai/tdd-guardian/0.10.2/scripts/tdd-guardian/receipt.js record --id I344-WI-1 --lane swift-red --files Packages/PicseeKit/Tests/PicseeInfrastructureTests/Issue344LoopPreferencesTests.swift`

Log: `.build/i344/wi1-red.log`.

## GREEN

Added coding key, encode true, decode absent/invalid as false. No test file edits since RED.

Full configured `unit` lane via plugin `runLane` under outer with-ram/heavy-lock: PASS. 1439 tests in 36 suites; Swift test run 48.616s; lane including LCOV 96.960s. `testCounts` in runLane JSON is null because its generic parser does not recognize the raw Swift aggregate, so counts above are quoted directly from output.

Logs: `.build/i344/wi1-unit.log`, `.build/i344/wi1-unit-result.json`. LCOV: `coverage/lcov.info`, lines14911/14911, functions2892/2892, statements14911/14911, branches unmeasured. Coverage threshold audit is a later root workflow stage.

Configured `integration` lane via plugin `runLane` under outer with-ram/heavy-lock: PASS, 4 tests, 0 failures, runLane53.501s. This job was already admitted when the user requested the heavy pause; it completed without restarting. Logs: `.build/i344/wi1-integration.log`, `.build/i344/wi1-integration-result.json`.

## Receipt verification and resolved pause

A user-requested heavy-job pause initially deferred receipt verification. After explicit resumption, the identical-filter command below completed; that pause is resolved and no gate remains pending for WI-1:

`PICSEE_SWIFT_FILTER=issue344LoopPreference /Users/jack/.picsee/device/ram/with-ram.sh i344-wi1-verify scripts/heavy-lock.sh node /Users/jack/.codex/plugins/cache/xiaolai/tdd-guardian/0.10.2/scripts/tdd-guardian/receipt.js verify --id I344-WI-1`

After explicit user resumption, the command above completed with the lane green and SEPARATION-HELD; log `.build/i344/wi1-verify.log`. Expected MEDIUM note covers only the documented compiling property stub. WI-1 is DONE; no recorded test line changed. No commit or push performed.
