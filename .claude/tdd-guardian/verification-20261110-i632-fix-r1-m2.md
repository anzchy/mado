# #632 audit fix round 1 — WI-2 verification

Scope: normal fixture startup slack and L1 ignored-input cleanup. Production behavior is unchanged. Normal unit/owner fixtures now use30 seconds, intentional hangs keep2 seconds, and parent runners allow90 seconds. Queue proof observes the real waiting marker and holds32 seconds before release; monotonic evidence proves blocking exceeds the actual30-second execution budget. Original output/status, no-retry, cleanup and retained-evidence assertions remain. The M1 footer remains byte-identical (SHA256 `7ff7dc0d05e42db4e985748f572967a0ed226ffc3c882ebd52a7a8cd95ea42ac`).

## TDD

Receipt `I632-FIX-R1-WI-2` was recorded at parent `215772e5f720e8884622c5efe6e194e8a8d4a90f`, before fixture-budget repair: assertion-failure, one of14 tests failed; dirty_source was empty. Only the new external startup oracle was fingerprinted. The prior raw run confirmed the three-second delay event and inner124 from the old two-second budget. Pre-receipt scaffold failures were rejected, as explained in the plan clarification.

Official verification completed GREEN with `SEPARATION-HELD`, no findings, at2026-11-10T19:39:27.132Z. Oracle SHA256 remained `7bdcf04aa7f0a14cca17c038da36e54f38a838231d26dacf8a6aef56f4e55413`. The M1 fixture-I/O correction remains separately disclosed with its actual HIGH separation findings; WI-2 does not change or replace those receipts.

## Default-concurrency gate

Command (no concurrency override):

```sh
PICSEE_HEAVY_LOCK_WAIT_SECS=7200 scripts/heavy-lock.sh node scripts/tdd/node-lane.mjs scripts/tdd/unit-lane.test.mjs .agents/skills/picsee-delegator/scripts/owner-gates.test.mjs scripts/ci/test-watchdog.test.mjs scripts/tdd/swift-lane.test.mjs scripts/tdd/unit-startup.test.mjs
```

PASS53/53, failures0, errors0, skips0;82.815 seconds. Then the official receipt verifier reran the configured manual lane and judged its specification held. Each job had its own heavy-lock call; no concurrent heavy jobs were launched by this task.

Independent review: APPROVED WITH NOTES, no remaining M2 findings. Coverage applicability audit: PASS; unchanged Swift/watchdog/exporter/thresholds permit reuse of the fresh M1 split-lane coverage. See the M2 review and coverage artifacts. No full-parallel package pass or JavaScript coverage percentage is claimed.

Private evidence references, gpt-imple-1 evidence dir: i632-fix-r1-m2-raw-red.log, i632-fix-r1-m2-red.log, i632-fix-r1-m2-default-node.log, i632-fix-r1-m2-verify.log, i632-fix-r1-m2-verified-receipt.json, i632-fix-r1-m2-gates-batch.log.

Still open: L2 older-worktree launcher compatibility fails closed; L3 retained logs have no pruning; L4 owner-gates tests remain in the manual lane. No App, package, exporter, threshold, retry, quarantine or production deadline changes.
