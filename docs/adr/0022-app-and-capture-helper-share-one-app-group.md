---
status: proposed
date: 2026-11-23
---

# ADR-022: The app and the Capture helper share one App Group

[ADR-018](0018-capture-helper-embedded-accessory-process.md) embeds the Capture helper as a separate sandboxed app. [ADR-021](0021-capture-helper-owns-the-capture-folder-chooser.md) keeps the Capture Folder state in "the App Group defaults": the helper's bookmark, the display path and the fallback flag. Mado reads the display path and the flag for Settings › 截图, and both processes read the Capture Bar switch and the after-Capture choices there. No ADR named the entitlement that makes this possible. The release entitlement gate did not know it either, so `mado-v0.0.2-rc.1` failed with `unexpected entitlement com.apple.security.application-groups` (#854).

## Decision

- **One App Group, the same in both targets:** `com.apple.security.application-groups = ["GRT84NAK4T.io.github.anzchy.mado.capture"]`. It is set in `App/Resources/Mado.entitlements` and in `App/CaptureHelper/CaptureHelper.entitlements`. It is team-prefixed, so it needs no provisioning profile for Developer ID distribution.
- **What it is for** (`CaptureBarIdentity.appGroupID`):
  - **The shared `UserDefaults` suite.** It holds the Capture Bar switch, the permission state, the shortcut bindings, the after-Capture choices, the Capture Folder record and the #694 Annotate hand-off record. Darwin notifications tell the other process to read it again.
  - **The shared group container.** It holds two files: the helper's single-instance lock file (one helper for every copy), and the Annotate hand-off JSON file that backs up the defaults record (#694 fix1).
- **The release gate checks it exactly.** `scripts/release/check-entitlements.mjs` accepts the key only as an array of exactly that one group. Any other group, an extra group, an empty array or a non-array fails, and so does a missing key, because the helper hand-off needs it. This holds in release and in debug.

## Why this is not a sandbox bypass

- Both apps stay sandboxed. The group gives no access to user files, folders or other apps' data: it adds only a container that these two apps share.
- File access is unchanged. Mado still opens images only through user-granted Access Roots and File Grants (ADR-008, ADR-011). The helper writes only to ~/Downloads (ADR-018) or to the folder the user picked in its own open panel (ADR-021).
- The shared defaults and container hold settings, a display path, flags, a lock file, the hand-off record and the helper's own app-scoped bookmark, which Mado cannot resolve (ADR-021). No security-scoped access is passed between the processes through the group.

## Considered options

- **No shared container; pass state over XPC or Darwin notifications only.** The helper must read the switch at login before Mado runs, so it needs persisted shared state. Rejected.
- **A `group.`-prefixed App Group.** On macOS that form is tied to a provisioning profile; the team-prefixed form is not, which fits Developer ID distribution without profiles. Rejected.

## Consequences

- The entitlement gate's decided set grows from five keys to six (sandbox, user-selected read-write, app-scope bookmarks, network.client, the Sparkle mach-lookup pair, the App Group). Its tests pin the exact value.
- The helper's own entitlements (Downloads read-write, user-selected read-write, app-scope bookmarks, the App Group) are not yet checked by the release workflow (#854).
- Changing the group identifier changes where both apps read their shared settings. It needs a migration and a new ADR.
