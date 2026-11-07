# Open and grant a folder

Opening an image gives a File Grant for that file only. Folder browsing needs an Access Root selected in the
system open panel. This recipe is seeded for P0-04; implementation smoke is not independent validation.

## Sub-features

- `ACCESS-01`: ←/→ after a File Grant asks for folder access; Cancel preserves the image.
- `ACCESS-02`: the root survives relaunch; rebuild is a separate, still **unverified** criterion.
- `ACCESS-05`: the last window releases its root, evidenced by the access log.
- `OPEN-02`, `OPEN-06`, `VIEW-10`: File → Open… accepts folders, File → Open Recent holds folders only,
  View → Previous Image / Next Image and Inspector buttons route the same commands.

## How to get to it (user POV)

Open one JPEG from Finder, press →, choose Grant Folder… in the Browsing Needs Folder Access sheet, then select
its folder in the Grant Folder Access panel. Alternatively use File → Open… (⌘O) to choose a folder.
After quitting and relaunching use File → Open Recent. Close the window after browsing.

## Driving it with computer use

Preconditions: doctor passes; a new fixture folder `$RUN_DIR/fixtures/grant/` contains three manifest-verified
synthetic images. No existing Access Root covers it. Do not delete the sandbox container. Independent validation belongs to the delegator. Fix round 1 also authorizes implementor smoke to choose a
non-containing fixture folder in the powerbox and verify the mismatch sheet and scope-start result.

1. Open the first image through `open -a` with the recorded bundle path. Capture `ACCESS-01-file.png`.
2. Press →. The sheet titled **Browsing Needs Folder Access** names the parent folder and has **Grant Folder…**
   and **Cancel**. Capture `ACCESS-01-arrow-prompt.png`. Cancel; capture the unchanged image. Repeat with ←.
3. Choose Grant Folder…. The directories-only panel is titled **Grant Folder Access**, starts in the parent,
   and has **Grant Folder** as its confirmation button. Select the parent. → advances in Finder order.
   A different fixture folder is still saved in Recent, but **Folder Does Not Contain This Image** reports the
   mismatch after the system panel ends. Capture the sheet and unchanged image; cancel it. Record
   `AccessGrant kind=panelFolder scopeStarted=true|false` from `access` logs for this NSOpenPanel path,
   rather than inferring scope success from a Finder `open -a` File Grant.
4. Use View → Previous Image / Next Image and the Inspector buttons. Ends stop, without wrapping. Text input
   keeps arrow keys. ⌘O → folder opens its first image; cancelling either panel changes nothing.
5. Quit (⌘Q), relaunch the same absolute bundle, doctor, choose File → Open Recent → fixture folder.
   The first image appears without another grant. Capture `ACCESS-02-relaunch-browsing.png`.
6. Close the window. Save the `access` category lines from app.log. The public line is
   `AccessLease root=<UUID> remaining=0 outcome=released`; its signpost spans first start to last stop.
   A window closure alone proves nothing. Include the matching root ID and log timestamps in the record.
7. **Bookmark after rebuild (unverified):** build A grants the folder and quits; commit/build a later SHA as B
   with the same Apple Development team. Launch B, doctor, open the folder from Open Recent. Quote the launch line
   `AccessRoot root=<UUID> outcome=resolved|stale|failed creating=<SHA-A> current=<SHA-B>` from app.log.
   Record any repeated panel or signing/resolve failure. A relaunch of A does not answer this question.

Proof: screenshots for the prompt, Cancel, navigation and relaunch, both build manifests/SHAs for rebuild,
plus the launch and release log excerpts. The delegator writes `docs/validation/P0.md` and fills ADR-008's result.

## Gotchas

- Never pre-grant folders, copy files into the container, or accept folder open events/drops as Access Roots.
- File Grants never persist. Recent confers no access and adds no Library Folder. A failed root reuses the grant
  sheet; the complete repair UI belongs to ACCESS-03/P2-01.
- AppKit sheets, panels, menus, buttons and true sandbox/bookmark semantics require device evidence.
- A rebuild may invalidate bookmarks. Keep this **unverified** until the two-build procedure above is recorded.
- Never drive or terminate a Mado instance this run did not launch; run doctor before interacting.
