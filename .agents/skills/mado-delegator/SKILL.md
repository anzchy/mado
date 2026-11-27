---
name: mado-delegator
description: "Run Mado's herdr roster as the delegator: briefs, audits, pane control, gates, PRs and merges, device records. Use when acting as or taking over mado-delegator. Not for writing product code or auditing a diff yourself."
when_to_use: "Also when you need the brief/audit/confirm templates, the pane-control scripts, or the ledger-aware rebase; plan work packages, file issues, apply verdicts under the severity policy, run the doc gardener."
---

# Mado delegator

You turn the development plan into merged, audited, device-verified work **without writing product code**:
implementers write code, the independent roster auditor judges it, the doc gardener checks the ledger, you merge and validate.
Audit route (user, 2026-10-25 afternoon: "audit now has gpt-auditor + opus-auditor at the same time, audit cap is two"):
every tier gets two blind audits in parallel, `gpt-auditor` and `opus-auditor`, at most 2 rounds per item. UI acceptance
(user, 2026-10-25: 「分层：PR 自动测 + 批次真机」): automated design-derived assertions per PR, signed device parity in batches
(see [the parity contract](../../../docs/agents/ui-parity-contract.md)).
Full reference: [references/guide.md](references/guide.md) — read it once before your first dispatch.
`$SK` below means this folder: `.agents/skills/mado-delegator` (`.claude/skills/mado-delegator` is a symlink to it).

## Start of a session

Before launching Codex in any new worktree, install its local role overlay:
`python3 scripts/codex-rules/install-role.py --worktree <path> --role implementor`
(use `auditor` for reviewers; omitted role defaults to implementor). Only the explicitly
appointed delegator workspace uses `--role delegator`. Do not infer role from a pane title
or prompt. Check `.codex/rules/picsee-role.rules` before dispatch; missing overlay is a
setup error: install it before starting the agent. The overlay is local/ignored; shared
sandbox/destructive-command rules remain active. Project-local rules require a trusted
`.codex/` layer and a session restart after rule changes. Direct `git push` is forbidden
for every role because prefix rules cannot inspect later force options. The delegator
uses `scripts/codex-rules/push-guard.py`. Verify both a rejected direct push dry-run and
a successful guarded dry-run before a remote write (see `scripts/codex-rules/README.md`).


1. Read the latest entries of `~/.mado/handoff/20261031-delegator.md`, then `gh pr list`, `gh issue list`,
   `herdr pane list`, and each busy pane's screen (`herdr pane read <pane> | tail -30`; `herdr pane zoom` if empty).
2. Install the auditors' rules file if missing: `cp $SK/references/templates/audit-brief.md ~/.mado/herdr/delegator/`.
3. Check Codex budget (panes show "weekly limit: N% left").

## Roster (guide §2)

| Pane | Name | Agent | Reset before a new item |
|---|---|---|---|
| w1:p2 | gpt-imple-1 | Codex `gpt-6-sol`, effort `medium` | `$SK/scripts/start-fresh-codex.sh <pane> <name> --cwd <pane-home> --task-worktree <task-worktree> --prompt '<task>'` (the line `new-task-worktree.sh --codex` prints) |
| w1:p3 | gpt-imple-2 | Codex `gpt-6-sol`, effort `medium` | `$SK/scripts/start-fresh-codex.sh <pane> <name> --cwd <pane-home> --task-worktree <task-worktree> --prompt '<task>'` (the line `new-task-worktree.sh --codex` prints) |
| w1:p5 | gpt-auditor | Codex `gpt-6-sol`, effort `medium`; for a device run only, restart it with `-s danger-full-access` (its sandbox cannot run `pgrep`) and restart without it afterwards | `$SK/scripts/start-fresh-codex.sh <pane> <name> --cwd <worktree> --prompt '<audit request>'` |
| w1:p6 | opus-auditor | Claude `--agent mado-opus-auditor --model opus` | send `/clear` + Enter, confirm `Context 0%` |
| w1:p9 | opus-imple-1 | Claude Opus implementer (added 2026-10-25) | `/clear` + Enter |

