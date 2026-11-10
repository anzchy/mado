# Specification Attack — tests-20261110-i632-bound.md

## Verdict: SURVIVED

Reviewed the bound-only plan and matrix before implementation. Zero open gaps. This supersedes prior split-run specification attacks for the explicitly narrowed round-2 task. Coverage exporter redesign and its child-command bounds are expressly deferred, so the earlier exporter-discovery finding is outside this decision's scope.

## Attacks defeated by the existing matrix

| Attack | Killed by |
|--------|-----------|
| Hard-coded success | Normal success/nonzero result cases; owner failure and timeout |
| Lookup-table fixture behavior | Actual full parallel Swift and unchanged LLVM coverage acceptance |
| Half operation: launch watchdog without owning real Swift helper | Real hung-command detached-helper PID liveness and follower lock admission |
| No state transition: reuse previous evidence | Consecutive-run byte-preservation and distinct capture-directory case |
| Ignored full-suite command/arguments | Swift fixture rejects changed command; real full-suite acceptance |
| Wrong boundary: start600s before lock admission | Real queue delay exceeds shortened Swift budget but run passes after admission |
| Silent timeout or stale successful coverage | Exit124, explicit diagnostic, nonzero owner LCOV and no exporter launch after failed Swift |
| Retry instead of failure | Actual fixture launch count and timeout evidence |
| Order-dependent stale result | Seeded prior successful coverage followed by failed/timed-out current run |
| Unbounded Swift process | Actual timeout, bounded elapsed check, detached-helper death and follower lock acquisition |
| Outer guardian preempts normal queue/cleanup | Config9000000ms versus admission7200s and bounded execution/cleanup defaults |
| Weakened unchanged coverage | Owner success versus below-threshold failure and real configured coverage gate |

## Units with no law

- Guardian configuration is a static public command/default/coverage contract.
- Real Swift/LLVM acceptance checks external adapter compatibility; no new computation law is introduced.
