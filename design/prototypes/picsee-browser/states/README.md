# Mado C 设计状态稿

这里是应随仓库提交的 **25份正式静态状态稿**，与上一级的交互原型分开维护。目录内容不依赖 `.stitch/`、登录凭据、Stitch CLI 或远程图片。

## 打开

项目根目录运行以下任一方式：

```sh
# 与交互原型使用同一服务
python3 -m http.server 4311 --bind 127.0.0.1 --directory design
# 地址：http://127.0.0.1:4311/prototypes/picsee-browser/states/index.html

# 单独预览状态稿，兼容原4313地址
python3 -m http.server 4313 --bind 127.0.0.1 --directory design/prototypes/picsee-browser/states
# 地址：http://127.0.0.1:4313/index.html
```

也可用 `npm run preview:prototype` / `npm run preview:states`。请经HTTP打开，索引需要读取本地manifest；不以双击file://作为验收方式。

## 素材分工

| 路径 | 作用 | 是否提交 |
| --- | --- | --- |
| `manifest.json` | 唯一页面目录：名称、文件、视口、来源类别及每页 HTML 的 SHA256 | 是 |
| `index.html` | 从manifest加载的浏览索引，不另维护一份页面列表 | 是 |
| 25个同名HTML | 正式静态状态；不声明按钮行为已实现 | 是 |
| `journeys.html` | 用户旅程图，是[计划 §1.6](../../../../docs/PICSEE_DEVELOPMENT_PLAN.md)旅程索引的视图（ADR-013），两者不一致时以 §1.6 为准；卡片只引用本目录的状态稿，不显示实现进度（进度看功能账簿）。不是状态稿，不进 `manifest.json`，由 `index.html` 链接 | 是 |
| `home-image-wall.html` | 首页图片墙参考稿，图片墙外观的来源：2026-10-30 用户在三个方向中选定 C（斜置拼贴、缓慢漂移）并要求放大（「选C，但是图片墙可以放大」），之后定为「C 取代 B4 外观，保留拖入反馈」（[grilling 记录](../../../../docs/plans/20261030-bottom-bar-home-wall-grilling.md)，spec #311）。正式状态是 21 `first-launch.html`（#317），`design:check` 从本页读取倾斜、透明度、圆角、阴影和漂移的期望值；21 的中央是 B4 的，不取本页的中央（#441）。`?theme=dark` 看深色。**不是状态稿，不进 `manifest.json`**；App 对照 21，不对照本页。原型在分支 `prototype/footer-transparent` | 是 |
| `grid-footer-fill.html` | 打开文件夹后的常驻底栏参考稿，80% 底栏外观的来源：2026-10-30 用户选定「填充 80%（很实）」、不要顶部分隔线（「不要，靠 80% 底色区分」），只有未打开文件夹的窗口没有底栏（「只有未打开文件夹的窗口没有底栏」），spec #311。正式状态是 11/12 和其他画网格底栏的页面（#317），`design:check` 从本页读取填充、分隔线和左侧竖线的期望值。`?theme=dark` 看深色。**不是状态稿，不进 `manifest.json`**；App 对照这些正式页，不对照本页。原型在分支 `prototype/footer-transparent` | 是 |
| `assets/images/`、`assets/manifest.json` | 13个按内容哈希命名的共享图片，替代95处重复base64 | 是 |
| `_ds/` | 设计系统编译后的运行时副本，由import工具同步 | 是，保证预览可直接运行 |
| `vendor/` | 固定版本React预览依赖；不是原生App依赖 | 是 |
| `provenance/stitch.json` | 原始Stitch screen IDs与打包前后哈希，不含凭据或签名下载URL | 是 |
| `_d_meta.json` | 设计系统绑定与资产索引 | 是 |

图片来源及摄影师链接见 [ASSETS.md](../ASSETS.md)。状态稿使用既有示例图及其缩略版；提取时保持原始图片字节，未改变构图。原型文件名、日期等演示信息不代表真实EXIF。

## 页内子情况

22、24、26 三页按 [ADR-014](../../../../docs/adr/0014-recoverable-folder-states-in-window.md) 把子情况放在同一页里，35、36 两页（#214，spec #212）、21、11、12 三页（#317，spec #311）和 37、38、39 三页（#680）同样如此；用查询参数切换，不带参数的地址就是主状态，`sha256` 固定的也是它的字节。按钮没有行为。

