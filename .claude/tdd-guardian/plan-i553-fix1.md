# TDD Plan: #553 audit fix round 1

## Work Items

### WI-1: Repair design-export instructions and separate lasting checks from ticket-range evidence
- **Description**: Address gpt F1, opus F1/M1/M2 and the delegator's lane-inventory failure without rewriting the three existing commits or changing Swift.
- **Acceptance criteria**:
  - [ ] Both generated design prompts name the actual PicseeUiSystem_bb8eab export; replay preserves that executable global. Every prompt's design-system global agrees with its sibling manifest and bundle.
  - [ ] The persistent living-doc suite scans current stale identities only; no fixed-SHA ADR, validation or acceptance tripwire remains in always-run suites. Future legitimate historical records/acceptance changes do not fail the lasting scan.
  - [ ] A separate one-shot CLI requires explicit --base and --head and checks the chosen immutable range's frozen records/former-name notes/ledger acceptance. Missing or invalid revisions and malformed options fail visibly. It never silently skips an unavailable base.
  - [ ] Run that CLI for the full #553 range and retain output. Later changes outside the chosen head cannot affect its verdict.
  - [ ] Keep docs-node because RED receipts need the docs Node lane. Update the exact discovery-lane inventory and explain that lightweight Node probes do not need heavy-lock; heavy probes still require it and integration stays manual.
  - [ ] Restore docs/release/notes-template.md to bf5052b2 bytes; replay skips it, and docs/release/README.md labels mado-v/Mado DMG instructions pending #552.
  - [ ] All Node suites pass in the full worktree and depth-1 clone; ledger HTML, design and whitespace gates pass.
  - [ ] Add commits, preserve existing history and write Report-Task: i553-fix1-a handoff with fix/test map and gate logs.
- **Required tests**:
  - Real prompt/manifest/bundle export agreement and replay preservation — Level 1/2, S5.
  - Actual lasting suite succeeds from a depth-1 clone, after new ADR/validation records and a sanctioned acceptance fixture change, while a stale current command still fails — Level 3, S5.
  - One-shot CLI real Git range fixtures: valid rename accepted, forbidden historical or acceptance edits rejected, missing/invalid revisions rejected, outside-range changes irrelevant — Level 1/3, S5.
  - Exact lane inventory accepts docs-node and retains heavy/manual properties — Level 1.
  - Release template byte equality to baseline and replay protection; pending #552 marker — Level 1/2.

## Risks & Assumptions
- Fixed audit head is d22c0050; baseline for the original rename evidence is bf5052b2. Resolve explicit ranges independently of the working tree and moving branch names before checking content.
- Generated bundle globals are executable identifiers, not app-name prose. React/ReactDOM are external prerequisites, not exports of the design bundle.
- Missing Git history is expected in lasting depth-1 CI. Only the one-shot range CLI requires explicit historical objects.
- The docs-node lane was needed to record docs RED; changing its exact inventory must preserve the existing native discovery lock requirements.
- User expressly says no Swift runs unless Swift changes. Do not rerun native/coverage gates for this Node/docs-only fix; prior #553 native evidence remains historical.

## Deferred / Out of Scope
- L1–L4 remain open and must be listed in the PR/handoff.
- Release implementation #552, repo rename #554 and tooling rename #556.
- Renaming generated bundle/manifest exports, Swift changes, unrelated doc cleanup, pushing, PR creation and gardening.
