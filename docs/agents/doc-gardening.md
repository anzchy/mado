# Doc gardening: keeping the feature ledger true

This is the single procedure for the picsee doc gardener. Two thin wrappers load it:
- `.claude/agents/picsee-doc-gardener.md` for Claude Code;
- `.codex/agents/picsee-doc-gardener.toml` for Codex.

Change the procedure here, never in a wrapper.

**Why it exists.** `docs/feature-ledger.md` is the system of record for what picsee can do. The rule is that
the commit that changes a behaviour also rewrites its row. The ledger's own gate can't tell whether a
sentence is still true, and authors forget. The gardener runs once a day over everything merged to main since its last run and
catches the rows those changes made stale. This follows two published practices:
- OpenAI's harness-engineering team runs a recurring doc-gardening agent that scans for stale docs and
  opens fix-up PRs, because repository knowledge is the system of record;
- Anthropic's long-running-agent harness lets an agent change a feature's status only after it has
  verified that feature end to end, and forbids removing or editing tests.

## When it runs

**Once a day, on main** (user 2026-11-04: 「之后picsee-doc-gardener 每天跑一次，当前跑得太频繁了」, choosing
a daily sweep on main). PRs no longer wait for a gardener run: opening or re-pushing a PR runs neither the gate
nor the gardener, and the PR body carries `Ledger-Gardener: DAILY <base7>..<head7> (covered by the daily sweep)`.
The commit that changes a behaviour still rewrites its row; the daily sweep catches what it missed.

The delegator runs the daily sweep in a clean worktree detached at `origin/main`. It runs the gate script first,
over everything merged since the last sweep, and starts the gardener only when it prints `RUN`:

```sh
node scripts/ledger/garden-gate.mjs <last-swept-main> origin/main
```

`<last-swept-main>` is the main head the previous sweep covered, kept in `~/.picsee/gardening/last-daily-sweep`
(machine-local). After the sweep, write the new main head there. An `UPDATED` or `NEEDS-OWNER` result lands as one
small PR (`docs(ledger): garden <base7>..<head7>`). A `BLOCK` on main means a merged commit weakened acceptance or
upgraded a row without evidence: tell the user, open an issue, and fix it in that PR.

The table below is the gate's rule set. The `--since`/`--verdict` rows applied to PR re-pushes and are kept for a
manual rerun of a sweep after its own fix-up commit.

| Situation | Rule | Gate prints |
|---|---|---|
| No changed path is mapped, and no commit names a ledger row ID or a plan WP ID | **Skip** the gardener | `Ledger-Gardener: SKIP <base7>..<head7> (no mapped paths)` |
| PR opens and the range is mapped | Run `pr` once | `RUN` |
| Re-push after a fix round or a rebase, last verdict CLEAN or UPDATED | Rerun only if the commits since the gardened head are mapped; otherwise reuse the verdict for the new head | `Ledger-Gardener: REUSE <V> <base7>..<head7> (no mapped change since <S7>)` or `RUN` |
| After NEEDS-OWNER | No rerun when every commit since the gardened head changes only the ledger md/html, leaves 状态 and 验证 unchanged and 怎么确认 unchanged before the first 「限制：」, leaves a 「限制：」 marker in every row that already had one, adds or removes no row, and the HTML check passes | `Ledger-Gardener: RESOLVED <base7>..<head7> (owner fixed rows after NEEDS-OWNER at <S7>)` or `RUN` |
| Last verdict BLOCK | Always rerun | `RUN` |

**Mapped** means a changed path is under `App/`, `Packages/*/Sources/` or `docs/validation/`, is `project.yml`,
`docs/feature-ledger.md` or `docs/feature-ledger.html`, or is named (or under a directory named) in a 在哪 cell.
Commit messages are mapped when they name an existing row ID or a `P<n>-<nn>[a-z]?` work package. Other tooling,
`.github/` and design pages are not mapped unless a 在哪 cell names them.

The gate fails closed. A `--since` that is not an ancestor of head, as after a rebase, makes it judge the whole
merge-base..head range, so a mapped PR gives `RUN`. Any error (unknown ref, unreadable ledger, git failure) gives `RUN`.
The gate never writes the ledger: SKIP, REUSE and RESOLVED set no area review date.
Text appended after 「限制：」 is trusted as a limitation, so new acceptance must never be written there.
The gate ignores branch names: it maps IDs only from commit messages, and paths only from the changed files.