| 页面 | 不带参数 | 子情况 |
| --- | --- | --- |
| `empty-folder.html`（22-BD） | 这一层有子文件夹：子文件夹卡片、「包含子文件夹浏览」「选择其他文件夹…」，内容区可拖入 | `?case=no-subfolders` 最近打开的文件夹；`?drag=over` 拖入时的提示 |
| `permission-denied.html`（26-BC） | 授权失效：侧栏该文件夹变灰带 ⚠、子文件夹收起（› 与 `aria-expanded="false"`）；「重新选择文件夹…」「选择其他文件夹…」。侧栏「个人收藏」「最近查看」两行和「侧栏里的收藏和最近查看不受影响。」标为 **PENDING(P3-14)**：它们随 P3-14（J4）落地，P2-08c 验收不含（ADR-014） | `?cause=volume` 外接磁盘未连接；`?cause=missing` 找不到；`?cause=unknown` 原因分不清时的「无法访问此文件夹」；`?case=moved` 26M-C 同卷移动或改名后跟随，网格上方的提示条（不是权限失败）。各子情况同样带 PENDING(P3-14) 标注 |
| `folder-loading.html`（24） | 正在读取：进度、「取消读取」持有初始键盘焦点（#443） | `?case=failed` 读取失败 · 24F-A（#236 用户选定）：读取中途停止、授权根仍可读时，内容区居中写「没能读完“待整理”」和一句说明，「重试」为主按钮并持有键盘焦点，另有「选择其他文件夹…」；不显示部分网格，侧栏该文件夹与底栏都不显示部分计数，底栏写「读取未完成」。授权根不可读属于 26 |
| `settings.html`（35 设置 · B） | 设置窗口，左侧边栏（用户：「选B」）选中「通用」：外观、始终显示大图工具、语言说明。缓存大小、版本与构建号、上次检查时间都是示例，旁边标「示例」。App 还没有的控件置灰、不可聚焦并标「即将推出」（用户：「显示但置灰」）：「显示」三项（PREF-03）、「更新」的自动检查与立即检查（DIST-05）、「关于」的三个链接 | `?section=general\|display\|capture\|cache\|update\|about` 选中对应分类；「显示」与 15 页面板是同一组偏好。`?section=capture`「截图」（#680/#682，在「更新」之前，决定 5.1）：设置方案 A，一张表单分四组（截图工具条、截图之后、全局快捷键、文字识别），在固定大小的窗口里滚动；控件画的是 #682 的目标状态，不标「即将推出」；录屏权限状态下是决定 5.7 的原句。云端识别开关画成关闭并带「未填写密钥」：保存密钥并同意后才能打开（ADR-0019）。`?section=capture&bar=off` 关闭截图工具条：这一页其余设置（含文字识别）都变灰、不可编辑但仍可见（决定 5.2，owner：「变灰，不能改」）；`?section=capture&scroll=ocr` 滚到文字识别 |
| `capture-bar.html`（37 截图工具条 · A） | 整块屏幕（1280×800）：系统菜单栏、另一个 App 的窗口，Capture Bar 浮在上面：拖动把手、区域截图、窗口截图、全屏截图、识别文字、打开 Mado、收起到菜单栏。画的是默认位置：鼠标所在显示器的顶部居中、菜单栏下 32 px；拖动后按显示器记住位置（grilling 2.2）。#682 只断言工具条的尺寸与内部布局，不断言屏幕位置 | `?hover=region` 悬停填充和提示（名称与 ⌃⇧⌘1）；`?state=collapsed` 收起，只剩菜单栏图标；`?state=menu` 收起并打开菜单栏图标的菜单；`?state=denied` 录屏权限被拒：工具条下的说明与「打开系统设置」，区域截图与菜单栏图标带红点 |
| `capture-thumbnail.html`（38 截图缩略图 · A） | 截图后右下角的 Capture Thumbnail（存储打开）：240 宽的带框缩略图和下方「已存到 ~/下载 · 已拷贝」 | `?hover=1` 悬停：变暗，出现 拷贝、标注、在 Mado 中打开、识别文字、移到废纸篓；`?save=off` 存储关闭并悬停：「存储」排第一（决定 3.5），状态行「只在剪贴板里 · 没有存储」；`?kind=text` 识别文字后的「已拷贝 N 个字符」与引擎标签；`?kind=text&panel=1` 点开后的可编辑文字面板；`?kind=notext` 「没有找到文字 · 剪贴板没有改变」 |
| `annotate.html`（39 标注模式 · D） | 大图窗口的 Annotate Mode：右侧竖排工具条（选择 \| 箭头 矩形 文字 荧光笔 画笔 遮挡 裁剪 序号 \| 撤销 重做 \| 拷贝 存储 \| 完成），图片适应工具条左边的区域；矩形工具选中，有四个标记。悬停提示带单字母快捷键 V A R T H P M C N（决定 5.5） | `?tool=redact` 遮挡选项浮层：马赛克/实色块、强度和常驻的可还原提示（决定 5.4）；`?tool=redact&style=solid` 实色块；`?saved=1` ⌘S 之后「已存储为 DSC_0342-annotated.jpg」与「在访达中显示」；`?sheet=unsaved` 有未存储标记时按 Esc：不存储 / 取消 / 存储。窗口矮到放不下工具条（约 530 以下）时，工具条在自身内部滚动（`max-height` + `overflow-y: auto`），本页不另设矮窗口子情况 |
| `shortcuts.html`（36 键盘快捷键 · C） | 帮助 → 键盘快捷键打开的只读窗口（用户：「选 C」），三张卡片：文件与窗口（任何时候）、网格（浏览文件夹时）、大图（查看一张图片时）；没有搜索 | `?card=files\|grid\|viewer` 给该卡片加虚线描边，只用于对照，App 没有这个状态 |
| `first-launch.html`（21 首次打开） | 首页：没有底栏和侧栏，中央是 B4 的拖入提示「把照片文件夹拖到这里」和「选择文件夹…」「或按 ⌘O」，两行相距 18 pt，没有格式标签行（#441，用户：「打开首页的这行字我不喜欢，删掉」「B4 centre; re-pin page 21 (Recommended)」）；图片墙在中央后面缓慢漂移，「减弱动态效果」时不动 | `?drag=over` 拖入时：图片墙淡到 40%，提示改为「松开即可打开」并用强调色，虚线框用强调色；`?theme=dark` 深色 |
| `grid-light.html`、`grid-dark.html`（11/12 网格） | 底栏盖在网格上，窗口底色 80%，没有顶部分隔线 | `?scroll=behind` 多两行图片并把一行滚到底栏后面；`?transparency=reduced` 「减弱透明度」时底栏 100% |

