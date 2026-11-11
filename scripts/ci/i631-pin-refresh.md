# #631 ViewerChromeOverlay function pin refresh (M6, pending review)

This candidate refreshes only the whole-source digest of the existing
`ViewerChromeOverlay.swift:198` function exception. It is a separate commit so
the delegator can keep or drop it after review. It does not authorize coverage
enforcement or a new exception.

## Evidence and rationale

- Source: `Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift`.
- Old SHA-256: `eeaab6be2ec0eef7d42b97e09f1494ec03f4632302a08a78de4bd131c573fc7d`.
- New SHA-256: `a1e985e2de3bf574033337383db0daeec08eec043126fd0d7a00bd05f41d9a18`.
- Source diff from #358: `hitTest` at lines 478–486 changes `for group in groups.reversed() where !group.isHidden && group.frame.contains(local)` to a plain loop with `guard !group.isHidden, group.frame.contains(local) else { continue }`. The pinned callback at line 198 is unchanged. The original #631 rationale remains: a temporary toolbar button is instantiated only to read its label; its callback is never installed.
- Exact pinned symbol at line 198: `$s9MadoMacUI14ChromeToolViewC18accessibilityValueypSgyFyyYbScMYccACYbcfu_yyYbScMYccfu0_`; its SHA-256 identity is `0d760c77616e860a9bc85999c00fc95ffaff7fac32df2f45b221310e00f0cdcd`.
- Toolchain: Xcode 26.6 (17F113), Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, arm64 macOS 26.0), Apple LLVM 21.0.0.
- Fresh atomic-counter diagnostic on the #358-integrated source: both non-UI and MacUI shard LCOVs map this exact symbol at line 198 and report `FNDA:0`. Logs and artifacts are in `.build/i631-d-pin-diagnostic/` in the #631 worktree. These diagnostic exports are not acceptance preflight artifacts. The evaluated LCOVs contain no test-source records.

## Review status

Independent reviewers: **gpt-auditor and opus-auditor, blind confirmation pending** on this refresh commit. They must verify the unchanged symbol identity, zero valid hits, rationale, and absence of newly exempted behavior. Delegated approver: **gpt-6-astra acting as owner-decider under the owner's delegation, pending**. The delegator records their outcomes after review. This is not owner approval to enable `COVERAGE_ENFORCE`.

The existing exception decision remains `i631-fn-astra.md B`; this M6 record only refreshes its source pin. All other function and file exceptions retain their prior decisions and digests.
