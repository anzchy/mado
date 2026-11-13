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

## Group 5: prototype choices and the remaining open items (2026-11-13, second round)

Prototype: throwaway branch `prototype/680-capture-ui` (commit 96b47f79), never merged. The owner chose Settings A, Capture Bar A and Thumbnail A: 「A A A .the fourth: 标注模式工具栏放在右边竖排，重新更新这个Prototype」. Annotate Mode therefore uses variant D: a vertical tool strip floating at the right edge of the window. While annotating, the image fits the area to the left of the strip, so the strip never covers it. This refines 4.1: the tools sit in that strip, not in the top toolbar.

| # | Question | Decision (owner's choice) |
|---|---|---|
| 5.1 | Where the Screenshots tab sits in the Settings sidebar | Before Updates. |
| 5.2 | The other settings on that tab when "Show capture bar" is off | Greyed out and not editable. They stay visible, so the layout does not jump. |
| 5.3 | Minimum mosaic strength | Even the weakest setting makes a full line of ordinary body text unreadable. The implementer measures the pixel value on test assets, and the ticket's acceptance records it. No number is fixed here. |
| 5.4 | Showing that a mosaic can be reversed | A permanent line of small text sits under the strength slider whenever mosaic is chosen. The user can switch to a solid box from there. There is no dialog. |
| 5.5 | Tool shortcut keys | Single letters, active only in Annotate Mode: V select, A arrow, R rectangle, T text, H highlighter, P pen, M redaction, C crop, N step marker. While the user is typing in a text mark, letters type text and do not switch tools. The strip's hover tips show the letters. ⌘E enters Annotate Mode. The viewer uses no bare letter keys today (Space, arrows, Esc, Return, 0, 1, +, −, Tab; letters only with ⌘), so there is no conflict. |
| 5.6 | ← / → in Annotate Mode | Nudge the selected mark. With nothing selected they do nothing. They never change images; to change images the user leaves with Esc first, which asks about unsaved changes (4.1). |
| 5.7 | Explaining the extra capture prompt on macOS 15+ | One line on the Screenshots tab, under the Screen Recording permission status: 「在 macOS 15 及以后，系统会不定期再次询问是否允许 Mado 截取屏幕。这是系统要求，选择允许即可继续截图。」 It does not name a frequency, because Apple has not published one. If the system prompt shows the helper's name rather than Mado, the device test replaces the name in this line. No extra dialog at capture time. |

Preview Set after ⌘S (owner: 「let codex weigh in on best practices that fit a common user's UX」, recommendation recorded on #680): the user stays in Annotate Mode on the original; a confirmation shows 「已存储为 <name>」 with Show in Finder; a second ⌘S writes `-annotated-2`; the open Preview Set does not change, and the copy appears in the Grid and in later sets.

## Not yet decided (for a later round)

- Whether the helper gets its own Screen Recording entry, and what name it shows (device test on 14/15/26; 14/15 skipped by the owner, 「skip macOS 14, 15 device test」).
- Short windows: below about 530 px of height the tool strip needs a fallback (scroll, two columns, or a "more" item). The native implementation proposes one.
