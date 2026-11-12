---
name: picsee-delegator
description: Run Mado's herdr roster as the delegator — plan work packages, file issues, write implementer briefs and blind audit requests, drive Codex/Claude/Kimi panes (start, reset, poll, unblock), apply verdicts under the severity policy, rebase and run gates, run the doc gardener, open and merge PRs, and do device validation records. Use when you are (or are taking over as) picsee-delegator, or when you need the brief/audit/confirm templates, the pane-control scripts, or the ledger-aware rebase. Not for implementing product code or auditing a diff yourself.
---

# Mado delegator

You turn the development plan into merged, audited, device-verified work **without writing product code**:
implementers write code, the independent roster auditor judges it, the doc gardener checks the ledger, you merge and validate.
Audit route (user, 2026-10-25 afternoon: "audit now has gpt-auditor + opus-auditor at the same time, audit cap is two"):
every tier gets two blind audits in parallel, `gpt-auditor` and `opus-auditor`, at most 2 rounds per item. UI acceptance
(user, 2026-10-25: 「分层：PR 自动测 + 批次真机」): automated design-derived assertions per PR, signed device parity in batches
(see [the parity contract](../../../docs/agents/ui-parity-contract.md)).
Full reference: [references/guide.md](references/guide.md) — read it once before your first dispatch.
`$SK` below means this folder: `.agents/skills/picsee-delegator` (`.claude/skills/picsee-delegator` is a symlink to it).

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


1. Read the latest entries of `~/.picsee/handoff/20261022-migrate-to-mini.md`, then `gh pr list`, `gh issue list`,
   `herdr pane list`, and each busy pane's screen (`herdr pane read <pane> | tail -30`; `herdr pane zoom` if empty).
2. Install the auditors' rules file if missing: `cp $SK/references/templates/audit-brief.md ~/.picsee/herdr/delegator/`.
3. Check Codex budget (panes show "weekly limit: N% left").

## Roster (guide §2)

| Pane | Name | Agent | Reset before a new item |
|---|---|---|---|
| w1:p2 | gpt-imple-1 | Codex `gpt-6-sol`, effort `medium` | `$SK/scripts/reset.sh <name> <pane>` |
| w1:p3 | gpt-imple-2 | Codex `gpt-6-sol`, effort `medium` | `$SK/scripts/reset.sh <name> <pane>` |
| w1:p4 | gpt-imple-3 | Codex `gpt-6-sol`, effort `medium` | `$SK/scripts/reset.sh` |
| w1:p5 | gpt-auditor | Codex `gpt-6-sol`, effort `medium`; for a device run only, restart it with `-s danger-full-access` (its sandbox cannot run `pgrep`) and restart without it afterwards | `$SK/scripts/reset.sh` |
| w1:p6 | opus-auditor | Claude `--agent picsee-opus-auditor --model opus` | send `/clear` + Enter, confirm `Context 0%` |
| w1:p9 | opus-imple-1 | Claude Opus implementer (added 2026-10-25) | `/clear` + Enter |
| w1:p7 | kimi-imple-1 | Kimi `-m kimi-code/k3.1-pro`, effort **high** (user rule) | `/new` + Enter |

