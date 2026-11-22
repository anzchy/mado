# Capture Bar and Capture Thumbnail

The Capture Bar is a small always-on-top helper (a separate signed process) that takes region, window and full-screen captures, saves them as `mado-YYYYMMDDHHmmss.png` and copies them. A Capture Thumbnail appears for about five seconds after each capture with Copy, Annotate, Open in Mado and Move to Trash (Save when saving is off).

## Sub-features

- CAP-01 Capture Bar (enable, modes, shortcuts, collapse, helper lifecycle)
- CAP-02 Capture Thumbnail (actions, saving off, Capture Folder prompt, Annotate hand-off)

## How to get to it (user POV)

- Settings (⌘,) > Screenshots > Show Capture Bar (id `settings.capture.enabled`).
- Bar buttons: Region Capture, Window Capture, Full Screen Capture, Recognize Text, Open Mado, collapse chevron.
- Global shortcuts: ⌃⌥1 region, ⌃⌥2 window, ⌃⌥3 full screen, ⌃⌥4 capture and recognise, ⌃⌥0 show/hide bar.
- Thumbnail buttons appear on hover, bottom-right of the display.

## Driving it with computer use

Preconditions: a signed Debug build launched by the run, GUI lock held, input source ABC (`ctrl+space` through System Events toggles it; read it back with a TIS query), a clean desktop (captures include whatever is on screen).

- Enable: AX press `settings.capture.enabled` or click the switch. Result: a new `MadoCaptureHelper` process and the bar. Screen Recording may already be granted on the machine; macOS may still show its periodic "bypass the system private window picker" prompt for the helper at the first capture: click Allow (our helper). A never-granted machine cannot be reproduced without changing privacy settings: NOT VERIFIED.
- Region: click the bar button, then a CGEvent drag. Drag from bottom-right to top-left to put the pointer inside the region and prove no cursor is captured.
- Window: click the button, move over a window, click. Full screen: click the button.
- Verify: `ls -lt ~/Downloads` for the name; `clip <png>` (NSPasteboard, accepts public.png or public.tiff) and compare bytes with the file; `sips -g pixelWidth` for size. Same-second captures get `-2`: send two shortcut chords back to back.
- Thumbnail time: after the capture take screenshots every ~1.2 s and crop the corner; equal file sizes mean the thumbnail is still there.
- Buttons: hover the thumbnail first. Copy replaces a sentinel clipboard with a PNG. Trash: the file appears in `~/.Trash`. Open in Mado: a window titled with the file name. Annotate: log line `capture annotate handoff outcome=matched` and Annotate Mode.
- Saving off: turn off "Save captures to the Capture Folder" (AX `settings.capture.after-save`); the thumbnail then says "Only on the clipboard · Not saved" and shows Save.
- Collapse: drag the bar by its left edge, click the chevron; a menu-bar icon appears; click it or press ⌃⌥0 to restore. A capture while collapsed must not contain the icon.
- Shortcuts: click a field, press a chord via CGEvent; a duplicate shows "already used by"; Restore Defaults.
- Off: AX press `settings.capture.enabled`; `ps` shows the helper gone.
- Capture Folder Change...: the helper's open panel is an AXSystemDialog of the helper PID.
- Cold hand-off: quit Mado (the helper stays), capture, click Annotate; Mado starts and enters Annotate Mode.

## Gotchas

- Hit only the visible thumbnail buttons; the layout changes with saving off (Save adds a button).
- A click on the area behind the bottom-right notice brings the app under it (for example a terminal) to the front and hides the Mado window.
- Dragging the thumbnail out with CGEvents did not start a drag in run p-device-20261122-v002: drag-out is NOT VERIFIED.
- The helper's own panel: ⌘⇧G then Return did not navigate when driven by synthetic keys; a typed path was garbled by a Chinese IME when the source was not ABC.
- Captures contain the desktop; keep them under `~/.mado/` and never in the repository. Move test captures out of `~/Downloads` afterwards (only files with this run's timestamps).
- The helper's UI language is not the app's `-AppleLanguages` override.
