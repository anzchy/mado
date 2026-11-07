# 功能账簿

**picsee** · 首次建账 2026-10-21 · 分支 `main` · 依据 [分阶段开发计划 v0.2](./PICSEE_DEVELOPMENT_PLAN.md)

这份账簿只回答一件事：**picsee 原生 App 现在实际有什么**。每一项能力占一行，写明状态、代码位置，以及在运行中的 App 里怎么确认。

建账时还没有任何 Swift 源文件，所以每一行都是 `Absent`。这些行是**先写好的验收**：「怎么确认」现在就写成将来要做的操作，实现之后只改状态、验证、位置三格，验收不跟着实现降低（见「防止验收被悄悄放宽」）。

它不是 changelog、计划或 ADR。什么时候变的看 git 历史和 `CHANGELOG.md`；先后顺序与验收门槛看 `docs/PICSEE_DEVELOPMENT_PLAN.md`；为什么这样做看 `docs/adr/`；实测数据和过程记录看 `docs/validation/P*.md`。

浏览器原型 `design/prototypes/` 和 `design/prototypes/picsee-browser/states/` 里的 mockup **不算** picsee 的能力。它们是设计输入，在本账簿里不能把任何一行推到 `Absent` 以外。

## 状态

状态只能是下面五个词之一，枚举是封闭的：

| 状态 | 含义 |
|---|---|
| `Shipped` | 已实现，并在真机运行的 App 里按「怎么确认」验证通过 |
| `Partial` | 能用，**但有一条写明的限制** |
| `Stub` | 类型、接口或 UI 已存在，行为还没有 |
| `Absent` | 还没做 |
| `Unknown` | 依赖系统或第三方提供、在 picsee 里从未测过，不做任何声称 |

- `Shipped（仅 JPEG）` 这类写法算错。细节写进「怎么确认」。
- `Partial` 必须在「怎么确认」里写一条 `限制：`，说明限制是什么。
- 写着 `Stub` 的能力，对外不能说 picsee「有」。
- **功能开关后面的能力**：代码已合入但默认关闭（编译开关、隐藏设置），记 `Stub`，并在「怎么确认」里写明开关名。开关打开并通过真机验证后才能改 `Shipped`，同一次提交删掉开关或写明保留理由。

## 验证

「验证」一格记录**最强的一次证据**，也是封闭枚举：

| 验证 | 含义 | 对应 NASA 验证方法 |
|---|---|---|
| `无` | 没有证据 | — |
| `单元` | 自动化测试覆盖了逻辑，没有经过 App 界面 | Test（部分） |
| `集成` | 在 App 进程或 UI 测试里跑通，但不是人在真机上操作 | Test |
| `真机` | 按「怎么确认」在真实 Mac 上操作通过，`docs/validation/` 有记录 | Demonstration |

- `Shipped` 要求验证为 `真机`，且「怎么确认」里链接对应的 `docs/validation/` 记录。只有单元或集成证据的能力最多记 `Partial`，限制写「真机未验」。
- 涉及显示的行（1:1、缩放、Retina）要在 1× 和 2× 两种屏幕上都验证过，才算 `真机`。
- 性能类的行，数字写进 `docs/validation/`，本账簿只链接，不抄数字。
- **每个入口都要验。** 「怎么确认」用“或”“/”“、”列出的每个入口（按键、手势、菜单、按钮、拖入）和每个取值（如“JPEG 或 PNG”）都是验收的一部分，要分别验证。只验了一部分，最多记 `Partial`，`限制：` 写明没验的入口。没验的入口不能借另一个入口的结果算通过（例：VIEW-03 只按了 +/−、没试触控板捏合，就不是 `真机`）。
- **保存和写出要第二次独立确认。** 写着“保留”“退出重开”“记住”的行，要退出 App 再打开，在 App 里看到结果；写文件的行（导出、另存、去除元数据），要读文件本身确认（如 `mdls`、`exiftool`、`shasum`），不以 App 的成功提示为准；写着“释放”的行，以日志为准，不以窗口关了为准。
- `真机` 的记录按 `.agents/skills/macos-device-test/features/` 里该行的运行步骤做；还没有步骤的行，先写步骤再验证。

## 怎么写各列

| 列 | 写法 |
|---|---|
| ID | `区域-两位序号`，如 `VIEW-03`。一经分配不改、不复用；删掉的能力移到「不做」并保留 ID。brief、测试名、validation 记录都用这个 ID 引用 |
| 能力 | 用户能感知到的一件事，一行一件 |
| 计划 | 开发计划的工作包 ID，可多个，用 `、` 分隔。它说明这条需求从哪来；没有工作包的能力先补进计划再进账簿 |
| 在哪 | 路径从仓库根写起，放在反引号里，如 `Sources/PicseeViewer/ViewerSession.swift`。不写行号、不写计数、不写构建产物（`.build/`、`DerivedData/`）。`Absent` 写 `—` |
| 怎么确认 | 一个在 App 里能做的操作和应看到的结果，不是“看代码”。列出几个入口，就是几个都要验（见「验证」）。**验收部分（「限制：」之前）不超过三句、约 150 字**；「限制：」之后的文字不计入这个长度，但每一句都要是事实（未验的入口、仅单元的范围、待哪个工作包）。过程、截图、日志与历史写进 `docs/validation/`，这里只放链接 |

最后一条是从 mdpro 吸取的教训：mdpro 账簿的单元格逐渐长成上千字的修复史，没人能对着 App 一行行走下去。

## 防止验收被悄悄放宽

这一条参考 Anthropic 长时运行 agent 的 feature list 做法：功能列表一开始全部标为未通过，agent 只能改“是否通过”这一项，删改测试步骤被明确禁止，并且必须像真实用户那样端到端验证后才能标为通过。

- **状态升级的那次提交，可以追加或修改「限制：」文本，但不得改写「怎么确认」中的验收本身。确需改验收时，单独提交并在提交说明里引用用户原话或 ADR。**
- 升级状态的人不能是唯一的验证者：`Shipped` 的真机记录由真机测试角色（`claude-imple-1`）写，实现者不能自己给自己出记录。验证记录单独提交，带 `Validated-by: <角色> run=<运行 ID>` trailer；实现提交带 `Implemented-by: <角色>`。所有提交可能是同一个 git 作者，gardener 靠这两个 trailer 区分角色。
- 一行从 `Shipped` 退回 `Partial` 或更低，在同一次提交里写明原因，不删除原记录。
- 不能用删掉「怎么确认」里某个入口的办法让一行升级：删入口算改验收，同样要单独提交并引用用户原话或 ADR。

## 维护

- **改变用户可见行为的那次提交，同时改它的那一行。** 不留到之后的清理提交。新能力、状态变化、发现某条声称是假的，都在当次提交里改。参考 Google SRE 的定义，凡是用户看得见的变化都算发布，都要有对应的行。
- 新增的命令 ID、菜单项、偏好键、entitlement、声明的 UTType，必须出现在描述它的那一行，不能挂在无关的行上凑数（见「门禁」）。
- **区域审查**：每个区域在下面的审查表里有最近一次审查的日期和审查人。超过 30 天未审查、且这期间该区域有代码改动的，下一次合入前先审查（相当于 OpenAI 的 doc-gardening，定期清理过时文档）。
- 一次审查只写日期、审查人和范围 `<base7>..<head7>`；发现写进 gardener 报告和 PR 描述，不写进账簿（#324）。

## 门禁

`npm run ledger:check` 的五条规则门禁仍在计划中。实现后，它会作为 CI 和合入前检查的一项，检查：

1. 状态、验证两格都在枚举里；`Partial` 有 `限制：`；`Shipped` 的验证是 `真机` 且链接了 `docs/validation/`；
2. ID 不重复；计划一格的工作包 ID 在开发计划里存在；
3. 每个路径都能解析到文件；没有行号、计数和构建产物路径；`Absent` 的位置是 `—`；
4. App 声明的每个名字都出现在某一行：CommandRouter 的命令 ID、菜单项 identifier、`DisplayPreferences` 的键、entitlements、`Info.plist` 声明的 UTType；
5. 同一次提交里，某行状态升级的同时改写了「怎么确认」中的验收本身，报出来交给审查；只追加或修改「限制：」文本不报。

它**不能**判断一句话是不是真的：路径存在不代表那条行为还在。这需要真机复验和区域审查来补。

在 `ledger:check` 实现之前，合入审查时按上面五条人工核对。

`docs/feature-ledger.html` 是本文件的渲染视图，可按状态、阶段筛选和搜索，**由本文件生成，不要手改**。
每次提交改动本文件时，都在同一个提交里运行 `npm run ledger:build` 并提交生成的 HTML；CI 运行
`npm run ledger:html-check`，拒绝过时的 HTML。`ledger:check` 仍是迁移计划 A12 的后续工作。

## 发布门槛怎么读

不单独维护一份发布清单，直接按「计划」一列筛选：

- **v0.0.1（J1+J2 对外版，计划 §5 v0.5）**：计划 §1.6 中 J1、J2 两行列出的账簿行，加 DIST-01/02/03，全部是 `Shipped`，或 `Partial` 且限制已被用户接受（引用原话）；
- **v0.0.2**：计划为 P0–P3 的行，同样要求（原 v0.0.1 门槛，2026-10-28 移来）；
- **首发 v1**：计划为 P0–P6 的行，同样要求；格式类的行未达标时，从对外支持声明里删掉，而不是保留一个 `Partial`。

---

## Part 1 — picsee 现在有什么