22、24、26、35、36、21、37、38、39 都接受 `?theme=dark`；11/12 各是一种外观。35、36 由分支 `prototype/shortcuts-sheet` 上的 `prototype-settings.html?variant=B`、`prototype-shortcuts.html?variant=C` 定稿而来，原型文件不进本目录。15 页面板里的「键盘快捷键」入口已去掉（用户：「Page 15 中去掉快捷键入口」）。

`shortcuts.html` 每一行的 `data-shortcut` 写它对应的命令（`command:<CommandID>`、`menu:<菜单标题>` 或 `key:<按键处理>`，多个用 `|` 分隔）。`scripts/design/shortcut-model.mjs` 从 `CommandID.swift`、`App/Commands/CommandMenu.swift`、`ChromeWindowCommands.swift` 读出菜单快捷键，与页面逐行比较：页面上每个 `<li>` 都算一行，没有 `data-shortcut` 的行、行外的按键、多一行、少一行或按键不同都失败。`App/` 与 `Packages/MadoKit/Sources` 里每处 `keyDown` 的 `case`、`keyCode ==` 和 `.onKeyPress` 处理的按键，都要在该脚本的 `KEY_SITES` 里登记为页面上的某一行或写明不列入的理由（如聚焦控件内的 Tab/Space/Return、侧栏分隔条的方向键）；新增未登记的按键或登记的按键消失都失败。不比较：`keyDown` 里的修饰键变体（网格里 ⇧/⌘ 加方向键），以及同一文件里同一按键的第二处处理。编辑菜单的撤销、剪切、拷贝、粘贴、全选只作用于搜索框，不列入。

## #680 · 截图与标注（37–39 与 35「截图」）

来源：一次性原型分支 `prototype/680-capture-ui` 上的 `design/prototypes/capture-proto/`（提交 `96b47f79`），原型文件不进本目录。Owner 2026-11-13 在原型里选定设置 A、截图工具条 A、缩略图 A，标注模式改为第四种：「A A A .the fourth: 标注模式工具栏放在右边竖排，重新更新这个Prototype」；随后「好，做固定设计稿，然后派 #682 和 #690，设计稿风格与已有页面风格一致设计稿补充到 design 相关文件夹，update user journey」。决定见 [grilling 记录](../../../../docs/plans/20261113-capture-annotation-ocr-grilling.md)（第 2–5 组）与 spec #680。原型里的方案切换器、底部说明栏、「已选/未选」标记和状态行不进状态稿。

