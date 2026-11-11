# Delegated #631 function coverage decision (2026-11-10)

Recorded from gpt-6-astra (high) under the owner's delegation. This is a delegated design call, not owner approval to enable enforcement. The text below is the durable repository copy of the decision.

**Decision: retain strict per-mapping coverage, test the 12 live callback entries, and permit only two precisely enumerated exceptions.** This explicitly clarifies D2/D3 and amends D4; it does not authorize enforcement yet.

**A — Denominator.** Use unique normalized `FN/FNDA` identities across shards, with compatible mappings required—not summed or maximized `FNF/FNH` summaries. The current raw function result is **3224/3238**. Lines remain unique `DA` locations, currently **13375/13375**. LLVM exports summaries and function records through different paths; **3212/3212 is not interchangeable evidence**. [LLVM exporter](https://github.com/llvm/llvm-project/blob/main/llvm/tools/llvm-cov/CoverageExporterLcov.cpp)

**B — Treatment of the 14 entries.**

- **Require coverage through tests for the 12 `DesignComponents.swift` entries.** These wrap live button, keyboard and hover callbacks. “Compiler-emitted” does not make their invocation irrelevant. Exercise the installed callbacks and assert effects; directly calling their destination helpers is insufficient.
- **Authorize two function-specific exceptions:** `ViewerChromeOverlay.swift:198`, whose callback is supplied to a temporary value used only for its label; and `InspectorPanel.swift:191`, the empty initializer callback replaced during view update. Neither warrants artificial invocation solely for coverage.
- Keep these separate from the existing 17 declaration-only file exceptions. Each entry must bind exact path, symbol, location, source digest and toolchain, with rationale and this decision’s reference. Reject duplicates, wildcards, unmatched/stale entries and exceptions that become covered. Additions or replacements require a new explicit reviewed decision; a count cap alone is insufficient. No blanket SwiftUI/closure exclusion.

Report **raw coverage, each exception, and eligible coverage separately**. With unchanged mappings, acceptance becomes **3236/3236 eligible functions**, with two disclosed exceptions—not “3238/3238 covered.”

**C — Local/CI parity.** Yes. CI, owner-gates and #632’s unit lane must share the same evaluator, denominator and exception policy before enforcement. Different execution layouts are acceptable; different definitions of passing are not. Legacy summaries may remain diagnostic.

**D — Next-round acceptance.**

1. Record this policy amendment; implement callback tests and shared evaluation using RED-first tests. Prove new uncovered mappings, exception drift, malformed/missing evidence and incompatible shards fail closed.
2. Obtain exact **100% eligible functions and executable lines in every module and Package**, with positive denominators and no rounding. Preserve all provenance/inventory checks.
3. Demonstrate local/CI evaluator agreement, then freeze the candidate SHA, toolchain and exception manifest.
4. Complete the previously mandated **ten predeclared cold runs plus cache-restored validation**: all tests pass, thresholds pass, loop-exit throw hit ≥1 each run, complete artifacts and measured overhead. No discarded runs, retries-to-green, exclusions added during the batch or batch restart. Only then review the enforcement switch.

**Product source changes are allowed only when demonstrably necessary for meaningful tests**, using minimal behavior-preserving seams. Do not reshape production code merely to remove coverage mappings or manufacture hits.