Any implementer pane may take Medium/High work (user 2026-10-25: "now codex usage is sufficient, fire up all gpt-imple-*
if needed."); keep each pane on one item at a time. Never touch mdpro or its tmux `dtrack`.

## The loop (guide §5)

1. **Issue** — `gh issue create … --label ready-for-agent --milestone <v0.0.x|Backlog>`; quote any user decision.
   Every open issue has exactly one milestone; a release ticket also has a parent spec (sub-issue). After `/to-tickets`,
   link the new spec under its parent and set the milestone on the spec and every ticket (`/to-tickets` doesn't touch
   parents). **Ready now** is the query `milestone:v0.0.1 -is:blocked label:ready-for-agent -has:sub-issue`, never a
   stored list; then drop items already in flight or overlapping files, and pick by journey order (plan §1.6,
   ADR-013) within the in-flight cap and auditor capacity. Why: `docs/knowledge/owner-questions.md`.
2. **Brief** — copy [templates/brief-template.md](references/templates/brief-template.md) to
   `~/.picsee/herdr/<impl>/<item>-brief.md`. For UI work, fill the per-state design and evidence fields in
   [the C design parity contract](../../../docs/agents/ui-parity-contract.md) before dispatch, including the
   **design-derived assertion rows** (selector · property · media range · viewports, from the pinned CSS) that the
   implementer must turn into the first RED. Late assertions drove P3-01, P3-10 and #136 past the round cap. Read the code before
   writing fences. Before dispatch run `$SK/scripts/overlap-check.py claim -- <the brief's "You own" paths>`: a
   `SHARED` code file with an in-flight branch means sequence the two items, or base the new branch on the other one
   (only when that one is close to merge, or is groundwork for the new one); never two parallel branches on one core file.
   Before dispatch, run `node .agents/skills/mado-verify/scripts/mark-target.mjs <pane-home> <briefed-worktree> <issue-number> <Report-Task> <absolute-handoff-path>` to write dispatch-owned JSON `{worktree, branch, issue, task, handoff}` in the pane home's `.build/mado-verify/target-worktree`. Pane homes must be on a branch containing `.codex/hooks.json` after merge; trust the Codex project hook with `/hooks`, and accept Claude implementer pane workspace trust so agent-frontmatter hooks run. Codex uses `$tdd-guardian-workflow`;
   Kimi needs the hand-written test-first steps. Dispatch: `herdr agent prompt <impl> 'New task: … Read and follow <brief>…'`.
3. **Watch** — mandatory after every dispatch and rearm for every fix/audit round: attach
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
4. **Audit** — before dispatch, check the handoff's mado-verify issue comment link covers its final head SHA. Every tier: `gpt-auditor` and `opus-auditor` blind and in parallel, neither sees the other's report. Reset
   `gpt-auditor` and `/clear` `opus-auditor` before every audit or confirm; neither runs Swift tests, so the delegator
   supplies and reruns owner gate evidence: `$SK/scripts/owner-gates.sh <worktree> <sha> <prefix>` in the background;
   `design:check` needs `npm ci --ignore-scripts` and Playwright Chromium in the gated worktree; without them it
   fails closed (`design≠0`). A summary without `DONE` is no evidence. Exit 1 means a lane failed even with `DONE`;
   inspect the lane exit codes printed to stdout and the summary file, fix failures and rerun before pushing.
5. **Apply verdict** — merge both verdicts. C/H block → fix + fresh-context confirm by each auditor; at most 2 auditor rounds
   per item (blind audit + one confirm). C/H still open after round 2 → stop and ask the user whether to continue. User-visible/AC Medium → one fix round, no
   confirm. Other Medium/Low → PR "Still open". If consulting
   [confirm-and-fix-templates.md](references/templates/confirm-and-fix-templates.md), fill its `<auditor>` placeholders
   once per auditor.
6. **Rebase** — `$SK/scripts/rebase-ledger.sh` in the PR worktree (never pipe `git rebase`; it keeps `#` body
   lines), then `$SK/scripts/rebase-verify.sh <old-base> <audited-head> <new-base> <new-head>`. A verdict covers a
   patch: replay the audited full-index patch with `git apply --cached --3way` in an isolated index on the new
   base, then require an exact tree match with the new head. Only `docs/feature-ledger.md` and
   `docs/feature-ledger.html` are excluded (regenerated and checked by the ledger gate); paths, renames,
   deletions, modes, binary content, tests, docs, design and dependencies remain in scope.
   `CODE same` means that clean replay exactly matches the candidate tree, including when nearby upstream
   context changed; it keeps audits and smoke. Patch hashes are diagnostics, not the equality decision.
   `CODE differ` → quick combination check by both auditors before gates.
   `MESSAGES differ` → fix before pushing. Exit 4 means either compared patch is empty,
   including ledger-only ranges: inspect both ranges, obtain fresh applicable audit/smoke evidence, and document
   any N/A lane with a reason; there is no carry-forward evidence. Rerun all gates yourself (guide §5.6).
7. **Gardener — daily, not per PR** (user 2026-11-04: 「之后picsee-doc-gardener 每天跑一次，当前跑得太频繁了」).
   PRs carry `Ledger-Gardener: DAILY <base7>..<head7> (covered by the daily sweep)`; don't run the gate or the
   gardener on open or re-push. Once a day, in `picsee-wt/owner-gates` detached at `origin/main`, run
   `node scripts/ledger/garden-gate.mjs <last-swept-main> origin/main` (`~/.picsee/gardening/last-daily-sweep`); on
   `RUN`, `picsee-doc-gardener` (Claude subagent on Haiku / Codex custom agent), mode `pr`, that range. UPDATED /
   NEEDS-OWNER → one small `docs(ledger): garden <b>..<h>` PR (限制/在哪 only; acceptance changes only in a separate
   commit quoting the user); BLOCK → tell the user, open an issue. Record the swept head. Keep the weekly `full` run
   (`docs/agents/doc-gardening.md` §When it runs).
8. **PR & merge** — body: Summary, Review table + Still open, `## Gates`, `Ledger-Gardener:` line. Build Gates with
   `gh run view <id> --json headSha,url,status,conclusion,jobs,event,attempt > run.json`, then
   `node scripts/agents/gates-rows.mjs <summary.txt> --ci run.json --head <sha>` for the seven owner-gates lanes (including `design-check`) and CI
   `app-tests`. App PASS requires supplied matching --head, exported event other than workflow_dispatch, exported attempt=1,
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
   signed build of the PR head under the GUI lock; `FAIL` blocks, `NOT VERIFIED` needs a named blocker and the user's
   OK, App code changed since → redo. The smoke promotes no ledger row; full parity stays batched (step 9).
   Push with `python3 scripts/codex-rules/push-guard.py` (exact lease OID after rebasing an owned PR branch). Wait for checks
   to register, `gh pr checks --watch`, then `gh pr merge --rebase` (authorised when no blocking C/H,
   CI green, and `Device-Smoke:` is PASS or n/a). Merge as soon as an item is ready; don't hold a green branch for
   another. **After every merge, archive the merged item's receipts from its implementer worktree, pane homes included**:
   when `.claude/tdd-guardian/receipts.json` exists, run `node scripts/tdd/archive-receipts.mjs <worktree>` there
   (one immutable envelope per verified, structurally valid ID in `~/.picsee/archive/tdd-guardian/receipts/`;
   invalid/unverified entries are listed as skipped; collisions use `<ID>.<worktree>.json`; identical reruns report no-op).
   Stop post-merge cleanup on an archive error. **Then remove eligible PR worktrees right after the merge**
   (user 2026-10-30: 「已经提交并成功merge pr的对应的worktree要及时清除，这个要作为一个rule」): before `git worktree remove`,
   preserve the other untracked `.claude/tdd-guardian/` evidence in `~/.picsee/archive/tdd-guardian/<worktree>/`
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
   Record in `docs/validation/P<n>.md` with `Validated-by: picsee-delegator run=<id>`;
   garden; PR. Defect found → issue + FAIL limit + fix brief + re-validate.
10. **Log** — update `~/.picsee/timeline.json` and append the handoff log; record user decisions verbatim.

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
