---
name: macos-device-test
description: Verify Mado features in a signed macOS app on a real desktop, capture device evidence, and write a ledger-linked validation record. Use when acceptance depends on real windows, input, pixels, relaunch, or sandbox grants that automated tests cannot establish.
---

# Mado macOS device test

Use this skill for an independent device acceptance run. Start with the relevant rows in `docs/feature-ledger.md` and the work package in `docs/PICSEE_DEVELOPMENT_PLAN.md`. The row's 「怎么确认」 is the acceptance criterion. Read [features/README.md](features/README.md) and the matching recipe before driving the app; write a missing recipe before claiming device validation. Read [references/device-runbook.md](references/device-runbook.md) for build, doctor, input, evidence, cleanup, and record details needed for the run.

## Run boundary

- The device tester must differ from the feature implementer. A validation record written by the implementer cannot establish `真机` or `Shipped`.
- Before any desktop action, run `.agents/skills/picsee-delegator/scripts/gui-lock.sh status`. Acquire the shared GUI lock for the run before launching, activating, clicking, typing, or capturing, and keep the `acquisition_id` it prints. Hold it through relaunches and release it after cleanup, including failed runs, with `gui-lock.sh release <run-id> --acquisition-id <uuid>`. If another project holds it, drive no GUI.
- Check for an existing Mado process before launch. Never drive or terminate an instance the run did not start, including the user's installed copy. Keep the sandbox enabled; use normal powerbox grants. Do not alter privacy settings, pregrant folders, or edit the container without the user's approval.
- Keep screenshots, logs, fixtures, and briefs under `~/.picsee/`, outside the repository. Use the recorded PID and build SHA to tie evidence to this run.

## Sequence

1. Choose the machine and ledger entry points in the brief. The Mac mini covers @1x; @2x criteria need a suitable Retina machine or an explicit `NOT VERIFIED` verdict.
2. Build a signed `.app` with `scripts/device/build.sh`. Acquire the GUI lock before launching with `scripts/device/launch.sh`; require every `scripts/device/doctor.sh` check to pass.
3. Drive each listed entry point through the app's real user path. Prefer stable keyboard and accessibility handles. Capture the action and resulting state; verify persistence after relaunch and file writes by reading the file. Record synthetic input or other deviations.
4. Give each criterion and entry point `pass`, `FAIL` with reproduction, or `NOT VERIFIED` with a specific blocker. Tool limitations and unrun paths are `NOT VERIFIED`, never inferred passes. Do not invent performance numbers.
5. Run `scripts/device/cleanup.sh` for the owned process, release the GUI lock, and write a separate `docs/validation/P<n>.md` commit with `Validated-by: <role> run=<run-id>`. Give the evidence and proposed ledger limits/status to the ledger owner. The owner updates the ledger and generated HTML; run the doc gardener before the validation PR.

The [runbook](references/device-runbook.md) contains the exact helper contracts and proof standards. The [feature map](features/README.md) links the user-path recipes; read only those needed for the current run.
