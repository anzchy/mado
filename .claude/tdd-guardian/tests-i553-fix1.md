# Test Matrix — WI-1: #553 fix round 1

Plan: .claude/tdd-guardian/plan-i553-fix1.md. All fixtures use real filesystem/Git/CLI processes; no mocks. S5 cases check complete finite record/path domains and state transitions, not sampled example percentages. No asynchronous retry or concurrency behavior is introduced.

## Unit: Design prompt runtime-export contract

**Law**: Every design-system global instructed by a prompt is the namespace actually exported by its adjacent manifest/bundle; replay preserves that contract.

### Case: All tracked prompts match actual exported namespaces
- **Category**: property
- **Lane**: integration (Node design/name-check suite)
- **Spec level**: S4 — enumerate every tracked _ds_prompt.md with a sibling bundle/manifest.
- **Input**: Both picsee-browser/_ds and states/_ds prompts, sibling _ds_manifest.json namespace and _ds_bundle.js export. Exclude external React/ReactDOM prerequisites from the design-system-global set.
- **Expected output**: Every copied design-system window global equals the manifest namespace and is actually exported by its bundle; both current PicseeUiSystem_bb8eab names pass. MadoUiSystem_bb8eab in either prompt fails.
- **Observable side effect**: None.
- **Assertion strategy**: Level 1 — compare parsed prompt globals to actual namespace and bundle export, reporting path/global mismatch.
- **Mock boundary**: none — real tracked artifacts.
- **Refactor that would break this**: Changing the public runtime export without synchronizing its copied instructions.

### Case: Replay keeps executable namespaces while renaming surrounding prose
- **Category**: state
- **Lane**: integration (Node replay tests)
- **Spec level**: S5 — preserve executable meaning through first and repeated rename.
- **Input**: Temp repo with Picsee app-name prose, both prompt variants and unchanged PicseeUiSystem_bb8eab manifests/bundles.
- **Expected output**: Prose becomes Mado, all executable namespace occurrences remain PicseeUiSystem_bb8eab and resolve to the bundle; second replay leaves bytes unchanged.
- **Observable side effect**: Temp Markdown bytes rewritten once, bundle/manifest unchanged.
- **Assertion strategy**: Level 2 — read files after real CLI execution and compare expected first output plus second-run snapshots.
- **Mock boundary**: none — real replay CLI and filesystem.
- **Refactor that would break this**: A mechanical text transform rewriting protected runtime identifiers.

## Unit: Lasting living-doc identity scan

**Law**: Current stale identities fail independently of Git history, while legitimate historical evolution cannot create a baseline tripwire.

### Case: Depth-1 branch runs every Node suite
- **Category**: success
- **Lane**: integration (explicit fix gate)
- **Spec level**: S5 — cloning removes parent objects but preserves lasting test behavior.
- **Input**: Actual fix branch cloned via file:// with --depth 1; assert repository is shallow and bf5052b2 object absent, then run all scripts Node suites, including scripts/name-checks/*.test.mjs.
- **Expected output**: All tests pass without fetching old history or silently skipping history-dependent contracts.
- **Observable side effect**: Scratch clone and gate logs.
- **Assertion strategy**: Level 3 — actual shallow Git state and real Node process exit status/output.
- **Mock boundary**: none — real clone and test runner.
- **Refactor that would break this**: Introducing a historical-object requirement into always-run checks.

### Case: Future records and sanctioned acceptance remain legal but stale commands fail
- **Category**: state
- **Lane**: integration (Node scan fixture)
- **Spec level**: S5 — future unrelated commits must preserve scan result; wrong current identity must change it.
- **Input**: Real temp tracked repo or scratch clone: add ADR-0018 and validation record, append to an existing validation record, change a ledger acceptance under a later owner-approved fixture commit. Then insert Packages/PicseeKit or -scheme Picsee in current AGENTS prose.
- **Expected output**: Lasting scan passes all historical/acceptance evolution before the stale command, and fails after that command; no ancestor SHA lookup.
- **Observable side effect**: Fixture commits/files only.
- **Assertion strategy**: Level 1/3 — observable CLI/test verdict before and after actual file transitions.
- **Mock boundary**: none — real Git/filesystem and lasting scanner.
- **Refactor that would break this**: Reintroducing the original ticket's frozen historical constraints into permanent checks, or turning scanner into a no-op.

## Unit: One-shot rename-range check CLI

**Law**: Verdict is a function of the explicitly selected immutable base/head trees; later working-tree or repository changes outside that range are irrelevant. Within that range only the agreed note and narrow ledger substitutions are permitted.

### Case: Valid complete rename range passes with evidence
- **Category**: success
- **Lane**: integration (dedicated one-shot CLI tests, not fixed-range lasting tests)
- **Spec level**: S5 — exhaustive finite record/row preservation over chosen fixture trees.
- **Input**: Real fixture Git base/head commits with ADR/validation note additions and four allowed acceptance substitutions; include OPEN-08/CMD-01 limitation-only name fixes and literal pipes in code cells.
- **Expected output**: CLI --base <base> --head <head> exits 0 and names checked range/counts; current branch/working tree content is not used instead of those trees.
- **Observable side effect**: None beyond stdout.
- **Assertion strategy**: Level 1/3 — actual exit status and report for real Git content.
- **Mock boundary**: none — real CLI and Git.
- **Refactor that would break this**: Comparing the working tree rather than selected commits or dropping one protected record/row.