- 37、38 是整块屏幕，不是 Mado 窗口：背景用共享图片 `b2b2e3fddb8288fe4613.jpg` 当桌面，画一个示例文稿窗口。39 是大图窗口本身（同 13），图片 `b3525a0437e56edf3a3f.jpg`。
- 颜色都用 `_ds` token。以下是接受的例外（#680 r1）：38 缩略图悬停时的深色遮罩（黑 55%）和遮罩上的白色按钮文字；39 实色块遮挡（纯黑，导出时就是黑色）；39 的标记颜色 annotation red, fixed：固定为 `--color-danger` 浅色值 `#dc2626`，深浅外观都一样，因为标记是图片内容，拼合后的 Annotated Copy 不能随 App 外观变化。
- #682 / #690 的度量（工具条宽度与偏移、浮层几何、确认条位置、设置行布局）写在 #680 的交接记录里，按页面 + 查询参数在 1280×800 测量。
- 36 `shortcuts.html` 这次不变：它的行由 `scripts/design/shortcut-model.mjs` 与代码逐行比较，标注模式的单字母快捷键（V A R T H P M C N）、⌘E 与全局截图快捷键，由实现这些按键的 ticket 同时加进 36。

## #347 · Viewer Tools 与 Thumbnail Size 对照映射

Owner 于 2026-11-03 回复「A A C」：220 保留原高度比例，窄窗规则继续生效；图标、计数与缩放文字使用文字色及 halo。本表取代上一轮 `.72 × size` 的高度和仅图标处理。14/16/33 无参数仍为深色，`?theme=light|dark` 切换外观并保留其他根 class。13 `viewer-quiet.html`、25 `image-error.html`、27 `original-size.html` 也接受相同查询（#447，owner：「Add light pins (Recommended)」）；无参数或无效参数仍为原深色，13 的工具仍隐藏。三页的浅色背景/文字沿用 14 的 tokens，浅色工具填充、blur 与 inset backing 同 14；深色工具保留原实色，未随之改成半透明。

**固定输入**：五页都把 canonical `design/picsee-ui-system/tokens/viewer-grid.css`（与 `_ds` 副本逐字相同）内联为 `<style data-viewer-grid-tokens>`；14/16/33 的 `<style data-viewer-tools>` 内联 `viewer-grid-variants.css` 的作者源。没有 linked stylesheet 或 `@import` 决定这些页的几何或颜色。Grid 的尺寸规则在既有 inline media cascade 内，`PinnedDesign.swift` 直接解析同一份被 HTML SHA 固定的规则。修改作者源后必须同步内联和 manifest；design check 检查同步。

