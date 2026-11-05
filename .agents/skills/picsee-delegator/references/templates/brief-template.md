# <implementer> task: <WP or #issue> — <one-line summary> (delegator, <date>)

You are **<implementer>**. New task, fresh session. Worktree `~/Documents/mac-app/picsee-wt/<implementer>`.
Branch: `git fetch origin && git switch -c <branch> origin/main` (main ≥ <sha7>). Issue #<n>.
Tier **<Low|Medium|High>** because <reason>. Under the 2026-10-25 override, every tier receives independent `opus-auditor` review.

## Read first
- `AGENTS.md` (binding: test-first, named-path staging, commit format, ledger md+html, heavy lock, dangerous commands).
  Codex loads it itself; tell Kimi explicitly.
- `docs/feature-ledger.md` rows <IDs>; plan section <WP>; ADRs <list>; `docs/validation/P<n>.md` §<WP>.
- `gh issue view <n>`. User decisions to honour, quoted: 「…」.
- If UI changes: [`docs/agents/ui-parity-contract.md`](../../../../../docs/agents/ui-parity-contract.md), `design/DESIGN.md`, native mapping, and the exact HTML states mapped in plan §1.3.

## Today / wanted
<what happens now, with evidence (file:line, device run); what must happen instead>

## UI design contract (required for user-visible UI; otherwise write `无 UI 变化`)

Use [`docs/agents/ui-parity-contract.md`](../../../../../docs/agents/ui-parity-contract.md). Before coding, pin the design Git tree OID plus HTML/manifest SHA256 and list **each** affected `states/manifest.json` name, HTML path, viewport, appearance, plan §1.3 work package, ledger ID and native entry point. Split wide/compact, light/dark and visible/hidden states into separate rows; mark states outside this work package `PENDING`, not passed.

| State / HTML | Design hashes | Viewport / appearance / scale | Native user path + fixture | Ledger / WP | Native exception + source | Proof / remaining limits |
|---|---|---|---|---|---|---|
| `<manifest name>` / `<states/file.html>` | `<tree OID; HTML SHA256; manifest SHA256>` | `<width×height; light/dark; @1x/@2x>` | `<steps + deterministic input>` | `<ID / Pn-nn>` | `<specific mapped exception or 无>` | `<region/behavior/focus/a11y/zh-en checks; NOT VERIFIED items>` |

Define comparison regions, measurement coordinates and any dynamic-data masks before seeing the App screenshot. Implement from the design token/component contract; do not treat browser mockup clicks as native behavior. Device evidence requires a signed sandboxed App at matching viewport/appearance and raw reference/native PNGs tied to source/build SHAs outside the repo. A visual match alone never upgrades the ledger to `Shipped`.
List every changed reachable state and required viewport/appearance/scale/language/action. Before merge each needs green design-derived assertions (`AUTO-PASS`, below), both audits, and the delegator's `Device-Smoke:` of the changed path; signed parity against the HTML runs in batches. `PENDING` requires an unreachable state and named future work package.

### Design-derived assertions (written first; the delegator pre-fills the left columns)

Each changed state gets one row per design rule it depends on. The delegator copies selector, property and media range from the pinned CSS **before dispatch**; the implementer writes these tests as the **first RED** of the UI work item, using `PinnedDesign` (`Packages/PicseeKit/Tests/PicseeMacUITests/PinnedDesign.swift`: `assertLength`, `assertEdges`, `assertFont`, `assertColor`) against the **rendered frame**, not layout inputs or constants.

| State | Selector · property · `@media` range | Viewports to assert | Rendered-frame test | Content pressure |
|---|---|---|---|---|
| `<manifest name>` | `<.grid-footer · padding · max-width: 1023px>` | `<both sides of every breakpoint the rule has, plus the manifest viewport>` | `<test name>` | `<longest zh/en label; scroll bar on/off; column-count boundary widths>` |