### Case: Range rejects corruption, omission and unrelated acceptance edits
- **Category**: failure
- **Lane**: integration (one-shot CLI fixture tests)
- **Spec level**: S3/S5 — reject known forbidden transitions across exhaustive protected content.
- **Input**: Separate fixture heads modifying an original ADR line, duplicating/omitting a former-name note, deleting/adding a frozen record, dropping a ledger row, editing a non-allowed acceptance word or an allowed row's condition beyond the app-name token.
- **Expected output**: Each exits nonzero and identifies affected record/row; only original allowed substitutions pass.
- **Observable side effect**: None beyond diagnostics.
- **Assertion strategy**: Level 1/3 — process status and relevant file/row diagnostic.
- **Mock boundary**: none — real fixture commits and CLI.
- **Refactor that would break this**: Broadening exceptions or normalizing all acceptance text.

### Case: Explicit revisions are required and outside-range evolution is irrelevant
- **Category**: guard
- **Lane**: integration (one-shot CLI fixture tests)
- **Spec level**: S3/S5 — invalid input rejection and chosen-range determinism.
- **Input**: Missing --base/--head, unknown argument, missing option value and nonexistent revisions. Separately, run against a valid chosen pair, then append a newer commit with a new ADR, validation edit and sanctioned acceptance change while retaining the original pair.
- **Expected output**: Invalid input fails loudly without a skipped-success result. Original pair still passes after later commits; selecting that later head is evaluated on its own content rather than silently ignored.
- **Observable side effect**: None beyond fixture commits and report.
- **Assertion strategy**: Level 1/3 — compare statuses/diagnostics and original-pair stable result before/after outside-range commits.
- **Mock boundary**: none — real CLI and Git object availability.
- **Refactor that would break this**: Defaulting to HEAD/bf5052b2, swallowing an absent object, or consulting the working tree.

## Unit: TDD lane discovery inventory

**Law**: Exact inventory contains the required docs-node manual lane; all heavy probes stay locked and native integration stays manual.

### Case: Docs receipt lane is included with lightweight probe exemption
- **Category**: success
- **Lane**: unit (existing swift-lane Node tests)
- **Spec level**: S2 — explicit complete configured lane set and heavy/Node partition.
- **Input**: Real config includes docs-node command node scripts/tdd/node-lane.mjs scripts/name-checks/living-docs.test.mjs, node --version probe and manual gateOn.
- **Expected output**: Exact inventory includes docs-node; Node probes are exempt from heavy-lock because no heavyweight discovery occurs; Swift/Xcode probes retain heavy-lock; integration stays manual.
- **Observable side effect**: None.
- **Assertion strategy**: Level 1 — complete name-set equality and lane command/probe/manual properties, with reason comment describing RED receipt necessity.
- **Mock boundary**: none — actual config.
- **Refactor that would break this**: Adding/removing a configured lane or changing its public resource-discovery contract.

## Unit: Release template fence

**Law**: Original notes-template bytes are restored and replay never mutates that #552 input.

### Case: Template restoration and replay exclusion
- **Category**: state
- **Lane**: integration (one-shot original range check plus replay fixture)
- **Spec level**: S5 — protected release-input preservation.
- **Input**: Actual restored template compared once to bf5052b2, and a temp replay fixture with docs/release/notes-template.md containing former-app artifact names.
- **Expected output**: Actual bytes equal baseline once; fixture template remains byte-identical after first and second replay; release README explicitly marks Mado tag/DMG procedure pending #552.
- **Observable side effect**: Other fixture prose may rename; template does not.
- **Assertion strategy**: Level 1/2 — exact bytes and pending-marker text in context of Mado release instructions.
- **Mock boundary**: none — actual file and real replay CLI.
- **Refactor that would break this**: Expanding replay scope to #552's release-template input or removing the pending condition.

## Coverage of the work item

| Criterion | Cases |
|---|---|
| Prompt globals and replay | All tracked prompts match actual exported namespaces; Replay keeps executable namespaces |
| Lasting history independence | Depth-1 branch runs every Node suite; Future records and sanctioned acceptance remain legal |
| One-shot range evidence | Three one-shot CLI cases; run actual original #553 selected range separately |
| Docs lane inventory | Docs receipt lane is included with lightweight probe exemption |
| #552 release fence | Template restoration and replay exclusion |
| Final gates/handoff | All Node suites full/depth1, ledger HTML, design, whitespace and documented fix→test map |

## Deferred

L1–L4, app/runtime changes and broader repo/tooling/release work stay deferred. No Swift changed, therefore no Swift/native or coverage rerun under the explicit fix brief. The new one-shot CLI's unit fixture tests are lasting; the original ticket's specific base/head invocation is one-time evidence only.
