# #632 audit fix round 1 — WI-2 coverage applicability

Independent auditor: tdd_plan. Verdict: PASS for reuse applicability.

M2 changes only Node fixture helpers, the startup oracle, its manual-lane registration and plan notes. Swift sources, coverage exporter, exclusions and thresholds are unchanged. The production watchdog hash matches the audited M1 candidate.

The fresh M1 owner-approved CI split profiles and exact merged LCOV remain applicable: lines/statements16701/16701; functions3212/3212 by LLVM summary; branches unmeasured with threshold0. The baseline caveat of14 zero-hit generated-closure FNDA entries remains; there are no uncovered line records. See the M1 coverage artifact for provenance and exporter details.

Default-concurrency Node validation passed53/53 with zero failures, errors or skips,82.815 seconds. Node code is outside Swift instrumentation; no JavaScript coverage percentage is claimed. This reuses the split evidence and does not claim a fresh full-parallel package pass. Receipt verification is reported separately.

Audit was read-only; no jobs or writes by the auditor.
