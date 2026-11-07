# Local XCUITests (#145 / #130)

Run from this worktree on an unlocked macOS 14+ desktop with Xcode, xcodegen,
Apple Development signing configured, and UI Automation authorized:

```sh
scripts/ui-tests.sh              # default: keyboard + menu states (flows)
scripts/ui-tests.sh all          # smoke, keyboard, menu states, both-surface audit
scripts/ui-tests.sh flows 10     # ten consecutive keyboard + menu passes
scripts/ui-tests.sh audit        # Grid and viewer accessibility audits
scripts/ui-tests.sh smoke        # original three-image fixture smoke
```

These tests are local/manual (or an optional nightly job). They are outside
required PR checks and Swift package coverage. No required workflow is changed.
The runner wraps each xcodegen/xcodebuild command with
`~/.picsee/device/ram/with-ram.sh i145 scripts/heavy-lock.sh`, builds before
reserving the desktop, then takes the shared GUI lock. A busy lock uses its
supported wait operation; it never starts UI testing unlocked. The EXIT trap
waits for processes referring to the test build to finish, then releases only
the returned acquisition ID, including assertion failures. If they remain after
330 seconds, it retains the GUI lock and prints the exact recovery command;
confirm those test processes have ended before using that command.
Keep the command in the foreground; let XCTest teardown finish before closing
its terminal. Inspect a killed/interrupted run for a remaining test App before
starting further desktop work; never quit an App you did not start.

Evidence is saved under `~/.picsee/ui-tests/i145-<timestamp>-<pid>/`: build logs,
per-run logs, JSON summaries, `.xcresult` bundles and `passes.log`. The runner
stops at the first unsuccessful run. Skips, expected failures, incomplete runs
and zero tests fail its pass counter; retries are not used to replace failures.
Open a result bundle in Xcode to inspect audit issues and attachments.

`flows` is the default so a normal invocation runs the reliability checks without
the known audit failures. With the current product, explicit `all` and `audit`
runs are expected to exit **65** because native findings remain unsuppressed:
[#365](https://github.com/anzchy/picsee/issues/365)–[#374](https://github.com/anzchy/picsee/issues/374)
cover 12 occurrences (Grid 6, Viewer 6). Compare each retained finding's surface,
audit type, description and element identifier (or label/value) with those issue
bodies; use frames as location context, not stable identity. An unmatched finding
or additional occurrence is new evidence to triage, rather
than a reason to assume every exit 65 is already explained. Preserve logs and
file each distinct new finding. `all N` with `N > 1` stops at repetition 1 while
these findings persist; the runner stops at its first unsuccessful repetition.

All tests use ADR-012's unique container fixture and `XCUIApplication()` bound
to the built Target Application. They never drive the open panel. The existing
prelaunch guard skips if any Mado is already running; it does not quit it.
A skip is **NOT VERIFIED**, not a reliability pass. Teardown terminates only
the test-launched App. App/test-host cleanup hooks can leave fixture directories
behind after XCTest termination. Once owned processes drain, the host runner
removes only exact run-prefixed UUID directories proved by that run's native
folder-marker logs, including their private `.test-access` state. Unlogged
siblings, unexpected top-level files and symlinks are preserved/refused. The fixture
shares the installed App's container/cache/preferences; no persistent settings
are reset. English language arguments apply to this process only; fixture order
is derived from the displayed Grid rather than a fixed user sort preference.
The explicit `PICSEE_UI_TEST_FIXTURE` build flag is confined to the test build.

The runner copies the three input images to its run directory's `fixtures/`,
passes that directory only to the test runner, and removes those exact staged
inputs at exit. App image bytes still enter through ADR-012's launch environment
and are written into the App's own container. No external folder grant is added.
Persistent DerivedData and the test App live at `~/.picsee/ui-tests/dd/`.
A run-local `.xctestrun` expands build paths there; the test command runs from the
run directory, with its PWD outside Documents/Desktop/Downloads.

This avoids launching the test App and its resource bundles from the worktree
under Documents. Previously the image fixture was already in Application Support,
but the App executable, resources and injected build-product paths were under
Documents; macOS displayed a Documents access prompt during launch. The owner
chose **Don't Allow**. Never grant Documents/Desktop/Downloads access, change TCC,
disable sandboxing, or use a temporary entitlement to make these tests work.

Before each UI invocation, the runner lists on-screen windows owned by
UserNotificationCenter through CoreGraphics. A watcher repeats that check during
execution. If a window appears, the run stops (exit 78), records its window title
and ID, and terminates only newly started processes belonging to this run. No
privacy prompt is accepted or dismissed by the test tools. If macOS withholds a
window title, report that fact and inspect the visible prompt for its exact text;
do not guess it or continue the run. `prompts-before-*.json`, `prompt-*.json` and
`monitor-*.log` retain this evidence.

Runtime staging checks can run without launching an App:

```sh
python3 scripts/tests/ui-test-runtime.test.py
python3 scripts/tests/ui-test-prompts.test.py
```

The keyboard test keeps Current Item distinct from the nonempty Selection,
pages both ways, ends on another viewer image, restores the Grid, then sends
more keys without a mouse click. After Esc, Shift-Down must change the Grid's
Current Item: vertical arrows are handled only by the focused Grid collection,
not by window-level commands. Shift-Up restores the original Current Item while
preserving Selection before appearance comparisons. This focus oracle is
independent of the Current Item ring and Space/Left/Right command routing. Filenames come from native child text and the
Current Item comes from the Grid footer. Native collection wrappers expose no
usable Selection value, so retained cell screenshots compare the same Current
Item before/after preview and a selection-preserving Shift-arrow redraw.
Comparisons decode pixels and allow at most 2/255 per channel: captured focus-ring
corners showed that antialiasing variation in otherwise unchanged cells. The
selected-cell inequality check must still reject the visibly different fill.
The menu test checks zoom in/out, Actual
Pixels, Fit and Inspector across Grid → loaded viewer → Grid.
These are characterization tests of existing product behavior. Temporary wrong
expectations used during development demonstrate that the oracles detect a
failure; they are not product regression RED receipts or fixes.

The audit runs on both the completed Grid and loaded viewer. Its issue handler
must always return false so every finding remains visible to XCTest. A Grid
audit failure must not prevent the viewer audit. Record each finding's surface,
audit type, description and element details; file each distinct finding as a
GitHub issue with label `needs-triage` and milestone `Backlog`, preserving all
occurrences/surfaces in its evidence. Do not suppress findings or expected-fail
the audit to make it green. Product bugs found by the other tests require an
issue and an explicit issue-linked expected failure or owner direction.

This fixture set does not verify production Powerbox grants, real bookmarks,
external folders, full VoiceOver behavior, all keyboard paths/locales, Retina
rendering, persistence or distribution-signed builds. A passing native audit
alone does not establish A11Y-01 acceptance.