### 打开与输入

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| OPEN-01 | 首次打开空态 | Partial | 单元 | P1-02、P1-07 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageStatus.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/`、`App/CanvasWindowController.swift` | 冷启动、没有打开过文件夹：显示 21 页空态，有“选择文件夹”按钮和拖入提示；没有底栏和侧栏（打开文件夹后才出现）；首页也不显示查看器浮动控件。⌘O 可选单张图片或文件夹。限制：首页隐藏查看器浮动控件（#331）仅单元与 App 测试，rc.2 签名 21 页浅深对照通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)，zh-Hans）；#315 起 21 页空态的外观为图片墙（图片墙的漂移与暂停见 OPEN-08）；图片墙、中央操作与尺寸规则的签名 @1x 对照通过（J1）；搜索/排序/显示待 P3；⌘O 与打开路径沿用既有实现；B4 之前的 21 页空态 @1x 记录（[P1-07](validation/P1.md#p1-07空态加载失败取消菜单焦点与中英文本)、[#92](validation/P1.md#p1-08c-沉浸工具与窗口-chrome)）不覆盖图片墙外观；加载、读取、无结果与较低细节状态的新布局仅单元；真冷启动、首页 ⌘O 选单张图片、加载/取消未验。 #499：首页主按钮显式使用 on-accent 白字；英文真实按钮在浅色→深色→浅色的像素与尺寸不变仅单元；中文主按钮浅深色白字 rc.2 @1x 真机通过（J1）。 |
| OPEN-02 | 打开面板 | Partial | 无 | P0-09、P1-02 | `App/PicseeApp.swift`、`App/Commands/CommandMenu.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift` | ⌘O 选一张图时画布显示该图，选一个目录时进入该目录网格；在面板里取消，当前状态不变。限制：⌘O 与面板重连路径在 Access Root 内选图会启动所在目录扫描，仅单元（P2-08）；⌘O 选目录进网格 rc.2 @1x 真机通过（[正式测量](validation/P3.md#运行-perf146rc2-20261104-2055v001-rc2-正式测量mac-mini-1x)，经 AX 写入面板路径；[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239) 经首页按钮）；rc 记录中面板取消未记录；File › Open…、⌘O 选图、取消与不支持文件的提示已 @1x 真机通过（[记录](validation/P1.md#p1-02finder打开面板拖入与输入失败)）；底部 Open… 按钮仅单元；首页不显示底部 Open… 按钮，⌘O 与首页“选择文件夹…”不受影响（#331）。 #507：面板交来的符号链接目录在原选择权限内解析目标后创建书签；原始 URL 的首次标题保留所选名称；最近记录按规范目标写入，显示目标文件夹名；面板已解析的 URL 沿用目标名。仅自动测试，签名真机待复验。 |
| OPEN-03 | 从 Finder 打开 | Partial | 单元 | P1-02、P2-08 | `App/Info.plist`、`App/PicseeApp.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Input/`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift` | 在 Finder 对一张 JPEG 用“打开方式 → picsee”，App 启动并显示该图。限制：Finder 打开方式与双击未验（rank `Alternate`）；`open -a` 多文件集合、←/→ 不回绕、未授权单图 Esc 无变化 @1x 通过（[记录](validation/P1.md#p1-02finder打开面板拖入与输入失败)）；授权目录内单图 Esc 回网格仅单元（P3-01）。 P2-08 在 Access Root 内打开图片（Finder、拖入或 ⌘O）也启动所在目录扫描；既有 @1x ←/→ 与不回绕验证早于此接线，尚未复验。 #507：单个文件夹（普通或经符号链接）的打开事件按实际目录类型判定，与普通文件夹一样先弹出文件夹授权面板并预选规范目标；面板授权前不建 Access Root、不写最近记录；与拖入共用的 openInput 路径有 App 集成测试（面板应答为测试替身），真实 Finder/Open With 交付待签名复验。 |
| OPEN-04 | 拖入打开 | Partial | 单元 | P1-02 | `Packages/PicseeKit/Sources/PicseeApplication/Input/`、`Packages/PicseeKit/Sources/PicseeMacUI/Input/`、`App/CanvasWindowController.swift` | 从 Finder 拖一张图进窗口，显示该图；拖入不支持的文件给出明确提示，当前图不变。限制：首页拖入高亮、图片墙淡到 40%（开启「降低透明度」时拖入期间图片墙隐藏）仅单元；拖入 Access Root 内的图片会启动所在目录扫描，仅单元（P2-08）；#73 修复后 @1x 合成拖入通过：未打开过的图片、ZIP、文件夹与多文件夹提示、多图成集合（[记录](validation/P1.md#p1-02finder打开面板拖入与输入失败)）；拖入文件夹现进网格，仅单元（P3-01）；真实鼠标与签名 App 未验。 #507：拖入单个文件夹（普通或经符号链接）不依赖 URL 的目录尾标记，按实际目录类型判定后走与普通文件夹相同的文件夹授权面板，预选规范目标；取消面板不留授权、最近记录或书签；App 集成测试中面板应答为测试替身，真实鼠标拖入与签名沙盒待复验。 |
| OPEN-05 | 无法读取的图片 | Partial | 单元 | P1-07、P2-03 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageStatus.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerRetryIntent.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/`、`App/CanvasWindowController.swift` | 打开截断的 JPEG：显示 25 页错误态，有“重试”和“下一张”；底部工具仍可用，可经网格按钮或 Esc 返回；不会显示上一张图。限制：网格/Esc 仅单元（P3-01）；@1x 三类错误/重试（截断 PNG）与构图/窄窗通过（[P1](validation/P1.md#p1-07空态加载失败取消菜单焦点与中英文本)、[#92](validation/P1.md#p1-08c-沉浸工具与窗口-chrome)）；JPEG/加载中未验；过滤后下一张与扫描中重试仅单元，原生组合未验；错误图标按 25 页 SVG 绘制为空心模板（32 pt、viewBox 24、描边 1.3，muted），标题完整显示、窄窗换行；文件名与原因合并为一行 muted 文本，仅文件名中间省略、原因完整保留（窄窗必要时换行），全文见 tooltip 与 AX；重试为主按钮、下一张为文本按钮；rc.2 @1x 真机已见 25 页构图与「重试」「下一张」（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)）；25 页浅深对照 FAIL (APP)：实心错误图标 → #530（v0.0.2）；适应窗口工具禁用为既定行为，用户 2026-11-06 选择「保持禁用，改设计稿 (Recommended)」，设计稿已改（#539）（[J2 rc.3](validation/P3.md#j2-rc-acceptance-delta-on-v001-rc3-240)）；截断 JPEG、网格/Esc 返回、加载完成后的取消未记录。#538：禁用的缩放标签只应用一次 0.4 不透明度；浅深离屏/窗口宿主像素、启用态回归与禁用激活仅单元，签名真机未验。 |
| OPEN-06 | 最近打开 | Partial | 单元 | P2-08、P2-09、P3-14 | `Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/RecentFolderStore.swift`、`App/Access/AccessMenus.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessRecovery.swift` | 打开一个目录后退出重开，最近列表里有它；授权失效时显示重新授权入口；不保存图片副本。限制：重启后浏览、随改名更新、运行中目录消失后第一次 Open Recent 即提示重连 @1x 通过（[记录](validation/P2.md#p2-01授权根存储重连与租约)，早于 P2-07 监听，未复验）；目录在卷上找不到时现显示页 26「找不到」与「在新位置选择…」，重绑后最近项按记录时根位置映射到新位置（#231，自动测试；签名构建冒烟见 PR，未写入 docs/validation）；窗口内正在看的目录不存在时，刷新失败先查授权根：授权根失址直接进入页 26，不先显示失败与重试（#238），授权根仍可读则显示「读取失败」与重试，仅单元；签名真机未验；最近目录重开现进网格，仅单元（P3-01）；仅文件夹、最多 10 项；不保存图片副本未验；损坏库降级仅单元。有多文件预览集合时从最近列表或已授权目录进入，集合要到进入目录浏览时才结束；转入重连提示或出错时集合保留，←/→ 仍在集合内移动，按代码推断，无测试（#150）。带 schemaVersion 的新存储格式（#216）的重启保留仅单元，现有真机重启记录早于该格式。 #507：经符号链接的文件夹只在文件夹面板授权后进入最近记录，按规范目标写入并显示目标文件夹名，以真实目录去重；从最近记录重开时跟随书签目标。仅自动测试，签名真机待复验。 |
| OPEN-07 | 从剪贴板打开 | Absent | 无 | P4-02 | — | 截图到剪贴板后选“从剪贴板打开”，新窗口显示该图 |
| OPEN-08 | 首页图片墙 | Partial | 单元 | P3-16 | `Packages/PicseeKit/Sources/PicseeMacUI/States/FirstLaunchView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/FirstLaunchLayout.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/FirstLaunchDrift.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/B4Samples/`、`Packages/PicseeKit/Sources/PicseeMacUI/Input/ViewerDropView.swift` | 没打开文件夹的窗口（首页）：内容区铺满倾斜的图片墙，只用内置的六张样图，不读用户磁盘；倾斜、列、交错与不透明度在浅色、深色下与 21 页一致；中央可“选择文件夹…”或拖入；拖入可打开的文件夹时图片墙淡出、拖入提示高亮，松开即打开；不能打开的拖入不变化，取消后恢复；图片墙不进辅助功能、不拦截拖入。 限制：图片墙几何、浅深色、拖入与辅助设置仅单元；开启「降低透明度」时拖入期间图片墙隐藏（不透明度 0），开启「减弱动态效果」时拖入即时变化、不淡化；图片墙按 21 页缓慢上下往返漂移（#316），只在窗口可见（未最小化、未隐藏、未被完全遮挡）且 picsee 在前台、未开「减弱动态效果」时运行，切到后台、最小化、隐藏或被遮挡时停在原位，回来后从同一位置继续；开启「减弱动态效果」时立即停在原位，关闭后在其余条件满足时继续；离开首页即停止并移除动画；漂移的速度、幅度、暂停/继续与这些触发仅单元（窗口可见与前台由注入的读取器驱动；切后台、最小化的真机行为未记入 docs/validation，遮挡未在真机验证，也未测 CPU/GPU）；首页隐藏查看器浮动控件（#331，见 OPEN-01，仅单元与 App 测试）；签名真机、VoiceOver 实走、@2x 与 21 页视觉对照未验。 |

### 查看与画布

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| VIEW-01 | 适应窗口 | Partial | 单元 | P1-03 | `Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasPlacement.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridViewerPresentation.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Components/DesignComponents.swift` | 分别打开横图和竖图，都完整居中显示；拖动改窗口大小，图随之适应。限制：不超过 1× 适应、1× 时对齐 backing 网格；0 键、View › Fit 与改窗口后重新适应 @1x 真机通过（[记录](validation/P1.md#运行-20261023-114600-view-01-04-05-minip1-0337mac-mini-1x)）；显式重开回到 fit；Inspector 打开时，窗口宽于 720 pt 的 viewer 画布变窄，此时按画布区域 fit 仅单元、真机未验；P1-08 的全尺寸内容窗口（适应区含标题栏条带）与比例指示器入口真机未验；比例指示器改为无静态填充/边框的 12 pt 系统 sans 主文字色、hover 才填充，适应/1:1/自定义百分比内容仅有渲染与布局单元（#364），真机未验；@2x 未验；⌘9（新显示在 View › Fit 上的快捷键）与该菜单项走同一 fit 命令，裸 0 不变，仅单元与 App 测试（#348），真机未验。#444：缩放模式控件打开「适应窗口 / 1:1 · 100%」菜单，选「适应窗口」走同一 fit 命令；查看器侧栏显隐改变画布宽度后保持适应并按新画布重算，仅单元与 App 测试，真实菜单弹出与真机未验。 |
| VIEW-02 | 实际像素 1:1 | Partial | 真机 | P0-03、P1-03 | `Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasTransform.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 按 1，在 2× 屏上一个图像像素对应一个物理像素；窗口拖到 1× 外接屏后仍是 1:1（27 页）。限制：P0-03 的 `1` 键在 [@2x](validation/P0.md#p0-03画布真机验收7view-02--view-03)、[@1x](validation/P0.md#p0-03画布真机验收-1x7view-02--view-03mac-mini) 已验；缩放模式菜单「1:1 · 100%」rc.2 @1x（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)）与 rc.3 @2x 真实 backing 像素（[@2x](validation/P3.md#2x-gate-on-v001-rc3-macbook-241)）真机通过，VoiceOver 读出缩放模式按钮（J2）；actualPixels 路由的 1 与按钮真机未验；跨屏拖窗未验；多文件仅显示首个；⌘0 与 View › Actual Pixels（菜单现显示 ⌘0）走同一 actualPixels 命令，裸 1 不变，仅单元与 App 测试（#348），真机未验。 27 页浅深对照通过（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)）。#444：缩放模式菜单的「1:1 · 100%」走同一 actualPixels 命令（点标签不再在适应与 1:1 间切换），菜单路径真机通过（见上）。 |
| VIEW-03 | 以光标为锚点缩放 | Partial | 单元 | P0-03、P1-03 | `Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasTransform.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 触控板捏合或按 +/−，光标下的那个像素始终停在光标下。限制：zoomIn/zoomOut：P0-03 的 +/− 在 [@2x](validation/P0.md#p0-03画布真机验收7view-02--view-03)、[@1x](validation/P0.md#p0-03画布真机验收-1x7view-02--view-03mac-mini) 已验；捏合、完整 VoiceOver 未验；现按键路由/菜单/按钮真机未验；按钮或指针在面板/画布外时以中心缩放，锚点选择已单测；⌘+（含 ⌘=）/⌘− 与裸 +/− 同锚点同步长，仅单元与 App 测试（#348），真机未验。 |
| VIEW-04 | 平移与边界 | Partial | 单元 | P1-03 | `Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasTransform.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift`、`App/CanvasWindowController.swift` | 放大后拖动，图像不会被拖出可见范围；回到适应窗口后位置复原（27 页）；限制：四向边界与 0 复原 @1x 真机通过（合成拖动，[记录](validation/P1.md#运行-20261023-114600-view-01-04-05-minip1-0337mac-mini-1x)）；#521：工具按钮有焦点时拖动不平移，rc.2 FAIL（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)），rc.3 修复后浅深色下平移 @1x 真机通过（[J2 rc.3](validation/P3.md#j2-rc-acceptance-delta-on-v001-rc3-240)，合成拖动）；真实鼠标/触控板拖动与 @2x 未验；工具焦点下画布拖动，以及 Inspector/侧栏/工具浮层背景/覆盖层按下不抢焦点、不平移，已通过窗口级合成事件回归（#527）；非活动窗口首击仅激活时保留工具焦点，后续 Tab 沿原工具顺序继续，仅窗口级合成事件通过（#527）。 |
| VIEW-05 | 全屏 | Partial | 单元 | P1-03 | `Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasTransform.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift`、`App/CanvasWindowController.swift`、`App/Commands/CommandMenu.swift` | ⌃⌘F 进入和退出全屏，当前图和缩放状态保持；限制：⌃⌘F 进出、适应重算 @1x 真机通过（[记录](validation/P1.md#运行-20261023-114600-view-01-04-05-minip1-0337mac-mini-1x)）；实际像素/自定义缩放下全屏、菜单与绿色按钮入口、@2x 未验。 |
| VIEW-06 | 按 EXIF 方向显示 | Partial | 单元 | P0-05、P1-03 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageIOPipeline.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 打开 S1 素材里八种 Orientation 的样本，全部正向显示；限制：@1x 真机方向 1–8 通过（[P0-05/06 记录](validation/P0.md#p0-0506解码真机验收9view-06--view-07--view-08--fmt-01mac-mini)）；@2x 未验 |
| VIEW-07 | 透明图 | Partial | 单元 | P0-05 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageIOPipeline.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 打开透明 PNG，透明区域按背景设置显示，不是黑色；限制：@1x 真机不发黑（[记录](validation/P0.md#p0-0506解码真机验收9view-06--view-07--view-08--fmt-01mac-mini)）；尚无背景设置；@2x 未验 |
| VIEW-08 | 大图不卡界面 | Partial | 单元 | P0-05、P1-04 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/DecodeAdmission.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/ImagePipeline.swift`、`Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasDecodePolicy.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageLoader.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageHost.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/FirstPreviewTracing.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 打开 48MP 图：加载期间窗口能拖、菜单能开；先出预览再变清晰；限制：@1x 预览→清晰及 AX 移窗可响应已验（[P0 记录](validation/P0.md#p0-0506解码真机验收9view-06--view-07--view-08--fmt-01mac-mini)、[P1 记录](validation/P1.md#p1-04渐进细节与位深资源上限)）；48MP 用 45.4MP；鼠标拖窗/菜单、@2x 未验。渐进、位深/上限、重请求与重试仅单元，原生 opener 未验；合格源首预览可走磁盘缓存（见 CACHE-02）；查看器解码与缓存像素、网格钉住共用同一内存预算，钉住占满时可见解码等待而不失败，仅单元（P3-06）。 |
| VIEW-09 | 快速切图不串图 | Partial | 单元 | P1-05、P2-08 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageLoader.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageHost.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`App/CanvasWindowController.swift` | 快速打开 A→B→C，让 A 最后才解码完：画布、标题、Inspector 都只显示 C；限制：“A 最后完成”单元通过；@1x 自然时序仅见一次（[记录](validation/P1.md#p1-04渐进细节与位深资源上限)），无延迟钩子、@2x 未验；标题仅文件名（Inspector 元数据随切换同步见 INFO-02，仅单元）。同代次修订只重试一次；清旧像素回 opening、关闭/失败清理及 #58 消耗重试后的延迟旧查找、#122 迟到旧 pin/旧观察与取消均仅单测，#122 与网格内快速翻图真机未验。 P2-08 外部重命名/替换触发新呈现代次并更新画布与标题，仅单元与 App 接线测试覆盖；签名真机未验。 |
| VIEW-10 | 上一张 / 下一张 | Partial | 单元 | P2-03 | `Packages/PicseeKit/Sources/PicseeApplication/Access/FolderNavigation.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderSnapshotNavigation.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/ViewerSessionNavigationHost.swift`、`App/Commands/CommandMenu.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/DisplayPreferences.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/PreviewSet.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Input/FilePreviewSet.swift`；菜单 ID：`folder.loop.menu`；偏好键：`loopThroughImages` | ←/→ 按目录顺序翻图；到首尾时按设置停止或循环。限制：既有按键/菜单/按钮顺序及首尾停止 @1x 通过（[记录](validation/P0.md#p0-04--p0-09授权与-session-真机验收811access-01--access-02--access-05--open-02--open-06--view-10--cmd-02--a11y-02mac-mini)）；工具按钮未验；P2-03 循环/筛选/排序、P2-04 递归快照重建与扫描中快照、末端、方向合并仅单元，原生组合未验。#344「循环浏览」默认关闭、持久化、跨窗口同步及目录边界仅单元；菜单仅编译 App 测试，真机未验。#345 冻结预览集（含多选）与 Finder 多文件集按同一偏好循环，保持集合及排序/筛选顺序，单图不重载、查看中切换即时生效、跨边界快速翻页仅单元；Grid → Space → 菜单切换 → 循环 → Esc 的图片呈现、菜单标题/勾选与当前项滚入可见区有编译 App 测试，真机未验。查看器导航标签按活动预览集的冻结顺序与数量显示序号，无活动预览集时按当前已完成筛选快照显示实际所看文件的 1-based 序号与总数（`文件名  i / N`）；翻图、文件增删及递归重扫后的标签与 AX 同步有单元测试，查看中通过真实菜单排序/筛选及多选 3/12 预览翻页有编译 App 测试（#445）；无活动预览集的目录读取时沿用 `Reading…`，独立图片或不在快照中的图片不显示虚构序号；14 页主色与文字光晕、260 pt 上限处长文件名中间省略且保留序号及 #444 控件回归仅自动化，签名真机与 VoiceOver 未验。 |

### C 沉浸界面

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| CHROME-01 | 工具自动隐藏 | Partial | 单元 | P1-08 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`App/CanvasWindowController.swift` | 不动鼠标约 2.5 秒，底部三组工具和窗口红绿灯一起消失；隐藏后 Tab 聚焦不到、VoiceOver 读不到它们（13 页）。限制：@1x 隐藏后 AX 只剩画布见[记录](validation/P1.md#p1-08c-沉浸工具与窗口-chrome)，#92 r5 签名像素确认紧凑深色静态隐藏外观；隐藏时 Tab/命中排除仅单元，VoiceOver、@2x 未验。 13 页浅深对照通过（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)）。 #351：工具组使用平台磨砂材质，上覆 30–100% panel 色（默认 50%）与固定 50% 内衬；14/16/33 浅深 × 30/50/100 的颜色、圆角、阴影及工具命中/隐藏回归仅单元，旧实色验收保留在 100%；真实模糊、系统减弱透明度回落、@2x 与签名目测待验。 设置滑块与各运行中/后来新建 viewer 的颜色层同步、重新创建偏好 store 后的恢复及 Inspector 画面不变已有 App 自动测试；签名重启与设备视觉待验。 |
| CHROME-02 | 唤回工具 | Partial | 真机 | P1-08 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerChromeHost.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`App/CanvasWindowController.swift`、`App/ChromeAdapters.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Components/DesignComponents.swift`、`App/Commands/CommandMenu.swift` | 鼠标移到底边或按 Tab，工具出现；移到顶部，红绿灯出现；按 Tab 时先唤回、再聚焦第一个控件（14 页）。限制：@1x 底边/顶边/Tab 唤回及窄窗不重叠通过（合成指针，[记录](validation/P1.md#p1-08c-沉浸工具与窗口-chrome)）；#92 r4 签名像素确认浅深面板尺寸/轮廓与完整短名；网格中 Inspector 打开时 Tab 进入 Inspector（单图模式下 Tab 仍聚焦沉浸工具），仅单元；rc.2 Tab 唤回三组工具并聚焦「显示侧栏」@1x 真机通过（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)），rc.3 合成指针进入底边 32 pt 带唤回工具，14 页浅深对照通过（[J2 rc.3](validation/P3.md#j2-rc-acceptance-delta-on-v001-rc3-240)）；顶部红绿灯唤回未验；真实鼠标、@2x 未验。首页（未打开文件夹或图片）底边与 Tab 不唤回工具，首页不显示这些控件（#331，见 OPEN-01）。工具组按 14 页 CSS 使用单层 0.5 pt 轮廓（浅色文字色 12%、深色 16%）与柔和阴影（浅色文字色 8%、深色黑色 45%）（#363），浅深渲染/图层单元通过，真实屏幕阴影方向、@2x 与真机未验，既有 #92 r4 像素记录早于该改动。缩放标签使用 100 pt 最小宽度、12 pt sans，文字为主文字色（浅色 #1a1a1a、深色 #e5e7eb），悬停时文字色不变、背景为主文字色的浅色 5%／深色 8%；文字描边光晕未实现，悬停色由强制悬停态与已安装视图的 onHover 处理器渲染单元覆盖（采样点在标签内）；真实指针悬停未验（合成 mouseEntered/mouseExited 不触发 SwiftUI 悬停），留待签名真机冒烟。#444：左下工具组按 14 页改为 侧栏 / 返回网格 / 更多（104 pt 宽，按钮在 x 5/37/69），缩放组 174 pt 宽，缩放模式控件 100×26 带下拉箭头、打开「适应窗口 / 1:1 · 100%」菜单；打开与信息移出工具组，仍可从 File › Open…（⌘O）、View › Show Inspector（⌘I）与「更多」菜单进入；几何、菜单路由与菜单锁仅单元（菜单弹出用替身），「更多」菜单内容与主菜单同源有 App 测试（菜单项标识 `viewer.more.inspector`、`chrome.always-show-tools`），没有可打开的菜单（无 provider 或 presenter）时「更多」禁用，缩放模式菜单弹出并列出两项 rc.2 @1x 真机已见（J2），「更多」菜单弹出真机未验。#538：禁用的缩放标签只应用一次 0.4 不透明度；浅深离屏/窗口宿主像素、启用态回归与禁用激活仅单元，签名真机未验。 #351：工具组使用平台磨砂材质，上覆 30–100% panel 色（默认 50%）与固定 50% 内衬；14/16/33 浅深 × 30/50/100 的颜色、圆角、阴影及工具命中/隐藏回归仅单元，旧实色验收保留在 100%；真实模糊、系统减弱透明度回落、@2x 与签名目测待验。 设置滑块与各运行中/后来新建 viewer 的颜色层同步、重新创建偏好 store 后的恢复及 Inspector 画面不变已有 App 自动测试；签名重启与设备视觉待验。 |
| CHROME-03 | 操作中不隐藏 | Partial | 单元 | P1-08 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerChromeState.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`App/CanvasWindowController.swift`、`App/Commands/CommandMenu.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Components/DesignComponents.swift` | 打开菜单、拖动控件、Inspector 或 Filmstrip 展开时工具不消失；结束后重新计时。限制：@1x 菜单、键盘焦点锁与点击后回画布通过（[记录](validation/P1.md#p1-08c-沉浸工具与窗口-chrome)）；P3-13 Inspector 面板展开时工具不隐藏仅单元、真机未验；#92 r4 签名像素确认工具布局；拖动、Filmstrip、@2x 未验。工具组按 14 页 CSS 使用单层 0.5 pt 轮廓（浅色文字色 12%、深色 16%）与柔和阴影（浅色文字色 8%、深色黑色 45%）（#363），浅深渲染/图层单元通过，真实屏幕阴影方向、@2x 与真机未验，既有 #92 r4 像素记录早于该改动。缩放标签使用 100 pt 最小宽度、12 pt sans，文字为主文字色（浅色 #1a1a1a、深色 #e5e7eb），悬停时文字色不变、背景为主文字色的浅色 5%／深色 8%；文字描边光晕未实现，悬停色由强制悬停态与已安装视图的 onHover 处理器渲染单元覆盖（采样点在标签内）；真实指针悬停未验（合成 mouseEntered/mouseExited 不触发 SwiftUI 悬停），留待签名真机冒烟。 #351：工具组使用平台磨砂材质，上覆 30–100% panel 色（默认 50%）与固定 50% 内衬；14/16/33 浅深 × 30/50/100 的颜色、圆角、阴影及工具命中/隐藏回归仅单元，旧实色验收保留在 100%；真实模糊、系统减弱透明度回落、@2x 与签名目测待验。 设置滑块与各运行中/后来新建 viewer 的颜色层同步、重新创建偏好 store 后的恢复及 Inspector 画面不变已有 App 自动测试；签名重启与设备视觉待验。 |
| CHROME-04 | 工具常驻 | Partial | 单元 | P1-08、P3-11 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/DisplayPreferences.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`App/Commands/CommandMenu.swift`、`App/UI/SettingsPanelWindow.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Preferences/UserDefaultsDisplayPreferencesStore.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Components/DesignComponents.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`App/CanvasWindowController.swift` | 开启“始终显示工具”，工具不再隐藏；退出重开后设置仍在。限制：@1x 常驻开关及重开保持通过（[记录](validation/P1.md#p1-09外观与显示偏好)）；#92 r4 签名像素确认工具布局；设置窗口控制与菜单双向同步仅自动化测试；窗口间同步仅单元、@2x 未验；网格底栏“显示”面板（P3-11 #114）不含常驻开关，常驻仍只在设置“通用”与菜单。带 schemaVersion 的新存储格式（#216）的重启保留仅单元，现有真机重启记录早于该格式。首页不显示工具，常驻设置在首页不生效（#331，见 OPEN-01）。工具组按 14 页 CSS 使用单层 0.5 pt 轮廓（浅色文字色 12%、深色 16%）与柔和阴影（浅色文字色 8%、深色黑色 45%）（#363），浅深渲染/图层单元通过，真实屏幕阴影方向、@2x 与真机未验，既有 #92 r4 像素记录早于该改动。缩放标签使用 100 pt 最小宽度、12 pt sans，文字为主文字色（浅色 #1a1a1a、深色 #e5e7eb），悬停时文字色不变、背景为主文字色的浅色 5%／深色 8%；文字描边光晕未实现，悬停色由强制悬停态与已安装视图的 onHover 处理器渲染单元覆盖（采样点在标签内）；真实指针悬停未验（合成 mouseEntered/mouseExited 不触发 SwiftUI 悬停），留待签名真机冒烟。 #351：工具组使用平台磨砂材质，上覆 30–100% panel 色（默认 50%）与固定 50% 内衬；14/16/33 浅深 × 30/50/100 的颜色、圆角、阴影及工具命中/隐藏回归仅单元，旧实色验收保留在 100%；真实模糊、系统减弱透明度回落、@2x 与签名目测待验。 设置滑块与各运行中/后来新建 viewer 的颜色层同步、重新创建偏好 store 后的恢复及 Inspector 画面不变已有 App 自动测试；签名重启与设备视觉待验。 |
| CHROME-05 | Esc 返回来源 | Partial | 单元 | P1-08、P3-01 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorFocus.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 从网格进入的大图按 Esc 回到网格；单独打开的图，其文件夹已授权时 Esc 回该文件夹网格，否则不会出现一个不存在的网格。限制：网格来源与单图回网格仅单元（P3-01），签名原生组合未验；单张图（File Grant）Esc 无网格、工具焦点 Esc 回画布 @1x 已验（[记录](validation/P1.md#p1-08c-沉浸工具与窗口-chrome)）。工具或 Inspector 的 Esc 键盘焦点返回画布后显示焦点环（#362），仅有渲染单元，真机未验。#444：左下「返回网格」与画布焦点下的 Esc 走同一返回路径（键盘聚焦在工具上按下时也直接返回，不只回画布），仅单元与 App 测试，真机未验。 |
| CHROME-06 | 固定窗口与全屏光标 | Absent | 无 | P4-03 | — | 全屏不动鼠标，光标随工具一起隐藏；固定窗口模式下窗口大小不随图片改变 |

### 外观与显示偏好

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| PREF-01 | 跟随系统 / 浅色 / 深色 | Partial | 单元 | P1-09 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/DisplayPreferences.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Appearance/WindowAppearanceAdapter.swift`、`App/Commands/CommandMenu.swift`、`App/UI/SettingsPanelWindow.swift` | 默认跟随系统，系统外观切换时窗口即时变化；手动选深色后不再跟随（11/12 页）。限制：系统外观实时切换仅单元证明（真机需用户切换系统设置）；手动浅/深即时切换与深色重开保持 @1x 真机通过（[记录](validation/P1.md#p1-09外观与显示偏好)）；设置窗口与菜单双向同步仅自动化测试；浅色重开未验；@2x 未验。设置外观选项的选中显示与 AX 值仅自动化测试；离屏 2× 位图检查不代表 @2x 真机验收。 |
| PREF-02 | 减少动态效果 | Partial | 单元 | P1-09 | `Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Appearance/MotionPolicy.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`App/CanvasWindowController.swift` | 打开系统“减少动态效果”，工具显隐和面板切换没有动画。限制：工具显隐与面板切换本身无动画；组件过渡随系统开关为 0（单元）；系统开关真机未验（用户步骤）。 |
| PREF-03 | 显示设置 | Partial | 单元 | P3-11 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/DisplayPreferences.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Preferences/UserDefaultsDisplayPreferencesStore.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridDisplayPanelView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`App/UI/SettingsPanelWindow.swift`、`App/CanvasWindowController.swift` | 15 页：点底部右侧“显示”按钮弹出面板，调缩略图大小、显示文件名、填充裁剪 / 完整显示（外观、始终显示大图工具在设置「通用」里调），立即生效，退出重开仍保留；限制：底部“显示”面板与设置窗口“显示”分区共用一组 app 级偏好（#114）：缩略图大小 140–280 pt（步长 10，默认 220）、显示文件名、填充裁剪 / 完整显示，改动即时作用于网格、以 UserDefaults 重启保留（偏好键 `thumbnailSize`、`showFileNames`、`thumbnailFit`，取默认值时不写入），仅单元与 App 集成测试，真机未验（滑块拖动、重启、@2x、深色、阴影均未验）。外观与始终显示大图工具在设置“通用”，面板不含这两项，也没有键盘快捷键链接。缩略图大小是最小列宽（`--thumb-min`），窗口 720 pt 及以下时网格固定 145 pt，滑块无可见效果。面板打开时，Esc 无论焦点在面板内、网格或底栏，也无论 Inspector 是否显示，都先关闭面板并把焦点还给“显示”按钮；面板内 Tab / Shift-Tab 只在面板控件间循环；点击面板外（网格、侧栏、底栏其他控件）关闭面板，点击照常生效；以上经窗口按键/鼠标路由的单元与 App 集成测试，真机未验。#349 起 ⌘+ / ⌘− 以 20 pt 调节、⌘0 重置为 220；双窗口网格、设置滑块与底栏面板共用即时偏好，合法旧值（如 170/260）保留、缺失值回落 220，其余偏好不变。设置滑块的 AX 名称、数值与范围、增减动作、隐藏状态及键盘遍历仅 App 自动测试；真实 VoiceOver、中文 Settings 与签名真机重启同步未验。#350：Grid 捏合复用同一偏好，双窗口渲染、Settings 滑块与重新创建 UserDefaults store 的同步已有 App 自动测试；真实触控板手感与签名 App 重启仍待 owner 真机检查。窗口窄于约 290 pt 时面板变窄，“缩略图”下拉标题可能截断（仅检查控件不重叠、不出面板）。中英文控件标题无截断与重叠仅自动化检查。 #351：设置“显示”新增「工具背景不透明度」，范围 30–100%、默认 50%，允许小数；打开的两个 viewer、后来新建的 viewer 与重新创建 UserDefaults store 后的 viewer 同步值和实际工具颜色层像素均经 App 自动测试。旧数据缺字段或类型异常回落 50%，有限越界值截到边界，其余偏好保留；持久化、观察者通知与完整旧值对照经包测试。滑块支持原生键盘遍历/方向键、AX 名称/百分比值/范围/增减及隐藏分区排除；中英文标题和数值宽度经真实控件帧测量，构建产物含两种译文；Inspector 区域的元数据、帧与像素在调节时不变。以上为自动测试，实际 VoiceOver 朗读、签名 App 退出重开、系统减弱透明度回落与 @2x 仍待真机。 #351 M1：设置“显示”四行共用标签列与控件起点；工具背景不透明度标题在 120 pt 标签列内允许两行，英文与简体中文完整文字、列对齐及切换分区后保持布局已有真实 Settings 窗口 App 自动断言；签名真机外观未验。 |
| PREF-04 | 偏好在窗口间同步 | Partial | 单元 | P1-09、P4-01 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Preferences/UserDefaultsDisplayPreferencesStore.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Appearance/WindowAppearanceAdapter.swift` | 开两个窗口，在一个里改主题、Filmstrip 显隐或工具常驻，另一个窗口即时同步（ADR-002）。限制：两窗口同步仅单元证明；文件夹排序字段与方向也经 DisplayPreferences 在窗口间同步，仅单元（#124）；App 目前只开一个窗口（P4-01）；Filmstrip 尚不存在（P2-06）。 |

### 文件夹浏览

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| FOLDER-01 | 扫描后进入网格 | Partial | 真机 | P2-02、P3-17b | `Packages/PicseeKit/Sources/PicseeInfrastructure/FolderBrowser/`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/`、`Packages/PicseeKit/Sources/PicseeCore/Models/`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ReadFailedStateView.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/FolderScanning.swift` | 打开 S2（5000 项）：扫描中显示 24 页读取状态，取消回到上一状态；完成后出网格，排序首张为当前项，Space 进大图可翻图。限制：网格入口、读取状态与取消恢复仅单元（P3-01）；多文件打开后进入文件夹再取消读取，恢复原多文件预览集合（同一张、同一顺序 ←/→）仅单元（#150；App 接线经 openGrantedFolder、openRecent 有 App 单元，打开面板授权后进入文件夹的路径无测试）；后台扫描未完成时取消读取不保留半扫描来源：没有多文件预览集合时只恢复所显示的图片，←/→ 走原生导航；有集合时恢复集合，←/→ 在集合内移动，后一种组合无测试（#150）；递归开关/边界与计数仅单元（P2-04）；网格中切换递归重扫时的读取状态、取消回到原网格与失败 Retry 仅单元（P2-04）；读取状态在网格外壳主列内（侧栏打开时位于其旁）显示仅单元（P3-10）；读后侧栏与底栏计数见 FOLDER-05；rc.2 读取 2 万项进网格与单独取消读取回到原网格 @1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)；早先 [@1x 记录](validation/P2.md#p2-02分批扫描取消与快照导航)）；5000 项打开到网格耗时未达计划 ≤1 s 目标，用户 2026-11-05 选择「Ship as known limit (Recommended)」，v0.0.1 带此限制发布（[正式测量](validation/P3.md)，运行 perf146rc2-20261104-2055；优化见 #516）；2 万项读取完成进入网格、首张为当前项 @1x 仅外观已见（不证明全部缩略图、耗时或 Space/Enter/Esc）；S2（5000 项）路径上 Space 进大图翻图同样未记录；page24 读取状态布局及既有取消恢复仅有自动化断言（#282），不代表整页视觉验收；@1x 签名对照通过，取消读取回到上一网格 @1x 已见（[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)，运行 parity-281-fix6-10301941）；取消读取恢复网格、读取中途失败后 Retry 两条路径上的网格底栏文件名与数量有 App 集成测试（#281），取消路径 @1x 已见，失败后 Retry 真机未验；读取中途失败（#238）先查授权根：根不可读交给第 26 页（不出现「读取失败」），根可读时内容区显示「读取失败」（24F-A：「没能读完“<文件夹>”」、「重试」持有焦点、「选择其他文件夹…」），不显示部分网格或部分计数，「重试」读取中取消回到「读取失败」，可读授权根内的子目录扫描失败不另弹文件夹授权面板；rc.2 @1x 真机已见 24F 不显示部分网格与计数、「重试」持有焦点、恢复可读后完成网格（J1），其余仅单元与 App 集成测试；24F 焦点按钮的 Return/小键盘 Enter 走各自操作：拒读未恢复时「重试」仍留在 24F 并恢复焦点，恢复可读后显示完整网格，「选择其他文件夹…」走选择操作，普通网格 Return 开图回归仅控件与 App 自动化覆盖（#442）；「重试」上的 Return rc.2 @1x 真机通过（J1），其余入口未记录；所看目录的监听静默刷新（保留排序、筛选与当前项）见 FOLDER-07，仅单元。；运行 parity-204-205-r2-11031824（main 4f830d6c，对照按当前设计重新渲染，[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)）：第 24 页除添加文件夹控件（#437，FAIL）外读取状态各项 @1x 通过，取消读取回到上一网格与 2 万项读取完成进入网格仅行为已见（合成点击）；rc.2 第 24 页侧栏「添加文件夹」行带 `+`、标题 `+` 在场，@1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)，#437） #507：经符号链接的文件夹与普通文件夹走同一条文件夹面板路径；面板授权后书签指向规范目标，真实 SystemSecurityScope 与真实/旧夹具扫描器的 App 测试在 2 秒内完成同样三张图的网格，拖入/Open With 在面板应答后同样完成；签名沙盒路径待复验。 |
| FOLDER-02 | 排序 | Partial | 单元 | P2-03 | `Packages/PicseeKit/Sources/PicseeCore/Models/FolderViewPolicy.swift`、`Packages/PicseeKit/Sources/PicseeCore/Models/FolderSnapshot.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FolderBrowser/FolderBrowser.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderMenuPolicy.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`folder.sort.menu`、`folder.sort.name.menu`、`folder.sort.modificationDate.menu`、`folder.sort.type.menu`、`folder.sort.size.menu`、`folder.order.menu`、`folder.order.ascending.menu`、`folder.order.descending.menu` | 按名称自然排序（img2 排在 img10 前）、修改日期、类型、大小，升降序都能切换；所选排序各窗口共用，重启后仍在。限制：排序字段与方向经 DisplayPreferences 跨窗口、文件夹和启动保留，仅单元（#124）；取消读取采用当前 App 排序（P3-01，#124）；递归结果的排序（P2-04）、投影、元数据与菜单策略仅单元；底栏入口复用菜单条件与策略仅单元；拍摄日期与像素面积排序见 FOLDER-06；原生菜单、中文与辅助功能真机未验；所看目录的监听静默刷新（保留排序、筛选与当前项）见 FOLDER-07，仅单元。 |
| FOLDER-03 | 扩展名过滤 | Partial | 单元 | P2-03 | `Packages/PicseeKit/Sources/PicseeCore/Models/FolderViewPolicy.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderScanCoordinator.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderMenuPolicy.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`folder.extensions.menu`、`folder.extension.all.menu`、`folder.extension.none.menu`、`folder.extension.<lowercased-extension>.menu` | 只勾选 PNG，列表与翻图都只剩 PNG；取消过滤后恢复，当前图合理保留；同一文件夹重扫仍只看 PNG，打开别的文件夹时清空。限制：同文件夹重扫及单图打开前结束扫描后仍保留扩展名过滤，换文件夹清空，重启不恢复；同文件夹以解析符号链接后的路径判定，别名等非符号链接路径未验；仅单元（#124）；取消读取恢复过滤（P3-01）、保留当前项、无匹配须待扫描完成才呈现，筛选等待中失败显示 Retry，首个可用批次按当前排序选 Current、后续批次不移项；静默刷新保留旧无匹配并延迟新无匹配至完成，上述与取消、Retry、晚到批次及跨扩展名别名先过滤后选可用 URL 仅单元；浏览时筛选隐藏当前项，当前项移到最近的可见项，仅单元（P2-07）；JPG 菜单同时覆盖 .jpg/.jpeg（大小写不敏感），晚到 .jpeg 当前项在 JPG 过滤下保留仅单元；原生菜单、无匹配状态与按钮真机未验。 |
| FOLDER-04 | 子目录递归 | Partial | 单元 | P2-04 | `Packages/PicseeKit/Sources/PicseeCore/Ports/FolderScanning.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FolderBrowser/FolderBrowser.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderScanCoordinator.swift`、`App/Commands/CommandMenu.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/WindowImageTitle.swift`；菜单 ID：`folder.recursive.menu` | 打开递归，嵌套目录的图片出现；含循环符号链接的目录扫描能结束，不重复列出 限制：默认关闭且仅会话，取消后菜单保留勾选；10 万访问项保护只用于递归，平铺目录不受此新上限；边界/去重/代次、跨扩展名别名过滤、快速切换/Retry 清图与取消恢复仅单元；网格中切换递归按文件夹读取重扫，取消恢复原网格与原勾选，失败显示 Retry，仅单元，真机未验。打开图片时设置标题栏代理图标（representedURL）仅单元；普通空结果标题/AXDocument 清理 @1x 样本通过（[记录](validation/P2.md#p2-04递归浏览的空结果标题复验)），该样本早于 ADR-014；递归空结果改显示 22 页后，其标题与 AXDocument 仅单元；本机 chmod 000 子目录错误与部分计数已测，沙盒权限未验；菜单勾选、真实循环链接、中英文 AX、@2x 未验；所看目录的监听静默刷新（保留排序、筛选与当前项）见 FOLDER-07，仅单元。 |
| FOLDER-05 | 扫描进度 | Partial | 真机 | P2-04、P2-09、P3-17b | `Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderScanCoordinator.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageStatus.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerChromeState.swift` | 还不知道总数时只显示“读取中”，不显示百分比；完成后显示真实数量 限制：目录读取与重试仅单元；完成计数取过滤后的导航快照，未过滤/过滤/零匹配、取消恢复及监听刷新后的计数有自动化断言；查看器原生状态文本在读取中、完成、取消与失败间切换有单元测试（#142/P2-09；监听路径使用临时目录，签名真机未验）；从文件夹进入的读取失败后不保留部分来源、不显示部分计数（#238，24F-A；仅单元与 App 集成测试），从单张图片进入的读取失败后仅可在已知图片中翻图，已有图的缩放命令可用；单图入口 Retry 保留当前图（含失败后翻到的图），之后按快照排序翻图；取消的完整真机状态未验；page24 所列项目已有渲染帧/图层断言（#282）：进度环、标题与说明、取消读取按钮样式、底栏读取状态、添加文件夹控件、侧栏分隔线；不代表整页视觉验收，@1x 签名对照通过（[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)，运行 parity-281-fix6-10301941）；侧栏宽与全宽底栏已一致；读取堆叠按 folder-loading.html 文字盒定位，进度环绕自身中心旋转（窗口缩放、侧栏显隐与宽度变化后仍与标题同中线），开启「减少动态效果」时进度环不旋转（仅单元），底栏读取状态 `—` 与 `Reading…` 完整显示，读取以找不到页（page 26）结束时读取状态清除、底栏改为「— 无法访问」（#332，仅单元与 App 测试），以「读取失败」结束时底栏为 `—` 与「读取未完成」、侧栏该文件夹显示 `—`（#238），失败页重试时恢复读取状态（仅 App 集成测试），侧栏中正在读取或重试的文件夹在数量未知时不显示数量，AX 标签也不含虚构的 0 images；已知数量保持显示，完成空目录后的真实 0 与失败破折号不变（#142/P2-09；仅自动化断言，变更后签名真机与 VoiceOver 未验）；以上其余行为仅单元与 App 集成测试，签名构建 @1x 底栏读取状态与第 26 页读取状态清除已见（运行 parity-281-fix6-10301941），失败页重试与减少动态效果真机未验；其他签名真机条件及 @2x 未验；所看目录的监听静默刷新（保留排序、筛选与当前项）见 FOLDER-07，仅单元。；运行 parity-204-205-r2-11031824（main 4f830d6c，对照按当前设计重新渲染，[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)）：第 24 页底栏 `— 正在读取…` 与读取中侧栏计数留空 @1x 通过，添加文件夹控件当时 FAIL（#437，rc.2 已通过，见 FOLDER-01）；取消子目录分批读取时恢复之前完整来源及底栏数量，旧目录准入前回调、取消后的迟到批次和快照回调不覆盖恢复结果（#506；仅 App 自动化断言，签名真机未验）；rc.2 @1x 真机已见读取状态（第 24 页对照 KNOWN #500、#502）、读取完成到 2 万张，24F 不显示部分计数（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)）；底栏真实数量的上屏未单独记录 |
| FOLDER-06 | 按拍摄日期 / 像素尺寸排序 | Partial | 单元 | P2-05 | `Packages/PicseeKit/Sources/PicseeCore/Models/FolderViewPolicy.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderScanCoordinator.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageFolderMetadataReader.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`App/CanvasWindowController.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`folder.sort.captureDate.menu`、`folder.sort.pixelDimensions.menu`；状态 ID：`folder.sort.pending`、`folder.sort.incomplete` | 选按拍摄日期排序，元数据没读完时显示“排序未完成”，读完后顺序稳定 限制：按需租约、旧代次丢弃、缺失值末尾与面积溢出安全、真实 ImageIO 头信息、菜单策略、非阻塞状态及 #108 同步头信息读取移离 Swift cooperative executor 仅单元；监听刷新保留未变项元数据、仅为新增或变更项读头与失败后保留已读值仅单元；缺失或读取失败时显示“部分排序元数据无法读取”，未知值排末尾；拍摄日期无时区信息按 UTC 解析，TIFF DateTime 回退可能是文件软件修改时间；排序字段与方向跨窗口、文件夹和启动保留，仅单元（#124）；原生菜单、中文、辅助功能、签名真机与 @2x 未验。 |
| FOLDER-07 | 外部变化同步 | Partial | 单元 | P2-07、P2-08 | `Packages/PicseeKit/Sources/PicseeCore/Ports/FolderWatching.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Watching/`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/FileGrantWatchDescriptor.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Identity/FileItemIdentityResolver.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderScanCoordinator.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderEntryRestore.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`App/Access/AccessServices.swift`、`App/CanvasWindowController.swift`、`App/PicseeApp.swift` | 在 Finder 里新增、删除、重命名图片，停止操作后列表很快一致；当前图被删时有明确的下一张 限制：每个授权根一个共享监听、合并（静默 200 ms、最长 1 s）、丢事件与回到前台全量重扫、当前项移到后继仅单元与临时目录 FSEvents 测试；所看目录下隐藏项与包内的变化不触发重扫；监听建立失败（授权或 FSEvents 拒绝）时不假装在监听，该窗口只在回到前台时重扫并重新订阅（App 接线未测）；后台刷新失败（含所看目录被删除或移走）时显示文件夹扫描失败与重试、保留旧列表，当前图文件已不存在则清除，目录回来后下一次变化自动恢复，授权根移动跟随 bookmark 并迁移监听，网格文件夹名称与窗口身份随新目录更新（P2-08，仅单元）；所看目录失址时：读取失败先查授权根，授权根失址则不显示失败与重试，直接进入页 26（按失联原因为「找不到」「外接磁盘未连接」「授权失效」或「原因未知」，见 ACCESS-03、ACCESS-04、FOLDER-09，#231、#238），授权根仍可读则显示「读取失败」与重试，仅单元，签名真机未验；重命名按文件资源身份保留当前项，同路径替换依资源修订重开，删除时显示后继；观看态新路径、新修订与底栏计数随完整快照重呈现（P2-08，仅单元与 App 接线测试覆盖）；网格 Inspector 随所选图片的资源修订更新元数据，未变修订不重复读取，重命名、删除后继与空态随当前项同步（P2-08，仅 App 接线测试覆盖）；浏览时筛选隐藏当前项，当前项同样移到最近的可见项；元数据排序下刷新保留未变项、仅读新增或变更项，仅单元；每次变化全量重扫所看目录；App 目前只开一个窗口，多窗口共享仅单元；刷新删除已选项时选择只收缩、被删项缩略图请求取消，可见缩略图按新快照重新请求，仅单元；2 s 目标只在假时钟上测了从事件到快照的等待，扫描耗时不计；网格文件名搜索时的监听刷新保留搜索词、筛选结果、计数与无结果页（见 GRID-07），仅单元；不在原导航顺序中的当前项（如被过滤排除的单图输入）静默刷新后移到首张可见图，无专门测试；原位内容变化若文件大小与修改日期均不变，刷新可能无法识别，内容摘要检查待后续；单图 File Grant 使用文件描述符 vnode 监听并在回到前台时对账，删除时清除图片，失去访问时提示重新选择，仅单元；文件在对账读取或细节解码途中进入废纸篓时静默清图、在对账读取途中移走时跟随新位置，不弹重连，直接移除或 bookmark 失效仍提示重连，由注入先后顺序的 App 测试覆盖（#273）；签名沙盒真机未验（#273）；5000 项扫描耗时及真实 2 s 未验。 |
| FOLDER-08 | 空文件夹 | Partial | 真机 | P2-08b | `App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/EmptyFolderStateView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridViewerPresentation.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/EmptyFolderContent.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageStatus.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderScanCoordinator.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridSidebarTreeView.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderSnapshotNavigation.swift` | 打开空目录显示 22 页空态，可“选择其他文件夹”；侧栏仍可用，底栏搜索与排序按钮留在原处但置灰，有图片时恢复可用。限制：按 ADR-014 采用 22-BD（有子文件夹列名称、「包含子文件夹浏览」，否则列最近打开最多 10 项；内容区可拖入文件夹）；仅单元：完整扫描且无图片才显示、读取中与有图网格上不显示、监听刷新随之切换、扩展名过滤仍为无匹配（仅模型状态：网格上扩展名过滤清空非空文件夹时不显示任何提示，直到 #125 的网格无匹配页）；子文件夹名称来自侧栏子项，侧栏子项到达前先显示最近打开；单图查看器的文件夹会话变空时（如打开的图片被移走），查看器表面显示 22 页内容并保留查看器外观，不显示「打开一个文件夹，开始浏览」（单元与 App 测试）；rc.2 @1x 真机已见空目录、0 张图片、最近打开行与「选择其他文件夹…」，Tab/Shift-Tab 按序，VoiceOver 读出这些控件（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)）；侧栏仍可用、底栏搜索与排序置灰、有图片时恢复可用以及按下「选择其他文件夹…」均未记录；22 页对照 FAIL (APP) → #518（v0.0.2）；拖入与英文上屏未验。查看器上的子文件夹列表只在变空时读取一次，不随监听更新，仅单元。#332：空文件夹页底栏名称槽为「—」、计数槽为「0 张图片」（搜索中亦然），仅单元测试；签名真机未验。#518：按固定版 CSS 修正空态标题/说明、最近列表与按钮行高，以及内容区上 16 pt、底栏上方 30 pt 留白；三行最近文件夹的图标/标题/列表顶边，浅深色、全部宽度断点两侧与回缩、两行/三行切换仅单元；子文件夹卡片与两项按钮、查看器零内缩空态的位置仅单元；拖放目标自身 frame 覆盖完整内容区，留白内拖放回调仅单元。位置按内容区（系统标题栏 28 pt 以下）与 CSS 在相同内容高度下比较；签名真机未验。#518 fix2：最近列表放不下时先压缩额外纵向间距，再在列表框内使用系统滚动条；「选择其他文件夹…」留在列表外、底栏上方，键盘聚焦最近行会滚入可见区。0/1/5/10 行、浅深色、网格与查看器的 640/772 pt 内容高度及 960×640 原生窗口回归仅自动测试；能放下时保留居中位置，签名真机重验未完成。#518 fix3：低于紧凑内容加最近标题与完整一行所需高度时，复用同一滚动视图整页滚动；0/1/5/10 项在 300/200 pt 内容高度、浅深色、网格/查看器，阈值两侧、尺寸恢复、聚焦行可达与有最近列表时的页面拖入仅自动测试；设计侧另验能放下的 1/5 项保持自然高度且不滚动。签名真机重验未完成。 |
| FOLDER-09 | 卷被卸载 | Partial | 真机 | P2-08、P2-08c | `App/Access/AccessMonitor.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/`（FileAccess、DiskMountPort、AccessDiagnostics、AccessFolderRecoveryLocation）、`Packages/PicseeKit/Sources/PicseeInfrastructure/Identity/URLRecoveryIdentityResourceReader.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/LostAccessStateView.swift` | 浏览外接盘时推出它，显示不可用状态，不崩溃；重新挂载后可以重新打开 限制：推出后各窗口停止该根的工作并显示页 26（卷未连接／原因未知；根目录访问被拒为「授权失效」，见 ACCESS-04），播报与重试按失联次数各一次；重新挂载按卷 UUID 校验书签、范围与根目录身份（会话内卷 UUID＋inode，可读期间捕获，不持久化、不改 ItemID），再恢复原文件夹、当前项与排序筛选，原位置不在则回根网格；身份校验失败停在「原因未知」；已挂载卷解析失败或系统废纸篓归「找不到」，回到前台或唤醒时重试；以上自动测试覆盖；签名构建 @1x 以 hdiutil 磁盘映像推出后显示页 26「外接磁盘未连接」、重新挂载后自动恢复原当前项，推出后切到其他文件夹再重新挂载不跳回（[记录](validation/P3.md#p2-08c-t7第-26-页失去访问-1x-真机验收)，运行 20261101-111926-i234）；USB 拔出与网络卷未验，@2x 未验；页 26 对照 FAIL（#354）。选中勾选不恢复（非本验收，ADR-014）。已捕获的 inode 变更或读不到时拒绝恢复；离线启动无已验证基线或旧式书签时需重新选择。没有卷 UUID 的卷（多为网络共享）不跟踪挂载事件，启动与回到前台时先列出根目录（仅单元）。rc.2 推出 DMG 后显示页 26、「选择其他文件夹…」初始焦点 @1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)）；减少动态效果真机未验，VoiceOver 只记录了按钮读出（J1）。 #354：外接盘图形改为第 26 页 SVG 轮廓（32 pt 外框内约 26×16 pt 笔画），标题保持 16 pt 中等字重（500）；浅深外观下独立 SVG 的 Alpha 轮廓、指示线和状态切换断言覆盖，签名真机未验。 |

### Filmstrip

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| FILM-01 | 展开 / 收起 | Absent | 无 | P2-06 | — | 默认收起；展开后只有一组翻图按钮和序号，画布不变小；退出重开保持上次状态（33 页） |
| FILM-02 | 点选跳转 | Absent | 无 | P2-06 | — | 点一张缩略图跳到该图；翻图时当前项自动滚到可见位置；切换目录后不再显示旧目录的缩略图 |

### 网格、选择与菜单

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| GRID-01 | 网格浏览 | Partial | 真机 | P3-01、P3-10、P3-17a | `Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderGridProjection.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`App/CanvasWindowController.swift` | 打开目录显示 11/12 页网格：紧凑标题、底部工具，没有顶部横幅；文件名单行显示。限制：快照、cell 复用、响应式几何（含 legacy/overlay 滚动条、浮点整列边界与实际 cell 帧）、缩略图装载、缩略图选择描边、文件名末尾截断、当前项环、常驻标题栏与浅深底块仅单元；侧栏/底栏框架、搜索与排序入口仅单元（P3-10）；Inspector 经 ⌘I 打开（P3-13，仅单元）；#215 的收藏、最近与信息入口显示「即将推出」，禁用、不可聚焦与中英文 AX 仅单元，功能仍待各自工作包；底栏“显示”入口自 #114 起可用（见 PREF-03），在第 22 页与读取失败时仍可用、在 Tab 顺序中位于排序之后，仅单元与 App 集成测试，右键与 Filmstrip 仅有统一模型的延后状态；监听触发的静默刷新不进入读取状态、保留当前项，仅单元（P2-07），刷新后滚动位置是否保持未测；第 11 页所列项目已有渲染帧/图层断言（#281）：缩略图框高与行距、当前项环与名称行、子文件夹行距、添加文件夹控件、侧栏分隔线、底栏左侧与 Space 提示、响应式网格与页脚断点；不代表整页视觉验收，根文件夹位置仍待 P3-15，@1x 签名对照通过（[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)，运行 parity-281-fix6-10301941）；底栏文件名与数量按 NSTextField 单元宽度排布（文字盒距 12/7pt），图片数量不截断；长搜索摘要在文件名之后截断，480pt 隐藏时不占宽度；未选中时当前项名称行着色；以上仅单元与 App 集成测试（完成、取消读取恢复、中途失败后 Retry、查看器返回），签名构建 @1x 对照通过（运行 parity-281-fix6-10301941），失败后 Retry 与查看器返回真机未验；rc.2 @1x 键盘选择与 Space/Esc 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)、[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)），rc.3 @2x 缩略图按 backing scale 解码（[@2x](validation/P3.md#2x-gate-on-v001-rc3-macbook-241)），VoiceOver 读出网格与当前项（J1），英文未验；上述 @1x 对照针对 #317 之前的第 11 页；#314 起 App 底栏为当前外观窗口底色 80%、无顶线，Reduce Transparency 时 100%，Grid 延伸至底栏下并保留 40 pt 底部内容 inset，末行与键盘选中末项避开底栏仅单元；新外观与滚动的签名真机、@2x 对照未验；#406 底栏侧栏开关按选中状态使用正文/次级图标色与 hover 底色，快速查看标签使用正文色、Space 键帽保留次级色，快速查看文字盒至首个工具保持 7+16pt 间距（扣除 NSTextField 的 2pt 内边距，#406 fix1），浅深主题与中英文文字宽度的布局帧/颜色回归仅单元，签名真机对照待后续批次。#405 起任何选择数量都不显示 ✓ 勾选标记，选中框保持原生「当前项 2pt 外环、其他选中项 1pt 缩略图边缘描边、无「当前项」文字」，均为用户 2026-11-03 决定（#405，1B、2B）的有意偏离：第 32 页在每个选中项上画 ✓，第 11/12/32 页 `.layout-exploration` 给每个选中项 2px 外环，第 32 页以「当前项」文字标出当前项；1pt 描边现绘制在缩略图之上，仅单元渲染帧；第 11 页待下一批 parity 重采。；运行 parity-204-205-r2-11031824（main 4f830d6c，对照按当前设计重新渲染，[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)）：第 11 页除添加文件夹控件外各项 @1x 通过，添加文件夹框内缺 `+`、文字与标题 `+` 偏浅仍 FAIL（#437），因此第 11 页 @1x 整页对照仍未通过，上文 parity-281-fix6-10301941 的通过只对当时（#317 之前）的设计；rc.2 第 24 页添加文件夹行 `+` 与标题 `+` @1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)，#437）；rc.2 11/12 对照 KNOWN（#500、#501），rc.3 @2x 11-light 对照通过（[@2x](validation/P3.md#2x-gate-on-v001-rc3-macbook-241)） #349：缩略图大小为 app 级偏好，宽度大于 720 pt 时框高按 size/220 缩放，140/220/280 三档、1600/1050/720/480 两侧断点、精确整列边界、浅深外观、长中英文文件名及 overlay/legacy 滚动条的实际渲染帧已有固定设计断言；不大于 720 pt 保持 145 pt 最小列宽和 150 pt 框高，不大于 480 pt 为单列。按键改变尺寸后保留各窗口当前项与选择、按 backing pixel 向外取整滚入底栏上方，并按新框尺寸装载真实 ImageIO 缩略图；双窗口即时同步仅包测试与 App 自动测试，签名真机、真实重启、中文 Settings、VoiceOver 朗读与 @2x 新尺寸清晰度未验，#350：Grid 捏合经纯映射调整同一缩略图大小，限于 140–280 pt，手势期间累积小增量并即时写入既有偏好；上下限反向、手势结束/取消/重新开始与外部尺寸变更已有包测试。Grid magnify 处理器（测试直接调用，未经窗口事件分发与命中测试）改变渲染 tile 宽度、保留完整选择与当前项、将当前项滚入可见区域；双窗口、Settings 滑块与重新创建 UserDefaults store 的同步，以及 viewer 捏合仍缩放图片，均仅自动测试。真实触控板双向手感及上下限由 owner 后续真机检查，未据此升级状态。 |
| GRID-02 | 网格与大图来回切换 | Partial | 真机 | P3-01、P3-17a | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/FolderGridProjection.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridViewerPresentation.swift`、`App/CanvasWindowController.swift` | 选中图片按 Space 或 Enter 看大图，按 Esc 回网格：未翻页时恢复原选择集合、当前项和滚动位置；单选翻页后仅选中最后所看图片，将其设为当前项并滚入可见区；多选预览翻页后保留原选择集合，将最后所看图片设为当前项。限制：#492 翻页（含循环）后经 Esc 或「返回网格」返回，以最后所看图片为当前项并揭示它：单选仅选中该图，多选预览保留存活选择集合；未翻页保留入口状态，预览中删除滚动锚点后不恢复失效锚点。底栏文件名、Return 重开目标和网格选中单元格同步，有单元及编译 App 测试；单选与多选翻页后 Esc、Return 重开 rc.2 @1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)、[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)，合成按键），Enter 开图未验。方向键（含 ⇧/⌘）移动后当前项以最小距离滚入可见区、已可见时不滚动，仅单元（#187）；连续方向键后单一选择、滚动条宽度变化及浮点整列边界的方向键列步长、选择/当前项/滚动恢复、预览中删除、单图 Esc 顺序、取消读取恢复，以及侧栏显隐或宽度变化后的网格列数与滚动恢复仅单元（App 接线无测试）；原生按键、像素、VoiceOver、中英文未验；当前项单元格的辅助功能值「当前」/「已选中，当前」（Current / Selected, Current）随当前项移动仅单元，VoiceOver 朗读未验（#150）；多选的选择与当前项恢复由 P3-09 单元覆盖，翻页返回的选中单元格与当前项另有 #492 编译 App 测试，rc.2 @1x 真机已见（J2）；所看目录的监听静默刷新（保留排序、筛选与当前项）见 FOLDER-07，仅单元。从查看器 Esc 回网格后底栏文件名与数量完整显示，有 App 集成测试（#281），原生按键与像素未验。P3-17a @1x 对照记录只看网格外观，不覆盖网格与查看器间的 Space/Enter/Esc。#345 循环后的 Esc 返回单选选择最后所看图片、多选保留存活选择集合，以最后所看图片为当前项并以最小距离滚入可见区（已可见时保持原滚动位置），有单元及编译 App 测试；真机未验。；运行 parity-204-205-r2-11031824（main 4f830d6c，对照按当前设计重新渲染，[@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)）：合成 Space 进入查看器、Esc 返回且当前项不变 @1x 已见，原生按键与 Enter 未验；Page Down/Up、Home/End 移动网格选择仅自动化验证，真机未验。 |
| GRID-03 | 快速滚动不串图 | Partial | 单元 | P3-02 | `Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridThumbnailScheduler.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessImageSource.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/ThumbnailCoverage.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/PrefetchResuming.swift`、`App/CanvasWindowController.swift` | 在 S2 里快速来回滚动，每个格子的图和文件名始终对得上。限制：可见区及邻近两行请求、复用/换目录/隐藏取消、身份/修订/倍率校验、失败回放与有限重试、可见优先级、授权缓存接线、按源比例取最小覆盖边（#161）、内存压力下只取可见格与压力结束后待管线恢复期满自动续取预取仅单元；S2 数量的快滚身份检查已自动化（5000 项、伪加载器迟到/乱序/错项/错尺寸/中途重排序，不读盘，#146）；rc.2 签名 S2 真机快滚：4 张截图 36 格按类核对，未见错格，逐格像素身份 NOT VERIFIED（[记录](validation/P3.md#s2-快滚身份grid-03)）；@2x 像素与视觉对照未验。 |
| GRID-04 | 多选 | Partial | 单元 | P3-09 | `Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/BrowserSelection.swift`、`App/CanvasWindowController.swift` | ⌘点击切换单项，Shift 点击从锚点选一段；计数正确，当前项与选择集合分开显示（32 页）。限制：原生选择与模型同步、缩略图 cell 重载后的选择绘制有单元覆盖；外部删除已选项时选择只收缩、不并入当前项，仅单元（P2-07）；32 页底栏计数属于 P3-10，签名 App 像素对照、VoiceOver 与真机手势待验。#405 起多选也不显示 ✓ 勾选标记，为用户 2026-11-03 决定（#405，1B）的有意偏离：32 页在每个选中项上画 ✓；非当前选中项以 1pt 缩略图边缘描边与文件名底色区分，描边此前被不透明缩略图遮住，现绘制在其上，仅单元渲染帧；选中框也按用户决定（#405，2B）偏离 32 页：32 页 `.layout-exploration` 给每个选中项 2px 外环，并以「当前项」文字标出当前项，原生为「当前项 2pt 外环、其他选中项 1pt 边、无「当前项」文字」，未改。 #522：有锚点时，Shift 方向键始终以锚点到新当前项的闭区间替换选择（与 Shift 点击相同），无锚点时回退单选并建立锚点；⌘移动焦点后继续 Shift、⌘构造的连续/不连续集合、空白点击清空后恢复区间及无锚点路径均有包级事件覆盖（含有/无 Session 回调）；左右反向跨锚点、上下按实际行步长移动与边界不变、普通方向键重建锚点、既有 Command keyDown 保留选择及无回调 Grid 路径有包级原生事件测试；选择集合计数为 3，不代表 App 底栏计数或物理键已验。 |
| GRID-05 | 多选后的预览范围 | Partial | 真机 | P3-09 | `Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/PreviewSet.swift`、`App/CanvasWindowController.swift` | 选 3 张按 Space，翻图只在这 3 张内；Esc 回来后仍是这 3 张被选中。限制：监听删除命中冻结预览集合时选取集合内后继，集合外图片不进入呈现范围，仅单元（P2-08）；冻结范围、删除扣除与 Esc 来源恢复有单元覆盖；⌘-click 选 3 张、Space 后翻图范围为这 3 张（2/3 → 3/3）、Esc 后 3 张仍选中，rc.2 @1x 真机通过（[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)，合成输入）。 #522：Shift 方向键现始终按已有锚点重建区间（无锚点回退单选），选集同步仅包级覆盖；包级原生 Shift→ 两次得到的连续三项，经 CommandRouter 预览仅含这三项且 Esc 恢复选择与锚点；此自动化不证明 App Space 接线或签名物理键行为。 |
| GRID-06 | 目录侧栏 | Partial | 单元 | P3-10 | `Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridSidebarTreeView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridViewerPresentation.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/DisplayPreferences.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Preferences/UserDefaultsDisplayPreferencesStore.swift`、`App/CanvasWindowController.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`grid.sidebar.toggle.menu`；偏好键：`gridSidebarWidth`、`gridSidebarVisible` | 侧栏可拖宽、可收起，从左下角入口重新打开；退出重开保留宽度。限制：160–320 pt 拖拽、底栏入口、键盘/辅助功能调整与 UserDefaults 往返仅单元；菜单入口（⌃⌘S）仅构建；子目录树的当前/父/子行、空白未知计数与键盘焦点仅单元（P3-10 slice 3）；签名真机、@2x、VoiceOver 与中英文未验。#444：从网格进入的大图可在左侧显示同一文件夹侧栏（左下「显示侧栏」或 ⌃⌘S；显隐独立于网格、每次进入大图默认隐藏，在本次查看中保持，返回网格时网格侧栏照旧（owner 2026-11-04）；宽度与网格共用；窗口窄到画布不足 318 pt 时侧栏最宽只取「内容宽 − 318」，低于 160 pt 则本宽度下不排版、变宽后恢复），画布相应变窄；侧栏显示时 Tab 顺序为画布→工具→侧栏（Inspector 显示时再到其关闭按钮，Shift-Tab 反向），隐藏时焦点回画布；单独打开的图片没有查看器侧栏（按钮与菜单项不可用）；仅单元与 App 测试，签名真机、浅深像素与 VoiceOver 未验。 |
| GRID-07 | 搜索与清除 | Partial | 单元 | P3-10、P2-08 | `Packages/PicseeKit/Sources/PicseeCore/Models/FolderSnapshot.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/GridSearchState.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/GridSearchProjectionScheduler.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorEscapePolicy.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridViewerPresentation.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridWatchedSearchRefresh.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridSearchReconciler.swift`、`App/CanvasWindowController.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`grid.search.menu` | ⌘F 在“搜索当前文件夹”里按文件名搜索；无结果时显示 23 页，点“清除搜索”后内容恢复，当前项合理。限制：文件名匹配、当前项恢复、23 页无结果纵向位置、间距、字体与浅深配色及底栏浅深色布局、底栏 1280/800/480 pt 设计间距、图标展开/失焦收起/清除、长搜索词中间截断及排序入口仅单元；监听刷新保留搜索筛选、当前项按最近幸存项、搜索状态与无结果页，搜索后进大图 ←/→ 只在筛选结果内翻图，仅单元；App 接线与 ⌘F 菜单路由、签名真机、中文、VoiceOver 与像素对照未验；Inspector 开启时搜索焦点、Esc 清除及 ⌘I 保持输入组合仅 App 单元；监听刷新与直接输入搜索后 Inspector 当前项及空结果同步仅 App 与包内单元。 |
| GRID-08 | 小窗口布局 | Partial | 单元 | P3-10 | `Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`Packages/PicseeKit/Tests/PicseeMacUITests/GridShellTests.swift`、`Packages/PicseeKit/Tests/PicseeMacUITests/GridFooterSearchTests.swift`、`Packages/PicseeKit/Tests/PicseeMacUITests/GridFooterLostEmptyStatusTests.swift`、`App/CanvasWindowController.swift` | 窗口缩到 800×680，侧栏、工具、长文件名都不重叠（29 页）。限制：800×680 下侧栏、40 pt 底栏、主列内实际 cell 与单行文件名不重叠仅单元；底栏搜索与排序控件在 Inspector 分栏后的 765/1060 pt 框架仅单元；信息已加入为禁用「即将推出」入口（“显示”自 #114 起为可用按钮，见 PREF-03），其与既有控件在 800×680 不重叠仅单元，截断与真机未验；800×680 子目录长名的单行截断与行/计数不重叠仅单元；签名真机、@2x、VoiceOver 与中英文未验。#332：底栏状态在页 22 空文件夹为「— 0 张图片」、在页 26 失去访问为「— 无法访问」（四种原因相同），侧栏切换前后不变，800×680 下计数不截断，仅单元测试（页 26 另有 App 自动测试，含选择其他文件夹／在新位置选择后取消读取时恢复底栏与失联侧栏行）；签名真机与中文界面未验。 |
| GRID-09 | 图片右键菜单 | Absent | 无 | P3-12 | — | 右键显示快速查看、在访达中显示、拷贝路径、收藏、图片信息五项；能用键盘操作，Esc 关闭后焦点回到原处（31 页） |
| GRID-10 | 在访达中显示 | Absent | 无 | P3-12 | — | 右键选“在访达中显示”，Finder 打开并选中该文件 |
| GRID-11 | 拷贝路径 | Absent | 无 | P3-12 | — | 右键选“拷贝路径”，粘贴到文本编辑出现该文件的完整路径 |
| GRID-12 | 收藏 | Partial | 单元 | P3-14 | `Packages/PicseeKit/Sources/PicseeCore/Library/PersonalImages.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Library/`、`Packages/PicseeKit/Sources/PicseeApplication/Library/PersonalImageProjection.swift` | 收藏后缩略图左上角出现心形标记，侧栏“个人收藏”里能找到；文件被移走后显示“找不到”，不显示错图。限制：仅存储与模型（单元）：收藏按授权根与根内相对路径加文件号保存，重启后仍在；移走、删除、换成别的文件或目录时解析为“找不到”，授权根失效或其文件夹被删除时为不可用且每次重新检查、不用旧结果；不复制图片或缩略图，单图授权的图片不能收藏。心形标记与收藏操作未接线；侧栏“个人收藏”仅显示为禁用、不可聚焦的「即将推出」入口（#215，单元），不能浏览收藏；按文件号判断，外部编辑器原子保存后也会显示“找不到”，再次查看该图后恢复；删除后新建的文件若恰好复用同一文件号，可能被当作原图显示；签名沙盒与真机未验。 |
| GRID-14 | 子文件夹树 | Partial | 单元 | P3-10 | `Packages/PicseeKit/Sources/PicseeApplication/Browser/SidebarFolderBrowser.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/SidebarFolderLoadSession.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FolderBrowser/SystemSidebarFolderEnumerator.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridSidebarTreeView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`App/CanvasWindowController.swift` | 侧栏里当前文件夹下列出子文件夹和各自数量，点子文件夹只浏览它；数量未知时不显示数字。限制：直接子目录枚举、真实非递归图片计数、越界链接排除和租约释放仅单元；侧栏行、父目录返回、取消恢复、关窗释放、监听刷新与慢计数不阻塞首屏仅单元；当前行 AX 选中值的本地化仅单元；文件夹树上方固定两行「即将推出」的收藏与最近，树的可见高度相应减少，仅单元；侧栏刷新先安装替换监听再进行权威读取，交接及读取期间的外部变化会触发后续刷新，仅单元/App 测试覆盖（#298）；签名真机、@2x 及 VoiceOver 未验。 |
| GRID-15 | 添加多个文件夹 | Absent | 无 | P3-15、P2-01 | — | 用“添加文件夹”加入第二个文件夹，两者都在侧栏，退出重开仍在；不复制任何图片 |
| GRID-16 | 所有照片汇总 | Absent | 无 | P3-15 | — | 点“所有照片”看到已加入的全部文件夹的图片；其中一个授权失效时只少掉它的图片，并提示重新授权 |
| GRID-17 | 最近查看 | Partial | 单元 | P3-14 | `Packages/PicseeKit/Sources/PicseeCore/Library/PersonalImages.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Library/`、`Packages/PicseeKit/Sources/PicseeApplication/Library/PersonalImageProjection.swift` | 看过几张图后，侧栏“最近查看”按时间列出它们；文件被移走后显示“找不到”。限制：仅存储与模型（单元）：按查看时间从新到旧保存最多 50 张，重看移到最前，重启后保留；移走后解析为“找不到”；计数在全部解析前为空，之后只数可用项；与“最近打开”的文件夹分开保存，互不影响。查看图片尚未记录访问；侧栏“最近查看”仅显示为禁用、不可聚焦的「即将推出」入口（#215，单元），不能浏览最近项；签名沙盒与真机未验。 |
| GRID-13 | 自适应 / 瀑布流布局 | Absent | 无 | P7-06 | — | 切到瀑布流，混合长宽比的图片按原比例排列，当前选中项不跳走 |

### 信息与元数据

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| INFO-01 | 基础 Inspector | Partial | 单元 | P3-13 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorMetadata.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageIOInspectorMetadataReader.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Inspector/InspectorPanel.swift`、`App/CanvasWindowController.swift`、`App/UI/WindowInspectorReader.swift` | ⌘I 打开右侧面板：缩略图、文件名、尺寸、类型、日期、大小和“加入个人收藏”；浅深色同一面板（16/34 页）；读不到的值显示“未知” 限制：基础字段与缩略图从授权文件读取；Grid 集合视图/大图 ⌘I、Tab、Esc、面板与内容分栏、1280/960/700 pt 响应式布局、16/34 页浅深色与中英五行文字/列距仅离屏测试；面板尚无加入个人收藏按钮，待 P3-14；标签列按当前语言最宽标签定宽，最小 48 pt（16/34 页为固定 48 pt，原生例外），仅离屏测试；Inspector 缩略图（240 px）经共用管线可见优先级准入，成功、失败与取消释放暂存（#194，仅单元/App 回归，真机未验）；16/34 页像素对照未验；网格搜索与 Inspector 焦点/ Esc 组合仅 App 单元。 |
| INFO-02 | 切图后信息不过期 | Partial | 单元 | P3-13 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorMetadata.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Tests/PicseeApplicationTests/InspectorModelTests.swift` | Inspector 开着快速翻图，面板始终只显示当前这张的信息 限制：受控延迟读取和当前项切换仅单元；签名真机快速翻图未验；监听刷新与直接输入搜索后的 Inspector 当前项和空结果同步仅 App 与包内单元；外部重命名、同路径替换及删除后的新名称、新元数据、后继或空态在观看态与网格态仅有 App 接线测试覆盖；网格未变修订不重复读取元数据亦仅有 App 接线测试覆盖；签名真机未验。 |
| INFO-03 | 拍摄参数、GPS、IPTC | Absent | 无 | P5-01 | — | 打开带 EXIF 的照片，Inspector 显示镜头、光圈、快门、GPS；没有这些数据的图不显示假值 |
| INFO-04 | Finder 标签 | Absent | 无 | P5-02 | — | 给图片设一个颜色标签，Finder 里看到同样的标签；按标签过滤只剩该标签的图 |

### 授权与文件访问

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| ACCESS-01 | 单文件打开后的目录授权入口 | Partial | 真机 | P0-04 | `Packages/PicseeKit/Sources/PicseeApplication/Access/FolderNavigation.swift`、`App/Access/FolderGrantPrompt.swift`、`App/CanvasWindowController.swift` | 在 sandbox 版本里只打开一张图，按 → 时提示授权所在目录，不会静默失败。限制：→/← 提示、面板授权、不匹配提示 @1x 真机通过（[记录](validation/P0.md#p0-04--p0-09授权与-session-真机验收811access-01--access-02--access-05--open-02--open-06--view-10--cmd-02--a11y-02mac-mini)）；rc.2 从 Finder 打开单张后按 → 提示授权、Esc 取消保留原图，@1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)）；AppKit 接线无单元 UI 证据。 |
| ACCESS-02 | 目录授权跨重启保留 | Partial | 真机 | P0-04、P2-01 | `Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/`、`App/Resources/Picsee.entitlements`、`docs/adr/0008-folder-access-read-only-app-scoped-bookmarks.md` | 授权一个目录，退出重开后直接可浏览，不再弹授权。限制：重启、跨签名重建、重复授权同根与重连后重启均 @1x 直接浏览（[P0](validation/P0.md#p0-04--p0-09授权与-session-真机验收811access-01--access-02--access-05--open-02--open-06--view-10--cmd-02--a11y-02mac-mini)、[P2](validation/P2.md#p2-01授权根存储重连与租约)）；损坏库仅单元；`com.apple.security.files.bookmarks.app-scope`，保持只读。rc.2（已含 #216 带 schemaVersion 的新存储格式）同一 bundle 重开后经「最近打开」直接浏览、不弹面板，@1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)）。 |
| ACCESS-03 | 失效授权的修复 | Partial | 单元 | P2-01、P2-08 | `Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/FileAccess.swift`、`Packages/PicseeKit/Sources/PicseeCore/Access/FileAccessPort.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessRecovery.swift`、`App/Access/AccessServices.swift`、`App/CanvasWindowController.swift` | 授权目录找不到（被删除或所在卷不可用）后打开最近项，提示重新连接；重新选择后恢复浏览。目录被移动或改名时，最近项直接在新位置浏览。限制：@1x 删除后弹 26 页重连、重选恢复同根、改名直接浏览（[记录](validation/P2.md#p2-01授权根存储重连与租约)）；#229 将重连提示换为恢复页后，签名 @1x 在「找不到」上见到恢复页（[记录](validation/P3.md#p2-08c-t7第-26-页失去访问-1x-真机验收)）；重选后进网格仅单元（P3-01）；同卷跨目录移动跟随仅实现者观察；卷不可用时浏览中进页 26 见 FOLDER-09，卷不可用后从最近项打开未验。 P2-08 授权根移址跟随 bookmark；单文件 File Grant 使用会话内 bookmark、失效后重连，不枚举父目录；真实 bookmark 与临时文件的单元覆盖同卷重命名与移入废纸篓；普通同名 `.Trash` 目录仍随 bookmark 打开；旧 inode 入废纸篓而原路径有可读新图时改读新图；编辑器将原文件改名为备份并在原路径写入新文件时继续显示备份（ADR-0011），仅单元；App 层对账读取或细节解码途中进入废纸篓时静默清图；对账读取途中移走时跟随，细节解码途中移走仍弹重连提示（未测）；直接移除或 bookmark 失效仍提示重连，由注入先后顺序的 App 测试覆盖（#273）；签名沙盒真机未验；跨卷废纸篓未测（ADR-0011）。 #230 按已捕获的根身份重新选择：匹配时恢复原子目录、当前项与排序筛选，不匹配时普通打开并保留原失效根，取消保持恢复页；以上自动测试覆盖，签名 @1x 仅验了匹配时重选回到原当前项（POSIX 拒绝路径，见 ACCESS-04），其余签名真机未验。 #231：已挂载卷的书签解析失败与系统废纸篓归「找不到」；启动、最近项、前台/唤醒与读者入口拒绝自动跟随废纸篓，普通同名 `.Trash` 不受影响；真实书签和 App 自动测试覆盖；签名 @1x 验了跨卷移动后书签解析失败归「找不到」（同上记录），其余签名真机未验。 #231：持久化重绑、保留目标 ID 的合并、相对路径最近项映射与精确 Undo 的数据层已由真实存储自动测试覆盖；新记入或浏览后更新的最近项保存可选的记录时根位置，重绑按该位置计算原相对路径，覆盖根两次移动后提升到原父目录的重叠路径及移动后新记入的相反情况；旧记录没有该字段时保留最后已知位置优先、再查会话内历史位置的回退行为，旧记录的重叠歧义无法还原；覆盖前台检查跟随改名后失联再重绑／合并；仅确认不存在的项移除，符号链接逃逸项保留原引用；App 接线及 Undo 仅自动测试；进程内写入失败时尝试恢复原存储字节，回滚失败无持久恢复记录，多文件写入不保证崩溃原子性；签名 @1x 重绑、精确撤销与保留目标 ID 的合并经容器存储只读核对（同上记录；重绑后根记录得到新 ID、数量不变），合并后撤销与重启恢复未验。 #231：页 26「找不到」提供「在新位置选择…」与「选择其他文件夹…」；重绑/合并后在网格上方持续显示可关闭的「已更新到…／撤销」，撤销恢复原根、最近项和原窗口失联位置；取消保持原页，其他文件夹按普通打开；显式选择废纸篓可浏览，启动、最近项与前台/唤醒检查仍拒绝自动打开。重绑与撤销失败会记录不含公开路径或书签数据的根 ID、阶段与错误类型并响铃一次，控件保留重试；成功与取消不响铃，以上由事务及 App 自动测试覆盖。上述流程与两尺寸浅深色布局、焦点/AX 为自动测试；签名构建 @1x 冒烟（文件夹移入废纸篓后回到前台进页 26「找不到」，在新位置选择后进网格并显示「已更新到…／撤销」，提示条在网格上方并随底栏更新保持，撤销后回到「找不到」）（见 [@1x 记录](validation/P3.md#p3-17a--p3-17b第-11-页浅色网格第-24-页读取文件夹-1x-对照)，运行 parity-281-fix6-10301941）；签名 @1x 跨卷移动后「在新位置选择…」重绑与撤销、「选择其他文件夹…」按普通打开、从最近项进页 26「找不到」再合并入已有根均通过（[记录](validation/P3.md#p2-08c-t7第-26-页失去访问-1x-真机验收)，运行 20261101-111926-i234）；@2x 未验；页 26 原生像素对照 FAIL（#354），重启后的持久化未复验。 #233：单文件非废纸篓失联进入重连时，在提示框前同步清掉画布、载入身份、窗口标题与代理图标、Inspector 及原生文件名 AX，并失效访问／输入代次、停 File Grant 监听；取消保持清空，过时重连回调不打开旧文件。真实临时文件 App 自动测试覆盖对账、前台、模拟唤醒、vnode 删除和解码先发现文件移除，包含预先挂起的对账返回、重选同文件／不同文件及旧文件重新出现后仍保留新选择；前台／模拟唤醒在原文件租约中实际读取一个字节，POSIX 拒绝不等于 TCC 撤权。重连面板仅选单个文件、从原目录开始，不提升为目录根；接受同／异文件仅验证共用续接方法，实际 powerbox 面板接受 NOT VERIFIED，待非实现者签名真机验证。WI-4：当前 File Grant 的 Inspector 失败与仍存在文件的载入失败，经原单文件租约实际读探查，确认拒绝或失联才进入同一清除／重连边界；可读损坏图保持普通解码错误，不自动重开或循环。Inspector 回调在代次／取消检查和错误状态映射之后执行；探查与对账均检查访问／输入代次，旧元数据、旧探查和旧对账在新输入尚未完成准入时返回，也不清屏、不取消新输入。实际新的 Inspector 读取／画布细节需求会获取当前输入代次，已开始的读取固定原回调上下文；拒绝其他输入后，原图仍能通过新读取发现失联。租约地址在实际打开前消失时先重解文件书签，同卷改名、普通 `.Trash` 与系统废纸篓仍分别跟随／静默清图；实际文件读取错误不当成普通解码错误忽略。以上由真实 POSIX／文件／ImageIO App 自动测试和回调时序单元测试覆盖。真正 TCC 撤权、物理睡眠唤醒与静默废纸篓路径的完整 AX 清除未验。#314 起提示条下方的网格延伸至底栏下（布局断言仅单元，签名真机未验）。 #354：恢复页「找不到」标题带实际文件夹名，说明使用第 26 页固定设计原文，中文分成两行且宽度不超过 460 pt；标题与目录名替换由真实临时目录 App 测试覆盖，说明由本地化字符串与原生行布局断言覆盖，签名真机未验。 #354：「找不到」图形改为虚线文件夹（32 pt 外框内约 26×26 pt 笔画），独立 SVG 的 Alpha 轮廓、虚线间隙和切换往返断言覆盖；签名真机未验。 |
| ACCESS-04 | 权限被撤销 | Partial | 单元 | P2-08、P2-08c | `App/Access/AccessMonitor.swift`、`App/Access/AccessServices.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessState.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/`（AccessCauseClassifier、FileAccess）、`Packages/PicseeKit/Sources/PicseeMacUI/States/LostAccessStateView.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift`、`Packages/PicseeKit/Tests/PicseeMacUITests/GridFooterLostEmptyStatusTests.swift` | 浏览中撤销目录访问，显示 26 页提示并可重新授权；不会从缓存里继续显示原图 限制：#230：根目录实际列出被拒时显示页 26「授权失效」与唯一按钮「重新选择文件夹…」，有卷证明的解析失败及系统废纸篓归「找不到」，其余解析或范围失败归原因未知（页面标题「无法访问此文件夹」）；访问、回到前台与唤醒时实际列出根目录；同根身份（卷 UUID＋inode 或书签身份）重选后回到原文件夹与当前项，不同身份按普通打开并保留原根失效；缓存权限错误不回退到内存或解码像素；以上自动测试覆盖。无窗口内引用时按书签内嵌身份回退（同目录或改名后恢复原根，不同目录或原路径新建目录按新根打开、原根仍失效）有 App 测试（#287）。签名构建 @1x：chmod 000 → 回到前台显示页 26「授权失效」与唯一按钮，按键后无网格、缩略图或图片像素 → 恢复权限后重选回到原当前项（[记录](validation/P3.md#p2-08c-t7第-26-页失去访问-1x-真机验收)，运行 20261101-111926-i234）；chmod 仅为 POSIX 拒绝，真正 sandbox/TCC 撤权未验证；@2x 未验；页 26 对照 FAIL（#354）。#232：当前失效文件夹在侧栏置灰并显示 ⚠ 与折叠展开符，不显示子目录或计数，保留已知父目录；四种原因、两窗口同步、恢复子树与计数、失效期间不枚举、选择不读取及原因 AX 文案仅单元/App 自动测试；签名 @1x 只见到卷未连接、授权失效、找不到三种原因的单窗口置灰行与 ⚠、› 及其 AX 值（同上记录），原因未知、两窗口同步与恢复子树计数签名真机未验，VoiceOver 未验。#332：页 26 底栏状态为「— 无法访问」，四种原因相同，侧栏切换后、撤销及选择其他文件夹／在新位置选择后取消读取回到页 26 后保持（失联侧栏行一并恢复），仅单元与 App 自动测试（英文界面）；中文界面与签名真机未验。 #354：恢复页标题改为「无法访问“<文件夹名>”」，保留侧栏「授权失效」文案和唯一重选按钮；真实临时目录 App 测试与本地化字符串断言覆盖。第 26 页失联底栏占位字形为「—」（U+2014），与读取、读取失败和空文件夹状态共用，仅自动测试；签名真机未验。 #354：「授权失效」图形改为带锁文件夹（32 pt 外框内约 26×26 pt 笔画），独立 SVG 的 Alpha 轮廓、锁体与锁环断言覆盖；签名真机未验。 |
| ACCESS-05 | 访问范围用完即释放 | Partial | 单元 | P0-04 | `Packages/PicseeKit/Sources/PicseeInfrastructure/FileAccess/FileAccess.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessImageSource.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageLoader.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Watching/WatchHub.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageIOInspectorMetadataReader.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Browser/SidebarFolderBrowser.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/FolderBrowser/SystemSidebarFolderEnumerator.swift` | 打开再关闭授权目录的窗口，诊断日志显示访问范围已释放（方法见 `docs/validation/P0.md`）。限制：关窗 `remaining=0 outcome=released` @1x 通过（[P0](validation/P0.md#p0-04--p0-09授权与-session-真机验收811access-01--access-02--access-05--open-02--open-06--view-10--cmd-02--a11y-02mac-mini)、[P1-04](validation/P1.md#p1-04渐进细节与位深资源上限)）；日志不分临时/租约；续租、P2-02 扫描租约、P2-04 递归取消/失败租约释放、P3-01 单图回网格短租约与 P2-05 元数据按需读取的逐图租约释放仅单元，网格窗口关窗未真机验；Inspector 逐次元数据读取的租约释放（P3-13）仅单元；P2-07 共享监听在有订阅期间持有该根的租约、最后一个订阅取消后释放，仅单元；关窗释放的真机记录早于 P2-07，有监听时未复验。单图 File Grant 的 vnode 描述符在租约内打开（P2-08，仅单元）。侧栏子目录枚举与计数的逐次租约释放、关窗与离开网格时的取消（P3-10 slice 3）仅单元。 |

### 缓存与资源

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| CACHE-01 | 内存占用有上限 | Partial | 单元 | P1-06、P3-06 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageMemoryCache.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/MemoryBudget.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/DecodeAdmission.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageIOPipeline.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/MemoryPressurePolicy.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ResourceSnapshotTracing.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/ImagePresentationPinning.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/PrefetchResuming.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageLoader.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridThumbnailScheduler.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridBrowserView.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessImageSource.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/ThumbnailCoverage.swift`、`App/PicseeApp.swift`、`App/UntestedResourceAdapters.swift` | 连续浏览 S2 三轮，内存不持续增长；两个窗口共用同一个上限（数据待 P3-08 记录于 `docs/validation/P3.md`）。限制：只衡量内存上限；Inspector 缩略图（240 px）经共用管线可见优先级准入，预算耗尽时等待，切图取消并拒绝迟到结果，编码仅释放已取得的钉住（#194，仅单元/App 回归，真机未验），磁盘缩略图已接线、见 CACHE-02。@1x 重开命中与截断图拒收已验（[P1 记录](validation/P1.md#p1-06内存成本与最小有界缓存)）；P3-06 共享账本（缓存、网格钉住与解码暂存同一上限，两窗口三轮无增长，压力停预取后恢复）、#161 按比例取尺寸、重叠修订一次复核、#122 迟到旧 pin/旧观察与取消票据仅单测，无 P3.md 数据；有效授权的钉住不因预算拒绝，可超出上限至多窗口所持缩略图；磁盘命中按边长的方形上界预约暂存，同一缩略图重钉只计一份像素；App 只有一个画布窗口，两窗口情形在当前构建中无法出现；预取、S2/压力与 #122 真机未验。 符合磁盘缓存条件的根授权缩略图同进程重开先复用驻留像素，按完整渲染键、源内容、载荷、授权和缓存 generation 复核后交付；未命中再走磁盘／新解码，共用既有预算与淘汰；内存结果在最后异步交接后再次检查 generation、授权与取消，临时钉住在拒绝或失败时平衡释放（#452，仅自动化，真机未验）。 |
| CACHE-02 | 缩略图磁盘缓存 | Partial | 单元 | P3-03、P3-04、P2-08 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ThumbnailDiskCache.swift`、`Packages/PicseeKit/Sources/PicseeCore/Identity/DurableThumbnailKey.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Access/AccessImageSource.swift`、`App/PicseeApp.swift`、`App/CanvasWindowController.swift` | 第二次打开同一目录，网格明显更快出图；手动删掉缓存目录后自动重建，原图不受影响；限制：查看器首预览及网格≤1024px 已接线，网格接线仅单元；查看器重开命中（据无源解码推断）及方向3/6、透明 @1x 已验（[P3](validation/P3.md#p3-03--p3-04磁盘缩略图缓存命中查看器路径)），余仅单元；写入失败后隔次重试、拒绝符号链接缓存目录与按 generation 拦截读取仅单元（见 CACHE-03）；网格重开加速、手删重建、跨进程崩溃、P3-05、@2x 未验（ADR-009）；P3-08 已测（[perf146rc2](validation/P3.md#运行-perf146rc2-20261104-2055v001-rc2-正式测量mac-mini-1x)，结论 inconclusive）。 P2-08 同路径替换时，内存像素按文件资源修订拒绝旧值，磁盘像素按修订与内容摘要拒绝，仅单元；签名真机未验。 符合条件的同进程重开顺序为内存→磁盘→原图新解码；内存命中仍读取源文件和载荷做不弱于磁盘命中的内容／有效性校验，同修订内容变化、撤权或清理代次变化拒绝旧证明；内存结果在最后异步交接后复核，清理代次变化按未命中回退，既有磁盘载荷租约读取语义不变（#452，仅自动化）。 |
| CACHE-03 | 清理缓存 | Partial | 单元 | P3-05、P3-07 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ThumbnailDiskCache.swift`、`Packages/PicseeKit/Sources/PicseeCore/Ports/CacheMaintenance.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Cache/CacheSettingsModel.swift`、`App/UI/SettingsPanelWindow.swift`、`App/PicseeApp.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`settings.menu`（⌘,） | 设置里显示缓存占用，点清理后占用归零，正在进行的旧任务不会把缓存重新写回；限制：实测占用、跨实例 generation、清理、写入失败降级及读 lease 延迟删除有自动化测试；写入失败后跳过下一次写入尝试，再于后续尝试重试，持续失败时继续隔次重试且原图仍可显示；设置在租约释放后刷新，删除失败显示本地化原因并可重试。新设置窗口的缓存分区显示占用并在确认后清理，取消与确认后的占用刷新仅自动化测试；设置窗口和菜单未做签名真机验收，@1x/@2x 均未验。缓存操作进行中清理按钮置灰、完成后恢复仅自动化测试。 |
| CACHE-04 | 本地诊断面板 | Partial | 单元 | P3-07 | `Packages/PicseeKit/Sources/PicseeCore/Ports/DiagnosticsProviding.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/PipelineDiagnostics.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageMemoryCache.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ThumbnailDiskCache.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/DecodeAdmission.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Diagnostics/DiagnosticsPanelModel.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Diagnostics/DiagnosticsPanelView.swift`、`App/UI/DiagnosticsWindow.swift`、`App/PicseeApp.swift`、`App/Commands/CommandMenu.swift`；菜单 ID：`diagnostics.menu`（Help › 诊断信息，无快捷键） | 打开诊断面板，看到本地的解码数、队列长度、缓存命中；不上传任何数据；限制：仅单元，尚无真机记录。面板显示内存预算（上限、钉住、可回收、解码暂存、峰值）、内存缓存与磁盘缩略图缓存的条目、大小和命中/未命中、解码队列的进行中/排队中数（含占用同一队列的磁盘缩略图读取）与已完成的源图解码数，读不到的值显示“未知”，只显示数量和大小、不显示路径；命中/未命中自本次启动起按每次已解析的查找累计，调用方随后取消或拒用结果不撤销计数；符合磁盘缓存条件的已授权文件夹缩略图与查看器图片（方向校正 SDR、第 0 帧、不超过 1024 像素）先查驻留内存，内容、授权与缓存 generation 验证后才计内存命中；未命中再读磁盘并计入磁盘缓存命中/未命中。超过 1024 像素、无文件夹授权的单文件或磁盘缓存未能准备的图片仍走普通内存路径；钉住像素计入内存条目和大小（#452）。面板在这两个分区下注明；磁盘“索引条目”“索引大小”是索引记录的当前版本缩略图行（不含索引文件和旧版本行），在 App 外删除的缩略图在读取修复前仍会计入，可能与设置里实测的占用不同，索引可读时最多每 10 秒重读一次（本缓存清理时立即重读）；读不到时，距上次成功读取不足 10 秒仍显示上次数值，之后每次刷新都重试并显示“未知”；四组数值分别读取，不是同一时刻；面板仅在可见时每秒刷新；分区标题为带名称标签的 VoiceOver 标题。面板窗口与菜单未做签名真机验收，@1x/@2x 均未验；菜单项位于“Help › 诊断信息”（`diagnostics.menu`），诊断窗口标题为“诊断信息”，仅单元；Window 菜单移除与 Help 菜单结构仅 App 单元。 |

### 命令与键盘

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| CMD-01 | 基础快捷键 | Partial | 单元 | P0-09、P6-09 | `Packages/PicseeKit/Sources/PicseeCore/Commands/`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/CommandRouter.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorEscapePolicy.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`App/Commands/CommandMenu.swift`、`App/CanvasWindowController.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ChromeWindowCommands.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Shortcuts/`、`App/UI/ShortcutWindow.swift`、`App/AppDelegate.swift`、`Packages/PicseeKit/Sources/PicseeApplication/EntryPoints/EntryPoint.swift`；菜单 ID：`command.preview.menu`、`command.enter.menu`、`command.zoomIn.menu`、`command.zoomOut.menu`、`command.actualPixels.menu`、`command.fit.menu`、`command.<id>.menu.alt.<n>`（隐藏的裸键备用项） | Space、←/→、Esc、Enter、0/1、+/−、⌘F、⌘O、⌘I 在菜单、按钮和键盘上触发的是同一个动作；未实现的不在菜单里显示快捷键。限制：preview/enter 接网格与菜单仅单元，search 的命令目录仅单元，⌘F 的网格 App 接线未验（查看态不可用）；既有菜单/按键与 ⌘W @1x 真机一致；现用工具按钮、新网格快捷键与焦点、Picsee › 设置…（⌘,）未验；按钮仅合成点击。Help › 键盘快捷键（`help.keyboard-shortcuts.menu`）可打开单实例三卡片只读窗口；⌘W 关闭、目录来源与中英文/浅深布局、键帽字形、行名与键帽居中、卡片副标题及其内边距仅单元和渲染断言，签名真机未验；Help 菜单结构与中英文 AX 仅单元，真机未验；报告问题见 CMD-06。View 菜单的缩放项现显示 ⌘+ / ⌘− / ⌘0（实际像素）/ ⌘9（适应），⌘= 同 ⌘+；裸 0/1/+/− 由隐藏菜单项保留查看器原路径；#349 起网格仅 ⌘+ / ⌘= / ⌘− 按 20 pt 调节缩略图大小（140–280），⌘0 重置为 220，⌘9 与裸键禁用；输入框聚焦时 ⌘ 缩放键交给输入框（CMD-02），仅单元与 App 测试（#348、#349），菜单中英文显示与真机按键未验；快捷键窗口与工具提示仍只列裸键。 |
| CMD-02 | 输入框和菜单优先 | Partial | 单元 | P0-09 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/CommandRouter.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorEscapePolicy.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`App/Commands/CommandMenu.swift`、`App/Commands/CommandWindow.swift` | 在搜索框里按 Space 或 ←，只编辑文字不翻图；菜单打开时按 Esc 只关菜单。限制：网格底栏搜索框见 GRID-07，DEBUG 预览搜索框不是已验路径；@1x 裸键证据来自已移除的 Inspector 占位字段（含打开目录后的 ←/→），网格搜索框中的裸键行为签名真机未验（见 GRID-07）；Edit 菜单与菜单 Esc @1x 真机通过；非画布窗口裸键未验；P3-01 改 Esc 顺序与 Space/Enter 预览后未复验。⌘+ / ⌘= / ⌘− / ⌘0 / ⌘9 在输入框聚焦时归输入框，菜单不缩放，按菜单项判定、不依赖键盘布局所报字符，其他 ⌘ 键仍走菜单（#348）；仅 App 测试，非美式布局与真实输入框中的 ⌘ 键真机未验。 |
| CMD-03 | 自定义快捷键 | Absent | 无 | P4-04 | — | 在设置里改一个快捷键，立即生效；与已有快捷键冲突时提示 |
| CMD-04 | 鼠标与触控板预设 | Absent | 无 | P4-04 | — | 切换滚轮为“翻图”或“缩放”，行为随之改变；不影响文本框里的选区和系统手势 |
| CMD-05 | 全局快捷键 | Absent | 无 | P7-09 | — | App 在后台时按全局快捷键，picsee 被唤到前台 |
| CMD-06 | 报告问题入口 | Partial | 单元 | P6-09 | `App/Commands/CommandMenu.swift`、`Packages/PicseeKit/Sources/PicseeApplication/EntryPoints/EntryPoint.swift`、`AppTests/ReleaseSurfaceTests.swift`、`App/UI/SettingsPanelWindow.swift`；菜单 ID：`help.report-issue.menu` | 在 Help 菜单选「报告问题…」，浏览器打开本仓库的新 issue 页面并带上 bug 模板。限制：Help 菜单项、设置 › 关于入口与共用 URL 仅自动化测试；签名真机打开浏览器未验。 |

### 窗口与桌面工具

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| WIN-01 | 多窗口 | Absent | 无 | P4-01 | — | 开 3 个查看窗口，菜单命令只作用于最前面的窗口；关掉一个不影响另一个窗口正在加载的同一张图 |
| WIN-02 | 窗口置顶与透明度 | Absent | 无 | P4-02 | — | 开启置顶后切到别的 App，picsee 窗口仍在最上层；透明度可调 |
| WIN-03 | 图片 pin | Absent | 无 | P4-02 | — | 把当前图钉到桌面，pin 窗口无边框、可缩放、可调阴影和透明度 |
| WIN-04 | 文本 pin | Absent | 无 | P4-02 | — | 复制一段文字后新建文本 pin，内容正确显示并可置顶 |
| WIN-05 | 幻灯片 | Absent | 无 | P4-05 | — | 开始幻灯片，按设置的间隔、循环或随机播放；可暂停和继续；解码慢时不会越积越多 |
| WIN-06 | 缩略导航图 | Absent | 无 | P4-06 | — | 放大长图时出现缩略导航图，点击可跳到对应位置；不放大时不出现 |
| WIN-07 | pin 跨重启保留 | Absent | 无 | P7-09 | — | 留着两个 pin 退出 App，重开后两个 pin 回到原位置 |

### 编辑与导出

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| EDIT-01 | 旋转与翻转 | Absent | 无 | P5-03 | — | 左转、右转、水平翻转、垂直翻转后画面正确；可以撤销和重做 |
| EDIT-02 | 裁剪 | Absent | 无 | P5-03 | — | 自由裁剪和固定比例裁剪；在旋转后的图上裁剪，导出结果与屏幕上的选框一致 |
| EDIT-03 | 导出另存 | Absent | 无 | P5-04 | — | 导出为 JPEG 或 PNG，可选尺寸和质量；透明 PNG 不变黑；选去除元数据后导出文件里没有 GPS；替换一个已存在的其他文件时取消或写入失败，旧文件保持完整；不能选源文件作为目标 |
| EDIT-04 | 复制图片、分享、打印、用其他 App 打开 | Absent | 无 | P5-05 | — | 复制图片后能粘贴到预览；系统分享面板、打印面板、“打开方式”菜单都能正常调出 |
| EDIT-05 | 移到废纸篓 | Absent | 无 | P5-06 | — | 删除一张图后它出现在废纸篓里；不存在永久删除选项 |
| EDIT-06 | 未保存编辑的提示 | Absent | 无 | P5-07 | — | 裁剪后不保存就切图或关窗口，提示保存、放弃或取消；选取消后编辑仍在 |

### 格式

格式行以 P6-01 的格式能力矩阵为准；未通过的格式从对外支持声明中删掉。

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| FMT-01 | JPEG、PNG、HEIC、TIFF | Partial | 单元 | P0-05、P6-01 | `Packages/PicseeKit/Sources/PicseeInfrastructure/Images/ImageIOPipeline.swift`、`Packages/PicseeKit/Sources/PicseeInfrastructure/Images/DecodeBudget.swift`、`Packages/PicseeKit/Sources/PicseeCore/Canvas/CanvasDecodePolicy.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerImageLoader.swift` | 打开 S1 素材里这四种格式，颜色、方向、透明都正确；限制：@1x 真机四种格式显示正确（目视，[记录](validation/P0.md#p0-0506解码真机验收9view-06--view-07--view-08--fmt-01mac-mini)）；S1 素材集未完整；颜色未测量；@2x 未验 |
| FMT-02 | GIF 动画 | Absent | 无 | P6-02 | — | 打开动画 GIF 正常播放；切走后停止播放、不再占用 CPU |
| FMT-03 | PDF 分页 | Absent | 无 | P6-02 | — | 打开多页 PDF，可以翻页，页码显示正确 |
| FMT-04 | 系统可读的 RAW | Absent | 无 | P6-03 | — | 打开 S4 里的 RAW 样本：能显示的标明是完整解码还是只显示内嵌预览；不能显示的给出明确提示 |
| FMT-05 | WebP、SVG、PSD 等扩展格式 | Absent | 无 | P6-01、P7-07 | — | 每种格式标明完整解码、只显示首帧或系统预览；SVG 里的脚本不会被执行 |
| FMT-06 | LibRaw 增强 RAW | Absent | 无 | P7-03 | — | 打开系统不支持的相机 RAW，按格式矩阵里声明的相机型号逐个通过 |
| FMT-07 | HDR 显示 | Absent | 无 | P7-04 | — | 在 HDR 屏上打开 HDR 照片显示高亮细节；拖到 SDR 屏后正常显示，不过曝 |
| FMT-08 | 超大图切片显示 | Absent | 无 | P7-08 | — | 打开超出分辨率上限的地图类大图，放大后逐步变清晰，内存不超过预算 |

### 可访问性与本地化

v0.0.1 起就是门槛，范围是 J1/J2 的页面（见计划 P3「MVP 还需检查」），P6-04 补全全部路径。

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| A11Y-01 | VoiceOver | Partial | 真机 | P3-10、P6-04 | `Packages/PicseeKit/Sources/PicseeMacUI/States/`、`Packages/PicseeKit/Sources/PicseeMacUI/Grid/`、`Packages/PicseeKit/Sources/PicseeMacUI/Chrome/ViewerChromeOverlay.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift`、`App/CanvasWindowController.swift` | 开 VoiceOver 走一遍打开→网格→大图→Inspector，每个控件都有正确的名称，隐藏的工具不被读出 限制：rc.2 @1x 打开→网格→大图各页控件名称已读出，静置隐藏工具后 AX 只剩图片（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)、[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)）；Inspector 一段未记录；英文未记录；朗读取自 VoiceOver 字幕面板（`last phrase` 返回 -1728）。 |
| A11Y-02 | 纯键盘操作 | Partial | 单元 | P0-09、P6-04 | `Packages/PicseeKit/Sources/PicseeApplication/Viewer/InspectorFocus.swift`、`Packages/PicseeKit/Sources/PicseeApplication/Viewer/ViewerSession.swift`、`App/CanvasWindowController.swift`、`App/Commands/CommandMenu.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Inspector/InspectorPanel.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift` | 不碰鼠标完成打开目录、选图、看大图、返回、打开 Inspector；焦点始终可见（28 页）。限制：网格键盘选图与 Esc 返回仅单元（P3-01）；读取态与网格中侧栏开关、宽度分隔条的 Tab 焦点仅单元（P3-10）；⌘O 选目录、空态按钮 Tab/Esc @1x 通过（[记录](validation/P1.md#p1-07空态加载失败取消菜单焦点与中英文本)），该记录是 B4 之前的空态，B4 首次打开按钮 Tab 与 Return rc.2 @1x 真机通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)），Esc 未记录；新 Inspector 关闭按钮焦点与 Esc 仅单元，失败态焦点环未验；网格、底栏、Inspector 关闭按钮的正反向 Tab 链（含无结果时清除按钮）仅单元；主菜单 ⌘I（快捷键与菜单项）在网格搜索编辑中保留搜索框编辑器与光标，仅 App 单元；侧栏子目录树行的 Tab 与方向键焦点仅单元（P3-10 slice 3）；空文件夹 22 页（FOLDER-08）的 Tab 焦点与焦点恢复仅单元；画布在按键把焦点移到画布时显示 2 pt 强调色环：Tab/Shift-Tab、工具或 Inspector 的 Esc、焦点在 Inspector 关闭按钮时按 ⌘I 关闭 Inspector；环已显示时，←/→（画布按键或主菜单键等价）在按键当时打开的相邻图保留该环，异步才开始的翻图（如首次需先建立文件夹扫描）不保留；Return/Space/Enter 开图、点击、程序化聚焦及网格/Finder/工具栏开图不显示，←/→ 未打开新图时也不会让之后的开图保留该环；浅深渲染与重绘调度单元，主菜单 ←/→、⌘I 与 Inspector Esc 的控制器路径 App 单元（#362），真机未验；签名真机未验；「读取失败」（24F-A，FOLDER-01）的「重试」焦点与 Return rc.2 @1x 真机通过（J1）；取消重试后回到「读取失败」的焦点恢复仅单元（#238）。 |
| A11Y-03 | 对比度与焦点不被遮挡 | Absent | 无 | P6-04 | — | 浅色和深色下文字与控件对比度符合 `design/DESIGN.md` 的目标；获得焦点的控件不被其他元素挡住 |
| A11Y-04 | 中英文界面 | Partial | 单元 | P1-07、P6-04、P6-09 | `App/Resources/Localizable.xcstrings`、`App/Commands/CommandMenu.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/Inspector/InspectorPanel.swift`、`Packages/PicseeKit/Sources/PicseeMacUI/States/`、`Packages/PicseeKit/Sources/PicseeMacUI/Shortcuts/`、`Packages/PicseeKit/Tests/PicseeMacUITests/ViewerLocalizationTests.swift` | 系统语言切到中文或英文，界面文字跟随变化，没有截断和未翻译的键名。限制：中文目录、空态/错误态局部布局与图标名称仅单元；侧栏“隐藏/显示/调整侧栏宽度”及设置窗口各分区（通用、显示、缓存、更新、关于；含缩略图缓存、清理缓存、缓存失败提示、「即将推出」标注）、网格缩略图失败占位「无法显示缩略图」及其 VoiceOver 标签中英文条目未上屏验证；Inspector 新字符串 en/zh-Hans 已入 catalog；侧栏失效文件夹的「Unavailable／无法访问」（#232）仅单元，屏上显示未验；新重连提示英文 “Choose File Again…” / “Choose this image again to reconnect access.” 与简体中文「重新选择文件…」/「请重新选择这张图片以恢复访问。」均未上屏验证；系统语言切换、中文签名像素未验；全界面截断检查待 P6-04。B4 首次打开的 3 条新文案（拖入提示、拖入时「松开即可打开」、⌘O）中英文条目已入 catalog，中文屏上显示已见（J1），截断未验；页 26 标题「找不到“<文件夹名>”」/“Can’t Find “%@””与「无法访问“<文件夹名>”」/“Unable to Access “%@””及找不到说明的中英文条目已入 catalog，屏上显示与截断未写入验证记录。诊断面板 19 个新字符串（17 个标签与 2 段说明）与“诊断信息”窗口标题的中英文屏上显示未验（P3-07）；Help、报告问题、键盘快捷键、收藏、最近、信息、显示与「即将推出」的中英文条目及菜单/入口 AX 仅单元，屏上显示与截断未验；快捷键窗口中英文目录文案与实际视图同一来源，屏上显示未验，中英文无截断、键帽字形完整、行名与键帽居中、卡片副标题完整及其内边距仅渲染断言；24F-A「没能读完…」、重试与选择其他文件夹…及底栏「读取未完成」的中文上屏已见（J1），英文未验（#238）。 rc.2/rc.3 zh-Hans 屏上文字：21/22/24/24F/26/网格/13/14/27/25 页通过（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)、[J2](validation/P3.md#j2-rc-acceptance-on-v001-rc2-240)、[J2 rc.3](validation/P3.md#j2-rc-acceptance-delta-on-v001-rc3-240)）；英文屏上显示未记录。 |

### 分发

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| DIST-01 | 签名与公证 | Partial | 真机 | P6-06 | `.github/workflows/release.yml` | 在另一台 Mac 上下载安装包后直接打开，Gatekeeper 不拦截；`spctl --assess` 通过；限制：发布工作流 `.github/workflows/release.yml`（#222）写好 Developer ID 签名、公证、staple 与 spctl 自检，rc.2、rc.3 已公证发布（rc.2 DMG 由运行 41951147247 产出），Mac mini 上 `spctl` accepted（[J1](validation/P3.md#j1-rc-acceptance-on-v001-rc2-239)、[J2 rc.3](validation/P3.md#j2-rc-acceptance-delta-on-v001-rc3-240)），另一台 Mac（MacBook）下载的 rc.3 经 codesign、`spctl`、stapler 接受（[@2x](validation/P3.md#2x-gate-on-v001-rc3-macbook-241)）；Gatekeeper 首次打开提示未记录。 |
| DIST-02 | 全新环境可用 | Absent | 无 | P6-05 | — | 新建一个 macOS 用户首次打开，没有旧授权和缓存也能正常使用；损坏的缓存数据库能自动恢复 |
| DIST-03 | 安装包内容干净 | Absent | 无 | P6-07 | — | 检查 `.app` 内容，没有 REA、研究素材、私人照片或开发路径；限制：`scripts/release/check-package.mjs` 在发布工作流里检查已签名的 `.app`（#222），目前只有单元测试、本机未签名 Release 构建，以及本机 Apple Development 签名的 stripped Release 通过 check-package 与 check-entitlements（非 Developer ID，不证明发布签名、公证或 Gatekeeper）验证过，rc.2 tag 已由发布运行 41951147247 真跑（[记录](validation/P3.md#运行-perf146rc2-20261104-2055v001-rc2-正式测量mac-mini-1x)）；该次 check-package 结果未写入验证记录。 |
| DIST-04 | 升级保留数据 | Absent | 无 | P6-08 | — | 用新版本覆盖旧版本，设置、收藏和目录授权都还在 |
| DIST-05 | 自动更新 | Partial | 单元 | P6-08 | `App/Updates/SparkleUpdatePort.swift`、`App/UI/SettingsPanelWindow.swift`、`App/Info.plist`、`App/Resources/Picsee.entitlements`、`scripts/release/check-entitlements.mjs`、`appcast.xml` | 有新版本时 App 提示更新，更新后签名校验通过；限制：真机未验。新增 entitlement `com.apple.security.network.client` 与 mach-lookup 临时例外 `<bundle id>-spks`/`<bundle id>-spki`（ADR-015），签名产物由 `check-entitlements.mjs` 核对，Developer ID 发布构建的核对已写进发布工作流（#222），v0.0.1 发布运行已执行（工作流成功，运行 42186493121）。设置窗口“更新”分区已接 Sparkle 2.10.0（#220）：自动检查开关、“立即检查”与“上次检查”经更新端口工作，仅用替身自动化验证；真机检查、安装与签名校验、第二次启动询问均未验证（#223）；更新器改为在首个主窗口显示后才启动，好让第二次启动的询问开在主窗口前面（#359），启动次序与只启动一次仅 App 自动测试与源码守卫覆盖，询问窗口的前后顺序真机未验，仓库根的 `appcast.xml` 已含 v0.0.1（1598）条目，由发布工作流开的 appcast PR 合入（#537）；“立即检查”读取该条目的真机行为未验证。“更新”分区“只为检查更新联系 GitHub”与“关于”分区“不收集数据、不上传图片”两段为静态文案，网络行为未验证；“关于”分区的隐私说明与源代码链接已启用，目标页面、焦点与中英文布局仅自动化检查，真机未验。 |
| DIST-06 | App 图标 | Partial | 无 | P1-10 | `App/Resources/Assets.xcassets/AppIcon.appiconset/`、`project.yml` | 在 Dock、访达（列表与图标视图）和 ⌘Tab 里看到 Lens 图标，浅色/深色下 16–512 pt 都清晰无白边。限制：@1x Dock 与访达列表/图标视图通过（[记录](validation/P1.md#p1-10app-图标)）；⌘Tab、浅色 Dock、@2x 未验；无 Icon Composer `.icon`。 |

### 增强

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| EXT-01 | 识别并复制图中文字 | Absent | 无 | P7-01 | — | 打开含文字的截图，选中文字复制，粘贴结果正确；缩放、旋转或翻图后选区不错位 |
| EXT-02 | 提取主体 | Absent | 无 | P7-02 | — | 对人像提取主体，复制后粘贴为带透明背景的图；换一张图后不会沿用上一张的结果 |
| EXT-03 | 跟随 Finder 排序 | Absent | 无 | P7-05 | — | 在 Finder 里手动排好顺序后用 picsee 打开该目录，翻图顺序与 Finder 一致；读不到时回到默认排序并提示 |

### 不做

这些是计划里明确不做或延期的事。移到这里的行保留原 ID，写明谁在什么时候决定的；以后要做，先改计划再挪回 Part 1。

| ID | 能力 | 决定 | 来源 |
|---|---|---|---|
| — | 覆盖原文件保存 | v1 不做，需先完成冲突检测和原子替换验证 | 计划 §7、[ADR-007](adr/0007-save-as-by-default-no-overwrite-in-v1.md) |
| — | GIF、PDF、RAW 的编辑写回 | v1 不做 | 计划 §7 |
| — | 永久删除、批量导出和批量删除 | 不做；基础多选不等于批量资产管理 | 计划 §1.0、§9 |
| — | Windows、iOS、账号、云同步、语义搜图、插件、复杂调色 | 不在计划内 | 计划 §9 |
| — | Pro、订阅、购买恢复 | 暂缓，付费模式未定 | 计划 §1.0 |
| — | 与 Picview 十种窗口模式逐项一致 | 不追求 | 计划 §6 |

---

## Part 2 — 环境差异

picsee 只支持 macOS，没有跨平台差异表，但同一能力在不同硬件和系统上可能表现不同。这里记录**只在部分环境验证过**的情况；表里没有的能力，默认指已在下表“基准”环境验证。

| 环境 | 基准 | 状态 |
|---|---|---|
| 显示器 | Mac mini 本地 1× 屏 + MacBook Retina @2x 屏（@2x 验收从 mini 经 SSH 执行） | Mac mini @1x 已测（P0-03、P0-09、P0-05/06）；MacBook @2x 已测（P0-03，本地运行）；经 SSH 的 @2x 未配置 |
| 系统 | macOS 14（最低部署版本）与当前正式版 | 建账时均未测 |
| 芯片 | Apple Silicon | Intel 为 `Unknown`，未验证前不声明支持 |
| 机器 | Mac mini（本地、唯一的本地真机测试机）与 MacBook（仅 @2x；经 SSH 时命令须进入其桌面启动的 tmux 会话） | Mac mini @1x 已测（P0-03、P0-09、P0-05/06）；MacBook @2x 已测（P0-03，本地运行）；经 SSH 的 @2x 未配置 |

某项能力在某个环境下行为不同，在本节加一行：`| <ID> | <环境> | <状态> | <差异与 validation 链接> |`。

## Part 3 — 区域审查

| 区域 | 最近审查 | 审查人 | 备注 |
|---|---|---|---|
| 打开与输入 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 查看与画布 | 2026-11-06 | doc-gardener | c812184..c45749c |
| C 沉浸界面 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 外观与显示偏好 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 文件夹浏览 | 2026-11-06 | doc-gardener | c812184..c45749c |
| Filmstrip | 2026-11-03 | doc-gardener | 4ca72f8..81e693b |
| 网格、选择与菜单 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 信息与元数据 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 授权与文件访问 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 缓存与资源 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 命令与键盘 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 窗口与桌面工具 | 2026-10-22 | doc-gardener | 历史复核见 git log -p -- docs/feature-ledger.md |
| 编辑与导出 | 2026-10-22 | doc-gardener | 历史复核见 git log -p -- docs/feature-ledger.md |
| 格式 | 2026-11-01 | doc-gardener | 7bcea16..b393b22 |
| 可访问性与本地化 | 2026-11-06 | doc-gardener | c812184..c45749c |
| 分发 | 2026-11-02 | doc-gardener | d069b65..c202172 |
| 增强 | 2026-10-21 | 建账 | 历史复核见 git log -p -- docs/feature-ledger.md |

### 2026-10-21 建账

依据开发计划 v0.2 的 P0–P7 工作包、1.0 节功能对应表和 1.3 节 20 页 mockup 映射，逐项建行。

这次没有检查什么：没有对照 Picview 实际运行逐项核对（Picview 功能见 `docs/PICVIEW_FEATURES.md`，只是静态资源证据）；没有对照 FastStone 调研报告补行；没有用户可见能力的工作包不单独建行：P0-01、P0-02、P0-06、P0-07（工程与技术验证）、P0-08（原生设计映射，体现在各 UI 行）、P1-01（身份与错误模型）、P3-08（规模验证，结果进 `docs/validation/P3.md`）。

### 2026-10-24 #92 已交付 UI 对照（c9504fe..94f67c2）

复核打开、画布、沉浸工具、偏好、文件夹读取、命令与本地化区域；六条 UI 行仅更新限制，状态与验收未变。A11Y-04 的中文证据说明需 owner 修正。

这次没有检查什么：未运行测试、构建或 App，未复测原始像素与交互；设备记录只覆盖其中列出的 @1x 入口，不代表整行验收通过。

### 2026-10-24 #58 缓存观察冲突审查

范围 `f478834..271e579`：VIEW-09、CACHE-01 仅追加限制与测试说明，仍为 `Partial` / `单元`；验收前缀保持不变。两行单元格分别约 392、234 字，需 owner 压缩限制，不能删去尚未验证的入口或条件。VIEW-06、VIEW-07、FMT-01 因管线路径被映射，但对应方向、透明和格式行为未改；引用的 P0/P1 记录仍存在。

这次没有检查什么：未运行测试、App 构建或真机；未读取审计报告或 PR 评论；未验证性能、内存压力、S2／两窗口及 @2x；生成器同步检查不代表行为验收。

### 2026-10-24 #58 限制缩写复核

范围 `f478834..2d1cfd0`：owner 仅压缩 VIEW-09、CACHE-01 的限制，分别约 170、163 个可见字符（两句、三句）；原提议已解决。两行仍 `Partial` / `单元`，验收前缀与既有证据链接不变；自然时序不可稳定复现、@2x、标题/Inspector 仅文件名、一次重试及清理、仅内存缓存、压力/S2/两窗口和本修复真机未验均保留。实现代码相对 `271e579` 未变，HTML 同步检查通过。

这次没有检查什么：未运行测试、构建或真机，未读取审计材料；不把限制缩写视作新增行为证据。

### 2026-10-24 #58 在最新 main 上复核（430e2a2..9a230ce）

VIEW-09、CACHE-01 的限制与当前代码和回归测试范围一致，状态/验证仍为 Partial/单元；逐提交核对验收前缀未变。VIEW-06、VIEW-07、FMT-01 因 ImageIOPipeline 路径映射纳入，方向、透明与格式行为未改；既有 P0/P1 验证链接存在并包含对应 ID。未发现新增的命令、菜单、偏好、entitlement 或 UTType 声明；没有能力升级。

这次没有检查什么：未运行测试、App 构建或真机，未读取审计报告或 PR 评论；不把源码与回归测试阅读视为运行通过证据，@2x、性能、压力/S2/两窗口及本修复真机仍未验。

### 2026-10-24 P2-03 在最新 main 上复核（d26e164..057462f）

FOLDER-02/03 的状态与验证仅升至 Partial/单元，逐提交核对验收前缀未变；OPEN-05、VIEW-10、FOLDER-01 的限制已对应过滤、同输入 Retry 与首图呈现的代码边界。新增目录菜单标识均在对应行中，涉及路径及既有验证链接有效，未发现 Shipped/真机升级。OPEN-05 合并现有 UI 证据后约 202 个可见字符，提议 owner 只压缩限制，保留验收、P1/#92 链接、JPEG/加载中未验以及 P2-03 原生组合未验。

这次没有检查什么：未运行测试、构建或 App，未读取审计报告或 PR 评论；未创建真机、性能、菜单/Retry/焦点、中文签名像素或 @1x/@2x 验收证据，源码与测试阅读不构成运行通过。

### 2026-10-24 P2-03 OPEN-05 限制压缩复核

owner 仅压缩 OPEN-05 的限制文本，全文约 165 个可见字符、两句；验收前缀、Partial/单元状态和代码路径未变。P3-01 网格/Esc、@1x 三类错误及重试的截断 PNG 证据、#92 构图/窄窗链接、截断 JPEG 与加载中未验，以及过滤后下一张、扫描中/后同图重试保留条件/权限仅单元和原生组合未验均保留；前轮长度提议已解决。

这次没有检查什么：未运行测试、构建或 App，未读取审计报告或 PR 评论；本次仅复核限制压缩与生成视图，不新增行为或真机验收证据。

### 2026-10-24 P3-03 磁盘缩略图缓存审查（00a5c6d..4e2685e）

本地 main 落后，本轮使用 origin/main 的 merge-base 00a5c6d。CACHE-02 的 Partial/单元升级未改原验收；没有 Shipped/真机升级，也未新增命令、菜单、偏好、entitlement 或 UTType 声明。原有路径与涉及的 P0/P1 记录有效；owner 须修正 CACHE-01 的无磁盘缓存声明，并压缩 CACHE-02 与 VIEW-08 的限制文本，验收及未验边界不得删减。ACCESS-04 仍 Absent，不能以租约拒绝单测代替运行中撤权验收。

这次没有检查什么：未运行测试、App 构建或真机，未读取审计报告或 PR 评论；源码与测试阅读不构成执行通过证据，未验网格接线、手删缓存重建、签名 sandbox 撤权、压力/S2/两窗口、性能及 @1x/@2x。HTML 同步检查不代表能力验收。

### 2026-10-24 P3-03 限制修订复核

复核 00a5c6d..4e2685e 及 owner 工作区修订：VIEW-08、CACHE-01、CACHE-02 的验收前缀逐字节不变，三行分别约 145、151、169 个可见字符，均不超过三句。CACHE-01 不再声称无磁盘缓存；CACHE-02 保留有限适用范围、仅单元和网格/手删重建/P3-04/05/08/签名真机未验，详细边界仍见 ADR-009。前轮三项提议均已解决；本次不升级状态或验证等级。

这次没有检查什么：未运行测试、构建或 App，未读取审计报告或 PR 评论；仅复核账簿工作区修订和 HTML 同步，不新增行为、性能或真机证据。

### 2026-10-30 #230 P2-08c T3 复核（5d3855ac..2baf12e，rerun）

2baf12e 按上一轮提议改账簿：ACCESS-04 由 Absent 改为 Partial/单元，「怎么确认」的验收前缀与基线逐字相同，限制为事实；FOLDER-09 与 A11Y-04 的限制已对应更新。复核 3516e14、e70825a、6c56f87 的源码：根目录实际列出被拒归为「授权失效」（AccessMonitor、AccessCauseClassifier），页 26 的唯一按钮为「重新选择文件夹…」，重选按根身份恢复原位置或普通打开并保留原根失效，与 ACCESS-03、ACCESS-04、FOLDER-09 的限制一致；ACCESS-05 的范围释放日志未改。提议（owner）：ACCESS-04 的限制补写「真机未验」（验证为单元时的既有规则，见「验证」一节）。

这次没有检查什么：未运行测试、构建或 App；未读取审计报告或 PR 评论；签名构建上的 chmod 冒烟与真实 sandbox/TCC 撤权没有验证记录，未在真机上检查。

### 2026-10-30 #202 首次打开 B4 散落相纸（c3584cc..61ab623，gardener pr）

OPEN-01、OPEN-04、OPEN-08 的限制随 B4 改动更新，「怎么确认」未改，OPEN-01、OPEN-04 状态未变；OPEN-08 由 Absent 改为 Partial/单元，有 FirstLaunch 三个测试文件（@Test 共 20 个）支撑。B4 只替换冷启动空态（`ViewerStateHost` 的 `.empty` 分支），错误态布局（OPEN-05）与空目录页（FOLDER-08）路径未变。路径触及但没有可见变化的行（`CanvasWindowController.swift` 只接线首次打开拖入高亮）：OPEN-05、OPEN-06、VIEW-05/09、CHROME-01/02/03、PREF-02、GRID-01/02/04/06/07/08、FOLDER-01/04/06/07/08/09、INFO-01、ACCESS-04、CACHE-02、CMD-01、A11Y-02（A11Y-02 另见提议）。

提议（owner 处理）：
- OPEN-08「在哪」补 `Packages/PicseeKit/Sources/PicseeMacUI/B4Samples/`（六张内置样图与 Package.swift 资源声明）与 `Packages/PicseeKit/Sources/PicseeMacUI/Input/ViewerDropView.swift`（拖入高亮回调）。证据：`Packages/PicseeKit/Package.swift`、提交 3248c41、8656334。
- A11Y-02 限制中「空态按钮 Tab/Esc @1x 通过」指 B4 之前的空态（P1-07 记录），B4 冷启动按钮的 Tab/Esc 未验。证据：`ViewerStateHost.swift` 的 `.empty` 分支改为 `FirstLaunchView` 内的按钮。
- OPEN-04 限制「相纸淡出」与代码及计划 P3-16 不一致：实际是淡到原不透明度的 40%（`FirstLaunchView.swift`、计划 P3-16）。

这次没有检查什么：未运行测试、构建或 App，未做真机或签名对照；未核对 B4 样图的 SHA-256 与授权；未读取审计报告或 PR 评论；B4 按钮的键盘焦点与 VoiceOver 路径只做了代码阅读，未实走。

### 2026-10-30 #202 首次打开 B4 散落相纸 复跑（c3584cc..fb21e36，gardener pr）

owner 的三处提议已核对：OPEN-08「在哪」补的 `B4Samples/` 与 `Input/ViewerDropView.swift` 路径存在；OPEN-04 限制「淡到原不透明度的 40%」与 `FirstLaunchView.swift` 的 targetAlpha 一致（浅色 0.3、深色 0.4，拖入时乘 0.4）；A11Y-02 的 B4 空态 Tab/Esc 只记单元，与 `ViewerStateHost.swift` 的 `.empty` 分支（`state.open` 位于 `FirstLaunchView`）一致。范围内 OPEN-01、OPEN-04、OPEN-08 的「怎么确认」前缀与引入前相同；OPEN-08 的状态升级提交 b306409e 未改验收。失败态布局（OPEN-05）与空目录页（FOLDER-08，`.emptyFolder` 另行绘制）未变；非失败的加载、无结果、缩小细节态的提示行改为堆叠在按钮上方，这些状态的行没有真机声称。

提议（owner 处理）：
- OPEN-01「怎么确认」的「显示 21 页空态」与计划 P3-16「替换 21 页外观，OPEN-01 行为不变」不一致；改写验收需单独提交并引用计划或用户原话。
- OPEN-04 限制补「降低透明度时拖入相纸隐藏」（代码中 `reduceTransparency && dragActive` 时 alpha 为 0）。
- A11Y-04 限制补 B4 首次打开的中英文文案未上屏。

这次没有检查什么：未运行测试、构建或 App；未核对 B4 样图的 SHA-256 与授权；未读取审计报告或 PR 评论；底部搜索、排序等禁用态在 B4 下的实际显示只做了阅读，未核对；未检查 `ViewerStateHost.layout()` 对标签少于三个的状态的索引行为。

### 2026-10-30 #202 首次打开 B4 散落相纸 第三次复跑（c3584cc..b5c8de1，gardener pr）

OPEN-01、OPEN-04、OPEN-08、A11Y-02、A11Y-04 的「怎么确认」验收前缀与 c3584cc 相同；OPEN-08 由 Absent 升为 Partial/单元（b306409e）时未改验收。范围内没有 真机 或 Shipped 升级，`docs/validation/` 未变，没有自证项。`node scripts/ledger/build.mjs --check` 在 b5c8de1 通过。

路径命中但没有可见变化的行（`CanvasWindowController.swift` 只接线首次打开的拖入高亮）：OPEN-06、VIEW-05/09、CHROME-01/02/03、PREF-02、FOLDER-01/04/06/07/09、GRID-01…08、GRID-14、INFO-01/02、ACCESS-01/03/04/05、CACHE-02、CMD-01。`ViewerStateHost.swift` 的失败态几何与 AX 子树不变（OPEN-05），空目录页由 `EmptyFolderStateView` 绘制（FOLDER-08）。加载、读取中、无匹配、缩小细节态改为提示行堆叠在按钮上方，相应行的限制已写明仅单元或 FAIL（GRID-07、FOLDER-05、A11Y-02），无需改动；「正在显示较低细节」没有行命名它。

提议（owner 处理）：
- OPEN-01 限制：c3584cc 版限制中的「加载/取消未验」「中文像素未验」「真冷启动未验」在本次改写中被删去，但 B4 的加载/取消（非失败态布局已改）、中文上屏与签名真机记录仍未有。建议补回这些未验项；「怎么确认」前缀不动（21 页验收按 owner 决定保留）。证据：`Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift` 的 layout()，`git show c3584cc4:docs/feature-ledger.md`。
- OPEN-08 限制：验收「拖入时相纸淡到原不透明度的 40%」在开启「降低透明度」时不成立，代码在该设置下拖入期间把相纸设为透明（`FirstLaunchView.swift` 的 targetAlpha，`reduceTransparency && dragActive ? 0`），计划 P3-16 没有此例外。建议在 OPEN-08 限制里点名，与 OPEN-04 的限制一致。
- A11Y-04 限制：「B4 首次打开的 6 条新文案（拖入提示、⌘O、三个格式标签）」实际只列出 5 条；第 6 条是拖入时的标题「松开即可打开」（`FirstLaunchView.swift` 的 refreshStyle；catalog 已有 en 与 zh-Hans）。建议补上。

这次没有检查什么：未运行测试、构建或 App，未做真机或签名对照；未核对 B4 样图的 SHA-256 与授权；未读取审计报告或 PR 评论；降低透明度的行为只读了代码，未实走。

### 2026-10-30 #202 首次打开 B4 散落相纸 第四次复跑（c3584cc..cfa1830，gardener pr）

owner 在 b5c8de1 之后的三处编辑已核对：OPEN-01 限制恢复了真冷启动、中文像素、加载/取消未验，并注明 P1-07 与 #92 记录早于 B4；OPEN-08 限制点名「降低透明度」拖入时相纸隐藏；A11Y-04 列出「松开即可打开」为第六条新文案，catalog 中 en 与 zh-Hans 齐全（B4 新增 6 个键，与限制一致）。OPEN-01、OPEN-04、OPEN-08、A11Y-02、A11Y-04 的「怎么确认」验收前缀与 c3584cc 相同；OPEN-08 的 Absent→Partial 升级（b306409e）未改验收，只在验收句与「限制：」之间多一个空格。范围内没有真机或 Shipped 升级，`docs/validation/` 未变，无自证项。`node scripts/ledger/build.mjs --check` 在 cfa1830 通过。

提议（owner 处理）：
- OPEN-08 限制：「计划 P3-16 未写此例外」不成立。计划 P3-16（`docs/PICSEE_DEVELOPMENT_PLAN.md` 第 262 行）写明「降低透明度（拖入时隐藏相纸）」，与代码（`FirstLaunchView.swift` 的 targetAlpha，`reduceTransparency && dragActive ? 0`）一致。上一轮 gardener 提议的「计划没有此例外」是错误的，建议改写为与计划一致。
- OPEN-08 限制：计划 P3-16 同行还写明「减弱动态效果（即时变暗、无淡化与展开）」。代码中 `FirstLaunchView.swift` 的 `expanded = dragActive && !reduceMotion` 使开启「减少动态效果」时中央照片不展开，而验收句写「中央照片展开」。建议在限制里点名，与计划一致。

路径命中但没有可见变化的行，与上一节相同（CanvasWindowController 只接线首次打开的拖入回调；ViewerStateHost 的失败态几何与 AX 子树不变，OPEN-05；空目录页由 EmptyFolderStateView 绘制，FOLDER-08；非空态的 composeState 仍只用于失败态）。Part 3 区域行已是 2026-10-30 doc-gardener，本次只追加备注。

这次没有检查什么：未运行测试、构建或 App，未做真机或签名对照，未实走减少动态效果与降低透明度；未核对 B4 样图的 SHA-256 与授权；未读取审计报告或 PR 评论；未判断 B4 样图进入 .app 是否影响 DIST-03（该行的在哪为 —，不属于本次触及的行）。

### 2026-10-30 #298 侧栏监听先订阅后读取（test/sidebar-watch-flake-298，140244b..22efc2d，gardener pr）

GRID-14 的限制随 fc4bd15、5e7d2c2、c457483、22efc2d 增补「侧栏刷新先安装替换监听再进行权威读取，交接及读取期间的外部变化会触发后续刷新，仅单元/App 测试覆盖（#298）」；「怎么确认」、状态（Partial）与验证（单元）未变，没有升级。代码与该限制一致：`loadSidebarTree` 在 `SidebarFolderLoadSession.start` 之前订阅，替换完成后才取消旧订阅。FOLDER-07 的 ID 因提交说明中的 P2-07 被映射，改动只在侧栏子目录树，判为无可见变化。路径触及但无可见变化的行（`CanvasWindowController.swift` 只改侧栏分支）：OPEN-01/04/05/06、VIEW-05/09、CHROME-01/02/03、PREF-02、FOLDER-01/04/06/08/09、GRID-01…08、INFO-01/02、ACCESS-01/03/05、CACHE-02、CMD-01、A11Y-02；ACCESS-04 因 `AccessServices` 的类型放宽无变化。`docs/validation/` 未变，没有真机或 Shipped 升级，没有自证项。`node scripts/ledger/build.mjs --check` 在 22efc2d 通过。

这次没有检查什么：未运行测试、构建或 App，未做真机或签名对照；侧栏外部变化的时序只从代码阅读确认，未实走 Finder 改动；未读取审计报告或 PR 评论；`.claude/tdd-guardian/tests-20261030-i298-fix1.md` 是流程记录，不属于账簿。

## 参考做法

- Anthropic，[Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)：一开始就写出完整功能列表、全部标为未通过；每项带测试步骤；agent 只能改“是否通过”，不能删改测试；必须端到端验证后才能标为通过。对应本账簿的「先写好的验收」和「防止验收被悄悄放宽」。
- OpenAI，[Harness engineering](https://openai.com/index/harness-engineering/)：仓库里的文档是唯一可信的来源；AGENTS.md 只做目录，指向更深的文档；有一份按产品区域和架构层打分、跟踪缺口的质量文档，以及定期扫描过时文档的 doc-gardening agent。对应「区域审查」，以及 AGENTS.md 只链接本账簿、不复制内容。
- OpenAI Cookbook，[Using PLANS.md](https://developers.openai.com/cookbook/articles/codex_exec_plans)：计划是活文档，写给对项目毫无了解的读者。对应「怎么确认」必须是任何人都能照着做的操作。
- Google SRE，[Reliable Product Launches](https://sre.google/sre-book/reliable-product-launches/) 与 [Launch Coordination Checklist](https://sre.google/sre-book/launch-checklist/)：用户可见的变化都算发布；清单里每一项都要能说明为什么需要，每条操作都要具体可行；清单定期复审。对应「维护」和「发布门槛怎么读」。
- Meta，[Holistic Configuration Management at Facebook](https://blog.acolyer.org/2015/10/16/holistic-configuration-management-at-facebook/)（SOSP 2015）：新代码先以关闭状态上线，用 Gatekeeper 逐步放开；配置当作代码，由校验器自动检查不变量。对应「功能开关后面的能力」和门禁的机器检查。
- NASA 系统工程的需求验证矩阵（[NASA NTRS](https://ntrs.nasa.gov/api/citations/20160003166/downloads/20160003166.pdf)）：每条需求标明验证方法（测试、分析、检查、演示）。对应「验证」列。SpaceX 的“每条需求都要带上提出它的人的名字”（Isaacson《Elon Musk》）对应「计划」列：每行都能追溯到工作包和背后的用户决定。没有找到 SpaceX 公开的需求矩阵原文。
- mdpro 的 `docs/feature-ledger.md`：五值状态、`Partial` 必须写限制、路径从仓库根写、同一次提交更新行，都沿用；单元格长成修复史的问题，用 150 字上限和 validation 链接避免。
