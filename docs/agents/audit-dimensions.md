# Audit dimensions: what both pre-landing auditors check

This is the single list of audit dimensions for Mado. Both auditors load it:
- `gpt-auditor` (Codex);
- `opus-auditor` (Claude Code on Opus, in its own herdr pane; `.claude/agents/picsee-opus-auditor.md`).

Change it here, never in a brief or an agent wrapper. The two verdicts can only challenge each other
if they cover the same ground, so a dimension one auditor checks and the other doesn't is a defect
in the process, not a style choice.

**Where the list comes from.**
- The base was the nine "full" dimensions of `/cc-suite:audit`, a plugin prompt. No published source
  for that list was found.
- It was reordered and extended against the published guidance:
  - Google Engineering Practices, *What to look for in a code review*: design first, then functionality
    including concurrency, complexity, tests, naming, comments, documentation;
  - ISO/IEC 25010: reliability and recoverability, performance efficiency, security, interaction
    capability including inclusivity;
  - Bacchelli & Bird 2013: review also transfers knowledge.
- Two dimensions were added because Mado's P0 risk sits there:
  - design and architecture fit;
  - concurrency and cancellation.
- "Redundant code" and "maintainability" were merged into one dimension.

## The dimensions

| ID | Dimension | What it asks in Mado |
|---|---|---|
| D1 | Design & architecture fit | Does the change belong, in this target, now? Does it respect the target split and dependency direction in [architecture §2.1](../PICSEE_ARCHITECTURE.md), and the ADRs in `docs/adr/` (for example ADR-001: AppKit owns windows)? Is it the simplest design that meets the brief, with no speculative generality? |
| D2 | Correctness & reliability | Does it do what the brief's ACs say on ordinary and edge paths? Covers error handling, failure and recovery paths (a missing file, a revoked grant, a corrupt image), and state left behind after a failure. |
| D3 | Concurrency & cancellation | Swift 6 isolation (`@MainActor`, `Sendable`, actors), data races, ordering, re-entrancy. A cancelled or superseded request must never deliver a stale result. No blocking I/O or decoding on the main thread. |
| D4 | Security, privacy & sandbox | The sandbox stays on and entitlements stay minimal. Covers security-scoped bookmark lifetime and whether access is released, secrets, and personal paths or e-mail in logs. Log fields are `.public` only when they are non-personal. No research material (`evidence/`, `design/`, npm, HTML/CSS) in any target. |
| D5 | Testing & validation | Do the tests prove each AC? Is the RED real, recorded before the code it tests? Are there missing cases: an edge, a failure, a concurrent case? Does each claim marked as proven on a real device have device evidence, as the [verification guide](../guide/feature-verification-guide.md) requires? |
| D6 | User-visible behaviour & accessibility | Does the UI behave as the brief and the [design spec](../../design/DESIGN.md) say? Check keyboard paths, VoiceOver labels, light and dark appearance, and Retina versus @1x rendering. Shortcuts that are shown must actually work; coming-soon entries must follow the greyed, disabled, unfocusable, no-shortcut and localized 「即将推出」 rule in AGENTS.md. |
| D7 | Performance & resources | Main-thread work, memory peaks, cache growth, work repeated per frame, CI and build time. Numbers must be measured; an untested number is a finding. |
| D8 | Observability | Is there enough logging and `os_signpost` to diagnose this change in the field, at the right privacy level? Is there any noisy logging on hot paths? |
| D9 | Maintainability & readability | Duplication, dead code, unclear names, long functions, deep nesting, leftover TODOs and workarounds. Comments should explain why, not what. |
| D10 | Compliance with rules | The brief's scope and out-of-scope list, AGENTS.md rules, commit format and the `Implemented-by:`/`Validated-by:` trailers, and the ledger rules in [`feature-ledger.md`](../feature-ledger.md). |
| D11 | Dependencies & environment | The toolchain lock (Xcode 26.6 / 17F113), CI runner and tool pins (versions, checksums, action SHAs). Every new dependency needs a reason. |
| D12 | Documentation & knowledge transfer | Validation records state only what was run. ADRs, the glossary and AGENTS.md stay true after the change. Would the next agent understand why the change was made? |