| 页面 / URL | Selector | Property | Value |
| --- | --- | --- | --- |
| 14 `viewer-controls.html?theme=light`、16 `viewer-inspector.html?theme=light`、33 `viewer-filmstrip.html?theme=light` | `.viewer-floating-controls > [data-viewer-controls]`（14/16：`leading/navigation/zoom`；33：`leading/zoom`） | `background-color`; `backdrop-filter` / `-webkit-backdrop-filter` | `color-mix(in srgb,var(--color-panel) var(--tool-background-opacity),transparent)`；panel `#fff`，opacity `50%`；`blur(20px) saturate(1.6)` |
| 同三页 `?theme=dark`（无参数默认） | 同上 | 同上 | panel `#141821`，opacity 仍 `50%`；同一 blur/saturation |
| 同三页，两种外观 | `[data-viewer-controls]::before` | `inset`; `border-radius`; `background-color` | 内衬 `2px` / `4px`；panel 的 `50%`（`--tool-content-backing-opacity`），在外层 50% 上叠加，使控件内部有效 panel 比例为 75%；外层设置的默认含义不变 |
| 同三页，两种外观 | `[data-viewer-controls] .ds-icon-button`、`.viewer-file-label > span`、`.zoom-label`；33 `.c-filmstrip .c-strip-count` | `color`; `text-shadow` | `var(--color-text)` = 浅 `#1a1a1a` / 深 `#e5e7eb`；`var(--tool-foreground-halo)` = `0 0 1px var(--color-panel)` |
| 同三页，两种外观 | `[data-viewer-controls] svg` | `filter` | `drop-shadow(var(--tool-glyph-ink)) drop-shadow(var(--tool-foreground-halo))`；同位文字色叠印 `0 0 0 var(--color-text)` 减少细线抗锯齿稀释，外缘 halo 同上；不改 SVG 线宽 |
| 同三页，两种外观 | `[data-viewer-controls]` | `border-radius`; `box-shadow` | 保留既有 `var(--radius-control)` = `6px` 与 `var(--shadow-soft)` |
| 11 `grid-light.html?thumbnail-size=140`、12 `grid-dark.html?thumbnail-size=140`，宽 >720 | `[data-thumbnail-size="140"]`（根元素属性选择器）；`.photo-grid`；`.thumbnail-wrap` | `--thumb-min`; `height` | min track `140px`，高 `H(width) × 140 / 220`，1280 时约 `119.735px` |
| 11/12 `?thumbnail-size=220`（无参数 / 无效参数默认），宽 >720 | `:root`；同上 | 同上 | min track `220px`，高 `H(width)`，1280 时 `188.16px` |
| 11/12 `?thumbnail-size=280`，宽 >720 | `[data-thumbnail-size="280"]`（根元素属性选择器）；同上 | 同上 | min track `280px`，高 `H(width) × 280 / 220`，1280 时约 `239.476px` |
| 11/12，全三档，宽 ≤720 | `.photo-grid`；`.thumbnail-wrap` | `grid-template-columns`; `height` | min track 固定 `145px`，高 `150px`；Thumbnail Size 在这里不影响几何 |
| 11/12，全三档，宽 ≤480 | `.photo-grid`；`.thumbnail-wrap` | 同上 | 一列 `1fr`，高 `150px` |
| 11/12，全三档、两种外观 | `.photo-name`；`.grid-bottom-bar` | 文件名 / 底栏 | 名称 `nowrap/hidden/ellipsis`；底栏保持窗口底部、高 `40px`、`--color-bg` 的 `80%`、无顶线；支持组合 `?transparency=reduced` / `?scroll=behind` |

`H(width)`：默认 `clamp(135px,14.7vw,225px)`；既有 ≥1600 断点为 `200px`，≤1050 为 `165px`。宽 >720 时，网格可用宽 A、列距 G、最小列宽 size：`n=max(1,floor((A+G)/(size+G)))`，实际 cell 宽 `(A-(n-1)G)/n`。≤720 把 size 换为 145；≤480 固定 n=1。cell 的既有内边距、行距与列距仍按 media cascade。1 CSS px 对应原生设计 1 pt；浏览器小数以渲染帧为准。

`npm run design:check` / `node scripts/verify_design_catalog.js` 在真实浏览器检查两种外观、480/720/1050/1280/1600 × 140/220/280、无参数/无效参数回退、长中英名截断与底栏不随尺寸变化。Viewer 检查三页 × 两种外观 × 平白/平黑底图，以截图内控件实际合成颜色与实际 glyph/text 核心像素计算对比度（glyph ≥3:1，计数和缩放文字 ≥4.5:1），并检查 halo；这不是原生设备验收。

16 的信息面板不变；33 只更新计数文字的文字色/halo，胶片条面板、图像、导航和布局规则不变。**13/25/27 的深色以及 28/34 保留的 solid tools 仅用于各自其他状态的旧对照，tool fill 已被本表的 14/16/33 取代，#351 不得使用它们作工具填充 oracle**。尤其浅色 Inspector 应用 `viewer-inspector.html?theme=light` 对照 tool fill，不用 page34。

Swift 默认几何 oracle 仍有效：`.thumbnail-wrap` 读取 root `--thumbnail-height` → `--thumbnail-height-base`，默认只解析原 clamp/200/165（≤720 直接 150），无须解析属性变体乘法。`GridThumbnailParity281Tests` 的 1280/188.16 与各断点默认行、`GridShellTests`、`PinnedDesignTests` 的默认值保持一致；后续 #349 另断言尺寸变体。

## #443 · 初始动作焦点

Owner 于 2026-11-03 选定「Keep focus on the action (Recommended)」：设计跟随 App。24 主状态的「取消读取」与 26 `?case=volume` / `?cause=volume` 的「选择其他文件夹…」在浅深色都持有初始键盘焦点并显示既有焦点环；24F 的「重试」保持不变。只更新设计源和测试，App 行为不变；对应账簿 FOLDER-01、ACCESS-03。

