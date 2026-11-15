---
status: proposed
date: 2026-11-14
---

# ADR-021: The capture helper owns the Capture Folder chooser and its bookmark

[ADR-018](0018-capture-helper-embedded-accessory-process.md) says the helper writes to the Capture Folder, which defaults to ~/Downloads, and that "a different folder is granted through an open panel and kept as a security-scoped bookmark". It does not say which process shows the panel or keeps the bookmark. #685 needs that answer.

## Decision

- **The helper shows the open panel and keeps the bookmark.** Settings › 截图 › 更改… posts a Darwin notification. The helper activates itself, shows an `NSOpenPanel` for folders, and makes an app-scoped security-scoped bookmark of the chosen folder.
- **Shared state:** the bookmark, the display path (with `~`) and a fallback flag are kept in the App Group defaults. Settings reads only the display path and the flag. The bookmark is the helper's own: Mado cannot resolve it.
- **New helper entitlements:** `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`. Mado.app already has the same pair (ADR-015, ADR-020). They grant only the folders the user picks in the panel. There is no temporary exception, no Full Disk Access, and no folder is granted in advance.
- **Resolution:** the helper resolves the bookmark before the first Capture after a launch and keeps the security scope open until another folder is chosen. A stale bookmark is made again. If the bookmark cannot be resolved, or its scope cannot be opened, the Capture goes to ~/Downloads (ADR-018's Downloads entitlement), the fallback flag is set, and Settings shows a note naming the folder that failed. Each later Capture tries the bookmark again.

## Considered options

- **Mado shows the panel and passes the bookmark to the helper:** an app-scoped bookmark resolves only in the app that created it, and the helper is a different app with its own bundle ID and sandbox. A document-scoped bookmark needs a document file both processes can read. Passing a live sandbox extension needs an XPC connection that does not exist yet. Rejected.
- **Mado shows the panel and the helper gets the path only:** the helper's sandbox would refuse the write. Rejected.

## Consequences

- The chooser works only while the helper runs. Settings greys the row while the Capture Bar is off, as grilling 5.2 already requires.
- The panel belongs to an accessory app with no Dock icon. It has to bring itself forward, and needs a device check.
