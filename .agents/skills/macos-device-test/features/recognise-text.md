# Recognise text, select on image and Cloud Recognition

Mado can copy text from an image: explicit Recognise Text from the viewer or the Capture Bar (On-device Recognition by default), direct select-on-image, and an opt-in Cloud Recognition (Baidu) with the owner's own keys.

## Sub-features

- EXT-01 Recognise and copy text in an image
- EXT-04 Cloud Recognition
- EXT-05 Explicit Recognise Text

## How to get to it (user POV)

- Viewer: View > Recognise Text (id `viewer.recognise-text.menu`).
- Capture Bar: Recognize Text button, or ⌃⌥4, then drag a region.
- Notice: `recognise-text.notice`; panel `recognise-text.panel`, editor `recognise-text.editor`, Copy `recognise-text.copy`.
- Settings > Screenshots > Text Recognition (cloud switch `settings.capture.ocr-cloud`, key fields `settings.capture.ocr-api-key` and `-secret-key`).

## Driving it with computer use

Preconditions: fixtures from `TestAssets/TextRecognition/` copied into the run folder (`mixed.png` has `中文测试`, `SIDE`, `Hello Mado`; `blank.png` has none); sentinel clipboard (`echo SENTINEL | pbcopy`); input source ABC for letter keys.

- Viewer: open with `open -a <bundle> mixed.png`, press the menu item with `menu.sh`. Result: notice "Copied 20 characters · On-device Recognition"; the clipboard holds the text.
- Panel: click the notice (or Tab until `recognise-text.notice` has focus, then Return or Space). Poll focus with an AX focus helper; chrome auto-hide changes the Tab count.
- Capture Bar: click Recognize Text, drag over text; no file is added to the Capture Folder. Over a white area expect "No text found · Clipboard unchanged" and the sentinel intact.
- Select-on-image: drag from inside a text line; expect a highlight and `⌘C` text. Hover shows an I-beam (take `screencapture -C`).
- Cloud: the switch stays off with "Save the keys first." until keys exist. Never enter, read or delete keys in a tester run; the owner does that. Consent sheet, engine label 百度云识别, error fallback and Remove Keys need the owner's keys.
- Chinese UI: write `zh-Hans` to `$RUN_DIR/app-lang.txt` before `launch.sh`.

## Gotchas

- A chord such as the notice click lands on the app behind the notice if the notice already timed out (5 s).
- `mixed-orientation-6.jpg` shows upside down in Mado and in Quick Look: treat it as a fixture problem, not an app orientation verdict.
- Text typed through a Chinese IME in the panel editor shows composition candidates; Esc cancels the composition only.