**Every dimension is checked on every audit.** When a change cannot touch a dimension, the auditor says
`n/a` and gives a reason in a few words (for example, `D6 n/a: no UI change`). An auditor does not drop
dimensions to save time. The risk tier changes how deep each check goes, not which dimensions are
checked:
- **Low** tier (docs, config): D1, D4, D10, D11 and D12 at full depth; the rest only for whatever the
  change actually touches.
- **Medium** tier: all dimensions at full depth.
- **High** tier (sandbox, file grants, deletion and other writes, concurrency core): all dimensions,
  plus a reproduction or a counter-proof for every D3 and D4 finding.

## Severity

| Severity | Meaning | Blocks landing |
|---|---|---|
| Critical | Data loss, a security or sandbox hole, or silent corruption on an ordinary path | Yes |
| High | One of: a defect a user or CI reaches on an ordinary path; an AC claimed but not met; a broken rule (dependency direction, research material shipped, sandbox weakened, a stale result delivered, an invented number) | Yes |
| Medium | A real defect or risk off the ordinary path, or debt with a concrete cost | No; counted, listed briefly |
| Low | A nit: style, naming, a small clean-up | No; counted only |

Before landing, Medium findings that affect user-visible behavior or violate an acceptance criterion get one
fix round. Do not open another confirm round merely to reach zero Mediums. Put every other Medium (test gaps,
evidence wording and technical debt) under the PR's `Still open` section and schedule it for a later Low
follow-up batch; those findings do not block landing.

- Every Critical or High needs three things: the file and line, an ordered trace of how an ordinary path
  reaches it, and the reason existing tests or checks miss it. A suspicion without a trace is at most
  Medium.
- An auditor never downgrades its own High without a reproduction or a counter-proof.
- A defect in code the change did not touch counts only when the change makes it reachable.
- The goal is better code health overall, not perfection: Lows never block.
- A range over about 400 changed lines of production code gets a Medium recommending a split.

## Independence

Active routing override: since 2026-10-25 opus-auditor is the only auditor for every tier (「Opus单审，gpt暂停」), so its
verdict is the merged verdict and there is no challenge step; see `docs/plans/20261021-herdr-roster-migration-plan.md`.
The rules below describe the dual-audit baseline.

Round one is blind:
- neither auditor reads the other's report folder, the delegator's notes, or PR comments;
- both get the same range, tier and AC list at the same time;
- the delegator merges the two verdicts.

A Low item from `gpt-imple-3` has one blind auditor, `opus-auditor`, with no merge or
challenge step; if that auditor raises the tier above Low, the item returns to two auditors.

When the auditors disagree on a finding, the delegator sends it as a `challenge` to the auditor that
did not raise it. That auditor confirms the finding with its own trace or refutes it with a
reproduction or a counter-proof. "Unlikely" is not a refutation.

## Report shape

```
VERDICT   <audit|confirm|challenge> · <item> @ <sha7>   (range <base7>..<sha7>)   tier <Low|Medium|High>
COVERAGE  D1 ok|n/a — <few words> · D2 … · … · D12 …
AC        AC-1 PROVED|NOT PROVED|WRONG — <own evidence>   (one line per AC)
FINDINGS
  F1. [Critical|High] D<n> <dimension> · <file:line> · <issue>
      trace: <ordered steps>
      fix: <one line>
  M1. [Medium] D<n> · <file:line> · <issue>
CONFIRM   (confirm mode) <finding id>: CLOSED|PARTIAL|OPEN — <evidence>
COUNT     C<n> H<n> M<n> L<n>   BLOCKING C<n> H<n>
```

The delegator rejects a report that has no `COVERAGE` line, or that skips a dimension without a reason.
