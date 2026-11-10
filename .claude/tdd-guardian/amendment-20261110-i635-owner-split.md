# Owner decision: temporary CI split package gate (#635 / #632)

Owner explicitly resumed the stopped #635 workflow after the final candidate's full-parallel package gate returned `status=timeout`, `phase=command`, `durationMs=600005`, no complete counts and no coverage report. The original result is retained byte-for-byte at `gpt-imple-1 evidence dir: i635-owner-original-timeout-verbatim.json` (also original `i635-r4-taskCompleted-unit-result.json`). This remains an environment failure, tied to known local full-parallel hang #632 by the owner's decision. No result is reclassified as PASS, no failed output is overwritten.

Owner instruction: “until #632 lands the Swift package gate runs split like CI” and “If both split lanes pass, commit per WI”. Each split command must acquire its own `PICSEE_HEAVY_LOCK_WAIT_SECS=7200 scripts/heavy-lock.sh`. No permanent configuration/CI/product change is part of #635.

Verified `Packages/MadoKit/Package.swift` test targets: MadoCoreTests, MadoApplicationTests, MadoInfrastructureTests, MadoMacUITests. `.github/workflows/ci.yml` uses the first three in parallel via `--skip 'MadoMacUITests\.'`, then MacUI serial via `--no-parallel --skip '(MadoCoreTests|MadoApplicationTests|MadoInfrastructureTests)\.'`. Both use `-Xswiftc -enable-incremental-file-hashing` and xunit output under the existing1500s watchdog. Local runs mirror these commands with absolute external evidence destinations; CI job deadline-epoch has no local job-start equivalent and is omitted.

The owner-authorized split gates replace the failing local full-parallel taskCompleted/commit unit invocation for this WI. CI's commands do not export fresh coverage; earlier candidate coverage100 remains historical, not a final-candidate rerun. AppTests-only change has no package source edits. No stale coverage is used to assert fresh final coverage. Final App candidate is already verified by fresh R3 SEPARATION-HELD and40x7 no-retry App execution. Final independent review remains required.

No push/PR. Keep #632 own stash untouched until #635 completed.
