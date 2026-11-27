# Fix brief template

```
# <item> fix round <k> (merged audit, delegator <date>)<. One round, no confirm round (no C/H).>

<If the implementer's context was reset: "Your context was reset. Read your handoff … and the brief … first.">
Branch <branch> @ <head7>, in the task worktree ~/Documents/mac-app/picsee-wt/<issue>-<slug> (the fix round continues there; the delegator re-runs mark-target.mjs for the new Report-Task). <Step 0: rebase onto origin/main — expected conflicts only in xcstrings / ledger md /
ledger html (regenerate); never pipe git rebase; a conflict elsewhere: stop and report.> Reports (unblinded for you):
~/.mado/herdr/gpt-auditor/<item>-r1.md and ~/.mado/herdr/opus-auditor/<item>-r1.md.

## Must fix (blocking; confirm round follows)
F1 [High] <one-paragraph trace> Fix: <direction, not code>. Tests: <continuation-gated / deterministic cases>.
<If a fenced file is needed: stop and ask.>

## One Medium round (no confirm for these)
- <finding>: <fix direction>

## Cheap Lows
- <…>

## Still open (do not fix)
<list>

Gates as before. RED receipts / pasted RED per behavioural fix (ids <item>-FIX<k>-WI-n), each recorded on a clean
committed tree (stubs in their own `Stub-For:` commit; the `tdd-separation=` line in the handoff). Commit per fix with Refs #<n>
and Implemented-by: <implementer>. Rerun mado-verify (Claude `/mado-verify`, Codex `.agents/skills/mado-verify/SKILL.md`)
on the final fix head and post a new evidence comment. <For a hosted-only failure: the hosted run's `.build/layout-evidence/`
record and the `layout-metrics-fingerprint:` line are in the brief; a fix for a hosted-only failure is not audit-ready
until the delegator's `hosted-preaudit.mjs dispatch` on the fix head prints GREEN with `retried=no`; a local pass is not its RED/GREEN.> Update the handoff with "Fix round <k>", the new comment URL
and the head SHA it covers. Do not push.
```

# Confirm request template

```
# Confirm round <k>: #<n> <item>. Fresh context.

Read `~/.mado/herdr/delegator/audit-brief.md` first: the confirm-phase read barrier and the scratch-isolation rule.

- Item <item>, tier <tier>. <Rebased onto <sha7> before fixing; rebased round-one head <sha7>.> Branch `<branch>` @
  <head7>, worktree <path>. Full range <base>..<head7>. Fix diff <r1head>..<head7>.

## Findings in scope (merged verdict)
- **F1 [High]** (<who raised it>) <restated finding>. Requested: <fix>. <Approved fenced hunks.>
- Medium fixes (judged here only for regressions): <list>
Still open (do not re-judge): <list>.

Your own earlier report: ~/.mado/herdr/<auditor>/<item>-r1.md. Fix brief: <path>. Handoff `Fix round <k>`: <path>.

## Scope
- each finding above: CLOSED / PARTIAL / OPEN with evidence;
- any Critical or High that the fix diff or the rebase introduced, exposed or worsened.

<test-run paragraph as in the audit request, per auditor>
Write ~/.mado/herdr/<auditor>/<item>-confirm.md and end with the VERDICT / COUNT block.
```

For the auditor who did NOT raise a High, say so: "raised by the other auditor; you did not raise it — judge it fresh".