- Assert on both sides of every breakpoint. A hard-coded value that matches the CSS at one viewport only is a failing implementation (P3-10 footer 7/2 pt vs 12/6 pt; #136 Inspector 220 vs 195 pt at 960).
- Include content pressure: the longest English and Chinese label (#136 labels overflowed 48 pt), the scroll bar taking width (P3-01 lost a column), and the window widths where the column count changes.
- No state is `AUTO-PASS` until all its rows are green. A row that can't be asserted gets `NOT VERIFIED` and a reason in the handoff, never a silent omission.
- Auditors check each row against the pinned CSS; a missing row is at least Medium for a user-visible state.

## Interaction & lifecycle (required for a new or changed mode, panel or async load; otherwise write `无交互/生命周期变化`)

Use [`docs/agents/interaction-lifecycle-checklist.md`](../../../../../docs/agents/interaction-lifecycle-checklist.md).
One row per case — Esc, focus, refresh, close, relaunch, cancel mid-load, tasks cancelled on close, late/stale
completion — or `n/a` with a reason. Visual dimensions stay in the UI sections above; do not repeat them here.

| Case | Start state | Event sequence | Expected result | Proving test or device run |
|---|---|---|---|---|
| `<case>` | `<…>` | `<…>` | `<…>` | `<test name / Device-Smoke step / n/a: reason>` |

## WI-0 — probe the risky seam first (only if an assumption needs the device)
<exact probe; throwaway code allowed, never committed; what to record; "if it can't be delivered, record NOT VERIFIED
and continue"; "if <bad outcome>, stop and report — that is High">

## Acceptance
- AC-1 … (each testable, tied to ledger rows)
- AC-n Ledger: only text after 「限制：」 may change; never above Partial without a device record; md+html in the same
  commit (`node scripts/ledger/build.mjs`); acceptance sentences are the delegator's (separate commit quoting the user).

## Ownership
**You own, and may edit:** <files / exact hunks>. **Not yours:** <files>. Shared with <other implementer>: <split>.
(Delegator: list real paths here; `overlap-check.py claim` reads them before dispatch.)
If a needed change crosses a fence: stop, propose the minimal hunk, ask in your final reply.

## Test-first
- Codex: `$tdd-guardian-workflow` (plan → design tests + spec adversary → per-WI RED receipt → implement → verify →
  coverage). Receipt IDs `<WP>-WI-n`.
- Kimi / no plugin: write the tests first; run only them
  (`scripts/heavy-lock.sh swift test --package-path Packages/PicseeKit --filter <Name>`); paste the FAILING assertion
  output (not compile errors) in the handoff; implement; rerun the same filter; paste GREEN.
- Test matrix: every applicable Interaction & lifecycle row becomes a matrix entry (or a named device run) before
  implementation; the handoff maps row → test.
- Changing an existing assertion: only where it asserts the old behaviour; list before/after/why.

## Gates (paste decisive lines)
```sh
export PATH=$HOME/.picsee/tools/xcodegen/bin:/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/heavy-lock.sh swift test --package-path Packages/PicseeKit --enable-code-coverage
sh scripts/tdd/swift-lcov.sh      # coverage/lcov.info: sum LF/LH and FNF/FNH → 100% lines and functions
xcodegen generate
scripts/heavy-lock.sh xcodebuild build -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci
node --test --test-reporter=spec scripts/tdd/*.test.mjs scripts/ledger/*.test.mjs
node scripts/ledger/build.mjs --check
```
Only the heavy job itself goes under `scripts/heavy-lock.sh`, one command per call.

## Device smoke (implementer smoke, not validation) — only if the brief needs it
`pgrep -x Picsee` first; never kill a Picsee you didn't start; `~/Applications/Picsee.app` is off limits; no
pre-granting, no container/store edits, no system settings; list root IDs you leave behind.

## Commits
`<type>(<scope>): <summary>`; body names #<n>, <WP>, ledger IDs; trailer `Implemented-by: <implementer>`; one WI per
commit. Generate this commit's receipt trailer with `node scripts/tdd/red-receipt-trailer.mjs --id <receipt-ID>`
and paste each generated `Red-Receipt:` line into the implementation commit (repeat for each relied-on ID).
The script refuses unverified receipts; verify first. A BROKEN receipt means re-recording under a new ID after
resolving and explaining the changed specification; never commit BROKEN evidence. Stage named paths only.
No push, PR, branch switch/deletion, `rm -r`, other worktrees.

## Handoff
`~/.picsee/herdr/<implementer>/<item>-handoff.md`: design; AC table (AC → proving test); RED/GREEN or receipts;
changed existing assertions; gates output; `git diff --stat origin/main..HEAD`; production lines per target; NOT
VERIFIED list; open questions. Reply DONE with the path.

## Open questions (defaults)
- OQ-1 … default: … — Follow each default; if WI-0 or the code contradicts one, stop and report.
