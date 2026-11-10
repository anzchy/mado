# M1 coverage audit — PASS

Independent auditor tdd_plan reused completed fresh gates; no duplicate tests/exports. All seven recorded source hashes match current files. Evidence in gpt-imple-1 evidence dir: i632-fix-r1-native/results.json, i632-fix-r1-coverage.json/.log, i632-fix-r1-final-source-hashes.json.

| Metric | Covered/total | Threshold | Result |
|---|---:|---:|---|
| Lines | 16701/16701 | 100% | PASS |
| Functions, LLVM summary | 3212/3212 | 100% | PASS |
| Statements, mirrors lines | 16701/16701 | 100% | PASS |
| Branches | Unmeasured | 0% | N/A |

Official single exact LCOV, not weighted; independent raw sums agree, no zero-hit DA. Original exporter/exclusions/thresholds unchanged. Critical paths NOT CONFIGURED; mutation disabled.

Fresh owner-approved split:1079tests/29suites48.083s/two known issues; serialMacUI708tests/14suites68.742s. Both PASS, identical test-binary hashes; only these current profiles merged before unchanged export. No fresh full-parallel wrapper pass claimed.

Raw FNDA still has14zero-hit generated closures (chrome1/design components12/inspector1) despite LLVM function summary100%; this baseline summary/detail limitation remains explicit. Changed Node/watchdog code is outside Swift instrumentation; no JS coverage percentage claimed. Behavioral process tests cover that tooling. Two historical High SEPARATION-BROKEN fixture-I/O findings remain intact; coverage PASS does not relabel them or create new RED.
