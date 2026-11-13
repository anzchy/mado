# Grilling record: screenshot Minibar, annotation and OCR (2026-11-13)

Inputs: [technical research](../research/20261113-capture-ocr-tech.md) and [annotation and user-journey research](../research/20261113-capture-annotation-ux.md). Both are document research and have not been tested on a device.

## Decisions made before grilling (owner, 2026-11-13)

| # | Decision | Owner's words |
|---|---|---|
| 0.1 | Embed the screenshot helper in Mado.app rather than shipping a separate app | 「内嵌」 |
| 0.2 | The helper's form is a floating toolbar | 「浮动工具条」 |
| 0.3 | Do annotation, and do it inside Mado | 「要做，不过是在Mado里面做」 |
| 0.4 | Save captures to ~/Downloads by default; another location can be set in Settings | 「默认 ~/Downloads，也可以在Settings中设置其他位置」 |
| 0.5 | Support common OCR APIs, Baidu OCR first | 「OCR是的，我希望支持常用的OCR API，优先支持百度OCR」 |

## Group 1: cloud OCR and privacy

| # | Question | Decision (owner's choice) |
|---|---|---|
| 1.1 | Who provides the API Key | The user enters their own Baidu API Key / Secret Key, stored in the keychain. Mado ships no key and pays no fees. |
| 1.2 | Consent before upload | The first cloud OCR shows "the image will be uploaded to Baidu" and remembers the user's consent. Settings has a global switch to turn cloud OCR off. |
| 1.3 | No key, offline, or quota used up | Fall back automatically to on-device recognition (Vision) and mark the result as on-device. |
| 1.4 | Which engine EXT-01 (select text on the image) uses | On-device recognition. Cloud OCR is used only for the explicit "recognise text" action. |

## Group 2: the helper and the floating toolbar

| # | Question | Decision (owner's choice) |
|---|---|---|
| 2.1 | Which buttons the toolbar has in v1 | Region, window and full-screen capture; capture and recognise text; open Mado. **No delayed capture.** |
| 2.2 | How the toolbar exists when not in use | It can be dragged and remembers its position. It can collapse to a menu bar icon and be restored from that icon or with a shortcut. |
| 2.3 | Where it is turned on, and whether it starts at login | Off by default. The user turns on the screenshot toolbar in Mado Settings and chooses separately whether it starts at login. Screen Recording permission is requested only at the first capture. |
| 2.4 | Global shortcuts | Default ⌃⇧⌘ series (for example ⌃⇧⌘1 region, 2 window, 3 full screen, 4 capture and recognise text). They can be changed in Settings, and conflicts are flagged. They do not take over the system's ⌘⇧3/4/5. |

## Group 3: after a capture

| # | Question | Decision (owner's words or choice) |
|---|---|---|
| 3.1 | Default behaviour after a capture | 「角落弹缩略图约 5 秒：复制 / 标注 / 在 Mado 打开 / 识别文字 / 删除 / 拖走；不理它就自动消失。复制和存盘默认打开，可以在Settings中设置disable，Settings 中要有一个专门的Screenshots相关Tab，用于组织这些选项。」 |
| 3.2 | Whether capture-and-recognise also saves the image | It does not save the image. The text goes to the clipboard, and a short notice shows the character count and which engine was used (on-device or Baidu). Clicking the notice opens a panel where the text can be viewed and edited. |
| 3.3 | File name and location | 「Downloads 根目录，命名不要出现空格，模板为`mado-20261113140532.png`」 |
| 3.4 | Browsing other captures in Mado | The first time a capture opens in Mado, Mado guides the user to grant the capture folder as an Access Root. Mado does not add a Downloads entitlement. |
| 3.5 | Where a capture lives when "Save" is turned off | It goes only to the clipboard. The thumbnail gains a "Save" button. Choosing Annotate or Open in Mado first saves the image to the capture folder, then opens it. Once the thumbnail disappears, the clipboard holds the only copy. |
| 3.6 | Two captures within the same second | Add a sequence number: `mado-20261113140532-2.png`. The first file has no number; later ones get -2, -3 in order. Local time is used. |

## Group 4: annotation

| # | Question | Decision (owner's choice) |
|---|---|---|
| 4.1 | How to enter annotation | Switch to annotate mode in the same window: ⌘E or the "Annotate" button. In this mode the toolbar shows annotation tools and arrow-key navigation is off. Esc exits, and asks first if there are unsaved changes. |
| 4.2 | How to save after annotating | ⌘S saves a copy as `<original name>-annotated.<original extension>` in the same folder (format follows 4.6) and never overwrites the original. ⌘C copies the annotated image without saving it. If the folder has no write grant, a save panel appears. This follows ADR-007. |
| 4.3 | v1 tools | Arrow, rectangle, text; highlighter, pen; redaction (solid box / mosaic); crop, numbered step markers. All are in v1. |
| 4.4 | Which images can be annotated | Any image open in Mado, whether a capture or an existing image. The save rule is the same. |
| 4.5 | Re-editable later | No. Saving merges the annotations into the image. Inside annotate mode the user can undo, redo, drag and adjust; after saving the file is an ordinary image, with no project file and no private metadata. |
| 4.6 | Save format | Keep the original format (`photo.jpg` → `photo-annotated.jpg`). Only formats Mado cannot write are saved as PNG. |
| 4.7 | Default redaction | Mosaic by default, with adjustable strength (owner's choice). Recorded risk: weak mosaic or blur can be reversed to recover text. The solid box stays available as the alternative. |
| 4.8 | Write access for ⌘S | Upgrade granted folders to writable: following the P5-04 plan, the entitlement changes to `files.user-selected.read-write`. Inside a folder the user has granted, ⌘S saves the `-annotated` copy directly. Anywhere else, a save panel appears. The original image is still never overwritten. Whether existing Access Roots become writable automatically is not yet verified and needs a device test. |

## Outputs

- GLOSSARY.md: Text Recognition, Capture, and Annotation terms and their relationships.
- [ADR-0018](../adr/0018-capture-helper-embedded-accessory-process.md): the embedded capture helper and its boundary for Screen Recording and file sharing.
- [ADR-0019](../adr/0019-cloud-text-recognition-with-user-key-and-consent.md): Cloud Recognition and image upload (amends ADR-015).
- [ADR-0020](../adr/0020-annotation-saves-a-flattened-copy-into-writable-access-roots.md): annotation saving, and making Access Roots writable (relation to ADR-007/008).

## Not yet decided (for /to-spec or a later round)

- How the extra capture prompt on macOS 15+ is explained in the interface.
- Whether the helper gets its own Screen Recording entry, and what name it shows (device test on 14/15/26).
- Layout of each option in the Screenshots Settings tab.
- Annotation tool shortcut keys, checked against the viewer's existing shortcuts.
