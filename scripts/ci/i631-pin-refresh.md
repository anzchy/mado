# #631 ViewerChromeOverlay function pin refresh (M6)

This refresh changes only the whole-source digest of the existing
`ViewerChromeOverlay.swift:198` function exception. It was prepared in the
separate commit `2ed16fbe` for independent review. It does not authorize
coverage enforcement or a new exception.

## Evidence and rationale

- Source: `Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift`.
- Old SHA-256: `eeaab6be2ec0eef7d42b97e09f1494ec03f4632302a08a78de4bd131c573fc7d`.
- New SHA-256: `a1e985e2de3bf574033337383db0daeec08eec043126fd0d7a00bd05f41d9a18`.
- Source diff from #358: `hitTest` at lines 478–486 changes `for group in groups.reversed() where !group.isHidden && group.frame.contains(local)` to a plain loop with `guard !group.isHidden, group.frame.contains(local) else { continue }`. The pinned callback at line 198 is unchanged. The original #631 rationale remains: a temporary toolbar button is instantiated only to read its label; its callback is never installed.
- Exact pinned symbol at line 198: `$s9MadoMacUI14ChromeToolViewC18accessibilityValueypSgyFyyYbScMYccACYbcfu_yyYbScMYccfu0_`; its SHA-256 identity is `0d760c77616e860a9bc85999c00fc95ffaff7fac32df2f45b221310e00f0cdcd`.
- Toolchain: Xcode 26.6 (17F113), Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, arm64 macOS 26.0), Apple LLVM 21.0.0.
- Fresh atomic-counter diagnostic on the #358-integrated source: both non-UI and MacUI shard LCOVs map this exact symbol at line 198 and report `FNDA:0`. Logs and artifacts are in `.build/i631-d-pin-diagnostic/` in the #631 worktree. These diagnostic exports are not acceptance preflight artifacts. The evaluated LCOVs contain no test-source records.

## Review and delegated approval (2026-11-11)

- Independent reviewer **gpt-auditor**, on `2ed16fbe`: `M6-REVIEW: APPROVE`; COUNT C0 H0 M1 L0 (gpt-auditor confirm report). Its Medium concerns the separately disclosed `P0-02-I631-C-WI-1` receipt history.
- Independent reviewer **opus-auditor**, on `2ed16fbe`: `M6-REVIEW: APPROVE`; COUNT C0 H0 M1 L5 (opus-auditor confirm report). The Medium is a test gap for the evaluator's source and decision identity pins; its five Low findings are nonblocking. M7 broken receipts, L3 legacy helpers and L5 hosted overhead remain open by delegated decision.
- Delegated approver **gpt-6-astra acting as owner-decider under the owner's delegation**: `DECISION: APPROVE`. Conditions: "Before freeze, record both reviewers' approvals and this delegated approval, clarify the B/M6 reference distinction, and correct stale policy status/counts. Retain disclosure of the nonblocking audit findings and broken receipts; confirm drift-rejection and local/CI parity checks on the final frozen candidate. Preserve the predeclared 10 cold + 1 restored protocol and keep COVERAGE_ENFORCE=false." This is a delegated approval of the digest refresh, not owner approval to enable enforcement.

The substantive authorization for the two exact function exceptions is
`i631-fn-astra.md B`. The manifest's `decision: i631-pin-refresh.md M6` for
ViewerChrome points to this **source-digest refresh provenance**, not to a new
exception authorization. InspectorPanel and all 17 file exceptions retain
their prior decision references and digests.

## Disclosures retained for freeze and PR

- Historical `P0-02-I631-WI-1` and `P0-02-I631-B-WI-2` remain **SEPARATION-BROKEN** (M7); no receipts were rewritten. `P0-02-I631-C-WI-1` is also **SEPARATION-BROKEN** because its RED fixture encoded the superseded permissive exception policy. The corrected `P0-02-I631-C-WI-1B` is **SEPARATION-HELD**. Round d's RED parity log is not a tdd-guardian receipt.
- The opus-auditor's nonblocking Medium is the missing direct regression for the evaluator's independent source/decision pins. Remaining Low audit findings include missing M2/L4 regression cases, the round-d receipt gap, and wrapped **test-source** counters despite atomic instrumentation. The review-status and policy-count wording findings are addressed in this docs update. L3 legacy helpers, L5 hosted overhead and two baseline Python owner-gate failures remain open by decision.
- The delegator's owner gates on `2ed16fbe` (prefix `i631d`) returned status 0 in every lane: Package lines 13403/13403, eligible functions 3235/3235 with two exceptions, 1,794 tests. Three local CI-layout preflights are recorded in the round-d handoff; they do not replace the predeclared 10 cold + 1 restored hosted protocol. `COVERAGE_ENFORCE=false`.
