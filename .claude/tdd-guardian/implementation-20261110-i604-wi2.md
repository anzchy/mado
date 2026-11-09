# WI-2: Retry, sibling navigation and late results — DONE

AppTests/Issue604SidebarFailureTests.swift received additive cases only; production files and package tests are unchanged from WI-1.

## Cases
- Scan-only failure, gated Retry failure, held successful Retry, real count 3 and baseline topology restoration.
- Actual readable sibling button navigation reaches its complete 2-image grid.
- Same-open late successful listing and late numeric count each preserve failure authority.
- Old recovery-parent listing success and failure each cannot replace the newer readable-folder tree.
- Boundary gates return captured real filesystem payloads despite cancellation; a forwarding lease observer delegates all acquire/release calls to real FileAccess. Tests await all observed leases released, then pump and assert stable tree/current count across 12 further actor/run-loop turns.
- Existing ABA stale-count, cancel Retry and removed-root guards rerun.

## Verification
Filtered App lane: 10 tests passed, 0 failed, 0 skipped, 3.080s. Log: /Users/jack/.picsee/herdr/gpt-imple-2/i604-logs/wi2-app.log.
Package source/tests unchanged: fresh WI-1 full unit and LCOV reused (1787 tests in43 suites,2 known issues).

## RED / separation
WI-2 NOT-RECORDED: these follow-on regression tests already pass the WI-1 fix, so no fake RED was manufactured. Original i604-WI-1 genuine collapse RED and SEPARATION-HELD evidence remain. All WI-1 recorded lines were retained; fixture capabilities and tests were added.

No commits, push or GUI runs.
