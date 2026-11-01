# I344-WI-2 — DONE

## Behavior

ViewerSession reads the shared display preference for next/previous enabled state and execution. FolderScanCoordinator navigation accepts explicit `mayWrap` input (default false); neighbor wraps only for complete snapshots with at least two eligible entries. Removed per-window loop state from the coordinator, complete restore points, failed-read restore points and restore/cancel assignment. Pending scan navigation remains nonwrapping. Preview Set/Finder paging remains unchanged.

`setFolderLoopEnabled` now changes the shared preference even without a folder scan or while previews are active. `displayPreferences` is an observable session snapshot, initialized from the store and synchronously updated by its observer callback, so another window's endpoint controls invalidate when loop changes.

## Tests and specification migration

New `Issue344LoopSessionTests.swift`: eight functions, including parameterized boundaries/cycles and actual Observation callbacks. Public commands verify visible host URL outcomes; two sessions share one real in-memory store.

Existing tests in FolderViewCoordinatorTests, FolderScanReadingTests, FolderEntryRestoreTests and Issue124ConditionsScopeTests were migrated because #344 explicitly removes the scan-owned flag. Coordinator wrap tests now supply explicit mayWrap. Preference lifetime assertions inspect the session/global preference; frozen preview tests retain paging/conditions assertions but now expect the toggle to persist. Other lifecycle, source, filter, sort, presentation and lease assertions were retained. These changes implement the documented matrix specification migration, rather than relaxing recorded assertions.

## RED/GREEN

- `I344-WI-2`, lane swift-red, filter `issue344SessionLoop`: assertion-failure, 5 of 7 functions failed before WI2 implementation. `.build/i344/wi2-red.log`.
- First full configured package unit lane PASS, 1446 tests/36 suites; Swift48.679s, runLane103.847s. LCOV emitted. `.build/i344/wi2-unit.log`, `.build/i344/wi2-unit-result.json`.
- Original receipt verified SEPARATION-HELD, `.build/i344/wi2-verify.log`.
- Independent observation regression appended without editing original lines. `I344-WI-2-observation`, filter `issue344SessionLoopObservation`: assertion-failure, 1 of 1 parameterized function failed before observable snapshot implementation. `.build/i344/wi2-observation-red.log`.
- Final full configured package unit lane PASS, 1447 tests/36 suites; Swift50.654s, runLane104.245s. LCOV14911/14911 lines/statements;2888/2888 functions; branches unmeasured. `.build/i344/wi2-observation-unit.log`, `.build/i344/wi2-observation-unit-result.json`, `coverage/lcov.info`.
- Observation receipt verified SEPARATION-HELD, `.build/i344/wi2-observation-verify.log`. Original receipt final verify reported nothing new because already settled, `.build/i344/wi2-final-verify.log`.

All heavy commands ran sequentially foreground with `with-ram.sh i344-<tag> scripts/heavy-lock.sh <command>`. Record and verify used matching PICSEE_SWIFT_FILTER for each receipt. MEDIUM already-present notes are explicit: original WI2 RED saw WI1 model changes; observation RED saw existing WI1/WI2 navigation implementation, while the observation regression independently rejected missing invalidation. No recorded assertion line changed.

No extra integration lane for WI2: matrix cases are in-process session behavior and pair controlled scanner with existing real adapter tests already included in full package lane. Root runs final coverage threshold audit/review later. No commit/push/rebase.

## Resolved native recovery ownership

The owner explicitly authorized four removals in CanvasWindowController: WaitingAccessPosition.loop, two constructor arguments, and the recovered scan setter. Root applied exactly those removals, so recovery cannot restore an obsolete per-window loop value. No other Canvas change was made. Subsequent App builds and WI-3 compiled menu tests passed (see WI-3 artifact). Actual native access-recovery interaction remains device-unverified; no separate recovery UI test is claimed.
