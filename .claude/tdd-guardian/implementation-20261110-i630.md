# WI-1: #630 issue520 App-test flake

Status: DONE — App/unit/integration/coverage GREEN; independent final review APPROVED WITH NOTES,0 actionable findings.

## Demonstrated causes
- Denied fixture: awaited read probe can be cancelled/replaced by a later callback. Controlled real chmod A/B/C sequence produced1 failed Swift test with39 failed expectations over20 iterations (retained URL/nil sheet/absent text; native/cancel setup passed). Post-assert drain reached real recovery for all iterations. Fix waits actual sheet readiness, retaining every original behavior assertion.
- Trash/reconciliation: a real native bookmark resolver failure NSCocoaErrorDomain:4 was held unchanged in the task that owns reconciliation. Filesystem then genuinely reached Trash/readable destination. Old typed FileAccessError bypassed existing missing-path current-bookmark classification, causing reconnect despite current Trash (exact no-sheet symptom) or readable move. Matched unlink already passed. Historical CI lacks native NSError provenance; this is a demonstrated reachable equivalence case, not a claim to have recovered its missing trace.

## RED before implementation
- i630-WI-1-denied / app-red: assertion-failure1/1, dirty_source=[]; raw1 test/39 issues14.579s. External i630-denied-red.log and i630-denied-recorded-raw.log.
- i630-WI-1-reconciliation / app-red: assertion-failure2/3; Trash no-sheet and readable-move presentation rejected, unlink control passed. Native setup/ownership passed. Source dirty note names App controller completion-only scaffolding; external i630-reconciliation-before-fix.patch proves original recovery exclusion remained during RED. Raw i630-reconciliation-red-output.log.
- Native false/error and TaskLocal provenance are real forwarding observations, no fabricated scope outcomes; test gate declines main-thread blocking. No manual UI clear, forced start result, timeout increase, retry loop or sleep fix.

## Minimal changes
- Existing missing-display-path classification now also handles an earlier typed FileAccessError; no new decoder retry, retry count or delay. Reuses existing current bookmark distinction among Trash, moved and missing.
- Test helper waits attached reconnect sheet after replaceable probe await. Recorded test lines preserved; only an added readiness wait.
- Internal reconciliation completion returns actual existing/created Task; observer drains watch installation and pending successors. This scaffolding preceded native RED and changes no recovery decision.
- ACCESS-03 limitation adds precise automated evidence; acceptance prefix/status unchanged. HTML regenerated and sync check passed. No signed/TCC claim.

## Actual App GREEN
- New native matched cases3/3 passed in1.339s.
- Associated filter issue520|issue630|issue140DisplayedFileGrantTrashClearsWithoutReconnectSheet|issue273|issue257|issue233:33 tests passed,0 fail,0 skip,39.755s, retry off.
- Denied controlled case1/1 (20 internal sequences) passed14.298s before product fix.
- Both official receipts verified SEPARATION-HELD with original matching filters and retry off after implementation.
- Current official unit + configured integration + coverage job records real results under external i630-green-job.log. Complete this report only after their actual outputs.


## Completed package/integration/coverage gates
- Official unit lane pass exit0,218545ms; full actual Swift root1787 tests/43 suites pass137.321s2known issues; XCTest root0 completed. Top-level framework serialized, no test omitted.
- Configured integration4/4 pass,0fail/skip,68494ms.
- Official coverage parser single LCOV147 files L16701/16701 F3212/3212 S16701/16701, branchesnull threshold0; configured gate PASS. App not instrumented;14 pre-existing zero generated-closure FNDA entries qualify summary100. See coverage-20261110-i630.md.
- All actual runner stdout/stderr preserved transparently under external i630-unit-1.log etc. Independent coverage audit PASS.
