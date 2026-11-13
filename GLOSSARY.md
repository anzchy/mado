# Mado

Mado is a macOS image viewer that browses images where they already are on disk, inside the sandbox. This glossary fixes the words for what the user can reach and how it is remembered.

## Language

**Mado**:
The app name for this sandboxed macOS image viewer; former name: Picsee (#547, ADR-0017).

### Access

**Access Root**（授权根）:
A folder the user granted through the system open panel, which Mado keeps a bookmark for across relaunches.
_Avoid_: authorized directory, location, 授权目录 (as a noun for the stored grant)

**File Grant**（单文件授权）:
Access to one file, given by opening it from Finder or dragging it in, that lasts only for the current session.
_Avoid_: calling it an Access Root, file bookmark

**Lost Access**（无法访问）:
The condition of an Access Root that Mado can no longer read, always shown with exactly one cause: Disk Not Connected, Not Found, Access Expired, or Unknown.
_Avoid_: broken root, stale grant, "revoked" as the general term

**Disk Not Connected**（外接磁盘未连接）:
The cause of Lost Access when the disk the Access Root lives on is not mounted.
_Avoid_: offline, unmounted root

**Not Found**（找不到）:
The cause of Lost Access when the disk is mounted but the Access Root's bookmark no longer resolves; Mado cannot tell deletion from a move to another disk.
_Avoid_: moved, deleted

**Access Expired**（授权失效）:
The cause of Lost Access when the folder is still there but the system refuses to let Mado read it.
_Avoid_: revoked permission, denied root

### Library

**Library**（图库）:
The sidebar's set of Library Folders and the "All Photos" view over them; it references images in place and never imports or copies them.
_Avoid_: catalog, collection, import

**Library Folder**（图库文件夹）:
A folder the user explicitly added to the Library, always lying inside some Access Root.
_Avoid_: source, location

**Recent Item**（最近项）:
A record that a file or folder was recently viewed, which reopens without asking only while it is still inside an Access Root.
_Avoid_: recent grant, history bookmark

### Window

**Home**（首页）:
A window with no folder open: the Image Wall with the way to choose or drop a folder, and no Bottom Bar.
_Avoid_: first-launch screen (when any folderless window is meant), start page, empty state

**Image Wall**（图片墙）:
The tilted collage of Mado's built-in sample photographs behind the Home; it never shows the user's own images.
_Avoid_: scattered prints (the B4 design it replaced), background photos

**Bottom Bar**（底栏）:
The bar along the bottom of a window with a folder open, holding the sidebar toggle, the Current Item with the folder count, and the Grid tools; the Grid may scroll behind it.
_Avoid_: footer, status bar, toolbar

### Browsing

**Grid**（网格）:
The thumbnail view of one folder's images, in the active sort and filter order.
_Avoid_: gallery, thumbnail list, "browser" when the grid is meant

**Reading State**（读取状态）:
What the Grid's content area shows while a folder is still being scanned; it shows no partial results and can be cancelled.
_Avoid_: loading grid, partial grid, progress percentage

**Current Item**（当前项）:
The one image that keyboard navigation and Space/Enter act on; it can be outside the Selection.
_Avoid_: focused image, active image, selected image

**Selection**（选择集合）:
The set of images the user has picked in the Grid, possibly empty or several.
_Avoid_: highlighted items, current item

### Viewing

**Preview Set**（预览集合）:
The ordered list of images the viewer pages through, fixed when the viewer opens: the whole filtered and sorted folder, starting at the Current Item, when nothing or a single image is selected, or only the selected images in grid order for a multi-selection.
_Avoid_: playlist, range, "all images" when only a selection was meant

### Settings

**Interface Language**（界面语言）:
The single language every piece of text in Mado appears in, including the text macOS draws for it: Follow System, English or Simplified Chinese. Follow System means Simplified Chinese when the system prefers Chinese, English otherwise.
_Avoid_: locale, region, "translation" for the setting itself

### Text Recognition

**On-device Recognition**（本机识别）:
Text recognition that Mado performs on the Mac itself, without sending the image anywhere.
_Avoid_: offline OCR, Live Text (when the engine is meant)

**Cloud Recognition**（云识别）:
Text recognition by an outside OCR service, using the user's own key; the image leaves the Mac.
_Avoid_: online OCR, Baidu OCR (when the general concept is meant)

### Capture

**Capture**（截图）:
An image of the screen, or part of it, that Mado takes on the user's command.
_Avoid_: screenshot (as a separate term), snap, grab

**Capture Bar**（截图工具条）:
The small floating toolbar for taking a Capture, which stays available when no Mado window is open and can collapse to a menu bar icon.
_Avoid_: Minibar, helper (when the visible bar is meant), floating toolbar

**Capture Thumbnail**（截图缩略图）:
The short-lived corner preview shown after a Capture, offering the next steps for that one Capture.
_Avoid_: quick access overlay, preview (Preview Set means something else)

**Capture Folder**（截图文件夹）:
The folder new Captures are saved to; ~/Downloads unless the user changes it.
_Avoid_: screenshot location, output folder

### Annotation

**Annotate Mode**（标注模式）:
The state of a viewer window in which the user draws marks over the current image instead of browsing.
_Avoid_: edit mode, markup, editor

**Annotated Copy**（标注副本）:
A new image file, next to the original and named with "-annotated", holding the original with the marks merged in.
_Avoid_: edited image, overwrite, project file

## Relationships

- The **Home** has no **Bottom Bar**; every window with a folder open shows it, including the **Reading State**, an empty folder, a failed read and **Lost Access**.
- A change of **Interface Language** takes effect at the next launch; until then all text stays in the language Mado launched with, so the window never shows two languages at once.
- Follow System maps any Chinese system language, Traditional included, to Simplified Chinese.
- Relaunching to apply an **Interface Language** reopens what was open: the same folder in the **Grid**, or the same image.
- **Interface Language** covers interface text only; file and folder names and metadata values read from a file are never translated.

- An **Access Root** is created only by a user action in the system open panel; a **File Grant** never becomes one by itself.
- A **Library Folder** lies inside exactly one **Access Root**; adding a Library Folder inside an existing Access Root creates no new grant.
- Granting an **Access Root** does not add a **Library Folder**; only the explicit "Add Folder" action does.
- A **Preview Set** never grows after the viewer opens; deleted or unauthorized items drop out of it.
- Opening a folder shows the **Reading State** until the scan completes, then the **Grid** with the first image in the sort order as the **Current Item** and nothing selected.
- The sort order is one app-wide preference shared by every window and folder and kept across relaunch; an extension filter belongs to one folder in one window, survives rescans of that folder and clears when another folder is opened or the app relaunches.
- Cancelling the **Reading State** returns to whatever was shown before; it never shows a partly scanned folder.
- Esc from an image opened on its own returns to its folder's **Grid** only when that folder lies inside an **Access Root**, through the **Reading State** if the folder has not been scanned, with that image as the **Current Item**.
- While an **Access Root** has **Lost Access**, no image from inside it is shown, including cached thumbnails; the cache is kept and reused once access returns.
- Choosing a folder at the new place for a **Not Found** root rebinds that same **Access Root** to it; it never adds a second one. If the chosen folder is already an **Access Root**, the lost one is merged into it.
- **Lost Access** belongs to the **Access Root** as a whole; one unreadable subfolder or image inside it is not Lost Access.
- **Lost Access** with cause Unknown is shown as plain 「无法访问此文件夹」; Mado never guesses a cause.
- A **Recent Item** confers no access; reopening one outside every **Access Root** asks the user to grant its folder.
- **Cloud Recognition** runs only after the user has agreed to uploads once and while its global switch is on; without a key, without network or out of quota, Mado uses **On-device Recognition** and says so on the result.
- Selecting text on an image always uses **On-device Recognition**; **Cloud Recognition** runs only when the user explicitly asks to recognise text.
- A **Capture** is saved to the **Capture Folder** unless saving is turned off, in which case it lives only on the clipboard until the user saves it from its **Capture Thumbnail**.
- Recognising text straight from the **Capture Bar** never saves the **Capture**.
- Opening a **Capture** in Mado gives a **File Grant** for that one file; browsing the other Captures needs the **Capture Folder** to be an **Access Root**.
- Any image open in Mado can enter **Annotate Mode**, not only a **Capture**.
- Saving in **Annotate Mode** always produces an **Annotated Copy**; the original image is never replaced, and the marks cannot be edited again after saving.

## Example dialogue

> **Dev:** "The user opened `~/Downloads/a.jpg` from Finder and pressed →. Do we show the Downloads folder in the sidebar?"
> **Domain expert:** "They only have a **File Grant**, so → asks them to grant `~/Downloads`. Once they do, it is an **Access Root** and shows under Recent, but it is not a **Library Folder** until they choose Add Folder."
> **Dev:** "And next launch, if they click `a.jpg` in Recent?"
> **Domain expert:** "It opens directly, because it is now inside an **Access Root**. Had they never granted the folder, the **Recent Item** would ask for it, since the **File Grant** ended with the session."

## Flagged ambiguities

- "授权目录" was used for both the stored grant and any folder being browsed: resolved as **Access Root** for the stored grant; a folder merely being browsed is just a folder.
- "图库里的文件夹" and "授权的文件夹" were treated as one thing: resolved as distinct, **Library Folder** ⊂ **Access Root**.
