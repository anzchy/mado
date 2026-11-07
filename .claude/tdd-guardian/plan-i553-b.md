# TDD Plan: #553 Mado living documentation rename, amendment 1

## Work Items

### WI-1: Rename living docs with narrowly authorised acceptance substitutions
- **Description**: Deliver an idempotent, committed mechanical rewrite script, its output, and small documented hand edits. Current app/package/module/scheme/product/bundle-ID/launch-flag/build-key references become Mado; historical records retain their text with one former-name note.
- **Acceptance criteria**:
  - [ ] Living docs and copyable native commands identify Mado, including MadoGitSHA and Packages/MadoKit.
  - [ ] GLOSSARY.md defines Mado as the app name and Picsee as its former name.
  - [ ] Ledger row IDs are unchanged. Acceptance before 限制： is identical to bf5052b2 except OPEN-03, CMD-05, WIN-02 and EXT-03, where only picsee/Picsee becomes Mado. Limitations may receive the ordinary mechanical name substitutions, including OPEN-08/CMD-01.
  - [ ] Every ADR and validation record has exactly one added former-name note and is otherwise byte-identical to bf5052b2.
  - [ ] Replay is idempotent and preserves filenames, links, tooling names/paths, repo references, research evidence and frozen release history.
  - [ ] Required Node/ledger/design/whitespace and foreground sequential native gates pass with logs.
  - [ ] After the green workflow, acceptance-only ledger md+html are committed separately with the exact owner quote, ADR-0017, #553, four IDs and Implemented-by trailer; mechanical output and hand edits are separate commits.
  - [ ] Handoff uses Report-Task: i553-b and lists commits, script/replay, hand edits, exceptions, receipts, logs and #554/#556 deferrals.
- **Required tests**:
  - Real living-doc scan rejects stale app package/module/scheme/flag/build identities and accepts only explicit contextual exceptions — assertion level: Level 1.
  - Fixed-baseline comparison protects all ADR/validation bytes except one note — assertion level: Level 1, S5.
  - Fixed-baseline comparison protects ledger IDs and every acceptance clause with exactly the four authorised substitutions — assertion level: Level 1, S5.
  - Real temp-repository replay verifies actual output, protected spans and second-run byte equality — assertion level: Level 2, S5.

## Risks & Assumptions
- Baseline bf5052b2 contains #550/#551. Do not compare to a moving origin/main.
- Amendment /Users/jack/.picsee/herdr/gpt-imple-2/i553-amend1.md authorises exactly four acceptance app-name changes and distinguishes limitations from acceptance.
- Match exceptions by context rather than exempting whole documents containing tooling references.
- Preserve Markdown link destinations and directory names; document filenames stay unchanged.
- #552 owns scripts/release/**, release workflow and DIST limitations apart from mechanical name fixes.
- The configured Swift unit/coverage lane remains applicable to workflow gates; Node tests need a manual receipt lane.

## Deferred / Out of Scope
- #554 repo rename, repo URLs and repo-name prose.
- #556 tooling names, ~/.picsee/, PICSEE_* variables, roster/herdr scripts and heavy-lock paths.
- Release tooling/workflow changes, release history, frozen appcast and research evidence.
- Other acceptance changes, app behaviour, signed build/device launch, pushing, PR creation and gardening.

### WI-2: Refresh the renamed guide's pinned bytes
- Discovered by the required full Swift gate: designRegistryPinsSources rejected the renamed DESIGN.md bytes.
- Preserve registry schema, color/size values and unrelated pins; change only the DESIGN.md SHA-256 in JSON and Swift metadata.
- Existing exhaustive invariant test provides RED before refresh (i553-WI-2), then targeted GREEN. No assertion edits.

### WI-3: Protect concrete roster protocol tokens during replay
- Review found session `picsee` and `project=picsee` were tooling identifiers reserved for #556.
- Add a real replay fixture first, record i553-WI-3 RED, then protect those exact spans and the original quoted owner name.
- Correct release runbook semantics to the already approved Mado tag contract; gate use on #552 and distinguish frozen former feed.
