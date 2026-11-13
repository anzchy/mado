---
status: accepted
date: 2026-11-13
---

# ADR-018: The Capture Bar is a helper process embedded in Mado.app with its own Screen Recording permission

The owner wants a FastStone-style floating capture toolbar, and has decided that it is embedded in Mado rather than shipped as a separate app ([grilling record](../plans/20261113-capture-annotation-ocr-grilling.md) 0.1, 0.2, 2.x).

## Decision

- **Process shape:** the Capture Bar runs in a separate helper app embedded in Mado.app. It has its own bundle ID, its own sandbox and no Dock icon. It is registered as a login item with `SMAppService`, and whether it starts at login is a separate switch in Settings. The helper is off by default and is turned on from Mado Settings.
- **Why not inside the main process:** Apple DTS says that floating over full-screen apps on all Spaces requires a process with no Dock icon plus a non-activating panel ([technical research](../research/20261113-capture-ocr-tech.md) §B). A viewer and a resident toolbar also have different lifecycles: the viewer should not stay resident for the sake of the toolbar.
- **Why not a separate app:** a separate app would need a second set of signing, notarisation, Sparkle updates and releases, and hand-off between the two apps would rely only on URL schemes or opening files. The helper is its own target, so splitting it out later stays cheap.
- **Permission boundary:**
  - Only the helper asks for Screen Recording, and only at the first Capture.
  - The helper captures with ScreenCaptureKit. It does not run the `screencapture` CLI.
  - Mado itself gains no Screen Recording permission.
- **Global shortcuts:** the helper uses Carbon hotkeys. The defaults are the ⌃⇧⌘ series and can be changed in Settings; Mado does not take over the system's ⌘⇧3/4/5.
- **File hand-off:**
  - The helper writes to the Capture Folder, which defaults to ~/Downloads. This needs `com.apple.security.files.downloads.read-write` in the helper only. A different folder is granted through an open panel and kept as a security-scoped bookmark.
  - The helper hands the file to Mado through Launch Services. Mado gets a File Grant for that one file.
  - Browsing the other Captures goes through the existing Access Root flow: the first time, Mado guides the user to grant the Capture Folder. Mado itself does **not** add a Downloads entitlement.

## Considered options

- **Inside the Mado main process:** cannot float over full-screen apps, puts the Screen Recording permission on the viewer, and forces the viewer to stay resident. Rejected.
- **A fully separate app:** two release processes and fragile hand-off between apps. Rejected.
- **Mado adds a Downloads entitlement so it can browse directly:** covers only the default location, and goes around the Access Root model. Rejected.

## Consequences

- On macOS 15 and later, region capture cannot use `SCContentSharingPicker`, so the system shows extra capture prompts at intervals. The interface has to explain this in advance; the wording is open.
- Whether the helper gets its own Screen Recording entry, and which name System Settings shows for it, has not been confirmed. Device tests on macOS 14, 15 and 26 are required before shipping.
- On macOS 14, region capture takes the whole display and then crops; newer APIs are used where the system version allows.
