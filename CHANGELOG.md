# Changelog

## v0.0.2 (unreleased)

Capture, annotate and recognise text. Mado now covers the path from taking a screenshot to marking it up and copying its text. All of these are `Partial` in the [feature ledger](docs/feature-ledger.md): they work and have a real-device record, with limits stated there.

### Added

- **Capture Bar**: capture a region, a window or the full screen from a floating bar or global shortcuts (⌃⌥1/2/3; ⌃⌥4 captures and recognises text; ⌃⌥0 shows or hides the bar). Shots are saved as `mado-YYYYMMDDHHmmss.png` in the Capture Folder and copied to the clipboard. The first capture asks for Screen Recording permission. Settings → Capture.
- **Capture Thumbnail**: after a capture, copy, annotate, open in Mado or move to Trash.
- **Annotate Mode** (View › Annotate, ⌘E): arrow, rectangle, text, highlighter, pen, numbered marks, mosaic or solid redaction, and crop, with undo and redo. ⌘S saves `<name>-annotated.<ext>` next to the original without overwriting it; ⌘C copies the result.
- **Text recognition**: select text directly on an image and copy it, or use Recognise Text (viewer or Capture Bar) to copy a whole image's text. It runs on your Mac by default (On-device Recognition).
- **Cloud Recognition** (optional, off by default): with your own Baidu AI Cloud keys and your agreement, Recognise Text can use Baidu's General Text Recognition (通用文字识别). The result says which engine was used. Settings names the Baidu product you must enable.

### Changed

- About and the privacy text now say that images stay on your Mac, with Cloud Recognition as the one exception.

### Known limits

- Rotate and flip are not in the viewer yet, so text selection after a rotate or flip is not covered.
- The Capture Thumbnail has no Recognise Text button yet; use the Capture Bar's recognise button or ⌃⌥4.
- Tested on a Mac mini at 1x with synthetic and manual input. Retina (2x), VoiceOver paths and some first-run permission flows are not verified.

## v0.0.1 (unreleased)

### Known issues

These are test-suite issues, not app behaviour.

- The same class of race (an assertion reads one layer before another async layer has settled) has recurred in the t231 tests (#333, #352). A shared wait helper and a forced-delay test seam are proposed as follow-up work.