| 固定输入 | SHA256 |
| --- | --- |
| `folder-loading.html` | `9531f552f4cc9fc4295315a988305671614a5ce1de7065c41425f28f4467328c` |
| `permission-denied.html`（#502 已重固定，动作焦点不变） | `e634308e79e4acf4832d799b02bfe565d4c289f1cffd7e31a23473bf9a51f8ad` |
| `manifest.json`（#443 当时的整份文件，#447 后已更新） | `3d4e8d83d8155d2688d1d3a7493c303e4563b3ced586418ab561de5d595ec6b3` |

## 维护

每页的 `sha256` 固定当前 HTML 的原始字节。修改正式状态稿后，先确认设计变更，再对该 HTML 运行 `shasum -a 256 <文件>`，将结果写入 `manifest.json` 对应条目；不要为绕过测试而重新固定哈希。`npm run design:check`（先 `npm ci --ignore-scripts` 与 `npx playwright install chromium`；可本地运行，CI 也在 `Design check` job 中运行；该 job 是 required check，owner 已在 #613 阶段 C 启用）用 `package-lock.json` 固定的 Playwright 在两个空闲端口上起预览服务，运行 `scripts/verify_design_catalog.js`：先跑 `scripts/design/*.test.mjs` 与快捷键对照，再检查 25 页的资源与布局、每页 HTML 与 `sha256` 一致、15 页没有「键盘快捷键」、35/36 的分类与卡片（逐个查询参数、浅深色、示例数值都标「示例」、35 每个分类的控件逐个列为可用或「即将推出」、36 每个可见行都有 `data-shortcut`）、22/26 的来源与 22/24/26 的子情况（24 读取失败：「重试」持有焦点、没有部分网格或计数、子情况样式只用设计 token）（含收起的子文件夹、PENDING(P3-14) 标注，以及说明文字没有只剩一两个字的行：字距在 −1…+1 px 之间逐档检查，结果不随机器字体变化），以及 `journeys.html` 的入口表、只播放主路径、每条支线结果播到正确的目的页、没有手写进度徽章、不引用原型文件和播放器焦点（含点过预览之后的 Esc 与 Tab）。端口可用 `PICSEE_DESIGN_PORT`、`PICSEE_STATES_PORT` 指定。

画网格底栏的 11 页（11、12、15、22、23、24、26、29、30、31、32）共用同一段 `<style data-bottom-bar>`：底栏绝对定位在窗口底部，网格滚动区和侧栏伸到它后面，底部留白加上底栏的 40px，内容仍能完整滚出底栏。#317 的检查从两张参考稿读取期望值，比较 21 的图片墙和拖入状态（21 的中央不与参考稿比较，按 B4 中央检查：提示、按钮、间距 18、没有格式标签行，#441）、每个底栏页的填充、分隔线、左侧竖线和滚动区；显示大图命令栏的页面原先固定为 #317 之前的 `sha256`（用户：「不改，只改网格底栏」）；#347 按用户确认的磨砂工具组设计更新 14/16/33 三项 pin；#447 再更新 13/25/27 三项 pin，加入浅色对照并保留原深色外观，其他大图页的 pin 保持不变。

以 [主设计规范](../../../DESIGN.md)、[组件与原生映射](../../../picsee-ui-system/native/README.md) 和 [实施计划](../../../../docs/PICSEE_DEVELOPMENT_PLAN.md) 为依据。浏览器交互仍在 [viewer-v2.html](../viewer-v2.html)，完整状态稿不等于原生实现。

`.stitch/` 仅为本地捕获/生成/迁移工作目录，整体忽略。当前机器可保留 `.stitch/deliverables` 指向本目录的兼容链接；仓库和预览均不依赖这个链接。截图与运行检查输出属于 `evidence/`，无需复制到每份稿旁边。

## #540 · Viewer Tools 不透明度变体

14/16/33 的 `?theme=light|dark&tool-opacity=30|50|100`、默认回退和 #351 应固定的 selector / computed-style 值统一维护在 [UI 对照契约 §#540](../../../../docs/agents/ui-parity-contract.md#540--viewer-tools-不透明度变体351-固定输入)。

## #502 · 所有侧栏状态保留添加控件

Owner 于 2026-11-04 选择「Re-pin the design (Recommended)」：第 22 页（含 `?case=no-subfolders`）与第 26 页的各分支保留「文件夹」标题的 `+` 和虚线「添加文件夹」按钮，与第 11、24 页复用相同标记和 CSS。控件位于侧栏，独立于替换子状态的文件夹树；内容区几何、#518 最近列表滚动规则和既有动作焦点不变。此重固定对齐既有 App，未增加原生功能。
