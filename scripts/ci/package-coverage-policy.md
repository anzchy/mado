# Package coverage policy for #631 (P0-02 tooling)

This records the 2026-11-10 delegated decision by gpt-6-astra (high),
`/Users/jack/.picsee/herdr/delegator/ci-p02/i631-fn-astra.md`. It clarifies D2/D3
and amends D4 of `~/.picsee/herdr/delegator/ci-p02/decision.md`. It is a
delegated design decision, not owner approval to enable enforcement.

The exact 100% gate measures each emitted, normalized `FN`/`FNDA` identity once
across compatible shards. Executable lines are unique `DA` locations. LLVM's
`FNF`/`FNH` and `LF`/`LH` summaries remain diagnostics, because they can count
different coverage units. A covered function needs a positive merged `FNDA`
counter. Source inventories, provenance, toolchain and mapping compatibility
must match before the gate considers any count.

The 17 declaration-only file exceptions live in
`package-coverage-exceptions.json`. The separate
`package-coverage-function-exceptions.json` permits exactly the two functions
named in the delegated decision: `ViewerChromeOverlay.swift:198` and
`InspectorPanel.swift:191`. Each entry pins the full source path, mangled symbol,
start line, source SHA-256, Xcode/Swift/LLVM toolchain, rationale and decision.
The evaluator rejects stale, covered, duplicate, wildcard and unmatched entries.
Adding or replacing one requires another explicit reviewed decision. There is
no general exception for SwiftUI closures.

Reports disclose raw functions, each exception and eligible functions
separately. For the prior two-shard mapping, raw was 3224/3238; after twelve
installed callback tests are covered, the expected result is raw 3236/3238,
two disclosed exceptions and eligible 3236/3236. `COVERAGE_ENFORCE` remains
`false` until the predeclared ten cold runs and cache-restored validation pass.

CI feeds the evaluator two independently exported shards. The local #632 unit
lane feeds it its one fresh full-suite artifact with `--shards non-ui` and
`--formal false`; owner-gates re-evaluates that retained artifact. Both layouts
use the same parser, inventory checks, exception manifest and exact gate. The
guardian's `coverage/package-eligible.lcov` is generated from the strict
evaluator's validated mappings, so its 100% threshold uses the same numerator
and denominator. LLVM's original summary LCOV may still be exported for
diagnostics but does not determine the local gate.
