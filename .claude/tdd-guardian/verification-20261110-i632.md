# #632 bound-only WI verification

Base: eeca5e303f1b4eab4021d75cf196a8cf110f0a73 (#635 merged). Clean rebase, no product/App/Package/CI changes. Implementation retains full parallel Swift command; no permanent lane split.

## Evidence

- Original comparison at613a3eea: full3/3PASS, split3/3PASS; root cause remains undetermined. Owner accepted inconclusive result, then explicitly requested only a600s post-admission bound after observed2h lock-holding hang. Issue632 remains open for recurrences.
- I632-BOUND-WI-1 original genuine assertionRED:6of7fail against nonfunctional API stub. Original raw RED retained, no re-recording.
- Targeted originalGREEN7/7; verifyGREEN but SEPARATION-BROKEN on documented fixture startup/queue input amendment. Original High finding remains; independent reviewer accepts rationale with notes. Production600 and recorded behavior assertions unchanged. Preexisting stub concern resolved by genuineRED evidence.
- Prior broader concurrent Node run45/46PASS hit normal fixture2s deadline; preserved in i632-resume-node.log. No source/test changes to address it. Fresh resumed four-file run under actualheavylock with --test-concurrency=1:46/46PASS,0fail/skip/cancel,43423.002ms. Includes seven new launcher/owner integration tests, existing watchdog and lane-inventory tests. i632-resume-serial-node.log.
- Owner-authorized temporary native split:1079tests/29suites/48.542s/2knownissues, then708tests/14suites/75.416s; both exit0. XML confirms1079+708=1787cases,0failure/error. Each invokes its own heavy-lock with7200s allowance and existing1500s CI watchdog, CI target selections plus existing coverage flag.
- Each profile copied after its successful lane; profile mtimes newer than corresponding invocation log creation. Executable SHA256 matches across both profiles. Only these current profiles were merged into the original default.profdata. Original exporter and lcov-total.py/official coverage parser unchanged.
- Fresh LCOV gate PASS: lines16701/16701, functions3212/3212, statements16701/16701 (LCOV line mapping), exact single-report merge, not approximate. Branches unmeasured, threshold0. Critical paths NOT CONFIGURED, mutation disabled. JavaScript launcher/owner scripts are outside configured Swift coverage; their process/lock behavior is covered by the real integration tests, not a claimed JS coverage percentage.
- Final source hashes match the versions used for fresh Node/native acceptance. Independent code/test review APPROVED WITH NOTES; see review-20261110-i632-final.md. Fresh independent coverage audit PASS is persisted in coverage-20261110-i632.md, including the unchanged14zero-hit generated-closure FNDA limitation despite100% LLVM summary.

## Owner gate decision

Until632lands, the standing owner decision uses CI split package gates rather than repeating the known full-parallel local hang. These fresh native passes and unchanged coverage gate provide taskCompleted/commit acceptance for this WI. No fresh configured full-parallel unit-lane PASS is claimed or fabricated. The production wrapper's actual deadline placement, timeout124, cleanup including detached helper, status/output, unique evidence and lock release are tested via external executable integration fixtures. No gate-bypass environment variable used.

## Artifacts

All raw evidence is in gpt-imple-1 evidence dir: i632-resume-native/{results.json,nonmacui.profdata,macui.profdata,nonmacui-outer.log,macui-outer.log}, corresponding test.log/xunit-swift-testing.xml, i632-final-coverage.{json,log}, i632-final-source-hashes.json, preserved RED/verify logs. Generated coverage/profiles/receipts/state remain ignored; only named source/tests/config/TDD markdown are committed.

Refs #632. Tooling only; no user-visible ledger row. No push/PR.
