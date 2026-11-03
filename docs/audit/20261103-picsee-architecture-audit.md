# Where delivery time goes in picsee: a process and architecture audit

Audit run on 2026-11-03 at the delegator's request. The task was to mirror the structure and rigour of mdpro's `docs/audit/20261101-vmark-mdpro-架构对比.md` ("the mdpro report" below) for picsee, and to check explicitly the six problem classes that report found.

The audit was read-only. Nothing outside this file was written, and no swift, xcodebuild, xcodegen, GUI or device command ran. No pane, worktree or herdr agent was touched.

Inputs:

- picsee at `origin/main` `4ca72f8d`, read from a fresh worktree.
- `gh` queries against `anzchy/picsee`: 196 merged PRs, 210 issues, the last 100 `ci.yml` runs and branch protection.
- Runtime files: `~/.picsee/herdr/{gpt,opus,fable}-auditor/*.md` (496 report files), the brief, fix-brief and handoff files under `~/.picsee/herdr/*/`, and `~/.picsee/handoff/*.md`.
- The machine-local `remote-ssh` skill and the delegator's auto-memory index.
- The mdpro report, read but not edited, for the mdpro, vmark and marktext comparison figures. I took those figures from it and did not re-measure them.

Every number in a "Measured" section comes from a command in the evidence index. Sections marked "Judgment" are my reading of those numbers. Where I could not measure something, the text says so. I made no comparison with other open-source macOS Swift apps, because I fetched no such repository and will not quote figures I did not take.

---

## 0. The answer in one paragraph

picsee did not repeat mdpro's biggest mistakes:

- Its always-on instructions are 192 lines (mdpro: 1,936).
- It has 16 ADRs, all of them about the product (mdpro: 161, about a third of them about process).
- Receipts are gitignored, so no PR carries them.
- The required CI finishes in about 7 minutes (mdpro: 25).
- Of the first-round High findings, 79 of 138 point at product code. Only 30 point at tooling, where in mdpro the tooling took most of the rounds.

The friction is real, but it has different causes. In the 13 days since the first commit, `main` took 1,433 commits and 196 PRs. Of those commits, 707 touch code. 646 touch `docs/feature-ledger.md`, and 363 change nothing but the ledger. Even so, the ledger still lists 0 of its 109 capabilities as `Shipped`: 65 are `Partial / 单元` and 44 are `Absent`. The median time from an issue being filed to its PR merging rose from 5.1 h (PRs merged before 10-29) to 26.1 h (from 10-29 on).

Three causes stand out:

