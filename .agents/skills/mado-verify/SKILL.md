---
name: mado-verify
description: Verify an implementation before handoff with Mado's gate ladder, test-integrity review, type-specific checks, and ticket evidence.
---

# mado-verify

Run before an implementer handoff, on the final head of the first handoff and again on the final head of every fix round. Claude invokes `/mado-verify`; Codex follows this file. There is no hook: the brief requires this skill (the `## Verify (mado-verify)` section of the brief template), and the delegator checks the record and the issue comment for the final head before audit and before merge with the manual check below.

```sh
node .agents/skills/mado-verify/scripts/evidence.mjs check --head <sha> [--worktree <wt>]
```

It exits 0 and prints `OK head=… issue=… comment=…` only when `<wt>` is clean, its HEAD is `<sha>`, `.build/mado-verify/<head>.json` exists for that head, every mandatory gate passed, and `commentUrl` is an issue comment on the recorded issue. Anything else (stale head, failed or missing gate, missing comment) exits 1 with the reason.

## 0. Define scope

Read the brief, the relevant `docs/feature-ledger.md` acceptance rows, and `git diff --name-status origin/main..HEAD`. The delegator writes `<session-cwd git toplevel>/.build/mado-verify/target-worktree` before dispatch with `scripts/mark-target.mjs`; check its JSON `{worktree, branch, issue, task, handoff}` against the brief, and do not rewrite it as an implementer. The old one-line format is invalid. List applicable layers and write `n/a: <reason>` for each layer that does not apply. Tooling work may have no ledger row. Pin the merge-base and final head SHA.

## 1. Gate ladder

Run gates in a clean worktree at the head: commit first, and never during a rebase, merge or cherry-pick. `owner-gates.sh` refuses (exit 2, summary `refused: …`, no `DONE`) when the worktree has tracked changes, one of those operations is in progress, or HEAD is not the given SHA. Run `git diff --check` first. Then run **the current branch's** `.agents/skills/picsee-delegator/scripts/owner-gates.sh <worktree> <head-sha> <prefix>` and read its `*-summary.txt` plus gate logs. Follow its gate order and stop on the first failure; fix it and rerun from the start. The owner script itself completes later lanes so the delegator has a full summary; a later success never excuses an earlier failure. Do not invoke a copy from another checkout. Its heavy jobs use `scripts/heavy-lock.sh`; keep each heavy command separate and foreground. Install design dependencies with `npm ci --ignore-scripts` when that layer applies and `node_modules` is missing. For App target changes, run the relevant filtered App tests separately. Record exact commands, exit codes and decisive lines. Never weaken a test or add retry/quarantine to turn a gate green.

## 2. Test integrity

Create `.build/mado-verify` first, then run `node .agents/skills/mado-verify/scripts/test-integrity.mjs --base <merge-base> > .build/mado-verify/integrity.json`. Inspect removed `#expect` / `XCTAssert`, new weak assertions, `.disabled` / `XCTSkip` / quarantine, retries, timeout changes and `exit(0)`. Compare before/after test counts. Read each WI's tdd-guardian RED receipt and SEPARATION verdict; if none exists, say so. Explain **every hit** in the evidence and handoff, including any `SEPARATION-BROKEN`. Hits are review findings, not automatic failures.

## 3. Extra checks by change type

| Change | Run and record |
|---|---|
| Concurrency, cancellation, scanning, caching, watching | Separate TSan lane via heavy-lock when available; relevant tests with `-test-iterations` and `-run-tests-until-failure`; record iteration count and failures. No retry. |
| Bug fix | Regression test RED on old code, GREEN on head; give both SHAs and outputs. If GUI-only, give reproduction steps and a device command. |
| UI state, layout, color | First RED from pinned CSS, then light/dark and other affected appearances. Each state gets AUTO-PASS or NOT VERIFIED. Do not add snapshot-testing dependency. |
| Flaky CI test | Follow `docs/agents/ci-flake-repro.md`, record exact command and run count. |
| Performance-sensitive path | Only report measured signed Release/signpost numbers with machine and build; otherwise NOT VERIFIED. |
| Sandbox authorization, relaunch, menus, window state | Implementer dry-runs scripts or AX selectors; give delegator the signed-app run command and output directory. Delegator performs Device-Smoke and ledger promotion. |

## 4. Issue evidence and record

Fill [`evidence-template.md`](evidence-template.md), preserving its headings and tables. Put structured fields in a JSON input accepted by `scripts/evidence.mjs`; each gate must have a `name`, `command`, and integer `exitCode`. The shared mandatory names live in `scripts/gate-policy.mjs`. `render` checks personal paths and key-like strings, and `post` refuses to call `gh issue comment` if the privacy scan hits. Read the rendered body before posting. `node .../evidence.mjs post <input.json>` posts text to the issue in the brief. Copy the returned comment URL into `commentUrl`, then `node .../evidence.mjs record <input.json>` writes `.build/mado-verify/<head>.json` (gitignored). Failed or incomplete gates can be recorded as evidence but never satisfy `evidence.mjs check`. A new commit needs a new comment and record. Put comment URL and covered head SHA in handoff.

For a UI change, screenshots of base and head must use the same state, window size, appearance and scale, and only `TestAssets` content. Scan the crop for private filenames, photos, notifications and other windows. The implementer supplies an exact capture command and output directory. The delegator in the desktop session uploads before/after images via `/browse` into issue comments; `gh` cannot upload comment attachments. The implementer's text and the delegator's images may be separate comments on the same issue. Mark screenshots NOT VERIFIED until uploaded. Do not commit screenshots.

## 5. Repair the recipe

If a command is stale or broken, correct this skill or its owned scripts on the same branch, rerun the affected gate from step 1, and name the correction in handoff. Do not change Device-Smoke, UI-Parity, or ledger acceptance here.
