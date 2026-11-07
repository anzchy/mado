---
status: proposed
date: 2026-10-27
---

# ADR-012: UI test fixtures enter through the App container

## Decision

The small local/nightly XCUITest set may launch a **test-compiled** Picsee with `-PicseeUITestFixture <name>`. The test sends three pinned `TestAssets` image bytes in launch environment variables. The App writes them to a uniquely named directory under its own `Application Support/Picsee/UITestFixtures`, then uses the existing `CanvasWindowController.openGrantedFolder` → folder scan → Grid presentation route. The fixture name permits only ASCII letters, digits and `-`; it cannot name a path or follow a supplied symlink. The adapter and its separate bookmark/recent stores exist only when both `DEBUG` and `PICSEE_UI_TEST_FIXTURE` are set. An ordinary Debug or any Release build omits the active adapter and ignores the argument, even if a Release build is passed the test flag.

The isolated test adapter treats readable files **inside that fixture directory** as a local root. It does not obtain a user grant or extend the OS sandbox. It keeps its synthetic bookmark records inside the unique fixture directory; they are not production Access Roots and are not evidence for the security-scoped grant or bookmark path in ADR-008. The production entitlements and Info.plist do not change. The normal system access adapter remains the only production path.

The delegated smoke probe confirmed that the test build can show the completed Grid through the ordinary scan/presentation code after fixture staging. It does not establish a user grant or production bookmark behavior; those remain signed device checks.

The UI test uses `XCUIApplication()` with `PicseeApp` set as its Target Application (`TEST_TARGET_NAME`), so Xcode launches the product built for that test run. A bundle-ID lookup is forbidden for choosing the launch target: LaunchServices can select another registered `io.github.anzchy.picsee` copy, including the user's installed App. The pre-launch check only looks for another running copy by bundle ID and skips the test if one exists. Before checking the Grid, the test waits for the unique fixture name at `grid.sidebar.folder`; a flag-off or wrong build then fails with an explicit fixture-entry message. The first proposed probe was aborted before launch when this risk was found.

## Options considered

| Option | Sandbox authority and entitlement | Release risk | What it covers and misses |
|---|---|---|---|
| Launch argument naming `TestAssets` directly | A path is not a Powerbox grant. `FileAccess.grant` requires a successfully started security scope, so this cannot lawfully open an external folder without a pre-grant. No entitlement is added. | A generic argument parser could leak; rejected. | Would exercise the full folder path only if authority somehow existed; cannot prove a grant by naming a path. |
| Copy a fixture into the App container, then use a bounded test-only launch hook (**chosen**) | [Apple documents](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) the App's unrestricted access to its own container. The local adapter changes no OS authority, entitlement or production access behavior. | Hook is behind an explicit compile flag absent from normal Debug and Release builds. Flag-off unit assertion checks the argument is ignored. | Exercises fixture staging, folder scan, Grid rendering and AX item count. Does not cover Powerbox, real security scopes, production bookmarks, grant/reconnect, external folders or persistence. |
| Drive `NSOpenPanel`/Powerbox with XCUITest | A real selection would grant the external folder; no entitlement change. | No code hook. | Covers a particular panel interaction, but is fragile and explicitly excluded by #130's small XCUITest decision. |
| Preseed a bookmark, use an absolute launch path, or add a temporary exception | A bookmark from another process is not a user grant for this App; an exception or pre-grant would change the authorization boundary. | Can contaminate Release settings and production data. | Would obscure the very sandbox behavior the test is meant to respect; rejected. |

Apple's [sandbox file-access guide](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) describes the grant supplied by the system panel and security-scoped bookmarks. A URL passed as a string has no such grant. The existing `ScopeSession` also rejects a root when `startAccessingSecurityScopedResource()` fails, which is why merely copying the fixture into the container is insufficient for the current `FileAccess.grant` contract.

## Probe and interpretation

From this worktree, the delegator runs this **one command** on the Mac mini under the shared GUI lock (it builds and executes the single UI test):

Before `launch()`, the test checks for any running `io.github.anzchy.picsee` App using `NSRunningApplication`. If another Picsee is running, it skips with `another Picsee is running; refusing to launch over it`; the probe must not close an App it did not start. Teardown is registered only after this test launches its target, and terminates only that launched App.

```sh
scripts/heavy-lock.sh xcodebuild test -scheme PicseeFixtureUI -only-testing:PicseeUITests/PicseeFixtureGridUITests/testContainerFixtureOpensThreeImageGrid -destination 'platform=macOS' SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PICSEE_UI_TEST_FIXTURE' -derivedDataPath .build/dd-issue132-probe
```

The expected observation is `grid.collection` containing exactly three `grid.cell` descendants after the scan completes. A passing probe establishes only that the test build can stage those images in its sandbox container and reach the Grid. It does not validate production user authorization or bookmark behavior. The UI test is local/nightly and outside PR gates and Swift package coverage.

### Probe result — 2026-10-27

Delegator run `probe-132b-10271749` ran under the shared GUI lock at pre-rebase head `ea85dc2`. Xcode reported **“Executed 1 test, with 0 failures”** in 5.5 seconds, with 0 skips. The test launched the build under test, found the unique fixture name at `grid.sidebar.folder`, then found exactly three `grid.cell` items. Teardown terminated only the process started by this run. macOS showed a one-time UI Automation authorization prompt; the user approved it for this probe. This observation verifies the fixture-to-Grid smoke path on that Mac mini run only. It does not verify Powerbox grants, production bookmarks, VoiceOver, or the other A11Y-01/CMD-01 acceptance steps.

After the rebase onto main with P2-08a (#140), `App/Access/AccessServices.swift` and `App/PicseeApp.swift` differ from `ea85dc2`: main's own changes, plus `browser = FolderBrowser()` in the fixture init. The delegator reran the same probe as `probe-132c-10272122` at `9f43bcd`: “Executed 1 test, with 0 failures” in 5.3 seconds, and no Picsee process was left running.

## Consequences

- The UI test target packages only three small synthetic files from `TestAssets`; no `TestAssets`, HTML, research material or test adapter is added to the production App bundle.
- This fixture build has the same bundle ID and team as the developer's installed Picsee. It shares that App container, thumbnail cache and preferences. The test hook keeps synthetic access records in only its unique fixture subfolder. At test teardown, `app.terminate()` invokes test-only App cleanup; the test also attempts `FileManager` removal of that exact run folder as a fallback. Neither path deletes the container or another run's folder. A forced process kill or denied test-runner container access may leave the one run folder for later manual inspection.
- A11Y-01 and CMD-01 do not advance from this harness. Its Debug build is signed with the project's Apple Development identity and team, not a Developer ID distribution build. Their native/VoiceOver and keyboard claims still require the specified device observations.

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
