# picsee C 设计状态稿

这里是应随仓库提交的 **22份正式静态状态稿**，与上一级的交互原型分开维护。目录内容不依赖 `.stitch/`、登录凭据、Stitch CLI 或远程图片。

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
| 22个同名HTML | 正式静态状态；不声明按钮行为已实现 | 是 |
| `journeys.html` | 用户旅程图，是[计划 §1.6](../../../../docs/PICSEE_DEVELOPMENT_PLAN.md)旅程索引的视图（ADR-013），两者不一致时以 §1.6 为准；卡片只引用本目录的状态稿，不显示实现进度（进度看功能账簿）。不是状态稿，不进 `manifest.json`，由 `index.html` 链接 | 是 |
| `home-image-wall.html` | 首页图片墙参考稿，图片墙外观的来源：2026-10-30 用户在三个方向中选定 C（斜置拼贴、缓慢漂移）并要求放大（「选C，但是图片墙可以放大」），之后定为「C 取代 B4 外观，保留拖入反馈」（[grilling 记录](../../../../docs/plans/20261030-bottom-bar-home-wall-grilling.md)，spec #311）。正式状态是 21 `first-launch.html`（#317），`design:check` 从本页读取倾斜、透明度、圆角、阴影、漂移和居中按钮的期望值。`?theme=dark` 看深色。**不是状态稿，不进 `manifest.json`**；App 对照 21，不对照本页。原型在分支 `prototype/footer-transparent` | 是 |
| `grid-footer-fill.html` | 打开文件夹后的常驻底栏参考稿，80% 底栏外观的来源：2026-10-30 用户选定「填充 80%（很实）」、不要顶部分隔线（「不要，靠 80% 底色区分」），只有未打开文件夹的窗口没有底栏（「只有未打开文件夹的窗口没有底栏」），spec #311。正式状态是 11/12 和其他画网格底栏的页面（#317），`design:check` 从本页读取填充、分隔线和左侧竖线的期望值。`?theme=dark` 看深色。**不是状态稿，不进 `manifest.json`**；App 对照这些正式页，不对照本页。原型在分支 `prototype/footer-transparent` | 是 |
| `assets/images/`、`assets/manifest.json` | 13个按内容哈希命名的共享图片，替代95处重复base64 | 是 |
| `_ds/` | 设计系统编译后的运行时副本，由import工具同步 | 是，保证预览可直接运行 |
| `vendor/` | 固定版本React预览依赖；不是原生App依赖 | 是 |
| `provenance/stitch.json` | 原始Stitch screen IDs与打包前后哈希，不含凭据或签名下载URL | 是 |
| `_d_meta.json` | 设计系统绑定与资产索引 | 是 |

图片来源及摄影师链接见 [ASSETS.md](../ASSETS.md)。状态稿使用既有示例图及其缩略版；提取时保持原始图片字节，未改变构图。原型文件名、日期等演示信息不代表真实EXIF。

## 页内子情况

22、24、26 三页按 [ADR-014](../../../../docs/adr/0014-recoverable-folder-states-in-window.md) 把子情况放在同一页里，35、36 两页（#214，spec #212）和 21、11、12 三页（#317，spec #311）同样如此；用查询参数切换，不带参数的地址就是主状态，`sha256` 固定的也是它的字节。按钮没有行为。

| 页面 | 不带参数 | 子情况 |
| --- | --- | --- |
| `empty-folder.html`（22-BD） | 这一层有子文件夹：子文件夹卡片、「包含子文件夹浏览」「选择其他文件夹…」，内容区可拖入 | `?case=no-subfolders` 最近打开的文件夹；`?drag=over` 拖入时的提示 |
| `permission-denied.html`（26-BC） | 授权失效：侧栏该文件夹变灰带 ⚠、子文件夹收起（› 与 `aria-expanded="false"`）；「重新选择文件夹…」「选择其他文件夹…」。侧栏「个人收藏」「最近查看」两行和「侧栏里的收藏和最近查看不受影响。」标为 **PENDING(P3-14)**：它们随 P3-14（J4）落地，P2-08c 验收不含（ADR-014） | `?cause=volume` 外接磁盘未连接；`?cause=missing` 找不到；`?cause=unknown` 原因分不清时的「无法访问此文件夹」；`?case=moved` 26M-C 同卷移动或改名后跟随，网格上方的提示条（不是权限失败）。各子情况同样带 PENDING(P3-14) 标注 |
| `folder-loading.html`（24） | 正在读取：进度、「取消读取」 | `?case=failed` 读取失败 · 24F-A（#236 用户选定）：读取中途停止、授权根仍可读时，内容区居中写「没能读完“待整理”」和一句说明，「重试」为主按钮并持有键盘焦点，另有「选择其他文件夹…」；不显示部分网格，侧栏该文件夹与底栏都不显示部分计数，底栏写「读取未完成」。授权根不可读属于 26 |
| `settings.html`（35 设置 · B） | 设置窗口，左侧边栏（用户：「选B」）选中「通用」：外观、始终显示大图工具、语言说明。缓存大小、版本与构建号、上次检查时间都是示例，旁边标「示例」。App 还没有的控件置灰、不可聚焦并标「即将推出」（用户：「显示但置灰」）：「显示」三项（PREF-03）、「更新」的自动检查与立即检查（DIST-05）、「关于」的三个链接 | `?section=general\|display\|cache\|update\|about` 选中对应分类；「显示」与 15 页面板是同一组偏好 |
| `shortcuts.html`（36 键盘快捷键 · C） | 帮助 → 键盘快捷键打开的只读窗口（用户：「选 C」），三张卡片：文件与窗口（任何时候）、网格（浏览文件夹时）、大图（查看一张图片时）；没有搜索 | `?card=files\|grid\|viewer` 给该卡片加虚线描边，只用于对照，App 没有这个状态 |
| `first-launch.html`（21 首次打开） | 首页：没有底栏和侧栏，图片墙在「选择文件夹」和拖入提示后面缓慢漂移，「减弱动态效果」时不动 | `?drag=over` 拖入时：图片墙淡到 40%，拖入提示和虚线框用强调色；`?theme=dark` 深色 |
| `grid-light.html`、`grid-dark.html`（11/12 网格） | 底栏盖在网格上，窗口底色 80%，没有顶部分隔线 | `?scroll=behind` 多两行图片并把一行滚到底栏后面；`?transparency=reduced` 「减弱透明度」时底栏 100% |

