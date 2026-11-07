# Keyboard and command routing

One command route for menus, buttons and keys; fields and menus consume their keys first. This recipe
covers P0-09's Inspector placeholder, not the real information Inspector or folder browser.

## Sub-features

- `CMD-01`: fit (`0`), actualPixels (`1`), zoomIn (`+`/`=`), zoomOut (`-`/`−`), open (⌘O),
  inspector (⌘I), escape (Esc from panel to canvas). Space, arrows, Enter and ⌘F are unimplemented.
- `CMD-02`: the Inspector placeholder field edits text without routing bare image commands; Esc closes
  an open menu before moving focus. The real search field remains unavailable.
- `A11Y-02`: canvas/panel Tab, Shift-Tab, Esc, visibility and focus rings. Opening a folder needs #8;
  selecting images and returning to grid need P3. Those acceptance steps are NOT VERIFIED here.

## How to get to it (user POV)

- File → Open…; View → Fit, Actual Pixels, Zoom In, Zoom Out, Show Inspector / Hide Inspector,
  Focus Canvas. App → Quit Mado; Edit → Cut, Copy, Paste, Select All; Window → Minimize.
- ⌘I reveals “Inspector Placeholder”. Tab enters “Focus test (not saved)”, which is transient and is not search.
- Panel buttons: Fit, Actual Pixels, Zoom In, Zoom Out, Hide Inspector. Open and Esc have no dedicated button.
- Accessibility IDs: `viewer.canvas`; `inspector.focus-test`; `command.<ID>.menu` and
  `command.<ID>.button` (button IDs only for fit, actualPixels, zoomIn, zoomOut, inspector).
  The menu IDs include open and escape as well. Plain key events have no accessibility element.

## Driving it with computer use

Preconditions: ABC input; System Settings › Keyboard › Keyboard navigation on to Tab between controls; open `TestAssets/synthetic/coordinate-grid.png` from Finder or File → Open….

- **Three entries.** From equal starting transforms, test Fit/0, Actual Pixels/1, Zoom In/+, Zoom Out/−
  using the View menu, placeholder button and canvas key separately. Record a verdict per command × entry.
  Reset the transform between entries; buttons anchor at the view centre, as do menu/key zooms when the pointer is over the panel or outside the canvas. Use the centre for equivalent-entry comparisons.
- **Open.** Test File → Open… and ⌘O separately. Choose an image, then repeat and cancel: image/transform/focus
  stay unchanged on cancellation. Directories cannot be selected; folder acceptance needs #8.
- **Inspector.** Test View → Show/Hide Inspector and ⌘I. Showing preserves canvas focus; hiding while a panel
  control has focus returns it to canvas. The Hide Inspector button is the button entry (show has no button).
- **Field priority.** Show Inspector and press Tab. Type `0 1 + − a b`, Space and arrows: only the field changes.
  Test Edit → Cut/Copy/Paste/Select All and their shortcuts. Press Shift-Tab from the field: canvas focus returns.
- **Focus Canvas from the panel.** Show Inspector, Tab into `inspector.focus-test`, then choose View → Focus
  Canvas once. Read the AX focused element immediately: expect role `AXImage` and identifier `viewer.canvas`.
  Focus the field again with no menu open and send Esc once: focus returns to the canvas while the panel stays
  visible. Esc on canvas does nothing. There is no dedicated Esc button.
- **Menu-open Esc precedence.** Focus `inspector.focus-test`, use `AXPress` on the View menu-bar item, and
  confirm its `AXSelected` value is `true`. Send Esc once: only the menu closes and the field remains the AX
  focused element. Send Esc again: focus returns to the canvas (`AXImage` / `viewer.canvas`). Reference
  evidence: delegator run `20261023-082840-CMD-02-menu-esc-session`; new runs use their own `RUN_ID`.
  No Space/arrows/Enter/⌘F menu items or shortcut hints should exist.
- **Disabled.** With no image loaded, menu zoom items and panel zoom buttons are disabled; image keys do nothing.
- **Focus.** Without the mouse, ⌘O chooses an image, ⌘I shows the panel, Tab enters it, Tab traverses controls,
  Shift-Tab from any panel control returns straight to the canvas, Esc returns to canvas. Confirm visible rings. Open another image with field focus and
  confirm focus is preserved. Folder/grid portions of A11Y-02 remain NOT VERIFIED pending #8/P3.
- **Proof.** `CMD-01-<ID>-<entry>.png`, `CMD-02-field.png`, `CMD-02-menu-escape.png` and an A11Y-02 focus sequence.

## Gotchas

- This is a seeded recipe, not evidence that native wiring passed. App menu/button/key wiring needs a device run.
- If automation cannot deliver Esc, record it as NOT VERIFIED and request a human device step.
- If another utility blocks menu clicks, record the menu entry as NOT VERIFIED separately from the key entry.
- Panel overlay preserves canvas geometry; use a pointer location outside the panel for anchored zoom comparisons.
- No folder, grid, preview, navigation or search behavior exists yet. Never replace those acceptance steps with
  placeholder behavior in the ledger.
