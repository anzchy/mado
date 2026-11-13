Report-Task: capture-annotation-ux-research-r1
# capture-annotation-ux research: how do annotation and viewing relate in comparable apps, and what journey fits Mado?

Scope note: all evidence is static (vendor docs, help pages, release notes, reviews, forum posts). Nothing here was tested on a device.
Status tags: CONFIRMED = read on an official vendor page; INFERRED = reasoned, or read only on third-party pages; UNCONFIRMED = the request's tag for a claim no source settled (same as UNKNOWN).

## Answer

- Capture tools follow two models. (A) **Transient hand-off**: capture, then a corner thumbnail or overlay with copy, save, drag and annotate, then an optional editor (macOS, CleanShot X, Shottr with the thumbnail option, Snipping Tool's window). (B) **Capture straight into an editor or overlay**: the canvas is the editor (Snagit with Preview in Editor, FastStone Capture "To Editor", Flameshot, ShareX's "Open in image editor" task, Shottr's default Editor choice).
- Viewers and editors follow a third model. (C) **Viewer with an explicit edit mode**: Preview's Markup toolbar toggle, Photos' Edit > Extensions > Markup, Quick Look's Markup button with Revert/Done, FastStone Image Viewer's Draw Board (D), IrfanView's Paint dialog (F12), XnView MP's Image > Draw.
- The capture-side apps that power users praise (CleanShot, Shottr) keep the default path short: the image is saved or copied and the editor is optional. Snagit's "everything goes to the editor and library" model draws complaints about duplicate .snagx files.
- The top viewer complaint is **silent overwrite**: Preview autosaves crops and resizes over the original, Quick Look Markup changes cannot be undone after the window closes, and Photos' Save Changes reportedly replaces the original. That supports ADR-007 (save-as by default).
- OCR lives in two places in almost every app: a **capture action** whose text goes straight to the clipboard (CleanShot, Shottr, ShareX silent mode), and a **viewer action** with selectable text in the image (Preview/Photos Live Text, Snipping Tool's Text actions). This matches ledger row EXT-01.
- Recommendation for Mado: a hybrid of A and C. The helper writes the capture to ~/Downloads at once and shows a transient thumbnail (Copy, Annotate, Open, Text, drag-out). The Annotate action opens Mado's viewer already in annotate mode. Annotate is a mode of the one viewer, not a second app. Done writes a new sibling file and never overwrites. Esc leaves the mode. Capture-text puts the text on the clipboard and creates no file.
- The owner must settle these decisions: what the default after-capture action is, whether a fresh capture may be overwritten (this conflicts with ADR-007), whether annotations stay editable, and what OCR'd captures and the Downloads file pile-up should do.

## Evidence

### Per-app comparison (capture tools)

| App | 1. Right after capture | 2. Where annotation lives; enter/leave | 3. Save after annotation | 4. OCR | 5. View/edit separation; complaints |
|---|---|---|---|---|---|
| macOS screenshot (⇧⌘3/4/5) | A floating thumbnail "floats in the bottom-right corner of the screen for a few seconds". Swipe right saves at once; you can drag it into a document or Finder; click opens a markup/share window. Files go to the Desktop by default; "Save to" changes this; hold Control to copy to the clipboard instead [1] CONFIRMED | Clicking the thumbnail opens a separate Markup window (the Quick Look-style Markup window) [1][2] CONFIRMED. It closes with Done or Revert [2] CONFIRMED | Done writes into the screenshot file. "your changes can't be undone after you close the window" [2] CONFIRMED | None in the capture flow. Live Text is available later in Preview [5] INFERRED | Thumbnail is optional ("Show Floating Thumbnail"). Users report it delays the file appearing in Finder, so some turn it off [1][16] INFERRED |
| CleanShot X | A Quick Access Overlay in a screen corner offers copy, save, annotate, upload, or drag into another app. It can be repositioned, resized and set to auto-close [6] CONFIRMED. "After capture" in settings picks the default action [7] INFERRED | A separate Annotate window [6] CONFIRMED. It opens from the overlay with ⌘E; the overlay also has ⌘C copy, ⌘S save, ⌘W close, ⌘U upload [8] INFERRED (iMore) | "Save your annotated screenshots as editable CleanShot project files" [6] CONFIRMED. Also flattened copy, save or drag [6] CONFIRMED | Capture Text is a capture mode. Text goes to the clipboard on-device, 30+ languages, plus a QR reader [6] CONFIRMED. A URL scheme can OCR an existing file [7] INFERRED | The editor stays out of the way unless you ask for it. Overlay ⌘S only works while hovering over the overlay (forum report) [9] INFERRED |
| Shottr | On first Area Capture the app asks: Editor or floating thumbnail, and remembers the choice. The thumbnail offers save, copy, text/QR, pin, and a pencil that opens the Editor [10] CONFIRMED. Auto-copy and auto-save are optional settings [11] CONFIRMED | A separate Editor window that opens on the capture's display [11] CONFIRMED. Copy (⇧⌘C) or Save (⌘S) hides the Editor; "Reopen Shottr" brings it back [10] CONFIRMED | ⌘S saves to a chosen default folder with auto-names; ⇧⌘S is Save As [10] CONFIRMED. In v1.10, recent captures keep editable annotations ("Restore Previous Pic") [11] CONFIRMED | Hotkey area OCR copies to the clipboard, with a remove-line-breaks button. ⌘O in the Editor copies text from a selection [10][11] CONFIRMED | The vendor says copy/save "hides the Editor window automatically to get out of your way" [10] CONFIRMED |
| Snagit | With Preview in Editor on, the capture opens in Snagit Editor and you click Finish. With it off, the file saves automatically or asks for a name [12] INFERRED (TechSmith search excerpt, not fetched) | Snagit Editor is a full editor with a recent captures tray and a Library [13][14] CONFIRMED | Every image capture is autosaved as .snagx in the Library. PNG/JPG come from Save As or Share [13] CONFIRMED | Grab Text opens a results dialog in Snagit Editor with Copy All [15] INFERRED. One release note says it works without opening the editor, so the current behaviour is UNCONFIRMED | A user complaint: "with every PNG, I also had a SNAGX file", fixed by turning off library autosave [17] CONFIRMED (user blog) |
| FastStone Capture | Output choices: editor, file, clipboard, printer, email, Office, upload. "To File" can save without a Save As dialog. Auto Save has a folder, can copy to the clipboard, and can open in an external program [18] CONFIRMED. A "To Draw (skip editor)" output exists in some version [19] INFERRED | A separate editor window with tabs, plus a Draw tool (callouts, arrows, step numbers, highlight, blur) [18] CONFIRMED | Proprietary lossless FSC format "preserves annotation objects together with image data for future re-editing", plus an option to auto-save an FSC copy when draw objects exist [18][19] INFERRED (search excerpt) | OCR "Capture text" makes text "editable instantly" (Windows 10/11). Where the result goes is UNCONFIRMED [18] CONFIRMED | Toolbar icons are customizable and the bar auto-hides at the screen top [18] CONFIRMED. No "Minibar" label was found in current docs [18] UNCONFIRMED |
| Xnapper | Pitched as "Snap → Preview → Share!" with auto-balance, auto-background and one-click redaction [20] CONFIRMED. Whether an editor window opens is UNCONFIRMED | UNCONFIRMED | "Screenshot history", compress output. Exact save/copy flow UNCONFIRMED [20] | "Select and copy text easily", on-device Vision [20] CONFIRMED | UNCONFIRMED |
| ShareX (Windows) | A configurable "After capture tasks" chain: copy, save, open in image editor, upload, quick task menu, "After capture" window, recognize text [21][22] INFERRED. The quick task menu popping up after every capture annoyed users [23] INFERRED | The image editor sits inside the task chain. Enter = "continue / run after-capture tasks with changes applied"; Esc cancels [24] CONFIRMED | The edited image flows into the later copy, save and upload tasks; Ctrl+S saves; Ctrl+Shift+C copies [24] CONFIRMED | Tools > OCR or a hotkey; it can OCR an image file. The OCR window has editable text, a language selector and Copy all; silent mode puts text on the clipboard [25] CONFIRMED | Power-user configurability and many dialogs [23] INFERRED |
| Flameshot | A capture GUI where tools are drawn on the selection itself, as an inline overlay [26][27] CONFIRMED | Inline: single-key tools (a arrow, r rect, t text, b pixelate); Space toggles the side panel [26] CONFIRMED | Ctrl+C copy, Ctrl+S save, Enter upload, Ctrl+O open in an app, Esc quit [26] CONFIRMED | None found (UNCONFIRMED) | Annotation happens before the file exists; there is no separate viewer |
| Windows Snipping Tool | The snip opens in the Snipping Tool window and is "automatically saved to your Screenshots folder" [28] CONFIRMED | Pen, highlighter, shapes and crop in that same window [28] CONFIRMED | Save as / Ctrl+S [28] CONFIRMED | A Text actions button: select/copy text, Copy all text, Quick redact, all local [28] CONFIRMED | — |

### Per-app comparison (viewers and editors)

| App | Where annotation lives; enter/leave | Save after annotation | OCR | View/edit separation; complaints |
|---|---|---|---|---|
| macOS Preview | A mode inside the viewer: the "Show Markup Toolbar" button [3] CONFIRMED | Autosave plus Versions. Revert To > Browse All Versions [4] CONFIRMED. "you can't edit, move, or delete the annotations after you save the image"; convert to PDF if needed [3] CONFIRMED | Live Text: drag to select, then Control-click > Copy Text; Tools > Text Selection if needed [5] CONFIRMED | Users report Preview silently overwriting originals after a crop or resize, with no clear save step [29][30] INFERRED (forum) |
| Quick Look / Finder Markup | The Markup button in Quick Look or the Markup Quick Action; Revert or Done [2] CONFIRMED | Saves to the file; "changes can't be undone after you close the window" [2] CONFIRMED | — | Quick Actions cannot be undone, as discussed by Eclectic Light [31] INFERRED |
| Photos (Mac) | Double-click > Edit > Extensions > Markup [32] CONFIRMED | "Click Save Changes" [32] CONFIRMED. Reviews say to duplicate (⌘D) first to keep the unmarked version [33] INFERRED | Live Text with Copy Text [34] INFERRED | Edit is an explicit button; markup sits two levels deeper |
| FastStone Image Viewer | Draw Board (Edit menu or D key) draws text, lines, highlights, rectangles, ovals, callouts [35][36] CONFIRMED / INFERRED (D key) | "Powerful Save As interface"; whether it overwrites is UNCONFIRMED [35] | Not mentioned [35] CONFIRMED | The full-screen viewer has "hidden toolbars that pop up when your mouse touches one of the four edges" [35] CONFIRMED. A quiet viewer with a modal Draw Board |
| XnView MP | Image > Draw in the viewer [37] INFERRED (author forum post) | Annotations flatten into pixels; an extra step is needed to save [37] INFERRED | UNCONFIRMED | — |
| IrfanView | Paint dialog (F12 or Edit > Show Paint dialog), a floating tool palette over the viewer [38] INFERRED | Normal Save. Not confirmed (UNCONFIRMED) | UNCONFIRMED | — |
| Windows Photos | A pen Markup tool in the editor [39] INFERRED | "Save as copy" keeps the original; a plain Save replaces it [39] INFERRED | UNCONFIRMED | — |

### Synthesis claims

- S1. Three journey models: (A) capture → transient overlay → optional editor; (B) capture → editor or inline canvas, then explicit output; (C) viewer → explicit edit mode → save. Source: the tables above · INFERRED.
- S2. Every surveyed capture tool offers a path with no editor (save, copy or drag from the thumbnail), and the tools reviewers praise make that the default or one keystroke away [6][10][1] · INFERRED.
- S3. Non-destructive re-editing exists only in capture tools, as project formats (.snagx, CleanShot project, FSC, Shottr's recent-pic restore). Viewers flatten or overwrite [3][6][11][13][18] · CONFIRMED for the formats, INFERRED for the pattern.
- S4. OCR appears both as a capture mode with clipboard output and as an in-viewer selectable overlay; none of the capture tools write a file for a text capture [6][10][25][5][28] · INFERRED (only that no file is written is inferred).
- S5. The most-cited viewer failure is overwriting the original without an explicit save [2][29][30][33] · INFERRED (user reports).

### Sources
[1] https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac
[2] https://support.apple.com/guide/mac-help/mark-up-files-mchl1fd88863/mac
[3] https://support.apple.com/guide/preview/prvw1501/mac
[4] https://support.apple.com/guide/preview/edit-images-prvw2015/mac
[5] https://support.apple.com/guide/preview/prvw625a5b2c/mac
[6] https://cleanshot.com/features
[7] https://skillselion.com/skills/ljagiello/agent-skills/cleanshotx (third-party)
[8] https://www.imore.com/cleanshot-x-gains-new-keyboard-shortcuts-quick-access-overlay-more
[9] https://talk.macpowerusers.com/t/how-i-use-cleanshot-x-keyboard-maestro-for-screenshots/31558
[10] https://shottr.cc/kb/startguide
[11] https://shottr.cc/
[12] https://support.techsmith.com/hc/en-us/articles/203731148-Automatically-Save-Images-to-a-Specific-Format-During-Capture
[13] https://www.techsmith.com/learn/tutorials/snagit/recent-captures-tray/
[14] https://www.techsmith.com/learn/tutorials/snagit/how-to-edit-a-screenshot/
[15] https://techsmith.com/learn/tutorials/snagit/edit-image-text
[16] https://maketecheasier.com/get-rid-floating-screenshot-preview-macos
[17] https://voiceofthedba.com/2024/09/02/stop-snagit-from-saving-snagx-files-automatically/
[18] https://www.faststone.org/FSCaptureDetail.htm
[19] https://www.videohelp.com/software/FastStone-Capture-/version-history
[20] https://xnapper.com/
[21] https://getsharex.com/
[22] https://store.steampowered.com/app/400040/ShareX/
[23] https://steamcommunity.com/app/400040/discussions/1/7098294290808211540
[24] https://getsharex.com/docs/image-editor
[25] https://getsharex.com/docs/ocr
[26] https://flameshot.org/docs/guide/key-bindings/
[27] https://flameshot.org/
[28] https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b
[29] https://forums.macrumors.com/threads/stop-preview-from-automatically-saving.1343404
[30] https://eclecticlight.co/2025/09/03/previews-saving-grace-and-how-to-use-it/
[31] https://eclecticlight.co/2019/02/07/quick-actions-3-the-problem-of-undo/
[32] https://support.apple.com/guide/photos/phteb52f43ce/mac
[33] https://imore.com/how-use-markup-photos-app-mac
[34] https://support.apple.com/guide/photos/pht6bc6bd5f5
[35] https://www.faststone.org/FSViewerDetail.htm
[36] https://dottech.org/?p=27490
[37] https://newsgroup.xnview.com/viewtopic.php?p=172424
[38] https://softerviews.org/IrfanPaint.html
[39] https://support.microsoft.com/windows/edit-photos-and-videos-in-windows-a3a6e711-1b70-250a-93fa-ef99048a2c86
[40] https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.downloads.read-write

## Task fit (frequent tasks → best model)

| Task | Best-fit model | Why (evidence) |
|---|---|---|
| Quick capture and share | A, with no editor | Thumbnail drag-out, copy or swipe-to-save is the fastest path [1][6][10] |
| Capture and annotate | A → annotate (one key from the thumbnail) | CleanShot ⌘E and Shottr's pencil lead to the editor, which hides on copy/save [8][10] |
| Capture and extract text | A dedicated capture-text mode, text to the clipboard, no image | [6][10][25] |
| Annotate an existing image | C (a viewer edit mode) with save-as | Preview, Photos and FastStone IV use a mode; overwrite complaints argue for save-as [3][29][33][35] |

## Recommended journey for Mado (INFERRED, proposal for grilling)

1. **Entry points.**
   - The Minibar (helper) offers: Area, Window, Full screen, **Text** (capture + OCR).
   - In Mado's viewer: an **Annotate** action (bottom chrome "More" menu plus a shortcut) and a **Text** action (Live Text-style overlay, which is ledger EXT-01).
   - Mado's menu bar: Capture submenu. Global hotkeys belong to the helper.
2. **Right after an image capture.**
   - The helper writes the PNG to ~/Downloads at once, so the file exists before any UI and nothing is lost if the user ignores it.
   - The helper then shows a small transient thumbnail (about 5 s, pauses on hover) with Copy (⌘C), Annotate (⌘E), Open in Mado (Return), Text, Trash (⌘⌫), and drag-out.
   - The default action after the timeout is "do nothing more"; the file stays in Downloads.
   - This honours "captures open in Mado" through Open/Annotate without forcing a window for the share-only task.
   - Alternative default: "open in Mado viewer". See O1.
3. **Mode switch.**
   - The viewer stays quiet, with chrome auto-hidden per DESIGN.md §3. Annotate is a mode in the same window, not a second app.
   - Entering the mode shows a tool palette overlay and a Done/Cancel pair. Tool letter keys are active only in this mode, Flameshot-style [26].
   - Esc or Cancel leaves the mode, with the EDIT-06 unsaved-changes prompt.
   - In annotate mode, viewer navigation (arrow keys, grid, slideshow) is suspended so a stray key cannot drop edits.
4. **Save semantics (ADR-007 compatible).**
   - Done (⌘S) writes a **new sibling file**, for example "<name> annotated.png", and switches the viewer to it. The original is never overwritten, the anti-pattern in [2][29][33].
   - ⌘C in annotate mode copies the flattened result without saving.
   - For non-capture images outside a writable root, Done falls back to a Save panel. Folder grants are read-only per ADR-008.
   - No project file in v1. Re-editability is an open decision (O3).
5. **OCR placement.**
   - Minibar Text: select an area, put the text on the clipboard, and show a short "Copied N characters" toast. No image file. Optional "show panel" to edit or retry the language, ShareX-style [25].
   - Viewer Text: a selectable text overlay on any open image (EXT-01). It also appears as a thumbnail action for fresh captures.
6. **The Downloads file.**
   - It is kept as the untouched original. Annotated output sits beside it.
   - Trash is offered in the thumbnail and in the viewer (EDIT-05, never permanent delete).
   - Use a dated, sortable filename template, like Shottr/FastStone [10][18]; the exact pattern is UNKNOWN until decided.
7. **Keyboard flow (proposal).**
   - Capture: hotkey → drag → release.
   - Thumbnail: ⌘C copy, ⌘E annotate, Return open, Esc dismiss.
   - Annotate: letter tools, ⌘Z/⇧⌘Z, ⌘C copy, ⌘S/Done save copy, Esc cancel.
   - Viewer: the existing Space, arrow keys and Esc stay unchanged outside annotate mode.

## Constraints

- **Sandbox (ADR-006, AGENTS.md).**
  - Writing to ~/Downloads needs the `com.apple.security.files.downloads.read-write` entitlement [40]. The entitlement exists (CONFIRMED); its exact wording was not retrieved (INFERRED).
  - Screen capture from the helper needs the user's Screen Recording permission. The exact API and the helper packaging (login item, menu-bar agent) were not researched (UNKNOWN). This must not grow into a Full Disk Access dependency.
- **ADR-007** (save-as by default, no overwrite in v1; `docs/adr/0007-save-as-by-default-no-overwrite-in-v1.md`): annotation output must be a new file. "Overwrite the fresh capture" would need an ADR amendment. CONFIRMED (read).
- **ADR-008** (folder access read-only): sibling writes outside Downloads need a Save panel grant. INFERRED from the ADR title only, body not read.
- **macOS 14 floor**: the Live Text-style overlay is assumed to come from VisionKit/Vision, available on 14. The exact API is UNKNOWN here.
- **Ledger rows touched** (`docs/feature-ledger.md`): EDIT-03 (export/save-as, :254), EDIT-04 (copy/share, :255), EDIT-05 (trash, :256), EDIT-06 (unsaved prompt, :257), EXT-01 (OCR select and copy, :300), OPEN-07 (open from clipboard, :116). There is no row yet for capture, Minibar or annotation; new rows are needed. CONFIRMED (read).
- **Rule 10 (spec before implementation)**: capture, annotation and OCR are new features and need /grill-with-docs, then /to-spec, then /to-tickets.
- **DESIGN.md §2–3**: no permanent tool bars, and the canvas fills the window. The annotation palette must be mode-scoped and must leave the accessibility tree when hidden. CONFIRMED (read).

## Open questions (default in brackets)

- O1. What should the default after-capture action be: transient thumbnail, open in Mado viewer, or open in annotate mode? [Thumbnail; per-user setting for the other two]
- O2. Should a capture also auto-copy to the clipboard? [Off by default; setting]
- O3. Should annotations stay re-editable after Done (a project or sidecar file, CleanShot/Snagit-style), or flatten to pixels? [Flatten in v1; no project format]
- O4. May Done overwrite a fresh capture that Mado itself just wrote to Downloads, as an exception to ADR-007? [No; write a sibling "annotated" file]
- O5. Does Minibar Text also save the captured image? [No image; clipboard only, plus a toast]
- O6. Is the OCR result a toast only, or also an editable panel (language, line breaks)? [Toast; "Show text" link opens a panel]
- O7. Filename template and subfolder: Downloads root or Downloads/Mado? [Downloads root, dated name; template UNKNOWN until decided]
- O8. Annotate on non-capture images in folders without a write grant: Save panel each time, or a default export folder? [Save panel, per ADR-007/008]
- O9. Which keys enter and leave annotate mode, and do letter tool keys conflict with existing viewer shortcuts? [E or ⌘E to enter; Esc cancels; letters only in mode; audit the shortcut map]
- O10. Does mosaic need a "true redaction" warning (pixelation versus a solid box)? [Offer a solid box as the default redaction; flag as UNKNOWN risk]
