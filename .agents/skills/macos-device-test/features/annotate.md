# Annotate Mode and Annotated Copy

Annotate Mode draws marks (rectangle, arrow, text, highlighter, pen, mosaic or solid redact, crop, numbered steps) on top of an image, and writes an Annotated Copy next to the original.

## Sub-features

- EDIT-07 Annotate Mode
- EDIT-08 Annotated Copy

## How to get to it (user POV)

- ⌘E in the viewer, View > Annotate, or the pencil on a Capture Thumbnail.
- Tool keys: V A R T H P N M C; toolbar `annotate.strip`; ⌘S save, ⌘C copy, Esc/Done leave.

## Driving it with computer use

Preconditions: a fixture with text (`TestAssets/TextRecognition/mixed.png`), input source ABC for tool keys (toggle for the IME test), no other dialog.

- Enter: ⌘E. Marks: press the tool key, then drag inside the image; marks outside the image are clamped, and a text click outside the image does nothing. Count marks with the AX `AXLayoutItem` rows.
- Select tool: click a mark; 8 handles for rectangle; drag a handle; arrow keys nudge; ⌫ deletes; ⌘Z and ⇧⌘Z undo and redo.
- Text with a Chinese IME: with Xiaohe shuangpin, `vswf` composes 中文; Space commits to the field, Return commits the mark; Esc while composing cancels only the composition.
- Prompts: Esc, ⌘W, ⌘Q and an external `open -a` of another file with unsaved marks show the in-window Save / Don't Save / Cancel sheet.
- Save: ⌘S gives a panel prefilled `<name>-annotated`; a second ⌘S prefills `-annotated-2`; the "Saved as" bar has Show in Finder (opens a Finder window selecting the file: close it afterwards).
- Copy: ⌘C puts a TIFF on the pasteboard; `clip <png>` converts it; compare size to the original (crop changes it).
- Crop: C, drag, Return.

## Gotchas

- Annotate ⌘C is TIFF only; the Capture Thumbnail Copy is PNG.
- AX tree queries hang while an Open panel is up: kill only your own `osascript`.
- Browse keys do not switch images in Annotate Mode (arrow keys nudge the selected mark).
