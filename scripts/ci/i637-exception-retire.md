# #637 ViewerChromeOverlay function exception retirement

## Delegated decision

> DECISION: A. Remove only the ViewerChromeOverlay manifest entry and evaluator pins (2 → 1); preserve InspectorPanel and all 17 file exceptions. Add scripts/ci/i637-exception-retire.md with source diff, artifact provenance, counts and decision; update current policy wording. Update and pass drift-rejection tests, including rejection of reintroducing the retired exception; verify local/CI parity. Require a fresh unit lane reporting Package coverage PASS at exactly 100% lines and eligible functions with one disclosed exception. Both auditors must review the resulting commit before my delegated sign-off is recorded.
>
> Measured at 2cc99ff9: 13,614/13,614 lines; 3,269/3,270 raw functions; InspectorPanel is the only zero-hit function.

This is the gpt-6-astra delegated decision, not owner approval. Both auditor reviews and delegated sign-off are pending after this implementation commit.

## Source change and artifact provenance

Commit `01b1e516` replaced `ScaleIndicator(..., action: activate).label` in `ChromeToolView.accessibilityValue()` with `ScaleIndicator.modeLabel(...)`. That removed the temporary button's uninstalled callback and its emitted zero-hit closure. The relevant source diff is:

```diff
- return ScaleIndicator(actualPixels: session.zoomMode == .actualPixels, customZoom: custom, action: activate).label
+ return ScaleIndicator.modeLabel(actualPixels: session.zoomMode == .actualPixels, customZoom: custom)
```

The source change is present at `2cc99ff9`. The earlier artifact was run `1794454813978` at `2cc99ff9`; it reported 13,614/13,614 lines and 3,269/3,270 raw functions, with InspectorPanel the only zero-hit function. The fresh local unit lane at the same source commit used run `1794458764107` (attempt 1). Its report is `coverage/package-report.md`, derived through the same strict evaluator as CI; its source artifacts are retained under `.build/unit-watchdog/run-CfHoNY/coverage` and its guardian LCOV at `coverage/package-eligible.lcov`. These paths are repository-relative.

| Measurement | Before retirement, stale two-entry policy | After retirement, fresh unit lane |
| --- | ---: | ---: |
| Executable lines | 13,614/13,614 | 13,614/13,614 |
| Raw functions | 3,269/3,270 | 3,269/3,270 |
| Manifest exceptions | 2 | 1 |
| Valid zero-hit exceptions | 1, InspectorPanel | 1, InspectorPanel |
| Eligible functions under current evidence | 3,269/3,269 | 3,269/3,269 |

The before column is the policy and measured raw mapping at `2cc99ff9`, not a claim that its stale manifest passed evaluation. The removed ViewerChrome closure no longer appears in that mapping.

## Verification

- RED: `scripts/heavy-lock.sh node --test scripts/ci/package-coverage.test.mjs` failed the new one-entry manifest assertion (`2 !== 1`). The prior positive ViewerChrome fixture also failed with `unapproved function exception source pin` against current source.
- GREEN: `scripts/heavy-lock.sh node --test scripts/ci/*.test.mjs scripts/tdd/*.test.mjs` passed: 616 pass, 0 fail, 2 skip.
- Fresh local/CI parity: the InspectorPanel fixture ran the same evaluator in two-shard CI and single-shard local modes, confirming `raw functions 4/5`, `exceptions 1`, and `eligible functions 4/4` in both. It also rejects duplicate, wildcard, changed source/toolchain/symbol, covered, unmatched, and retired ViewerChrome exceptions.
- Unit lane command: `scripts/heavy-lock.sh node scripts/tdd/unit-lane.mjs` exited 0. Result: `Package: lines 13614/13614; functions 3269/3270; raw functions 3269/3270; exceptions 1; eligible functions 3269/3269` and `Coverage gate: PASS (exact 100% executable lines and functions per module and Package)`.

No Swift source, workflow configuration, InspectorPanel exception, or file exception was changed here.