| Mode | Trigger | Range |
|---|---|---|
| `pr` | The daily sweep's gate printed `RUN`. The delegator runs it once a day | `<last-swept-main>`..`origin/main` |
| `full` | Once a week, scheduled by the delegator; when the user asks; or when an area in the ledger's Part 3 table is more than 30 days past its last review and code in it has changed | the whole ledger against the working tree |

A PR body carries the `Ledger-Gardener: DAILY …` line above. The daily sweep's own fix-up PR carries the
gardener's or gate's line for its range (see Output).

## What you may change, and what you may only propose

The asymmetry is the point. **You may make the ledger more cautious, never more optimistic.**
A wrong downgrade costs one re-check. A wrong upgrade is the false claim the ledger exists to prevent.

**Apply yourself.** These are edits to `docs/feature-ledger.md` (and, after them, its generated HTML) only:
1. **Moved paths.** A path in 在哪 that the range renamed (`git diff -M`) is rewritten to the new path.
2. **Deleted paths.** A path the range deleted is removed from 在哪. If that leaves a non-`Absent` row with no path, don't
   guess: report it as NEEDS-OWNER.
3. **Lost evidence.** A row whose linked `docs/validation/` record no longer exists, or no longer mentions
   the row's ID, is downgraded:
   - 验证 drops to the strongest evidence that remains;
   - `Shipped` becomes `Partial`;
   - one sentence is appended to 怎么确认: `限制：真机记录缺失（<file>），待复验。`

   Nothing else in that cell changes.
4. **Broken links.** A link to a renamed file is repointed. A link with no target is reported, not deleted.
5. **Area review.** For each ledger area the range touched, set its Part 3 row to today's date and reviewer
   `doc-gardener`, and replace its 备注 cell with the range `<base7>..<head7>`. Findings go in your report and
   the PR body, never in the ledger.

**Propose only.** Write these into the report for the owner. Never edit them yourself:
- any state or 验证 upgrade, whatever evidence you see;
- a new row, for a new capability or for a declared name with no row;
- any change to 能力, or to 怎么确认 beyond the sentence allowed in step 3;
- moving a row to 不做, or back.

## Procedure

1. **Inputs.** You need the mode; for `pr`, the branch's worktree path, the base and the head SHA; and the
   PR's ID or branch name. Anything missing returns BLOCKED.
2. **Read** `docs/feature-ledger.md` in full: its rules first, then its rows. Read the work package IDs in
   `docs/PICSEE_DEVELOPMENT_PLAN.md`.
3. **Collect the change.**
   - `git diff --name-status -M <base> <head>`
   - `git log --format='%H %s%n%b' <base>..<head>`
4. **Map the change to rows.** A row is *touched* when any of these holds:
   - **path**: a changed file is in its 在哪 cell, or under a directory named there;
   - **ID**: the row ID appears in a commit message, a changed test's name or path, a changed
     `docs/validation/` file, or the branch name;
   - **plan**: a work package ID in a commit message or the branch name is in its 计划 cell;
   - **surface**: a changed file adds or removes a declared name, meaning a CommandRouter command ID, a
     menu item identifier, a `DisplayPreferences` key, an entitlement, or an `Info.plist` UTType. Use the
     source tree layout in `docs/PICSEE_ARCHITECTURE.md` to find them.
5. **Judge each touched row.** Each row lands in exactly one of these:
   - **Updated.** The range already edits that row consistently.
   - **Stale.** Behaviour on the row's paths changed, but the row did not. Propose the edit: the new state,
     a 限制 if needed, and the evidence. Check the claim against the code at `<head>`, not the commit
     message.
   - **Unaffected.** The change provably has no user-visible effect, such as a pure rename, a test-only
     change, or a comment. Give the reason in one line.
