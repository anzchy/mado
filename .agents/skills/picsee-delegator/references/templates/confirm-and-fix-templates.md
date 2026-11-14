# Fix brief template

```
# <item> fix round <k> (merged audit, delegator <date>)<. One round, no confirm round (no C/H).>

<If the implementer's context was reset: "Your context was reset. Read your handoff … and the brief … first.">
Branch <branch> @ <head7>. <Step 0: rebase onto origin/main — expected conflicts only in xcstrings / ledger md /
ledger html (regenerate); never pipe git rebase; a conflict elsewhere: stop and report.> Reports (unblinded for you):
~/.picsee/herdr/gpt-auditor/<item>-r1.md and ~/.picsee/herdr/opus-auditor/<item>-r1.md.

## Must fix (blocking; confirm round follows)
F1 [High] <one-paragraph trace> Fix: <direction, not code>. Tests: <continuation-gated / deterministic cases>.
<If a fenced file is needed: stop and ask.>

## One Medium round (no confirm for these)
- <finding>: <fix direction>

## Cheap Lows
- <…>

## Still open (do not fix)
<list>

Gates as before. RED receipts / pasted RED per behavioural fix (ids <item>-FIX<k>-WI-n). Commit per fix with Refs #<n>
and Implemented-by: <implementer>. Rerun mado-verify (Claude `/mado-verify`, Codex `.agents/skills/mado-verify/SKILL.md`)
on the final fix head and post a new evidence comment. Update the handoff with "Fix round <k>", the new comment URL
and the head SHA it covers. Do not push.
```

# Confirm request template

```
# Confirm round <k>: #<n> <item>. Fresh context.

Read `~/.picsee/herdr/delegator/audit-brief.md` first: the confirm-phase read barrier and the scratch-isolation rule.

- Item <item>, tier <tier>. <Rebased onto <sha7> before fixing; rebased round-one head <sha7>.> Branch `<branch>` @
  <head7>, worktree <path>. Full range <base>..<head7>. Fix diff <r1head>..<head7>.

## Findings in scope (merged verdict)
- **F1 [High]** (<who raised it>) <restated finding>. Requested: <fix>. <Approved fenced hunks.>
- Medium fixes (judged here only for regressions): <list>
Still open (do not re-judge): <list>.

Your own earlier report: ~/.picsee/herdr/<auditor>/<item>-r1.md. Fix brief: <path>. Handoff `Fix round <k>`: <path>.

## Scope
- each finding above: CLOSED / PARTIAL / OPEN with evidence;
- any Critical or High that the fix diff or the rebase introduced, exposed or worsened.

<test-run paragraph as in the audit request, per auditor>
Write ~/.picsee/herdr/<auditor>/<item>-confirm.md and end with the VERDICT / COUNT block.
```

For the auditor who did NOT raise a High, say so: "raised by the other auditor; you did not raise it — judge it fresh".
