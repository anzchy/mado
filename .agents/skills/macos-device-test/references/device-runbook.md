# macOS Device Test (computer use) — Mado

This runbook supplies the exact helper contracts and proof standards for a real Mado device run.
The device tester must be independent of the implementer: the doc gardener flags self-certified
`Shipped` rows.

**Automation policy: automate every step that can be automated; bring in the user only where automation
truly can't work.**

- **Default executor:** computer use plus shell drives the whole run: clicks, keys, scrolling, focus changes,
  log reads.
- **When the user steps in:** only for a step with a known, recorded tool limit, or when an automated
  attempt fails because of the tool rather than the app. The brief names each such step up front; at that
  step the run stops, asks, then continues.
- **Verdict when the tool can't do a step:** NOT VERIFIED (tool limit), never FAIL. Rerun that step later
  with the user.
- **Record every deviation** where automation took a different path from a real user (e.g. activating the
  app instead of clicking its window).

Store run briefs under `~/.picsee/device-briefs/`; this keeps them separate from mdpro's `dtrack` session.

## 1. When this lane is the right one

| The automated lanes can't see… | so this lane checks… |
|---|---|
| real backing pixels on a given display scale | 1:1 actual pixels, Retina sharpness, no resampling at 100% |
| the cursor in screen space | the pixel under the cursor stays put while zooming (anchor) |
| wall-clock chrome timing with real input | tools hide after ~2.5 s, wake on mouse-to-top, stay while a menu/Inspector is open |
| the sandbox powerbox | `NSOpenPanel` folder grants, the "not authorized" entry point |
| app relaunch | security-scoped bookmark restore, access released on close |
| the window server | traffic lights hiding with the tools, full screen, focus rings, light/dark |

**Do not use it** for anything a pure function or a fake can decide. Command routing, selection state,
`ViewerChromeState` transitions on a controllable clock, request cancellation and cache keys belong in unit
tests. XCUITest covers what can be scripted through accessibility. This lane confirms that the geometry,
timing and permissions feeding those tested modules are real.

## 2. Pick the machine