6. **Integrity checks across the whole range:**
   - **Weakened acceptance.** In the same range, a row's state or 验证 went up **and** the acceptance
     itself in 怎么确认 was rewritten. This verdict is BLOCK. Appending or editing `限制：` text does
     not block; any acceptance rewrite goes in a separate commit that cites the user's words or an ADR.
     状态升级的那次提交，可以追加或修改「限制：」文本，但不得改写「怎么确认」中的验收本身。确需改验收时，单独提交并在提交说明里引用用户原话或 ADR。
   - **Upgrade without evidence.** A row became `Shipped` without `验证 = 真机` and a `docs/validation/`
     link that exists and mentions the row ID. This verdict is BLOCK.
   - **Entry points not all verified.** A row went up to `验证 = 真机` or `Shipped`, but its 怎么确认 lists
     several entry points or values (joined by 或, /, 、) and the linked `docs/validation/` record has no
     verdict line for one of them, or marks one NOT VERIFIED. This verdict is NEEDS-OWNER: the row stays at most
     `Partial`, with a `限制：` naming the unverified entry point.
   - **No second view.** A row went up to `真机` or `Shipped`, its 怎么确认 claims persistence (保留, 退出重开,
     记住), a file write (导出, 另存, 去除元数据) or a release (释放), and the validation record shows no
     relaunch, no read of the written file, or no log line respectively. This verdict is NEEDS-OWNER.
   - **Self-certification.** Every commit here can share one git author, so authorship proves nothing; the
     check reads commit trailers instead. For each row that went up to `真机` or `Shipped`, find the commit
     that added or changed its `docs/validation/` section. It is self-certification, and the verdict is
     NEEDS-OWNER, when any of these holds:
     - that commit has no `Validated-by: <role> run=<run-id>` trailer;
     - the role in it also appears in an `Implemented-by: <role>` trailer on a commit in the range that
       touches the row's paths;
     - the same commit also changes source code (anything outside `docs/`).

     The record must come from the device tester, in its own commit.
   - **Format.** Every touched row must also pass the ledger's format rules:
     - state and 验证 are in their enums;
     - a `Partial` row carries `限制：`;
     - an `Absent` row has `—` in 在哪;
     - no path has a line number, a count or a build output;
     - the acceptance part of 怎么确认 (the text before 「限制：」) is no longer than three sentences or about 150 characters.
       The 「限制：」 text does not count toward this length (user, 2026-10-26: 「放宽规则」); do not propose compressing it,
       but do flag a 限制 clause that is not a fact (process, history or a log belongs in `docs/validation/`).
   - **Stale HTML.** Run `node scripts/ledger/build.mjs --check` at `<head>`. If it fails, the verdict is
     NEEDS-OWNER: run `npm run ledger:build` and commit the HTML with the ledger change.
7. **Apply** the edits you are allowed to make in `docs/feature-ledger.md`, then run `npm run ledger:build`
   (or `node scripts/ledger/build.mjs`) so `docs/feature-ledger.html` matches. Do not stage or commit.
   The caller reviews `git diff -- docs/feature-ledger.md docs/feature-ledger.html` and commits both files as
   `docs(ledger): garden <base7>..<head7>`.
8. **Write the report** to `~/.picsee/gardening/<branch>-<head7>.md`, creating the folder if needed, and
   return it as your final message.

In `full` mode, take the base as the commit that last touched each area's Part 3 row, then run steps
4–8 for each area.

## Boundaries

- Edit nothing but `docs/feature-ledger.md` and its generated `docs/feature-ledger.html`; edit the HTML only
  through `npm run ledger:build` (or `node scripts/ledger/build.mjs`). Never stage, commit, push, rebase or
  switch branches.
- Run no tests, app builds or the app. The ledger HTML generator and its `--check` mode are the only build
  commands allowed; you read evidence, you do not create it.
- Never read audit reports or PR comments. Your verdict must be independent of the auditors.
- A row you can't decide is NEEDS-OWNER with your reason, not a guess.

## Output

```
GARDENER  <pr|full> · <branch> · <base7>..<head7>
VERDICT   CLEAN | UPDATED | NEEDS-OWNER | BLOCK
APPLIED   <n> edits
  - <ID> · <moved path | removed path | downgraded: reason | link | area review>
PROPOSED  (owner must act before the PR opens)
  - <ID or "new row"> · <what to change> · evidence: <file or commit>
UNAFFECTED
  - <ID> · <one-line reason>
BLOCKERS
  - <ID> · <weakened acceptance | upgrade without evidence> · <commit>
NOT CHECKED  <anything you could not read or decide, and why>
PR-LINE   Ledger-Gardener: <VERDICT> <base7>..<head7> (<n> applied, <n> proposed)
```

Each verdict means:

| Verdict | Meaning | What the caller does next |
|---|---|---|
| CLEAN | Nothing stale, nothing proposed | Puts the PR line in the PR body and opens the PR |
| UPDATED | Only edits you were allowed to apply | Commits the ledger and HTML diff, then opens the PR |
| NEEDS-OWNER | At least one proposal | The owner updates the rows, or writes `无用户可见变化：<ID> <reason>` in the PR body for each one; then the caller runs the gate with `--since <this head> --verdict NEEDS-OWNER`, and reruns the gardener only on `RUN` |
| BLOCK | Weakened acceptance or an unevidenced upgrade | The PR does not open until the commit is split or the evidence exists |

The gate's SKIP, REUSE and RESOLVED lines (see When it runs) stand in for the PR line and go into the PR body
the same way.
