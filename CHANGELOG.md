# Changelog

## v0.0.1 (unreleased)

### Known issues

These are test-suite issues, not app behaviour. CI's "App tests" job can fail intermittently on them, independent of the PR under test; rerun the job once. Work on them is paused until after v0.0.1 (#379).

- `t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores()` (`AppTests/LostAccessRecoveryTests.swift`): the test waits for the scan snapshot to complete, then checks the grid. The grid applies that snapshot in a later MainActor job, so under load the check can run first. A fix that waits on the grid is committed on `test/379-app-flakes` but not landed.
- `issue281RetryAfterFailedReadShowsTheReadingFooter()` (`AppTests/Issue281FooterIntegrationTests.swift`): the sidebar counts the folder in its own task, so it shows `0` or `2` depending on timing. #377 accepts both. The test may still fail if a folder-watch event reloads the sidebar during the held retry (not reproduced).
- The same class of race (an assertion reads one layer before another async layer has settled) has recurred in the t231 tests (#333, #352). A shared wait helper and a forced-delay test seam are proposed as follow-up work.
