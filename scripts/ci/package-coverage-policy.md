# Package coverage policy for #631 (P0-02 tooling)

The repository copies of the 2026-11-10 and 2026-11-11 gpt-6-astra (high)
delegated decisions are [i631-fn-astra.md](i631-fn-astra.md) and
[i631-audit-astra.md](i631-audit-astra.md). They are delegated design calls,
not owner approvals to enable enforcement.

The exact 100% gate measures each emitted, normalized `FN`/`FNDA` identity once
across compatible shards. Executable lines are unique `DA` locations. LLVM's
`FNF`/`FNH` and `LF`/`LH` summaries remain diagnostics, because they can count
different coverage units. A covered function needs a positive merged `FNDA`
counter. Source inventories, provenance, toolchain and mapping compatibility
must match before the gate considers any count.

The 17 declaration-only file exceptions live in
`package-coverage-exceptions.json`. Each entry pins an exact repository-relative
path, whole-source SHA-256, reviewed rationale, toolchain and the durable audit
decision. The evaluator pins the complete 17-entry manifest independently,
rejects additions, substitutions, duplicates and digest drift, and rejects any
executable mapping in an excluded source. The separate
`package-coverage-function-exceptions.json` permits exactly the two functions
named in the delegated decision: `ViewerChromeOverlay.swift:198` and
`InspectorPanel.swift:191`. Each entry pins the full source path, mangled symbol,
start line, source SHA-256, Xcode/Swift/LLVM toolchain, rationale and decision.
The evaluator rejects stale, covered, duplicate, wildcard and unmatched entries.
Adding or replacing any file or function exception requires another explicit
reviewed decision. There is
no general exception for SwiftUI closures.

An individual DA or FNDA counter at or above 2^63 is invalid evidence, even
if another shard or a neighbouring mapping has positive hits. The evaluator
checks each shard before aggregation, reports every invalid identity, raw count
and provenance separately from uncovered code and exceptions, and emits no
eligible artifact for that run. The reported local/owner-gate wrapped counters
remain a blocker for the hosted acceptance batch; #358 tracks investigation,
not a waiver.

To refresh a source or toolchain pin, the implementer supplies the source diff,
old and new digest, mapping identity and location, toolchain, and fresh coverage
evidence. An independent reviewer rechecks the exception rationale, unchanged
symbol identity, zero valid hits and absence of newly exempted behaviour. The
owner or an explicitly delegated owner-decider approves the refresh. Record the
reviewer and approver in the decision, then update the manifest, evaluator pins
and portable decision reference together. A symbol, rationale or toolchain
change needs a fresh explicit exception decision. Re-run drift rejection tests
and local/CI parity before freezing a candidate. #637 must follow this process
for ViewerChromeOverlay.swift.

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