22、24、26、35、36、21 都接受 `?theme=dark`；11/12 各是一种外观。35、36 由分支 `prototype/shortcuts-sheet` 上的 `prototype-settings.html?variant=B`、`prototype-shortcuts.html?variant=C` 定稿而来，原型文件不进本目录。15 页面板里的「键盘快捷键」入口已去掉（用户：「Page 15 中去掉快捷键入口」）。

`shortcuts.html` 每一行的 `data-shortcut` 写它对应的命令（`command:<CommandID>`、`menu:<菜单标题>` 或 `key:<按键处理>`，多个用 `|` 分隔）。`scripts/design/shortcut-model.mjs` 从 `CommandID.swift`、`App/Commands/CommandMenu.swift`、`ChromeWindowCommands.swift` 读出菜单快捷键，与页面逐行比较：页面上每个 `<li>` 都算一行，没有 `data-shortcut` 的行、行外的按键、多一行、少一行或按键不同都失败。`App/` 与 `Packages/PicseeKit/Sources` 里每处 `keyDown` 的 `case`、`keyCode ==` 和 `.onKeyPress` 处理的按键，都要在该脚本的 `KEY_SITES` 里登记为页面上的某一行或写明不列入的理由（如聚焦控件内的 Tab/Space/Return、侧栏分隔条的方向键）；新增未登记的按键或登记的按键消失都失败。不比较：`keyDown` 里的修饰键变体（网格里 ⇧/⌘ 加方向键），以及同一文件里同一按键的第二处处理。编辑菜单的撤销、剪切、拷贝、粘贴、全选只作用于搜索框，不列入。

## #347 · Viewer Tools 与 Thumbnail Size 对照映射

这组变体仅由 11/12/14/16/33 加载 `viewer-grid-variants.css`，值来自 `_ds/picsee-ui-system/tokens/viewer-grid.css`；其他状态不加载它。14/16/33 的默认外观仍是深色。`?theme=light|dark` 只切换外观，不改变布局；16 的图片信息面板、33 的胶片条保持现有规则。33 的前后翻图在胶片条里，没有独立 navigation pod。

| 页面 / URL | Selector | Property | Value |
| --- | --- | --- | --- |
| 14 `viewer-controls.html?theme=light`、16 `viewer-inspector.html?theme=light`、33 `viewer-filmstrip.html?theme=light` | `.viewer-floating-controls > [data-viewer-controls]`（14/16：`leading`、`navigation`、`zoom`；33：`leading`、`zoom`） | `background-color`; `backdrop-filter` / `-webkit-backdrop-filter` | `color-mix(in srgb, var(--color-panel) var(--tool-background-opacity), transparent)`；`--color-panel: #fff`、`--tool-background-opacity: 50%`；`blur(20px) saturate(1.6)`（`--tool-background-blur` / `--tool-background-saturation`） |
| 同三页 `?theme=dark`（也为无参数默认） | 同上 | 同上 | 同上，`--color-panel: #141821`；仍为 `50%`、`blur(20px) saturate(1.6)` |
| 14/16/33，浅 / 深 | 同上；后代 `.ds-icon-button` 与 `svg` | `border-radius`; `box-shadow`; `color`; `filter` | 保留 `var(--radius-control)` = `6px` 与 `var(--shadow-soft)`；图标改用 `var(--color-text)`（浅 `#1a1a1a` / 深 `#e5e7eb`），`drop-shadow(var(--tool-icon-halo))` = `0 0 1px var(--color-panel)` 边缘衬底，便于在明暗图像上辨认 |
| 11 `grid-light.html?thumbnail-size=140`、12 `grid-dark.html?thumbnail-size=140` | `.photo-grid`; `.thumbnail-wrap` | `--thumb-min`; `height` | `var(--thumbnail-size-min)` = `140px`；`calc(var(--thumb-min) * var(--thumbnail-height-ratio))` = `100.8px` |
| 11/12 `?thumbnail-size=220`（也为无参数 / 无效参数默认） | 同上 | 同上 | `var(--thumbnail-size-default)` = `220px`；高 `158.4px` |
| 11/12 `?thumbnail-size=280` | 同上 | 同上 | `var(--thumbnail-size-max)` = `280px`；高 `201.6px` |
| 11/12，三档尺寸与两种外观 | `.photo-grid`; `.photo-name` | `grid-template-columns`; `white-space`; `overflow`; `text-overflow` | `repeat(auto-fill, minmax(min(var(--thumb-min), 100%), 1fr))`；`nowrap` / `hidden` / `ellipsis`（既有名称规则） |
| 11/12，三档尺寸与两种外观 | `.grid-bottom-bar` | 位置 / 高 / 填充 / 顶线 | 保持既有 `data-bottom-bar`：窗口底部、高 `40px`、`--color-bg` 的 `80%`、无顶线；`?transparency=reduced` 与 `?scroll=behind` 可与尺寸参数组合 |

