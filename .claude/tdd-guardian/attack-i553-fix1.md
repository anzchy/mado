# Specification Attack — .claude/tdd-guardian/tests-i553-fix1.md

## Verdict: SURVIVED

Separate pre-implementation adversary pass; no implementation/test edits.

## Attacks defeated by the existing matrix

| Attack | Killed by |
|---|---|
| Hard-code scan success or remove meaningful checks | Future-record transition then stale current command must fail |
| Keep fixed historical SHA but skip if unavailable | Full/depth1 suite plus future-history evolution; one-shot requires explicit revisions and rejects absent objects |
| Move a fixed range check to another always-run suite | Actual all-Node depth1 gate and no fixed-range historical contract criterion |
| CLI ignores --head and reads working tree | Selected immutable-pair verdict remains unchanged after later historical/acceptance commits |
| CLI ignores --base or accepts everything | Valid pair plus corruption/omission/unrelated-condition negative heads |
| CLI silently skips bad history | Missing/invalid revision guard cases demand nonzero exit |
| Rename design prompt but leave bundle incompatible | Every prompt global compared to both actual manifest and bundle export |
| Check only one prompt copy | Complete tracked prompt enumeration |
| No-op replay passes idempotence | First output must rename surrounding app-name prose while preserving namespaces |
| Replay restores prompts once but rebreaks them later | Namespace preservation and second-run byte equality |
| Omit docs-node from exact config contract | Complete inventory includes docs-node and manual/Node properties |
| Weaken heavy-lock requirements for all lanes | Heavy/native discovery partition retains lock and manual integration assertions |
| Restore release template but replay changes it again | Exact template bytes after first and second replay |
| Claim current Mado release instructions work now | README pending-#552 condition required in Mado tag/DMG context |
| Collapse all acceptance to broad normalization | Four-ID-only substitution plus unrelated word/condition negative heads |
| Outside chosen range records become permanent tripwire | Future-history lasting scan succeeds; original pair deterministic after newer commits |

## Units with no law

None: explicit finite-domain preservation, selected-range determinism or lane inventory invariants cover every unit. Async/concurrency and unbounded performance attacks are outside this synchronous finite-tree fix contract.