| Machine | Use it for | Can't do |
|---|---|---|
| Mac mini (M4, 16 GiB, macOS 26.4, 1920×1080 @1x) | the local device-test machine; the plan §10 performance baseline and every check that doesn't need @2x | Retina criteria: record NOT VERIFIED (no @2x display) |
| MacBook Pro (M4, 24 GiB, macOS 27.0.1, Retina @2x) | @2x criteria only (P0-03, P1-03, state page 27), reached from the mini with the `ssh macbook` alias (working since 2026-11-01, #131) | baseline performance numbers (not the §10.1 baseline) |

On the mini, run from an agent session with access to the local desktop. For @2x, send commands over `ssh macbook` into a
tmux session started on the MacBook's own desktop. Signed builds and launches must run inside that desktop-started
session because a plain SSH session cannot reach the login keychain (`errSecInternalComponent`). Every record names
the machine, chip, memory, macOS version, display and scale.

The MacBook procedure, first passed on 2026-11-01 (#131: doctor 12 PASS, scale 2.0, a 960×640 pt window captured at
1920×1280 px):

- **Session.** The owner opens Terminal.app on the MacBook's desktop and runs `tmux new -s picsee-mbp`, then
  `caffeinate -dimsu &` inside it. Started from SSH, tmux is not on `PATH`: use `/opt/homebrew/bin/tmux`.
- **Permissions (owner only).** Terminal.app needs Screen & System Audio Recording and the permission that macOS 27
  lists as **Privacy & Security → Device Control and Data Access** (Accessibility on earlier macOS). Restart Terminal and
  tmux after granting. Check from inside tmux: `AXIsProcessTrustedWithOptions` and `CGPreflightScreenCaptureAccess`
  both return true. Plain SSH processes do not have them, so `osascript` over SSH fails with `-1728`.
- **Running a step.** Write a script on the MacBook that logs to the run directory, start it with
  `tmux send-keys -t picsee-mbp '<script>' Enter`, and poll the log over SSH. Set
  `PICSEE_XCODE=/Applications/Xcode-26.6.app`. Pass `--expected-sha` the 8-character short SHA that `build.sh` prints
  (for example `235e94ef`), not 7 characters.
- **First launch.** Sparkle's "Check for updates automatically?" window can sit behind the main window. Until it is
  answered for the bundle ID, `launch.sh`, `doctor.sh` and `shot.sh` fail with "missing visible Mado window" (#355).
  The answer is the owner's, because it also applies to their installed Mado.
- **Limits.** One device run at a time on the MacBook; never quit or kill a Mado the run didn't start. The MacBook is
  not the performance baseline. Until this session and those permissions are available, record every @2x criterion
  as NOT VERIFIED.

## 3. Isolation: one instance per machine

Two Mado instances must not be driven side by side on one machine. They share the bundle identifier, so
they share the sandbox container, preferences and bookmarks. Plain `open` may route to an existing instance;
`open -n` can create another, so isolation is checked before launch and the recorded PID identifies this run.
So:

- **One device run per machine at a time.** Never drive an instance this run didn't start (§5 records which
  one it started).
- **One computer-use driver per desktop.** On the mini, mdpro's `dtrack` tmux session drives the same screen;
  confirm it is idle before starting, and never send it commands or otherwise touch it.
- **Take the shared desktop GUI lock first** (agreed with mdpro; mdpro ADR-0141 WI-2). The lock is the directory
  `~/.cache/desktop-gui.lock/`, and its key=value `owner` file is the one that counts. Acquire it with
  `.agents/skills/picsee-delegator/scripts/gui-lock.sh acquire <run-id> <minutes> "<purpose>"` before the first launch,
  keystroke, click or screenshot, and keep the `acquisition_id=<uuid>` from its `ACQUIRED` line. Hold it across
  relaunches, and release it after cleanup, also on aborted runs, with
  `gui-lock.sh release <run-id> --acquisition-id <uuid>`.
  Exit 75 means mdpro holds it: drive nothing and wait, or tell the user. Never remove another project's lock.
- **The user's own Mado is off limits.** If a Mado is running that this run didn't start (an installed
  copy, a dev build from Xcode), stop and ask the user to quit it. Don't kill it.

## 4. Build a bundle — never test a bare executable

Computer-use grants are keyed by **bundle identifier**, and so is the sandbox container. Only a built `.app`
with `Contents/Info.plist` has one. A command-line target or `swift run` gives you a window computer use can't
see and a process the sandbox doesn't treat as Mado.

Quit the previous run's instance first (§11 cleanup kills it by its recorded PID), then build:

```bash
export PATH=/opt/homebrew/bin:$PATH
RUN_ID="$(date +%Y%m%d-%H%M%S)-<ledger-ids>"
RUN_DIR="$HOME/.picsee/device-runs/$RUN_ID"
scripts/device/build.sh "$RUN_DIR"
APP="$(cat "$RUN_DIR/bundle.path")"
```

The helper generates the project, then makes a signed **Debug** build in
`.build/device-<run-id>/` inside this worktree. It rejects modified, missing or untracked build inputs (including resources, plist, entitlements,
package files, test assets and project configuration), while allowing agent metadata in `.codex/`,
`.claude/` and `docs/`. It verifies the full input inventory against HEAD before and after the build,
refuses a running Mado, records input hashes, the short/full SHA and machine facts in `build.json`, and
saves build output in
`build.log`. Generated package caches are excluded from build inputs. If the inherited Xcode stamp marks allowed
metadata edits dirty, the helper normalizes the verified build SHA and re-signs the bundle, preserving
entitlements and signature metadata. Debug performance numbers do not count as a
Release baseline. A Release performance run needs its own explicit build and record.

The locked Xcode is **26.6, build 17F113** (decided 2026-10-22, following the Mac mini). The helper uses the
first of `/Applications/Xcode-26.6.app` and `/Applications/Xcode.app` whose `xcodebuild -version` reports that
build. `PICSEE_XCODE` explicitly overrides this search but is checked against the same build. On the MacBook,
Xcode 26.6 sits beside Xcode 27.1; Mado is never built with 27.1.
Confirm `xcodebuild -version` prints `Build version 17F113` before building. Product and scheme `Mado`, bundle identifier
`io.github.anzchy.mado` (#547, ADR-0017; renamed by #550/#551). Run long builds in the background and monitor `build.log`. If you test a Debug build, say so in the record: it's a different binary, and
its performance numbers don't count.

**Signing matters for the sandbox.** The sandbox and security-scoped bookmarks only work in a signed app.
Device-test builds are signed with the Apple Development certificate of team `GRT84NAK4T` (manual signing: style, identity and team set in `project.yml`; Xcode 26.6's GUI won't open on macOS 27, so no Xcode account and no automatic signing); an ad-hoc signed build isn't a valid device-test build. Whether a bookmark created by
one local build still resolves after a rebuild (a new signature) is **unverified**; P0-04 must find out. Until
then, a bookmark-restore check relaunches the *same* bundle, and the record states which build created the
bookmark and which one resolved it.

## 5. Launch, and what "ready" means

Each run gets an ID and a run folder outside the repo. Evidence goes there and survives cleanup:

```bash
scripts/device/launch.sh "$RUN_DIR"
# Records bundle.path, picsee.pid, process.json (PID/path/birth), start.txt, ready.json and app.log.
```

The helper calls `open -n -W` with the absolute bundle path (`-W` lets it notice an immediate App exit), finds exactly one new PID by its exact
executable path and a birth time after launch began, then records the PID, executable path and process start time (`ps -o lstart=`) in `process.json` before checking
readiness. Old, missing, ambiguous or retired ownership records are refused; use a fresh run directory. It never picks a PID by owner name or newest
name match. A pre-existing Mado blocks launch and is never recorded or stopped; cleanup signals only the recorded PID while its birth identity still matches. The P0 skeleton run opens no fixture; it has one empty window.

To run the App in a given UI language without touching system settings, write a language tag to `$RUN_DIR/app-lang.txt` before launching (for example `zh-Hans` to match the Chinese pinned pages). The helper then passes `-AppleLanguages (<tag>)` to that launch only, and the file stays in the run folder as evidence. Anything that isn't a plain language tag is refused before launch.

For a future file-opening recipe, pass the scratch fixture through the app's normal open entry point.
Opening a file this way is a **File Grant**: the sandboxed app can read that file without a dialog. A folder
must become an **Access Root** through the powerbox (`NSOpenPanel`), driven with computer use. Never work
around the powerbox: no Full Disk Access, no entitlement change, no copying files into the container.

**Ready means usable, not just "a process exists":** exactly one accessibility window titled `Mado`
or the verified fixture basename is present, its PID has an on-screen layer-0 CGWindow, and the public
launch log with the expected build SHA has appeared. The P0 skeleton is an empty window; future recipes also confirm their fixture is displayed.
Time out after 30 s and report what was missing. An Automation/Accessibility failure stops immediately;
an interactive prompt is a blocker to report, never something to dismiss automatically.

**First-launch state.** A cold-start test changes the app's shared sandbox state. Get the user's
approval for the named run before moving or editing any container/store file; record an intact backup
and its restoration. Never remove the container as a routine setup step.

## 6. Doctor: is this instance worth driving?

Run this read-only check first, and again whenever anything looks off. Every line must pass; a failing line
stops the run with that line as the reason.

```bash
scripts/device/doctor.sh "$RUN_DIR" --expected-sha "$(git rev-parse --short HEAD)"
```

The helper prints exactly one verdict line for each check below: `PASS <check>` (with documented
check-specific detail) or `FAIL <check> — <why>`. In particular, a passing window check prints
`PASS window — title=<name>`. It saves the output atomically as `doctor.txt` and exits non-zero if any fail.
Collection errors become FAIL on the affected checks; all twelve lines replace the previous report even
when a bundle, plist or record is missing or malformed. The twelve verdicts reach stdout before the report
write. If storage fails, an
additional `FAIL report-write` line names the failure, the exit is non-zero, and an old report is moved to
`doctor.stale.txt` (or removed). If storage prevents both, the diagnostic explicitly marks the old
`doctor.txt` STALE/UNUSABLE. `doctor-input.json` keeps the observations.

| Check | Pass when |
|---|---|
| `build-sha` | `Info.plist`'s `MadoGitSHA` equals the expected short SHA (defaults to this worktree's HEAD) |
| `bundle-id` | `CFBundleIdentifier` is `io.github.anzchy.mado` |
| `signature-team` | codesign reports `TeamIdentifier=GRT84NAK4T` |
| `signature-valid` | `codesign --verify --deep --strict` succeeds |
| `sandbox` | the signed `com.apple.security.app-sandbox` entitlement is true (explicit XML from `codesign -d --entitlements :-`) |
| `process-bundle` | recorded PID, executable and process birth all match the live process; the record is active |
| `fresh-sources` | every build input matches the committed inventory and recorded hashes; none is newer than the bundle Info.plist |
| `single-instance` | the recorded PID is the only running process named Mado |
| `window` | one snapshot of `properties of every window`, addressed by PID, contains exactly one window titled `Mado` or the basename of a file recorded in `fixtures.sha256.json`; untitled windows become empty titles, and `0 windows` is distinct from an AX error |
| `launch-log` | this PID's unified log since `start.txt` contains `Mado launch git=<expected SHA>`, unredacted |
| `machine` | model, chip, memory, macOS and main-display backing scale match `build.json`; check these against the brief too |
| `fixtures` | no fixtures for a skeleton run, or all fixture files match the run's `fixtures.sha256.json` |

For an image recipe, first verify the copies against `TestAssets/manifest.json`, then record the verified
relative paths and SHA-256 values as a JSON object in `fixtures.sha256.json`. Missing hashes with nonempty
fixtures fail. This fixture path has not been exercised by the skeleton proof.

The SHA in both the signed plist and the live process log matters: replacing a bundle on disk does not
replace an already-running image. A private or missing SHA never passes.

## 7. Drive

- **Follow the feature recipe.** Each feature has a file in [features/](../features/README.md) with its entry
  points, preconditions, steps and observable results. Run the recipe as written. If it's wrong, fix the
  recipe in the same change and say so in the record.
- **Stable handles first.** Prefer keyboard shortcuts and accessibility identifiers to coordinates. The
  identifier naming convention is set in P0-01 and listed in [`../features/README.md`](../features/README.md). Coordinates are a last
  resort; they differ between the local @1x mini and the @2x MacBook reached over SSH.
- **Characters and named keys are different inputs.** `key.sh` accepts exactly one printable character.
  Send named keys through `kc.sh`: Tab `48`, Esc `53`, Return `36`, Left/Right/Down/Up `123`–`126`, and
  Space `49`. For example, `key.sh "$RUN_DIR" tab` is invalid; use `kc.sh "$RUN_DIR" 48`.
- **Probe symmetrically.** Zoom in N steps, then out N steps, at the same cursor point. Navigate forward, then
  back. A directional defect is invisible to a one-way sweep.
- **Hold still and re-check.** For chrome timing, wait with no input and note when the tools hide; then wake
  them. Repeat with a menu, the Inspector and Filmstrip open.
- **Probe the boundaries.** The first and last image, an image smaller than the window, an 800×680 window, a
  very long file name, a folder outside every Access Root, a relaunch.
- **Feel isn't measurement.** Plan §10 metrics need ≥30 samples with p50/p95 from signposts or logs. A run
  that only looked smooth says "felt responsive, not measured".

## 8. Fixtures

Fixtures come from the `TestAssets/` manifest (P0-07; sets S1–S6 in plan §10.1). **Never personal photos.**
Copy them into `$RUN_DIR/fixtures/` and open the copies: later work can write next to an image, and the
committed originals must stay untouched.

A good fixture makes the screenshot **self-verifying**:

- **1:1 pixels:** a 1-px black/white checkerboard. At actual pixels it is crisp; any resampling turns it grey
  or moiré.
- **Zoom anchor:** a coordinate grid with labelled cells. The label under the cursor before and after zoom
  must be the same cell.
- **Orientation:** one image per EXIF orientation value 1–8, each showing an arrow and the word `TOP`.
- **Transparency:** an alpha gradient over a known pattern.
- **Large and broken:** S3's 48MP and 100MP images and a synthetic oversize header; S5's truncated and corrupt
  files.

## 9. Proof standards

A criterion passes only with evidence that meets all of these:

- **The real user path.** Drive what a user would: menus, keys, clicks, the powerbox. No debug menus,
  test-only hooks, `defaults write` to set up state, or files placed in the container by hand.
- **Every entry point the criterion lists.** If the ledger's 怎么确认 says "pinch or +/−", drive both. An
  entry point you didn't drive is NOT VERIFIED for that row, and is never reported as verified through a
  different one.
- **The action and the resulting state**, not only the final screen: what you did, then what changed.
- **A second, independent view of anything persisted or written.** Persistence is checked by quitting and
  relaunching, then looking in the app. A file write is checked by reading the file (`mdls`, `exiftool`,
  `shasum`), not by the app's success message. A released Access Root is checked in the log, not assumed from
  a closed window.
- **Tagged.** Every artifact's name carries the ledger row ID and the entry point, e.g.
  `shots/VIEW-03-pinch-after.png`.

## 10. Evidence

### Logs: unified logging, read by time window

```bash
log show --start "$START" --style compact --predicate 'subsystem == "io.github.anzchy.mado"' \
  > "$RUN_DIR/app.log"
```

A negative claim ("nothing was logged while scrolling") is only credible inside a window like this.
Interpolated values that aren't marked `public` show as `<private>`; if a criterion needs one, that's a
logging defect to report, not a reason to guess.

### Screenshots

Capture the window, not a screen rectangle: a terminal can cover Mado while a rectangle capture silently
records the terminal. The helper selects the on-screen layer-0 window by this run's PID and calls
`screencapture -l<CGWindowID> -o`, preserving native backing pixels without the shadow.

```bash
scripts/device/shot.sh "$RUN_DIR" P0-tooling-native-window
sips -g pixelWidth -g pixelHeight "$RUN_DIR/shots/P0-tooling-native-window.png"
```

Screen Recording is preflighted without requesting or changing permission. If missing, the helper prints
`FAIL` naming Screen Recording and exits non-zero. A temporary capture is decoded and sampled for visible
pixels; a black, transparent or empty result is rejected and removed before publishing the PNG. Existing
artifacts are never overwritten. The @2x MacBook proof is 960×672 pt → 1920×1344 px. Screenshots go to
`$RUN_DIR/shots/`, **never into the repo**. The repo is public.

## 11. Cleanup

Kill what this run started, by its recorded PID. Never by process name: `pkill -x Mado` would also kill the
user's own copy.

```bash
scripts/device/cleanup.sh "$RUN_DIR"
ls "$RUN_DIR/shots" "$RUN_DIR/app.log" "$RUN_DIR/doctor.txt"
```

- Cleanup requires an active ownership record. It compares the live PID, executable path and birth time
  to `process.json`, validates again immediately before SIGTERM, and signals that PID only. An identity
  mismatch refuses action; an independently confirmed exited process is reported without a signal.
- Every cleanup attempt writes the `retired` marker, including refused or failed attempts. Retired records
  cannot drive cleanup, doctor, capture or input. Evidence stays intact; a new launch needs a new run folder.
  Capture and input also validate birth identity immediately before their action.
- No process-name kill and no escalation to SIGKILL. If SIGTERM does not finish within five seconds,
  report the failure. Never kill an instance this run did not start.
- Evidence and scratch copies remain in the run folder. No recursive deletion is part of cleanup.
- Restore the sandbox container only if the brief changed it, and only as the brief says.
- Run cleanup after a failed or aborted run too, so a broken attempt does not contaminate the next run.

## 12. The verdict table

Every run produces one row per criterion and entry point, keyed by ledger row ID, with an explicit verdict:

| # | Ledger row | Criterion | Entry point | Result |
|---|---|---|---|---|
| 1 | VIEW-03 | Pixel under the cursor stays put, zoom in and out | `+`/`−` | pass |
| 2 | VIEW-03 | Same | trackpad pinch | **NOT VERIFIED** — computer use can't pinch |
| 3 | VIEW-02 | 1:1 survives moving between display scales | drag the window from a @2x display to a @1x display | **NOT VERIFIED** — no device-test machine has both scales |
| 4 | VIEW-02 | 1:1 checkerboard is crisp at actual pixels | `1` on @2x | **NOT VERIFIED** — MacBook SSH/tmux path is not set up |
| 5 | CHROME-01 | Tools hide after ~2.5 s, reappear at the top edge | idle, mouse | **FAIL** — stays visible after a menu closes |

- A criterion or entry point you couldn't exercise is NOT VERIFIED, with the blocker named. Never upgrade it.
- A criterion judged by feel says so.
- A FAIL carries the reproduction: exact inputs, expected value, observed value.
- **Confirm the root cause by reading the code, not by reasoning from pixels.** And establish whether suspect
  code is load-bearing before proposing to delete it.

## 13. Privacy and safety

- **When the computer-use provider offers `request_access`, request every required app in one call as its
  first step**, listing only what the brief needs. Start a fresh session for an independent acceptance.
  The shell-only P0 helper proof uses existing terminal Automation/Accessibility and Screen Recording
  grants; it does not manufacture a `request_access` call on a provider that has no such API.
- If an interactive permission prompt blocks a step, stop and report the question. Do not change privacy
  settings or click “Always allow” for anything other than Mado.
- Take the minimum screenshots needed. Never save one into the repo.
- **Never change system, privacy or security settings** to unblock a test, and never click a web link.
- **Menu-bar utilities** may own menu-bar coordinates and block clicks there. Don't request access to them;
  use the keyboard shortcut for the command, or record NOT VERIFIED.
- **Escape and other keys:** in mdpro (a WebView) the computer-use `key escape` arrived only as a key-up.
  In Mado, native Esc sent through `kc.sh "$RUN_DIR" 53` worked in the P1-08 device run (rows 5 and 9).
  Keep the direct computer-use `key escape` path distinct and unverified; use the proven key-code helper.
- **Input method:** switch to ABC before key checks; an IME can swallow keys. Never switch it from a script:
  on 2026-10-25 a Chinese IME (Doubao Pinyin) turned a typed open-panel path into
  `…095720-跑01-grid-explore、fixtures、grid` and the panel never navigated. `panel-choose.sh` now writes the path
  into the Go-to field through accessibility (AX `set value`), reads it back, and fails before Open on any mismatch; it
  prints the active `input-source:` read-only for the record and doesn't touch the pasteboard or type the path. After
  Open it checks the panel closed, else fails. It finds the ⌘O panel as an AXDialog window and the reconnect panel as
  the canvas window's sheet (the sheet form not yet driven live). The record must disclose this synthetic input.

## 14. Proving this skill (do once, then after big changes)

Run build → launch → doctor → one observable smoke action → evidence → cleanup. Fix a helper defect with a
failing regression test, clean up each failed attempt, then rerun the whole sequence. Preserve explicit
NOT VERIFIED entries for features the skeleton cannot exercise.

**Proof run: 2026-10-22**, MacBook Pro M4, 24 GiB, macOS 27.0.1, internal Retina @2x, Xcode 26.6 (17F113),
signed Debug. Runtime implementation SHA `4037cb6`; run `20261022-issue4-fix2-proof` under
`~/.picsee/device-runs/`. Build → launch → doctor → window capture → resize/readback/restore → doctor →
cleanup passed. Both doctors printed twelve PASS lines. The window-only PNG is 1920×1344 for a 960×672 pt
window. `size.sh` set 800×600, a separate System Events call read 800×600, then size was restored to
960×672. Cleanup terminated PID 38809, retired ownership and preserved the PNG, logs and report. This
re-proves capture/input identity checks as well as launch and doctor. The following documentation commit
changes no runtime helpers. The post-build metadata-only re-sign branch is covered offline for success,
failure and clean-stamp bypass; that branch is still not live-proven. Earlier runs and RED/GREEN outputs
remain in the issue #4 handoff. This is helper proof, not independent feature-ledger acceptance.

On 2026-10-22, a delegator ran `20261022-204006-VIEW-02-03-1x-mini` from an agent pane in the herdr session
on the Mac mini, at main `8a007b3`. Signed `build.sh` → `launch.sh` → `doctor.sh` (12 PASS, including
`machine` and `fixtures` with manifest-verified copies) → `shot.sh` (960×672 px for a 960×672 pt window,
@1x) → `key.sh` (`1`, `=`, `-`) → `cleanup.sh` passed. This was a P0-03 @1x feature run, not a full §14
proof; see `docs/validation/P0.md` §P0-03 @1x. `size.sh` and `kc.sh` were not
exercised on the mini.

Still **NOT VERIFIED**: a full Mac mini §14 proof, XCUITest, direct computer-use `key escape`, bookmark restore,
and the other future feature checks. Native Esc through `kc.sh 53`, the keyboard helper, and fixture-hash runs
were exercised by mini feature runs.
Historically, direct SSH signing on the mini failed with `errSecInternalComponent`; the MacBook therefore also
requires its desktop-started tmux session. No performance measurements.

Rerun the proof after changes to build, signing, launch, doctor or capture.

## 15. Helpers

Run from the worktree root. Requires Python ≥ 3.9, Node (tests only), macOS tools, XcodeGen on PATH and the
locked Xcode. By default the helper selects the first matching locked build from `/Applications/Xcode-26.6.app`
and `/Applications/Xcode.app`; `PICSEE_XCODE` overrides the application path, never the required build version.

```bash
export PATH=/opt/homebrew/bin:$PATH
RUN_DIR="$HOME/.picsee/device-runs/$(date +%Y%m%d-%H%M%S)-<ledger-ids>"
scripts/device/build.sh "$RUN_DIR"
scripts/device/launch.sh "$RUN_DIR"
scripts/device/doctor.sh "$RUN_DIR" --expected-sha "$(git rev-parse --short HEAD)"
scripts/device/shot.sh "$RUN_DIR" <ledger-id>-<entry-point>-<state>
scripts/device/size.sh "$RUN_DIR" 800 600       # points, prints the resulting size
scripts/device/key.sh "$RUN_DIR" o command   # exactly one printable character
scripts/device/kc.sh "$RUN_DIR" 53           # Esc; named keys use key codes
scripts/device/cleanup.sh "$RUN_DIR"
node --test scripts/device/tests/device.test.cjs
```

`winid.js` can also be called as `osascript -l JavaScript scripts/device/winid.js <pid>`; its tab-separated
columns are window ID, PID, layer, width and height in points, and title. Selection ignores owner names.
The helpers copied from mdpro `scripts/redesign/device/` at `9f133f1d` were committed unchanged first,
then adapted locally; no mdpro checkout is needed to run them.

Offline doctor contract tests use `scripts/device/doctor.sh --fixture <observations.json>`; they test
verdict formatting and non-zero failures and do not constitute device evidence. Real doctor input lives
in `doctor-input.json`. The test runner uses harmless copied sleep processes. Node tests allocate `fs.mkdtempSync` directories
under `os.tmpdir()` and remove them in `after()`; Python offline fixtures use `TemporaryDirectory` with
cleanup. Tests never write under `~/.picsee/device-runs/`. Run evidence stays outside the worktree. Build artifacts remain
inside `.build/device-<run-id>/`. Heavy jobs use `scripts/heavy-lock.sh`: picsee flock first, then mdpro’s directory lock, for **best effort** serialization. Only the heavy job itself goes under `scripts/heavy-lock.sh`, one command per call; never wrap an interactive or bare shell (`zsh`, `bash`, or `sh` without a script or `-c`), a REPL, a sleep/wait, or a persistent session, and never hold the lock while reading, thinking, or editing (see mdpro `docs/reference/20261023-heavy-lock-incident.md`, “Heavy-lock incident, 2026-10-23”, and mdpro `docs/adr/0135-one-heavy-lock-tool-serves-every-project-queues-in-arrival-order-and-admits-by-memory.md`, ADR-0135 “One heavy-lock tool serves every project, queues in arrival order, and admits by memory”). `PICSEE_MDPRO_LOCK` overrides the shared path (`off` skips); `PICSEE_MDPRO_SCRIPT` selects the optional interop test script. With inherited `MDPRO_HEAVY_LOCK_HELD=1`, reverse nesting has no verified handoff: it is unavailable and exits 70 before flock acquisition or workload launch; #665 will restore this path. Picsee-parent nesting remains available when its authenticated parent owns the shared lock. Limits: mdpro stale-reclaim races, SIGKILL of the picsee holder, and groups surviving KILL can overlap workers. picsee never reclaims stale directories: after timeout, check the owner’s `cmd` with `pgrep -f`, confirm no job processes remain, then manually remove the directory. After job exit, survivors are reported after 5 seconds and every 60 seconds; `PICSEE_HEAVY_LOCK_DRAIN_SECS` (default 30) bounds draining, then uses the same TERM/grace/KILL sequence as INT/TERM, waiting at most 5 seconds more. An empty group releases normally; survivors produce a warning and retain the directory. Drain timeout preserves the job status.

## 16. Recording the result

- Before recording any performance number in `docs/validation/` or citing it for a ledger status or limitation, fill the [benchmark vetting checklist](../../../../docs/validation/benchmark-checklist.md) for each metric.
- Write the record to `docs/validation/P<n>.md`, a section per run: date, machine/chip/memory/macOS, display
  and scale, bundle path, git SHA (and how it was verified, §6), fixtures, the verdict table, deviations and
  NOT VERIFIED reasons. Mention each ledger row ID it covers; the gardener matches on them. Evidence stays in
  `$RUN_DIR`; the record names the run ID.
- Commit the record on its own, touching nothing outside `docs/`, with a trailer naming the role and run:

  ```text
  docs(validation): P0-03 device run VIEW-02, VIEW-03 on Mac mini @1x

  Validated-by: <device-tester-role> run=<run-id>
  ```

  The gardener reads this trailer to rule out self-certification; a record without it can't lift a row.
- A row can move to `验证 = 真机` only from a record like this, written by the device tester. Raising a row to
  `Shipped` is still the owner's edit, never the gardener's. The same commit may append or edit `限制：`, but
  must not rewrite that row's acceptance in 怎么确认 (see `docs/feature-ledger.md`).
- A row whose recipe in [`../features/`](../features/README.md) is missing can't reach 真机: write the recipe first.
- A defect found here is a bug: it goes back through `/tdd-guardian:workflow` with a regression test that fails
  without the fix. This lane finds defects; it doesn't license an ad-hoc patch.
- After a fix, rerun the whole criteria table, not only the row that failed.

## Checklist

```
[ ] The criteria genuinely need a real window, pixels, input or the sandbox (§1)
[ ] Machine chosen; use the local mini except that @2x rows go over SSH to the MacBook or are NOT VERIFIED (§2)
[ ] No other Mado running; no other driver on this desktop (§3)
[ ] Built the .app with the locked Xcode, signed by GRT84NAK4T (§4)
[ ] Launched by absolute path with -n; PID recorded; window ready (§5)
[ ] Doctor passed, every line (§6)
[ ] Provider app grants or existing shell permissions confirmed; no privacy changes (§13)
[ ] Followed the feature recipe; every listed entry point driven (§7, §9)
[ ] Persistence and writes checked through a second view (§9)
[ ] Log window opened with a start time before interacting (§10)
[ ] Verdict table keyed by ledger row and entry point, NOT VERIFIED kept honest (§12)
[ ] Cleanup killed only our PID; evidence still in $RUN_DIR (§11)
[ ] docs/validation/P<n>.md written; ledger rows left to the owner (§16)
```