1. **One file, `App/CanvasWindowController.swift`.** It is 2,503 lines and has been changed in 149 commits. It sits outside the package coverage gate. It is cited in 36 of the 181 High or Critical finding lines. The four items that needed the most audit reports (p301, #136, #140, p310-s2) all failed on interactions inside it: Esc precedence, the Inspector combined with search and refresh, and focus.
2. **Acceptance criteria and test matrices that cover one feature at a time.** Auditors then find the interactions with other features one round at a time; 22 report files are "combo" re-audits.
3. **Proof on a real device that stays manual and @1x.** None of the 36 `Device-Smoke: PASS` lines ran @2x. App tests that wait on wall-clock time cause 8 of the 10 failed CI runs on `main`.

**In one line: picsee's process layer is the right size; the time goes into a window controller that nothing models, and into proof that runs only at the end and only by hand.**

---

## Part 1. Process and tooling layer

### 1.1 Measured: size of the layer

| Item | picsee (`4ca72f8d`) | mdpro (from the mdpro report) |
|---|---|---|
| `AGENTS.md` | 138 lines, 13,392 bytes. The longest line, 2,174 characters, is the heavy-lock paragraph about mdpro interop; the `## 命令` section is 4,994 bytes (37 %). 27 commits | 163 lines |
| `CLAUDE.md` | 6 lines (`@AGENTS.md` plus two Claude notes) | 494 lines |
| `.claude/rules/` | 1 file, `10-spec-before-implementation.md`, 43 lines, always on (no `paths:`) | 16 files, 2,109 lines; 7 always on |
| Global `~/.claude/CLAUDE.md` | 5 lines (gstack routing) | — |
| **Always-on per session** | **192 lines, 17,041 bytes**, about 5.0k tokens (estimate: one token per CJK character plus one per four other characters). Auto-memory adds a 28-line `MEMORY.md` (4,174 bytes, about 1.0k tokens) | **1,936 lines**, 31–36k tokens |
| Per-role load (on demand) | Delegator: `picsee-delegator/SKILL.md` 168 lines (about 3.9k tokens) plus `references/guide.md` 833 lines, 63,843 bytes (about 16k). Auditor: agent file 92 lines plus `audit-dimensions.md` 107 (about 3.6k). Gardener: agent 43 lines plus `doc-gardening.md` 188 plus the ledger, 475 lines and **135,761 bytes (about 41k tokens)** | Rules 70 and 71: 988 lines, always on |
| Machine-local process rules | 29 memory files, 564 lines (merge on green, push guard, heavy lanes serial, GUI lock, implementer order…). Codex does not load them | — |
| `.claude/agents/` and `.codex/` | 7 agents, 417 lines; `.codex/agents` 1 file; `.codex/rules/picsee.rules` 203 lines | 3 agents, 264 lines |
| Skills | `.agents/skills`: 24 skills, 116 files, 10,292 lines. `.claude/skills`: 3 symlinks and 20 copied directories (60 files); 19 are identical to `.agents`, and `pr` has drifted | 17 + 14 + 72 files |
| Delegator skill alone | 43 files, 5,816 lines in its 30 largest files, 340 KB, including `listen-notify.py` (1,000 lines, with 1,530 lines of tests) and `gui-lock.sh` (205, tests 328) | — |
| `scripts/` | 125 files, 12,916 lines; 32 test files (`*.test.mjs`, `test_*.py`, scripts and the delegator skill), 6,809 lines | 163 files, 25.8k lines |
| Hooks | none (no `.claude/hooks`, no `core.hooksPath`) | 12 files; 3 `PreToolUse` on every Bash call |
| CI workflows | 3 files, 453 lines (`ci.yml` 150, `pr-body.yml` 65, `release.yml` 238) | 13 files, 1,591 lines |
| ADRs | **16**, all product or architecture. 0012 (UI test fixture) and 0013 (build by journey slices) come closest to process. 9 are still `proposed` or have no status line, although the code they describe has landed | 161; 56 about process by title |
| Feature ledger | 475 lines, 109 rows; touched by **646 of 1,433 commits**; 233 commits are `docs(ledger): garden`; HTML view regenerated in 525 | 798 lines, 333 commits |
| tdd-guardian | `receipts.json` gitignored (`.gitignore:61`); 164 tracked plan, test, attack, coverage and review markdown files, 6,622 lines; 56 commits | `receipts.json` tracked, 11.3 MB, 385 commits |

### 1.2 Measured: what runs per change, and what it caught

The delivery window runs from 2026-10-21 (first commit) to 2026-11-03.

| | picsee |
|---|---|
| Commits on `main` | **1,433**, none of them merges. Commit types: docs 561, fix 444, feat 208, test 166, chore 14, refactor 12, design 12, ci 12 |
| …touching `App/`, `AppTests/`, `Packages/`, `UITests/` or `project.yml` | 707 |
| …touching only docs, design, `.claude`, `.agents`, `.codex` or root `*.md` | 592 |
| …touching only `docs/feature-ledger.{md,html}` | 363 |
| Merged PRs | 196 (10-22 → 11-03); median 10.5 files and 565 changed lines (last 60) |
| PRs whose diff contains ledger files | 137 of 196 |
| PRs with only docs, design or agent files | 69 of 196 |
| Issues | 210 opened, 81 open (52 `ready-for-agent`, 26 `needs-triage`) |
| Releases | `v0.0.1-pre.1` (10-27, unnotarised pre-release); `v0.0.1-rc.1` **draft** since 10-31 |
| PR open → merge, median | 0.1 h. PRs are opened after the audits, so this does not measure the item |
| Issue created → closing PR merged, median (100 pairs) | 9.5 h (p75 36.8 h). **5.1 h** for the first 50 merges, **26.1 h** for the last 50 (split at 10-29) |
| Ledger status after 1,433 commits | **0 Shipped**, 65 Partial (63 `单元`, 2 `无`), 44 Absent |
| `Validated-by:` commits (device records) | 32; `Implemented-by:` 1,000 |
| PR body lines | `Ledger-Gardener:` in 196 of 196 PRs (CLEAN 92, UPDATED 79, NEEDS-OWNER 20, SKIP 3); `Device-Smoke:` in 64 (PASS 36, n/a 26, NOT 1) |

Controls compared with what they cost and what they caught:

| Control | Cost (measured) | Catches (measured) |
|---|---|---|
| **Blind audit, one or two auditors per round** (`docs/agents/audit-dimensions.md`, D1–D12) | 496 report files over 178 items. Report files per item: 67 items had 1, 39 had 2, 22 had 3, 28 had 4, 11 had 5 and 11 had 6 or more. Both auditors count when both ran. 115 fix briefs; most for p301 (6), then p310-s2, p204 and #136 (4 each) | **138 first-round High or Critical findings** (137 H, 1 C: eviction deleting outside the cache). Dimensions: D2 64, D6 32, D5 21, D3 19, D4 13. The paths they cite: product code 79, tooling 30, design states 6, docs 5, other 18 |
| **Feature ledger and gardener** | 646 commits touch the ledger; 363 change only the ledger; the gardener reads 135 KB on each run; the delegator keeps `resolve_rows.py`, `resolve_part3.py` and a regenerate-HTML loop only to merge ledger conflicts (`guide.md:484–493`) | NEEDS-OWNER on 20 PRs (rows the owner had to decide). I found no defect credited to it. It moved no row to `Shipped` |
| **Device smoke before merge** (memory rule, 10-27) | One flow per UI PR on the mini @1x, under the GUI lock shared with mdpro | 36 PASS lines. The Sparkle prompt hidden behind the window (#359) came from a device run. **0 of 36 ran @2x**; the 4 that mention @2x say it was not verified (#402, #389, #387, #188) |
| **TDD RED receipts** (Swift lane) | Local only; never committed; one Medium (`implementation-already-present`) on every Swift receipt by design | Not a landing gate, so it causes no rebase churn. I found no catch credited to it |
| **Spec gate, rule 10** (10-28) | `/grill-with-docs` → `/to-spec` → `/to-tickets` before any new feature | No gated feature has landed yet, so I could not measure a catch |
| **CI** (`Walking skeleton`, `PR body Gates`, `Agent tooling` are required) | Run median 7.4 min, p90 11.5 (71 successful runs); per job: package non-UI 6.8, MacUI 6.7, unsigned build 1.8, App tests 4.3, design check 0.8 | 13 PR failures and 10 `main` push failures in 100 runs. **8 of the 10 `main` failures are `App tests`**, which is not a required check |

### 1.3 Judgment on Part 1

1. **Class 1, the always-on load, is not picsee's problem.** It is a tenth of mdpro's. Two things are still worth trimming. First, `AGENTS.md` carries a 2,174-character paragraph on heavy-lock internals that every session reads and that only matters to someone running a heavy lane. Second, the delegator's 833-line guide is a large load (about 16k tokens) for one role, and it is rewritten often (35 commits). The bigger risk is *where* process rules live. Twenty-nine memory files hold policy (merge on green, push guard, serial heavy lanes) that is not in the repo, that Codex never sees, and that no reviewer can audit.
2. **The audit is doing real work, and the work is mostly about the product.** That is the reverse of mdpro, where tooling items took most rounds. In picsee, 79 of the 138 first-round Highs point at `App/` or `Packages/`. They are correctness (D2) and user-visible behaviour (D6) defects that unit tests passed. So the dual audit is not ceremony. The fact that it keeps finding new Highs on a third, fourth or fifth pass of the same item is the signal that the step before it is weak (Part 3, RC1 and RC2).
3. **The ledger is the most expensive document and has produced the least.** It is touched by 45 % of all commits and needs its own merge scripts. Even so, the status it exists to record, `Shipped` (a device-proved capability), has never been reached: 32 device validation records exist, and no row was upgraded. The gardener runs on every push and mostly returns CLEAN or a mechanical UPDATED.

---

## Part 2. Architecture and platform

### 2.1 Measured: structure against `docs/PICSEE_ARCHITECTURE.md`

| Target | Files / lines | Tests (files / lines / test functions) | What the architecture doc says, and what the code does |
|---|---|---|---|
| `App/` | 22 / 5,039. **`CanvasWindowController.swift` 2,503 lines (50 % of App), 149 commits**; `SettingsPanelWindow` 537; `AccessMonitor` 530 | `AppTests/` 55 / 10,568 / 90 `@Test` | §2.1: the App owns lifecycle and assembly and has no algorithms. §2.1 also says window and fullscreen handoff stay in the window controller, and that package coverage does not prove the native wiring. In practice the window controller holds the mode rules for grid, viewer, Inspector, search and refresh, which is where the Highs are (§2.3) |
| `PicseeCore` | 31 / 1,124; imports Foundation, CoreGraphics, CryptoKit | 22 / 1,145 / 54 | Matches: no AppKit and no SwiftUI |
| `PicseeApplication` | 50 / 3,122; no AppKit | 104 / 11,774 / 335 | Matches |
| `PicseeInfrastructure` | 39 / 5,245 | 122 / 17,770 / 559 | **Deviation.** The doc says "依赖 Core"; `Package.swift:34` also makes it depend on `PicseeApplication` ("Preferences implement the Application store port"; 3 files import it). Four files import AppKit, among them `DiskMountPort.swift` and `UserDefaultsDisplayPreferencesStore.swift` |
| `PicseeMacUI` | 43 / 6,488; AppKit 28, SwiftUI 8 | 140 / 21,434 / 555 | Matches: depends on Core and Application only |
| `UITests/` | 1 file, 346 lines, 4 XCTest functions | — | The doc's §9 asks for UI tests on critical journeys; one fixture-grid file exists |
| **Totals** | **production 21,018 lines** (package 15,979, App 5,039); 18 files over 300 lines | **444 test files, 63,037 lines, 1,597 test functions; tests : production 3.0 : 1**. 74 test files are named after an issue or page (64 `Issue…`, 9 `Page…`) | mdpro 4.4 : 1, vmark 2.0 : 1, marktext 0.7 : 1 |

The package targets keep the split the doc specifies, apart from the Infrastructure → Application edge. The 100 % line and function coverage gate (tdd-guardian `unit` lane) covers the package only. `App/` is excluded by design (doc §2.1; `App/UntestedResourceAdapters.swift`).

### 2.2 Measured: CI lanes and platform coverage

| Lane | Where | Required | Median (sample) |
|---|---|---|---|
| Package tests (non-UI) | `macos-26` | via `Walking skeleton` | 6.8 min |
| Package tests (MacUI, `--no-parallel`) | `macos-26` | via `Walking skeleton` | 6.7 min |
| Unsigned build plus ledger HTML check | `macos-26` | via `Walking skeleton` | 1.8 min |
| App tests (`scripts/tdd/app-lane.mjs`) | `macos-26` | **no** | 4.3 min (max 64.3) |
| Design check (Playwright, `npm run design:check`) | `ubuntu-latest` | no | 0.8 min |
| PR body gates and agent-tooling tests | `ubuntu-latest` | yes | — |
| Path filters | **none**. Docs-only PRs #380, #357, #356, #310, #295 and #283 each ran the full macOS workflow (6.5–8.2 min wall clock) | | |
| Direct pushes to `main` | none among the last 80 commits (every one maps to a PR); `enforce_admins: false` | | |

Platform facts:

- The Mac mini display is 1920×1080 @1x. `@2x checks cannot` run there (`remote-ssh` skill).
- Signing "works only in processes started from the desktop session"; over SSH it fails.
- The @2x MacBook became reachable only on 11-01, after owner-only steps (#131). Its first run hit the Sparkle prompt hidden behind the window (#359).
- GUI runs take the desktop GUI lock shared with mdpro. One incident: on 11-01, a smoke subagent held the GUI lock from 12:40 while its build timed out twice waiting for the shared heavy lock (handoff 20261031).
- Open flake and timing issues: #59 (coverage), #312, #353, #379 (issue281 / t231 App tests), #358 (LCOV nondeterminism), #393 (window tests to a hosted bundle) and #400 (`waitUntil` 100 s cutoff). Closed ones of the same class: #197, #249, #277, #290, #327, #333, #376 and #390.

### 2.3 Measured: coupling and shared files

The files changed by the most commits, all time:

| Rank | File | Commits |
|---|---|---|
| 1 | `docs/feature-ledger.md` | 646 |
| 2 | `docs/feature-ledger.html` (generated) | 525 |
| 3 | `App/CanvasWindowController.swift` | 149 |
| 4 | `App/Resources/Localizable.xcstrings` | 58 |
| 5 | `PicseeApplication/Browser/FolderScanCoordinator.swift` | 49 |
| 6 | `PicseeMacUI/Grid/GridBrowserView.swift` | 46 |
| 7 | `PicseeMacUI/Grid/GridShellView.swift` | 42 |
| 8–9 | `docs/PICSEE_DEVELOPMENT_PLAN.md`; `picsee-delegator/references/guide.md` | 35 each |

Other files asked about: `project.yml` 11, `scripts/verify_design_catalog.js` 10, `design/…/states/manifest.json` 12, `TestAssets/manifest.json` 3, `.claude/tdd-guardian/receipts.json` 0 (ignored).

In audit findings, `CanvasWindowController.swift` appears in **36 of the 181** High or Critical lines across all rounds. Next come `GridShellView` (9), `FolderScanCoordinator` (8), `GridBrowserView` (7) and `ViewerStateHost` (6). There are 22 "combo" report files, written when an item was re-audited together with another item it overlapped. On the four items with the most report files, the later rounds found *new* Highs in that file rather than re-finding the old ones:

- **p301:** Esc intercept before Session precedence; Cancel Reading restoring the wrong viewer; the Current Item from a single image; flow-layout width.
- **#136:** the Inspector obscuring content; grid search focus moving into the Inspector; Esc never reaching search; a watched refresh leaving stale metadata.
- **#140:** a File Grant moved to Trash; the Grid Inspector keeping old dimensions after an atomic replace.
- **p310-s2:** a `focusContext == .textInput` early return bypassing panel keys; a cancel-restore race after search became async; a refresh moving the Current Item to the first item instead of the nearest survivor.

Rebase evidence: the delegator guide has a dedicated procedure for ledger conflicts (`guide.md:484–525`: HTML regenerate loop, three-way row merge, Part 3 area-table resolver, a `LEDGER` conflict class left to `rebase-ledger.sh`). The guide lists `CanvasWindowController` and xcstrings conflicts as the ones to "stop and resolve deliberately". The 10-31 handoff mentions rebases on 38 lines; for example, #383 was rebased twice after #382 and #384 because of a "garden commit area-table conflict".

### 2.4 Judgment on Part 2

1. **The package architecture is sound and should stay.** Core, Application and MacUI hold the dependency rules, and the 100 % package coverage gate is unusual and valuable. The one drift, Infrastructure → Application for a preferences port, is small. It should become a Core protocol or be written down in an ADR rather than left as an appended dependency.
2. **The architecture has a hole exactly where the defects are.** The doc assigns state rules to Session and host effects to App. Yet the cross-mode rules (which view owns Esc, what a refresh does to the Current Item under a search filter, where focus goes when the Inspector opens) were built inside a 2,503-line AppKit controller. No package test and no coverage gate reaches that controller, and it has one UI test file. Each feature adds a branch there; each audit finds the next interaction. That is the shape of mdpro's RC4 ("concurrency solved per feature"), moved from locks to window modes.
3. **The test pyramid's base is wide and its top is missing.** There are 1,597 package and App test functions, but 4 XCUITest functions. Every journey-level proof is a manual device smoke at @1x. App tests on wall-clock timing are the flaky layer, and because that check is optional, `main` turns red without blocking anyone. Flakes then become issues and reruns instead of failures that someone has to fix.
4. **Class 4 is minor here.** Running docs-only PRs through the full macOS workflow costs runner minutes, not much wall clock (about 7 min). A paths filter would save money but would not change delivery time much.
5. **@2x is a release blocker that nobody has scheduled.** 39 ledger rows name @2x, and no smoke ran there. Closing that gap at release time means one big session at the end, the same "host-last" shape as mdpro's RC1.

---

## Part 3. Diagnosis

### 3.1 Root causes, ranked by impact on delivery time

**RC1. The window-level state machine lives in an untested AppKit controller.**

- *Evidence:* see §2.1 and §2.3. The file is 2,503 lines with 149 commits and appears in 36 of 181 High lines. The four items with the most report files (p301 15, #136 15, #140 12, p310-s2 8) all found new Highs there in later rounds, and 22 combo re-audits exist.
- *Change:* move mode and focus rules (Esc precedence, grid, viewer, Inspector and search transitions, refresh survivor choice, cancel-restore) into a `WindowModeModel` in `PicseeApplication`. Test it table-driven over event sequences (open, search, Inspector, refresh, Esc, close), so it falls inside the 100 % gate. `CanvasWindowController` then only applies host effects, as doc §2.1 already says.
- *Cost and risk:* about one to two weeks. Splitting the 2,503 lines touches every open UI branch, so it should land between waves.

**RC2. ACs and test matrices cover one feature, not its interactions with others or its lifecycle.**

- *Evidence:* I sorted the first-round Highs by keyword. The counts are approximate, and one finding can match several themes: test or evidence gaps 34; layout, pixels or focus ring 33; lifecycle (cancel, close, relaunch, stale) 18; sandbox or grant 16; data loss 16; locale or truncation 11; ordering 6. Examples: English labels truncated (`i218`, #136), closing a window without cancelling `sidebarTreeTask` (`p310-s3`), a "UI AUTO-PASS" claim that exceeded its assertions (`p310s2`). The issue-to-merge median rose from 5.1 h to 26.1 h as items started combining Grid, Viewer, Inspector and search. That is partly item size, which I could not separate out.
- *Change:* add a standing interaction-and-lifecycle block to `brief-template.md` and to the test-design step:
  - every new mode or panel × {Esc, focus, refresh, close and relaunch, cancel mid-load};
  - every new string × {zh-Hans, en, longest label};
  - every new layout × {light, dark, @1x, @2x}.
- *Cost:* a template edit. It moves findings from the audit round to the matrix step.

**RC3. Proof on a real device is manual, happens last, and only at @1x.**

- *Evidence:* 0 of 36 PASS smokes at @2x; 0 `Shipped` rows; the UI test target holds 4 test functions; signing works only from the desktop session; one GUI lock is shared with mdpro.
- *Change:* grow `UITests/` into a small journey suite on the fixture container (ADR-0012 already exists). Start with J1 and J2 and the grid, viewer and Inspector paths in RC1, and run it on the macOS CI runner unsigned. Keep the human smoke for what CI cannot see: signing, sandbox grants, pixels. Batch one @2x pass per release candidate on the MacBook.
- *Cost:* the CI job gets longer. XCUITest on hosted runners has flakes of its own, so start with the cases that are deterministic.

**RC4. App tests that depend on time are flaky, and their check is optional.**

- *Evidence:* 8 of the 10 failed runs on `main` in the sample were App tests; there are 7 open and 8 closed flake or time-limit issues; #393 and #400 are still open.
- *Change:* land #393 (hosted bundle; no fixed time-limit rule) and #400. Then make `App tests` required. Until then, keep an explicit quarantine list instead of rerunning on red.

**RC5. The ledger is a hot file whose top status is never reached.**

- *Evidence:* 646 of 1,433 commits; 363 commits that change only the ledger; 233 garden commits; dedicated merge scripts; 135 KB read by each gardener run; 0 `Shipped` despite 32 validation records.
- *Change:* generate the "在哪" column and the verification column from tests and `docs/validation/` records, as vmark joins its ledger in CI (mdpro report §1.2). Keep the gardener only on PRs where the garden gate says RUN (started in `1bedb154`). Split the ledger into one file per area to cut conflicts. Ask the owner once to upgrade the rows that already have device records.

**RC6. Process rules live outside the repo.**

- *Evidence:* 29 memory files, 564 lines; the guide's 29 dated decisions; the heavy-lock paragraph in always-on `AGENTS.md`.
- *Change:* move the memory rules that are policy into `docs/agents/delegator-policy.md`, so Codex and auditors can see them. Move the heavy-lock detail into `scripts/heavy-lock.sh --help` and leave one line in `AGENTS.md`.
- *Cost:* small. This is the cheap form of mdpro's ADR-0147, done before the surface grows.

### 3.2 Complexity that is essential and should stay

| Control | Why it should stay (measured) |
|---|---|
| Blind audit with a confirm round | 138 first-round Highs, mostly D2 and D6 defects in product code that tests passed; the one Critical (cache eviction outside its root) |
| Five-target package split and 100 % package coverage | The dependency rules hold apart from one edge; Core, Application and MacUI tests are the bulk of 1,597 test functions |
| Sandbox from P0 (ADR-0006/0008/0011) | 13 first-round Highs filed under D4 (security, privacy, sandbox) were caught before release |
| Heavy lock and serial heavy lanes | Built after the 10-29 OOM on the mini; the lanes are shared with mdpro |
| One-flow device smoke | It found what CI cannot (#359 Sparkle occlusion); it is cheap per PR |
| Receipts kept out of git | Already avoids mdpro's RC5 (rebase drops, multi-MB diffs) |
| Required CI at about 7 min on macOS | Fast enough; macOS-only matches the product |
| Rule 10 spec gate | Too new to measure; keep it and re-measure in §5 |

---

## 4. Facts and judgments, kept apart

The facts are the tables in §1.1, §1.2, §2.1–§2.3 and the evidence index. The judgments are §0's ranking, §1.3, §2.4, §3 and §6. Caveats on the facts:

- "Report files per item" counts both auditors and confirm rounds, so it is not the number of rounds. The grouping key is derived from file names, so a few items may be split or merged.
- I sorted the findings into themes by keyword over the finding titles. Treat the theme counts as an approximation; the dimension counts (D2, D6…) are exact.
- Token figures are estimates (one token per CJK character plus one per four other characters). I did not run a tokenizer.
- The jump in issue-to-merge time from 5.1 h to 26.1 h may partly reflect larger P3 items. I could not separate item size from process friction.
- CI per-job medians come from 60 runs. Older runs had different job names, so the `Walking skeleton` sample mixes the old single job with the current gate.
- I made no peer comparison beyond mdpro, vmark and marktext, and those figures are the mdpro report's.

---

## 5. Measured deltas for a four-week follow-up

| Metric | Today |
|---|---|
| Always-on lines (AGENTS, CLAUDE, rules, global) | 192 (+28 memory index) |
| Commits that change only the ledger : commits that touch code | 363 : 707 |
| Ledger rows `Shipped` / `Partial` / `Absent` | 0 / 65 / 44 |
| `CanvasWindowController.swift` lines / its share of High lines | 2,503 / 36 of 181 |
| Report files per item, mean (product items) | 2.77 |
| Items with 4 or more report files | 50 of 178 |
| Issue → merge, median (last 50) | 26.1 h |
| Device smokes at @2x | 0 of 36 |
| XCUITest functions | 4 |
| Failed `main` runs caused by App tests | 8 of 10 (sample of 37 pushes) |
| Required CI run, median | 7.4 min |

---

## 6. A short sequenced plan

**Now, without a rule change:**

1. Add the interaction-and-lifecycle block to the brief template and the test-matrix step (RC2).
2. Ask the owner, once, to rule on upgrading the ledger rows that already have `Validated-by` records (RC5).
3. Quarantine the named flakes explicitly; stop treating a red `main` from App tests as normal (RC4).
4. Move the heavy-lock paragraph out of `AGENTS.md` and copy the policy memories into a tracked doc (RC6).

**Next, as work items through rule 10:**

1. `WindowModeModel` in `PicseeApplication`: extract Esc, focus, mode and refresh rules from `CanvasWindowController` with table-driven tests (RC1). Schedule it between waves.
2. #393 and #400, then make `App tests` required (RC4).
3. Grow `UITests/` into a journey suite on the fixture container, run it in CI, and schedule one @2x pass per release candidate (RC3).
4. Generate the ledger's evidence columns, split it per area, and run the gardener only on RUN (RC5).
5. Resolve the Infrastructure → Application edge: either a Core protocol, or an ADR recording the dependency as it stands.
6. Optional: a `paths-filter` so docs-only PRs skip the macOS jobs.
7. Re-measure §5 after four weeks.

---

## Evidence index

All commands ran in the audit worktree (`origin/main` `4ca72f8d`) unless the path says `~/.picsee/…`. The output is trimmed.

- **Always-on size:** `wc -lwc AGENTS.md CLAUDE.md .claude/rules/*.md ~/.claude/CLAUDE.md` → 138/6/43/5 lines, 17,041 bytes in total. `head -12 .claude/rules/*.md | grep -c '^paths:'` → 0. `awk '{print length}' AGENTS.md | sort -rn` → 2174 (line 108). The token estimate came from a Python CJK and ASCII counter → AGENTS about 3,912, guide about 15,942, ledger about 41,073.
- **Agent configuration:** `find .agents/skills -type f | xargs wc -l` → 116 files, 10,292 lines. `diff -rq .claude/skills/X .agents/skills/X` → 19 identical, `pr` differs. `ls -la .claude/skills | grep -c '^l'` → 3. `wc -l .claude/agents/* .codex/*/*` → 638 in total. `find scripts -type f | xargs wc -l` → 12,916. `wc -l .github/workflows/*` → 150/65/238. `ls docs/adr | wc -l` → 16, with `grep -m1 '^status'` per file.
- **History:** `git log --no-merges --format='@@…' --name-only origin/main | awk …` → total 1433, code 707, docs or agent only 592, ledger only 363. `git log --format=%s | sed 's/^\([a-z]*\).*/\1/' | sort | uniq -c` → docs 561, fix 444, feat 208, test 166. `git log --oneline | grep -c 'docs(ledger): garden'` → 233. `git log origin/main --format=%B | grep -c '^Validated-by:'` → 32.
- **Hot files:** `git log --no-merges --format= --name-only origin/main | sort | uniq -c | sort -rn | head -30` → ledger 646, html 525, CanvasWindowController 149, xcstrings 58… Per path: `git log --oneline origin/main -- <path> | wc -l` → project.yml 11, verify_design_catalog.js 10, states/manifest.json 12.
- **Ledger:** `awk -F'|' '/^\| *[A-Z0-9]+-[0-9]+ *\|/{print $4"/"$5}' docs/feature-ledger.md | sort | uniq -c` → 63 Partial/单元, 44 Absent/无, 2 Partial/无.
- **Code structure:** `find <target> -name '*.swift' | xargs cat | wc -l` per target. `grep -rhE '^\s*@Test'` and `grep -rhE 'func test…'` per test target → 90/4/335/54/559/555. `grep -rhE '^import' Sources/<m> | sort | uniq -c`. `sed -n 26,35p Packages/PicseeKit/Package.swift` → the appended `PicseeApplication` dependency.
- **PRs:** `gh pr list --state merged --limit 200 --json number,createdAt,mergedAt,changedFiles,additions,deletions,files,body,closingIssuesReferences` → 196 PRs; medians; path categories; `Device-Smoke`/`Ledger-Gardener` captures via `jq`; issue → merge pairs via `gh issue list --state all --limit 500 --json number,createdAt`.
- **CI:** `gh run list --workflow ci.yml --limit 100 --json …` → 71 successes, median 7.4 min, p90 11.5. `gh run view <id> --json jobs` over 60 runs gave per-job medians, and over the 10 failed `main` pushes gave 8 App tests and 2 Walking skeleton. `gh api repos/anzchy/picsee/branches/main/protection` → required `Walking skeleton`, `PR body Gates`, `Agent tooling`; `enforce_admins` false. `gh api repos/anzchy/picsee/commits/<sha>/pulls` over the last 80 commits → 0 without a PR.
- **Audits:** a Python parse of `~/.picsee/herdr/{gpt,opus,fable}-auditor/*.md`: 496 files; `COUNT C… H…` lines in 424; first-round `[High]`/`[Critical]` finding lines 138 (137 H, 1 C), with dimension and path classification; all-round C/H lines 181, of which 36 cite `CanvasWindowController.swift`; 22 `combo` files. `find ~/.picsee/herdr -name '*fix*brief*.md'` → 115.
- **Handoffs:** `grep -ci` over `~/.picsee/handoff/*.md` for rebase, conflict, gui-lock, @2x and flake. Quoted lines: #383 area-table conflict; the 11-01 GUI-lock hold during heavy-lock timeouts; #131 MacBook @2x setup on 11-01.
- **Flakes:** `gh issue list --state all --search 'flake OR flaky OR timeout in:title'` → #59, #312, #353, #358, #379, #393 open; #197, #249, #277, #290, #327, #333, #376, #390 closed. `gh issue view 400`.
- **Platform:** the `remote-ssh` skill (machine-local): mini @1x, signing only in desktop-session processes, MacBook @2x.

---

## 中文摘要（给 owner）

1. picsee 没有重复 mdpro 的主要问题：常驻指令 192 行（mdpro 1,936 行），ADR 16 份且全是产品决定，收据不入库，必需 CI 约 7 分钟（mdpro 25 分钟）。第一轮审计的 High 里，79 条指向产品代码，只有 30 条指向工具。
2. 13 天里 `main` 有 1,433 次提交、196 个 PR。其中 707 次改代码；646 次改了功能账簿，363 次只改账簿。账簿 109 行里仍然没有一行是 `Shipped`（65 Partial，44 Absent）。
3. 时间主要耗在 `App/CanvasWindowController.swift`：2,503 行，149 次提交，不在包覆盖率门禁内，出现在全部 181 条 High/Critical 里的 36 条中。p301、#136、#140、p310-s2 这几项后几轮审计找到的都是新问题：Esc 优先级、Inspector 与搜索和刷新的组合、焦点。
4. 验收标准和测试矩阵按单个功能写，没有覆盖功能之间的组合、生命周期、语言、布局，于是审计一轮补一个；共有 22 份 combo 复审报告。问题从开到合并的中位数从 5.1 小时升到 26.1 小时（部分原因是条目变大）。
5. 真机验证全靠手工、只在 @1x：36 次 smoke PASS 里没有一次在 @2x 跑；UI 测试只有 4 个函数。`main` 上 10 次 CI 失败中有 8 次是 App tests，而这个检查不是必需的。
6. 根因排序：① 窗口级状态机藏在不测的 AppKit 控制器里；② AC 不覆盖功能组合和生命周期；③ 真机证明手工、最后才做、只有 @1x；④ App tests 依赖时间、容易随机失败，而且不是必需检查；⑤ 账簿是热点文件，最高状态从没达到；⑥ 流程规则散在本机 memory 里，不在仓库。
7. 该保留的：盲审加 confirm、五 target 包结构和 100% 包覆盖、P0 起开 sandbox、heavy lock、单流程 smoke、收据不入库、快速的 macOS CI、rule 10 规格门。
8. 现在就能做：brief 模板加「组合与生命周期」清单；请 owner 一次性裁定已有真机记录的账簿行能否升级；明确隔离 flaky 测试；把 heavy-lock 长段移出 AGENTS.md，把政策类 memory 收进仓库文档。
9. 下一步（走 rule 10）：在 PicseeApplication 里建 `WindowModeModel`，把 Esc、焦点、模式、刷新规则移出 CanvasWindowController，用表驱动测试覆盖；做完 #393/#400 后把 App tests 设为必需；把 UITests 扩成 journey 套件进 CI，每个 RC 安排一次 @2x；账簿证据列改为生成、按区域拆文件。
10. 四周后按第 5 节基线复测。