沿用选定原型的列规则：Thumbnail Size 是列的**最小宽度**，列均分余宽；网格可用宽 `A`、列距 `G` 时，列数 `n = max(1, floor((A + G) / (size + G)))`，实际 cell 宽 `(A - (n - 1)G) / n`。缩略图框高为 size × `.72`，cell 与框之间的既有内边距不变。预览中 1 CSS px 对应原生设计的 1 pt；原生实现应断言推导出的实际 frame，不能把最小列宽当作固定 cell 宽。

`npm run design:check` 在真实浏览器中检查上述值、全部现有工具组、浅深外观、明暗极端底图、三档实际 frame、长中英名称截断和 Bottom Bar 不随尺寸改变。它也检查无参数与错误参数回到 220。测试临时换长名称与明暗底图，不改变静态素材或演示文件名。

## 维护

每页的 `sha256` 固定当前 HTML 的原始字节。修改正式状态稿后，先确认设计变更，再对该 HTML 运行 `shasum -a 256 <文件>`，将结果写入 `manifest.json` 对应条目；不要为绕过测试而重新固定哈希。`npm run design:check`（先 `npm ci --ignore-scripts` 与 `npx playwright install chromium`；可本地运行，CI 也在 `Design check` job 中运行）用 `package-lock.json` 固定的 Playwright 在两个空闲端口上起预览服务，运行 `scripts/verify_design_catalog.js`：先跑 `scripts/design/*.test.mjs` 与快捷键对照，再检查 22 页的资源与布局、每页 HTML 与 `sha256` 一致、15 页没有「键盘快捷键」、35/36 的分类与卡片（逐个查询参数、浅深色、示例数值都标「示例」、35 每个分类的控件逐个列为可用或「即将推出」、36 每个可见行都有 `data-shortcut`）、22/26 的来源与 22/24/26 的子情况（24 读取失败：「重试」持有焦点、没有部分网格或计数、子情况样式只用设计 token）（含收起的子文件夹、PENDING(P3-14) 标注，以及说明文字没有只剩一两个字的行：字距在 −1…+1 px 之间逐档检查，结果不随机器字体变化），以及 `journeys.html` 的入口表、只播放主路径、每条支线结果播到正确的目的页、没有手写进度徽章、不引用原型文件和播放器焦点（含点过预览之后的 Esc 与 Tab）。端口可用 `PICSEE_DESIGN_PORT`、`PICSEE_STATES_PORT` 指定。

画网格底栏的 11 页（11、12、15、22、23、24、26、29、30、31、32）共用同一段 `<style data-bottom-bar>`：底栏绝对定位在窗口底部，网格滚动区和侧栏伸到它后面，底部留白加上底栏的 40px，内容仍能完整滚出底栏。#317 的检查从两张参考稿读取期望值，比较 21 的图片墙和拖入状态、每个底栏页的填充、分隔线、左侧竖线和滚动区；显示大图命令栏的页面原先固定为 #317 之前的 `sha256`（用户：「不改，只改网格底栏」）；#347 按用户确认的磨砂工具组设计更新 14/16/33 三项 pin，其他大图页的 pin 保持不变。

以 [主设计规范](../../../DESIGN.md)、[组件与原生映射](../../../picsee-ui-system/native/README.md) 和 [实施计划](../../../../docs/PICSEE_DEVELOPMENT_PLAN.md) 为依据。浏览器交互仍在 [viewer-v2.html](../viewer-v2.html)，完整状态稿不等于原生实现。

`.stitch/` 仅为本地捕获/生成/迁移工作目录，整体忽略。当前机器可保留 `.stitch/deliverables` 指向本目录的兼容链接；仓库和预览均不依赖这个链接。截图与运行检查输出属于 `evidence/`，无需复制到每份稿旁边。