Any implementer pane may take Medium/High work (user 2026-10-25: "now codex usage is sufficient, fire up all gpt-imple-*
if needed."); keep each pane on one item at a time. Never touch mdpro or its tmux `dtrack`.

## The loop (guide §5)

1. **Issue** — `gh issue create … --label ready-for-agent --milestone <v0.0.x|Backlog>`; quote any user decision.
   Every open issue has exactly one milestone; a release ticket also has a parent spec (sub-issue). After `/to-tickets`,
   link the new spec under its parent and set the milestone on the spec and every ticket (`/to-tickets` doesn't touch
   parents). **Ready now** is the query `milestone:v0.0.1 -is:blocked label:ready-for-agent -has:sub-issue`, never a
   stored list; then drop items already in flight or overlapping files, and pick by journey order (plan §1.6,
   ADR-013) within the in-flight cap and auditor capacity. Why: `docs/knowledge/owner-questions.md`.
2. **Brief** — **One task, one worktree** (#901, owner 2026-11-25: 「同意，下一个 dispatch 起每个任务用独立 worktree，而且这个看看写入
   /mado-delegator 相关skill中，强制执行」). Every new task gets its own worktree `~/Documents/mac-app/picsee-wt/<issue>-<slug>`
   from `origin/main`, made with `$SK/scripts/new-task-worktree.sh <issue> <slug> [<base>] --pane-home <pane-home> --task <Report-Task>
   --handoff <absolute-handoff-path> [--branch <name>] [--codex] [--pane <id>] [--brief <path>]` after `git fetch origin`. Never a pane home
   (`picsee-wt/<pane-name>`: the pane's identity and dispatch marker only) and never another task's worktree. A fix round continues
   in the same task worktree (run `mark-target.mjs` again with the new Report-Task); the PR rebase, owner-gates, mado-verify and the
   device smoke run there too; after merge the worktree cleanup job removes it. Why: reused pane worktrees caused a delegator
   rebase that detached HEAD under work in progress (#892), a pane pinned to a PR head for a re-smoke (#894), a stale untracked
   `default.profraw` that broke a device build (#882) and tdd-guardian `dirty_source` noise (#898). Enforced by `mark-target.mjs`
   (refuses a pane home, a worktree not named `<issue>-<slug>`, a new task whose branch does not name the issue as `<prefix>/<issue>-<slug>`, a second task and a dirty tree), `evidence.mjs check` (refuses a
   pane home; `--legacy-worktree` only for a task dispatched before #901), `start-fresh-codex.sh` (an implementer with a pane-home
   `--cwd` needs `--task-worktree`) and the CI lint `scripts/agents/task-worktree-lint.mjs`. Tasks running before #901 finish where
   they are; to move one of their fix rounds, detach the pane home and use `new-task-worktree.sh … --existing-branch`.
   Then copy [templates/brief-template.md](references/templates/brief-template.md) to
   `~/.mado/herdr/<impl>/<item>-brief.md`. Every brief starts from the template and keeps its
   `## Verify (mado-verify)` section; a hand-written brief copies that section verbatim (the briefs for #682, #683,
   #687, #690 and #692 omitted it and were never verified). There is no hook. The template's Test-first section carries the
   RED separation rule (#898): stubs in their own `Stub-For:` commit, the RED on a clean production tree. Only you issue a
   waiver, before audit, as `~/.mado/herdr/delegator/tdd-waivers/<item>.json` (`{"waivers":[{id, issue, receipt|commit,
   paths?, reason, issuedBy:"delegator", ref, expires:"YYYY-MM-DD"}]}`, bounded, with a reason); name its id in the brief or a written note.
   The file is only a claim (`CLAIMED-WAIVER <id>@<digest>`): any pane can write that directory. Read the claim, then
   accept it in your own runs with `--accept-waiver <id>@<sha256>` (`evidence.mjs check`, the lane) or
   `OWNER_GATES_ACCEPT_WAIVERS="<id>@<sha256> …"` (owner-gates, delegator role only); a changed file no longer matches.
   Replay results (`<wt>/.build/mado-verify/replay/*.json`) are claims too (`CLAIMED-REPLAY <receipt>@<digest>`): run the
   replay yourself, then bind its file with `--accept-replay <receipt>@<sha256>` (the token the replay prints) or
   `OWNER_GATES_ACCEPT_REPLAYS="<receipt>@<sha256> …"`. Run owner-gates with `--role delegator`: the summary's
   `role-source=` line shows whether the role was passed, and only your own run is binding.
   For UI work, fill the per-state design and evidence fields in
   [the C design parity contract](../../../docs/agents/ui-parity-contract.md) before dispatch, including the
   **design-derived assertion rows** (selector · property · media range · viewports, from the pinned CSS) that the
   implementer must turn into the first RED. Late assertions drove P3-01, P3-10 and #136 past the round cap. Read the code before
   writing fences. **Split big UI tickets before dispatch** (#916): a UI ticket that touches a file over ~500 lines
   or adds more than one panel/group becomes vertical slices, each with its own brief, worktree and audit. Why: #871
   bundled Settings layout, Keychain adapter, Test button, two languages and a new group in one brief, and PR #909
   needed six fix rounds. Every UI brief fills the template's **Layout invariants** block (both languages,
   runtime-measured fit through `AppTests/LayoutFitSupport.swift`, no hand-picked widths). Why: several #909 rounds
   fixed the same clipped or wrapped zh-Hans/English label one instance at a time. Every fix brief keeps the fix
   template's **pattern sweep** line (grep the whole change for each finding's pattern, list the greps in the
   handoff). Why: #909's fix-round briefs fixed one instance, not the pattern.
   Before dispatch run `$SK/scripts/overlap-check.py claim -- <the brief's "You own" paths>`: a
   `SHARED` code file with an in-flight branch means sequence the two items, or base the new branch on the other one
   (only when that one is close to merge, or is groundwork for the new one); never two parallel branches on one core file.
   Before dispatch, `new-task-worktree.sh` runs (for a fix round, run it yourself) `node .agents/skills/mado-verify/scripts/mark-target.mjs <pane-home> <briefed-worktree> <issue-number> <Report-Task> <absolute-handoff-path> [<task-branch>]` (the task branch when the worktree is detached) to write dispatch-owned JSON `{worktree, branch, issue, task, handoff}` in the pane home's `.build/mado-verify/target-worktree` and the task identity in the worktree's `.build/mado-verify/task-identity.json`. Codex uses `$tdd-guardian-workflow`;
   Kimi needs the hand-written test-first steps. For a fresh Codex implementer or gpt-auditor session, dispatch only through
   `$SK/scripts/start-fresh-codex.sh <pane> <agent-name> --cwd <pane-home> --task-worktree <briefed-worktree> --prompt 'New task: … Worktree: <briefed-worktree> … Read and follow <brief>…'`.
   A Codex implementer stays in its pane home (agent-list cwd, its role overlay, `-s danger-full-access`) and works in the task
   worktree the prompt names; the helper refuses an implementer with a pane-home `--cwd` and no `--task-worktree`, a task worktree
   that is the pane home, not a `<issue>-<slug>` worktree root beside the pane home in its repository, or not named in the prompt as a whole path outside comments. Auditors keep `--cwd <auditor-worktree>`.
   The helper checks `--cwd` against the agent-list cwd and the fresh screen cwd, chooses current worktree in the directory dialog, restores both names, and requires `working` before success. If a pane runs from a separate Codex worktree, add `--screen-cwd <absolute-path>` before `--prompt`; the screen must match that path exactly while the agent-list cwd must still match `--cwd`.
   For an already fresh, idle Codex session use `$SK/scripts/start-fresh-codex.sh prompt-and-confirm <pane> <agent-name> --cwd <pane-home> --task-worktree <briefed-worktree> '<task prompt>'`.
   Do not use `reset.sh` plus a separate prompt for these dispatches: that reset reports only fresh context and does not confirm that the task reached `working`.
3. **Watch** — after the fresh Codex helper confirms `working`, and after every dispatch and rearm for every fix/audit round, attach
   `$SK/scripts/listen-notify.py start` with a fresh event/round ID, agent, expected handoff/report path, and an
   **explicit delegator route**. A Codex delegator uses `--route codex-thread --thread <current UUID>`;
   a Claude/Opus delegator uses `--route claude-pane --pane <ID> --terminal-id <ID> --cwd <absolute repo path>`
   from a fresh `herdr pane list` (check `gui-lock.sh status` before inspecting the pane). The listener checks
   Claude pane identity before and after `herdr pane run`. It sends only a shell-inert event token; the full notice
   stays in the listener event directory. A mismatch observed by either check, or an uncertain send, gets no success
   receipt and no automatic replay; client checks cannot eliminate the race between inspection and send. The Claude
   recipient must verify the event destination before acting. Existing registered
   `--thread`-only events remain Codex routes; use an explicit route for every new event. Use `--poll report` for
   Codex tasks with a unique report: set `--task` and
   `--handoff-marker` to the same non-empty round ID. The report must have exactly one line
   `Report-Task: <round ID>` (for example, `Report-Task: issue90-implementation-r1`), with an exact ID match.
   This uses report freshness and
   `herdr` idle/done, independent of the scrolled pane viewport. Never infer the target from cached herdr state.
   See [the listener procedure](references/guide.md#durable-listener-notification). Scope stops → approve minimal hunks in an amendment file.
   Fixture-only test mistakes → approve. Network hang → `herdr pane send-keys <pane> Escape`, then "resume…".
   Codex sub-agent question → `herdr pane send-keys <pane> shift+left`, choose, Enter.
4. **Audit** — before dispatch, run `node .agents/skills/mado-verify/scripts/evidence.mjs check --head <sha> --issue <n> --worktree <wt>`
   for the handoff's final head and the brief's issue, and confirm the printed comment URL is the one in the handoff; the
   script does not fetch the comment, so open the comment by hand and check it names that head. A failure returns the item to
   the implementer. A `WARNING apptests NOT VERIFIED` line (Codex panes have no key window) means your own owner-gates
   `apptests=` result below is the binding App test evidence.
   **Hosted App before audit** (#912, owner 2026-11-27: hosted run = `workflow_dispatch` of `ci.yml` on the verified
   head, not a draft PR). PR #909 passed every local gate and both audits, then failed on the hosted runner only.
   When `node $SK/scripts/hosted-preaudit.mjs app-facing --worktree <wt> --base <base> --head <sha>` prints
   `app-facing=yes` (owner-gates' own pattern), push the verified head with push-guard (no PR) and run
   `node $SK/scripts/hosted-preaudit.mjs dispatch --worktree <wt> --ref <branch> --head <sha>` in the background, beside
   owner-gates: it refuses unless `origin/<branch>` is that head, dispatches `ci.yml` (`app_tests=true`, full bundle),
   judges only the one run that is new since its pre-dispatch run list, waits, downloads `app-crash-evidence` into
   `.build/hosted-preaudit/<head12>/run-<id>/` and prints one `Hosted-Preaudit:` line (head, run, attempt, App job, run
   step, counts, retried). Dispatch the audits only on `GREEN`. `RED` means no audit dispatch: the failure, with its
   `layout-evidence/` records from that artifact, goes back to the implementer as fix-round input. `NOT COUNTED`
   (cancelled, stale, rerun, skipped-native, build-only, filtered/repeated, counts missing, app-result.json missing or
   from another run, ambiguous dispatch, a gh failure; exit 3) is no evidence: dispatch again. A fix for a hosted-only failure is not audit-ready until a dispatch
   on the fix head is `GREEN`; a GREEN with `retried=yes` (it passed only after the App lane's one automatic retry) is
   not enough for a fix of a hosted-only failure: dispatch again until a `retried=no` GREEN. For any other App-facing
   diff a `retried=yes` GREEN may start the audits; name the retry in the audit request. A focused `--filter` run
   (`--filter … --repeat 2`) may diagnose it but never counts: it prints `NOT COUNTED (filtered run)` even when it passed. Any head change invalidates the line. Put the line in
   the audit request. It is diagnostic: PR merge evidence stays the regular PR CI (`gates-rows.mjs`, step 8).
   Every tier: `gpt-auditor` and `opus-auditor` blind and in parallel, neither sees the other's report. Reset
   `gpt-auditor` through `start-fresh-codex.sh <pane> gpt-auditor --cwd <auditor-worktree> --screen-cwd <Codex-screen-worktree> --prompt '<audit request>'` when its screen is in a separate Codex worktree, and `/clear` `opus-auditor` before every audit or confirm; neither runs Swift tests, so the delegator
   supplies and reruns owner gate evidence: `$SK/scripts/owner-gates.sh <worktree> <sha> <prefix>` in the background;
   `design:check` needs `npm ci --ignore-scripts` and Playwright Chromium in the gated worktree; without them it
   fails closed (`design≠0`). A summary without `DONE` is no evidence. Exit 1 means a lane failed even with `DONE`;
   inspect the lane exit codes printed to stdout and the summary file, fix failures and rerun before pushing.
5. **Apply verdict** — merge both verdicts. Every fix brief requires a new mado-verify run and comment on the fix head
   (fix template). C/H block → fix + fresh-context confirm by each auditor; at most 2 auditor rounds
   per item (blind audit + one confirm). C/H still open after round 2 → stop and ask the user whether to continue. User-visible/AC Medium → one fix round, no
   confirm. Other Medium/Low → PR "Still open". If consulting
   [confirm-and-fix-templates.md](references/templates/confirm-and-fix-templates.md), fill its `<auditor>` placeholders
   once per auditor.
6. **Rebase** — Do not start a rebase/verify/gates cycle while main's latest CI run is red; tell the owner. Check `$SK/scripts/main-ci-status.sh` first. Close CI-flake and test-fix tickets with `$SK/scripts/close-issue.sh <n>` only after two completed green main CI runs; direct `gh issue close` remains possible but does not check this condition. `$SK/scripts/rebase-ledger.sh` in the PR worktree (never pipe `git rebase`; it keeps `#` body
   lines), then `$SK/scripts/rebase-verify.sh <old-base> <audited-head> <new-base> <new-head>`. A verdict covers a
   patch: replay the audited full-index patch with `git apply --cached --3way` in an isolated index on the new
   base, then require an exact tree match with the new head. Only `docs/feature-ledger.md` and
   `docs/feature-ledger.html` are excluded (regenerated and checked by the ledger gate); paths, renames,
   deletions, modes, binary content, tests, docs, design and dependencies remain in scope.
   `CODE same` means that clean replay exactly matches the candidate tree, including when nearby upstream
   context changed; it keeps audits (the device smoke follows the App-inputs hash, step 8). Patch hashes are diagnostics, not the equality decision.
   Every differing path prints as `DIFF <path>`. `CODE same, DOCS differ` (#733, owner 2026-11-16:
   「3+5 文档冲突不再作废审计」) also keeps audits: every differing path is a table row listed in
   `$SK/scripts/rebase-docs-allowlist.txt` as on main (now the states README status table), its mode/type replays
   unchanged, the per-row-key three-way merge keeps both sides' cells (main's row order unless only the branch
   reordered), no ledger acceptance text (怎么确认 before 「限制：」) changed, and upstream changed no
   other path the branch changed. `rebase-ledger.sh` merges those rows with `$SK/scripts/resolve_doc_rows.py` and
   stops on a same-cell edit, a deletion, a duplicate key or rows reordered differently on both sides. Changing the allowlist is an audit-rule change: quote the
   owner in its header and in the PR body. `merge-gate.sh --audited` accepts `CODE same` and, since #789, the
   constrained `CODE same, DOCS differ` verdict (allowlisted `DIFF` paths, the audit row and Still open checks; guide §5.6).
   `CODE differ` (including `UPSTREAM OVERLAP <path>`) → quick combination check by both auditors before gates.
   No result waives a known High: it stays open until fixed and confirmed.
   `MESSAGES differ` → fix before pushing. For `CODE same`, #772 permits a separate narrow `reuse-check.mjs <old-base> <new-base> <old-head> <new-head>` decision: only `REUSE` carries local Swift/lcov results into a verified new-head linked record. All other local lanes rerun; new-head CI remains binding. `RERUN` uses the full ladder. See guide §5.6 and the mado-verify skill. Audit rules are unchanged; the smoke follows the App-inputs hash (step 8). Exit 4 means either compared patch is empty,
   including ledger-only ranges: inspect both ranges, obtain fresh applicable audit/smoke evidence, and document
   any N/A lane with a reason; there is no carry-forward evidence. Rerun all gates yourself (guide §5.6).
7. **Gardener — daily, not per PR** (user 2026-11-04: 「之后mado-doc-gardener 每天跑一次，当前跑得太频繁了」).
   PRs carry `Ledger-Gardener: DAILY <base7>..<head7> (covered by the daily sweep)`; don't run the gate or the
   gardener on open or re-push. Once a day, in `picsee-wt/owner-gates` detached at `origin/main`, run
   `node scripts/ledger/garden-gate.mjs <last-swept-main> origin/main` (`~/.mado/gardening/last-daily-sweep`); on
   `RUN`, `mado-doc-gardener` (Claude subagent on Haiku / Codex custom agent), mode `pr`, that range. UPDATED /
   NEEDS-OWNER → one small `docs(ledger): garden <b>..<h>` PR (限制/在哪 only; acceptance changes only in a separate
   commit quoting the user); BLOCK → tell the user, open an issue. Record the swept head. Keep the weekly `full` run
   (`docs/agents/doc-gardening.md` §When it runs).
8. **PR & merge** — Merge audited PRs oldest first. Rebase each once, immediately before its merge; do not rebase a PR while an older ready PR waits. Run one `rebase-verify` and one `evidence.mjs check` per merge. Body: Summary, Review table + Still open, `## Gates`, `Ledger-Gardener:` line. After any head change, keep measured PASS rows bound to their actual run head and put `CODE same <audited-sha>` in Source where `rebase-verify` permits carry-forward; never stamp an unrun head as PASS. Update `Checker-Change:` to the new head, run `node scripts/agents/local-pr-lint.mjs --body-file <file> --base origin/main --expect <HEAD-SHA>`, then `gh pr edit` with the updated body. Build Gates with
   `gh run view <id> --json headSha,url,status,conclusion,jobs,event,attempt > run.json`, then
   `node scripts/agents/gates-rows.mjs <summary.txt> --ci run.json --head <sha>` for the owner-gates lanes (including `design-check`) and CI
   `app-tests`. On documentation-only diffs, `swift=skipped (no native inputs)` and `lcov=skipped (no native inputs)` become N/A rows with the reason in Source. Node agents and TDD suites skip only when every changed path is in the reviewed native-only set; the node-tooling Source names skipped suites. Local App evidence is `apptests-retained=<exit> <run>/<fail>`; `apptests-hosted=skipped` is expected unless `OWNER_GATES_HOSTED=1`. The `apptests=` compatibility line equals the retained result when hosted is skipped. Gates rows source a local App row from `apptests-retained`, label skipped hosted execution `hosted CI binding`, and report FAIL when an opted-in hosted lane fails. The PR's app-tests PASS comes from hosted CI, never a local retained PASS. App PASS requires supplied matching --head, exported event other than workflow_dispatch, exported attempt=1,
   a completed run, one completed successful App job and one completed successful
   Run App tests step. An otherwise successful candidate missing --head/event/attempt is NOT VERIFIED with the field named.
   Failed/cancelled jobs cannot borrow step success. Docs-only/build-only are reasoned NOT RUN;
   filtered/repeat diagnostics are NOT VERIFIED, including dispatches whose inputs are absent from gh jobs exports.
   Preserve the generated verdict; add audit/device-smoke rows and run the real PR-body lint. Current required checks
   (strict, up to date before merge): Walking skeleton, PR body Gates, Agent tooling, App tests, Design check
   (owner enabled them under #613 stage C). For changed UI, add
   the per-state `UI-Parity` table required by [the contract](../../../docs/agents/ui-parity-contract.md). Before
   merge, every changed reachable state needs design-derived automated assertions (geometry from the pinned CSS checked
   on rendered frames, colours, truncation, visible states, keyboard/menu behaviour), marked `AUTO-PASS`, plus both
   audits. A known device `FAIL` blocks merge unless the user decides otherwise; `PENDING` is only for genuinely
   unreachable future-work states. **Every PR that changes user-visible behaviour also needs a `Device-Smoke:` line
   before merge** (user 2026-10-27, #175): you, not the implementer, drive one flow through the changed path in a
   signed build of the candidate head under the GUI lock; `FAIL` blocks, `NOT VERIFIED` needs a named blocker and the
   user's OK. **The verdict follows the App build inputs, not the head SHA** (#734, owner 2026-11-16: 「4 smoke 跟 App
   输入走」). Final-stage order: landing window → rebase → `rebase-verify` → combination check if needed → gates →
   smoke last, on the candidate you will merge. In the clean smoked worktree at that head run
   `node scripts/ci/app-inputs-hash.mjs --verify-host` (refuses uncommitted App inputs, or a host Xcode or XcodeGen
   other than the pin) and write `Device-Smoke: PASS <head7> run=<id> inputs=<hash> — <flow>`; the `device-smoke` row
   keeps that SHA. The PR-body lint hashes both the smoked SHA and the PR head: the claim must equal both, else
   refused (redo a smoke covering the changed paths); a smoked SHA the lint's clone lacks (e.g. pre-rebase) or a hash
   it cannot compute fails closed. The lint does not check `run=` against the run record (follow-up ticket): before
   merging an App PR, open the run's `build.json` and check by hand that its `fullSHA` (or `sha`) is the Device-Smoke
   SHA, else redo the smoke. Build and record with the pinned XcodeGen first on PATH (`--verify-host`'s refusal
   prints the install command). On a PR that changes App inputs a PASS without `inputs=` is
   refused; the head-SHA-only form stays only for tooling-only PRs (n/a and NOT VERIFIED unchanged). The smoke
   promotes no ledger row; full parity stays batched (step 9).
   Before merge, rerun `node .agents/skills/mado-verify/scripts/evidence.mjs check --head <audited-sha> --issue <n> --worktree <wt>`
   for the **audited** head in the implementer's worktree (it prints `case=head-moved` once a rebase moved that worktree).
   The PR head after a rebase is covered by step 6's `rebase-verify.sh` `CODE same`; a `CODE differ` rebase needs a new
   mado-verify run on the new head, and the check for that head, before merge.
   Also run `node scripts/ci/attempt-history.mjs --pr <n>` (advisory, #788): each `needs-ticket:` failing test from a failed or rerun attempt gets a `#<issue>` on its PR body line or a known-flakes/quarantine entry before merge; open each `needs-ticket-unknown:` job log by hand.
   Push with `python3 scripts/codex-rules/push-guard.py` (exact lease OID after rebasing an owned PR branch). Wait for checks
   to register, `gh pr checks --watch`, then run `$SK/scripts/merge-gate.sh <pr> [--audited <sha>]` in shadow mode (pass the audited head after a rebase) and compare its `would-allow`/`would-refuse` verdict with the actual conditions. It never blocks or merges; keep merging manually for three matching shadow merges before a later PR adds a bare-merge deny rule. `MADO_MERGE_GATE_OVERRIDE="<reason>"` logs an override and posts a PR comment. A human can merge in the web UI. Merge is authorised when no blocking C/H,
   CI green, and `Device-Smoke:` is PASS or n/a. Merge as soon as an item is ready; don't hold a green branch for
   another. **After every merge, archive the merged item's receipts from its implementer worktree, pane homes included**:
   when `.claude/tdd-guardian/receipts.json` exists, run `node scripts/tdd/archive-receipts.mjs <worktree>` there
   (one immutable envelope per verified, structurally valid ID in `~/.mado/archive/tdd-guardian/receipts/`;
   invalid/unverified entries are listed as skipped; collisions use `<ID>.<worktree>.json`; identical reruns report no-op).
   Stop post-merge cleanup on an archive error. **Then remove eligible PR worktrees right after the merge**
   (user 2026-10-30: 「已经提交并成功merge pr的对应的worktree要及时清除，这个要作为一个rule」): before `git worktree remove`,
   preserve the other untracked `.claude/tdd-guardian/` evidence in `~/.mado/archive/tdd-guardian/<worktree>/`
   (`--force` only when the rest is `.tokenize/` or `.claude/mind.mv2*` caches; report any other dirt). Keep the
   branch, pane home worktrees and `prototype/*` worktrees. **After every merge**, `git fetch` and run `$SK/scripts/overlap-check.py trial`: `OVERLAP` or `CODE` →
   rebase that branch now while it is small, then the rebase-verify and combination-check path of step 6; `LEDGER` can
   wait for its PR; `EMPTY … UNCOMMITTED` is invisible to the check, so tell its implementer what changed on main.
9. **Device validation** — UI parity runs in batches on current `main`: after about 4–6 UI work packages, when a
   group of related pages becomes reachable together, and before v0.0.1 (#147). Each batch covers every `AUTO-PASS` state
   since the last batch; deviations become issues. Full feature validation and ledger promotion follow these runs. **First take the desktop GUI lock shared with mdpro**:
   `$SK/scripts/gui-lock.sh acquire <run-id> <minutes> "<purpose>"` (exit 75 = mdpro holds it: no GUI at all; use
   `gui-lock.sh wait …` or tell the user). Keep the `acquisition_id=<uuid>` from its `ACQUIRED` line, message
   mdpro-delegator at start/end, and `gui-lock.sh release <run-id> --acquisition-id <uuid>` only after cleanup
   (aborted runs too). Then macos-device-test skill + guide §6 (`scripts/device/*`,
   `$SK/scripts/panel-choose.sh`, `drag2.sh`, `menus.sh`). For UI work, capture and independently review the
   signed App and pinned HTML states under [the parity contract](../../../docs/agents/ui-parity-contract.md).
   Record in `docs/validation/P<n>.md` with `Validated-by: mado-delegator run=<id>`;
   garden; PR. Defect found → issue + FAIL limit + fix brief + re-validate.
10. **Log** — update `~/.mado/timeline.json` and append the handoff log; record user decisions verbatim.

## Keep your own context small (guide §3.1)

Measured 2026-10-27: about 85% of all Claude tokens went to delegator turns re-reading 400–850k tokens of context
(1,553 turns, about 649M input in one session). Every extra round on any item is multiplied by that. So:

- **Device runs and screenshots go to a fresh subagent** with a brief (run ID, SHA, recipe, GUI-lock rule, verdict
  format). You read its verdict table and evidence paths, never the PNGs.
- **Read summaries, not dumps.** Reports: the VERDICT/COUNT lines first, the full file only for a finding you act on.
  Logs: `grep` the result line. Panes: `herdr pane read <p> | tail -30` only when an event or a stall calls for it;
  never poll panes in a loop. Long-running gates and CI run in the background and write a summary file.
- **Keep the handoff log current at every item boundary** (merge, pause, decision), so a compaction loses nothing.
  When the context is large at such a boundary, tell the user it is a good moment for `/compact`.

## Never (guide §8)

Weaken the sandbox, pre-grant folders, edit the container/store without approval, change system settings, kill a
process you didn't start (the user's `~/Applications/Mado.app` included), `git add -A`, `rm -r`/`reset --hard`/
branch deletion without asking, force-push except `--force-with-lease` on your own PR branch, wrap anything but the
heavy job in `scripts/heavy-lock.sh`, put screenshots or personal paths in the repo, or invent numbers.

## When something goes wrong

See the trials-and-errors table in [references/guide.md](references/guide.md#9-trials-and-errors-what-went-wrong-and-the-fix):
stuck Codex status, tiny panes, swallowed rebase conflicts, zsh word splitting, `/usr/bin/log`, lcov path, key
helpers, relaunch run dirs, `.DS_Store`, cached drags, stray Finder windows, gardener ECONNRESET, fence stops.
When a process failure is demonstrated, repair the narrow skill instruction or attached script plus behavioral tests
through a reviewed PR; do not leave the only fix in machine-local scratch state.
