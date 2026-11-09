# UI 工作包的 C 设计对照契约

本规程用于任何新增或改变原生 UI 的工作包。目的：让 `design/` 中已确认的 C · Quiet Image Canvas 规则成为可追溯的实现输入，并让「与 HTML 一致」有明确的状态、尺寸和证据范围。纯内部改动在 brief 中写 `无 UI 变化` 即可。

## 依据与范围

- 视觉和交互方向以用户决定及 [`design/DESIGN.md`](../../design/DESIGN.md) 为准；**具体状态的布局、内容、显隐和交互目标是该状态在 `design/prototypes/picsee-browser/states/` 中的 HTML**。SwiftUI/AppKit 的颜色、points/backing pixels、组件和系统边界按[原生映射](../../design/picsee-ui-system/native/README.md)。若原型与设计规范冲突，先修设计源并取得该设计变更所需的用户决定，再改原生实现；不在 Swift 里悄悄创造例外。
- 20 个正式状态的唯一目录是 [`states/manifest.json`](../../design/prototypes/picsee-browser/states/manifest.json)。开发计划 [§1.3](../PICSEE_DEVELOPMENT_PLAN.md) 决定每页归属的工作包；[功能账簿](../feature-ledger.md)决定当前实现状态及「怎么确认」。`viewer-v2.html` 只提供已写出的交互参考。HTML 中的按钮、示例文件名或静态蓝框不证明原生功能、权限或可访问性已实现。
- 原生系统标题栏、菜单、字体栅格化、真实文件内容等按原生映射处理。每个与 HTML 不同的选择都在 brief 的「原生例外」列写具体元素、依据和预期结果；原生映射没有规定的差异，应先修设计或实现，不把它事后称为系统例外。

## #502 · 原生系统焦点环边界

Owner 于 2026-11-04 选择「Native exception (Recommended)」：App 的原生控件默认使用 macOS 系统焦点环，第 24 页读取、24F 读取失败和第 26 页访问恢复均保留系统环。HTML 的 2 pt 方形强调色环及主按钮双环属于网页表现，不要求 App 复制；对应映射见 [原生设计规范](../../design/picsee-ui-system/native/README.md#502--系统焦点环的原生边界)。

审查时，环的样式差异不计为 FAIL；焦点位置仍按具体状态验收。初始焦点必须落在规定动作，Tab / Shift-Tab 必须移到正确控件，焦点必须可见且键盘可达。不能用这一原生边界豁免错误的焦点位置、焦点丢失或导航问题。

## 实现 brief 必填

### P2-05 原生例外：元数据排序状态

`#108` 的按需元数据排序没有对应的 HTML 状态页。网格与单图查看器都在画布右侧以 12 pt 次要文字显示非阻塞状态：读取中为“排序未完成”，读完仍有缺失或读取失败的值为“部分排序元数据无法读取”；状态不遮挡点击目标。网格状态距右侧 20 pt、底部 12 pt；查看器避开底部工具组，状态位于其上方。背景跟随画布浅/深色。此条仅固定原生增量的预期，签名真机、中文与 @2x 对照仍待批次验收。

按一个可达原生状态对应一个 HTML 状态写表；同一页面的浅/深、隐藏/显示、宽/窄分别列行。暂未实现的状态应标明所属后续工作包并记为 `PENDING`，不得计入本轮通过数。

| 字段 | 必填内容 |
|---|---|
| 归属 | issue、工作包、账簿 ID、计划 §1.3 页号及 manifest `name`；状态是已实现、部分可达还是待本工作包实现 |
| 设计输入 | HTML 相对路径、manifest 中的视口宽高；从所选设计状态另行确定并固定浅色/深色外观（manifest 没有 appearance 字段）；设计 tree OID、HTML 与 manifest 的 SHA256；引用的 token/组件规范版本或路径 |
| 原生入口 | 用真实菜单、按键、拖入、文件或偏好抵达状态的步骤；固定素材与可重建的初始条件；对应语言、窗口大小、backing scale |
| 原生例外 | 元素、设计/原生映射依据、允许的差异和用户可观察的结果；没有则写 `无` |
| 验收 | 布局区域、几何/间距、字体/颜色/图标、显隐/选中/错误态、键盘/焦点/辅助技术/中英文；每项对应测试或真机步骤 |

在 brief 发出前固定设计源的 Git SHA 与上述哈希；实现中设计源改变就重写受影响的行和参考截图，不沿用旧截图。预期几何偏差、比较区域和动态数据遮罩必须在取图前约定；不得看见差异后才扩大容差或遮罩。

#347（后续 #349/#351）固定映射，owner「A A C」（2026-11-03）；以下规则与状态稿 README 同步：

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


14/16/33 的 token 与规则全在 SHA 固定的 HTML inline style 内，不再依赖外链。canonical token 为 `design/picsee-ui-system/tokens/viewer-grid.css`，与 `_ds` 和各页 `data-viewer-grid-tokens` 同步。13/25/27/28/34 的 solid-tools 填充已被本映射取代，#351 不得选它们作为工具填充 oracle；33 计数的色/halo 更新，其余胶片条面板与布局不变。原生材质按 #346 使用平台 blur；自动对比度按 glyph ≥3:1、计数/缩放文字 ≥4.5:1 与 halo 验证，设备另验。

## 对照与审计

1. 使用相同 manifest 视口、外观、语言和确定性素材，在 HTTP 预览里渲染 HTML；在**签名且 sandbox 开启**的 App 中经真实入口到达同一状态。按 `$macos-device-test` 先查并取得共享 GUI 锁，记录 App 完整 SHA、签名、设备/macOS、窗口 bounds、backing scale、设计 tree OID、HTML/manifest 哈希和运行 ID。窗口原图、网页原图、日志与比对图保存在 `~/.picsee/device-runs/<run-id>/`，不进公开仓库。
2. 独立于实现者的验收者以窗口截图的同一坐标系对照。逐区域报告位置和尺寸（points 与 backing pixels 分开）、边距/层级、文字裁切与字体、颜色/对比、图标和可见状态；注明测量位置、实际值、设计值和偏差。系统边界按 brief 中预先列出的例外判断。只能遮住已列明且会变化的照片/文件数据，不能遮住控件或文字缺失。
3. 静态像素之外，用 App 真正操作 Space/方向键/Esc、菜单、窗口缩放、浅深切换、焦点/Tab、可访问性、中文和错误恢复等本工作包相关入口。浏览器截图、单元测试和 `@1x` 通过都不能替代另一个入口或 `@2x`。未实现状态标 `PENDING`；未捕获的尺寸、主题、语言、设备或动作逐项写 `NOT VERIFIED` 和原因。
4. 当前独立审计者（2026-10-25 起 gpt-auditor 与 opus-auditor 双审，见 roster 计划）对原始截图、构建输入和行为记录作独立审查，按严重度列出差异和复现步骤。修复后，delegator 安排指定的独立设备验收角色在共享 GUI 锁下重建签名 App、重拍受影响状态并交付新原图和准确的修复版 SHA；审计者 只审核该批原图、记录与 SHA，不操作 App。缺少重拍证据的状态保持 `NOT VERIFIED`。轮次完成只说明交付范围内的结论，不自动代表 20 页全通过。PR 列出已比对、待实现和未验证的状态及仍开放发现。
5. 设备验证记录按[功能验收指南](../guide/feature-verification-guide.md)单独提交。账簿状态由 owner 按每行「怎么确认」及真机证据决定；视觉相似、HTML 渲染或静态审计本身都不能把一行升为 `Shipped`，也不能删减验收入口。

## UI 验收节奏：PR 自动门禁 + 批次真机

用户 2026-10-25 决定（选项原文）：「分层：PR 自动测 + 批次真机」。每个 UI PR 不再单独跑签名真机对照；真机像素与行为对照按批次做，v0.0.1 发版前（#147）再全量做一次。

用户 2026-10-27 补充（原文）：「for item1, do a one-flow device smoke test of the changed path before merging, and keep the full parity run in batches.」因此每个改变用户可见行为的 PR 合入前另做一次**变更路径真机冒烟**（下文，#175）；与固定版 HTML 的全量对照仍按批次。

### 每个 UI PR 合入前

delegator 在 brief 中列出**本次新增或改变的所有可达状态和必验条件**（视口、外观、倍率、语言、关键动作）。合入需要：

- **从固定版设计推出的自动断言**：几何（列数、尺寸、间距、内边距按 HTML/CSS 规则推导，并断言实际渲染的 frame，不只断言布局输入）、颜色与外观、文字截断、选中/当前项等可见状态，以及键盘、菜单、焦点等行为测试。测试写明它对应的设计文件与规则。
- **独立代码审计**（当前 roster 的审计者）覆盖上述断言是否真能拦住错误实现。
- PR 描述放一张逐状态表：设计 tree OID、HTML/manifest SHA256、对应的自动断言，和状态 `AUTO-PASS`（自动断言通过、待批次真机）/`FAIL`/`PENDING(<WP>)`/`NOT VERIFIED`。`AUTO-PASS` 不是视觉通过，账簿不能因此升级。
- 每个 PR 描述都必须有 `## Gates` 表格（`Lane | Status | SHA | Source`），固定 lanes 为 `package-tests`、`package-coverage`、`app-tests`、`unsigned-build`、`node-tooling`、`ledger`、`diff-check`、`design-check`、`audit`、`device-smoke`，各出现一次；额外 lane 也按相同规则检查。状态只能是 `PASS`、`FAIL`、`NOT RUN`、`N/A`、`NOT VERIFIED`：有结果的状态需要 7–40 位 hex SHA 和来源，`NOT RUN`/`N/A` 的 SHA 为 `—` 或空且必须写理由；任何 `FAIL` 都拒绝合入。`PASS` 的 SHA 可以是 PR head 的前缀；也可以是唯一标识 commit 对象本身的祖先 SHA（不剥离 tag），且该 lane 在 `scripts/agents/ui-parity-pr-body-lint.mjs` 输入表中声明的路径从该 SHA 到 head 无变化，此时无需 `CODE same`；输入路径以仓库根目录为基准，`package-coverage` 包含 coverage 配置与执行、导出、汇总脚本。已确认祖先的声明输入有变化时，拒绝旧结果。非祖先（如 rebase 前）、无法解析的 SHA、未声明可靠输入的 lane，仍要求 Source 含 `rebase-verify.sh` 的 `CODE same <40-hex>`。若有 `Device-Smoke:` 行，其状态和 SHA 必须与 `device-smoke` 行一致。
- `app-tests` 行由 `gates-rows.mjs --ci` 从保存的 CI run 生成，run 的 `headSha` 必须是 `gh run view` 导出的 40 位 hex SHA；owner-gates 不设本地 App lane（App tests 在 2026-10-29 的 OOM crash 后移到 CI，821c870f）。导出使用 `gh run view <id> --json headSha,url,status,conclusion,jobs,event,attempt > run.json`，一次运行 `node scripts/agents/gates-rows.mjs <summary.txt> --ci run.json --head <sha>` 生成七条 owner-gates 行与 CI App 行，再补 audit/device-smoke。**App 行 PASS 同时要求当前 head、已完成 run、唯一且已完成并成功的 App tests job，以及唯一且已完成并成功的 Run App tests 步骤**；失败或取消的 job 不能被成功步骤覆盖。过期、未完成、未知或缺失步骤证据均不能 PASS。其他 job 失败不改写 App 行；整个 CI 的放行还须满足其余检查。
- docs-only 的 App job 跳过写 `NOT RUN`；只有 `Native inputs` 与 `Walking skeleton` 均成功，理由才写 `no native input changed`，否则写 `skipped without a classifier decision`。成功 unsigned build、跳过 Build/Run App tests 的 build-only dispatch 写 `NOT RUN … app_tests=false`。过滤或重复诊断不能充当全量 App PASS：导出的 dispatch event、attempt 不为 1，或执行过 `Record repeat job start`、`Validate App repeat input`、`Upload App repeat logs` 时，成功测试写 `NOT VERIFIED` 并说明全量范围未证实。gh jobs 不导出 dispatch inputs，因此即使 dispatch 测试成功也保守处理；普通 PR/push 中这些标记均为 completed/skipped 时可按全量判定，历史无标记的导出仍兼容。
- 当前 main 的 required checks 是 **Walking skeleton、PR body Gates、Agent tooling**。**App tests 与 Design check 设为 required、启用 strict 是 #613 计划，由 owner 修改仓库设置后另行验证。** `Design check` 已在 CI 运行。`Walking skeleton` 的判定来自可信 PR base 的 `scripts/ci/walking-skeleton.mjs`，校验 Native inputs、Ledger HTML check、Package tests (non-UI)、Package tests (MacUI) 和 unsigned build；其绿灯本身不证明完整 App 测试通过。#613 / #587 计划将原生 App job 失败、取消、缺失或异常跳过收紧为汇总失败，可信分类器批准的 docs-only 跳过仍可通过。`Ledger HTML check` 当前在 macOS runner 上执行（包括身份检查与 release 回归），不是 Ubuntu。测试日志、xunit 结果和超时时的 sample 栈作为 artifact 保存。

- 写好 PR 描述后，在本地运行 `node scripts/agents/ui-parity-pr-body-lint.mjs --base main --body-file /path/to/pr-body.md`。若 `main` 与 `HEAD` 间改动了 `App/` 或 `Packages/MadoKit/Sources/MadoMacUI/`，脚本要求描述有含数据行的 `## UI-Parity` Markdown 表格、每行合法且非 `FAIL` 的状态，以及有效的 `Device-Smoke` 结论或带理由的 `n/a`；其他 PR 若写了 `Device-Smoke` 行，也检查其格式与理由。它不替代独立审计。独立 `pr-body.yml` workflow 在 `pull_request` 的 opened、edited、synchronize、reopened 事件上运行同一检查，并拆成没有 `needs:` 依赖的两个 fresh-runner jobs：`agent-tests` 只在 PR head 上运行测试；`pr-body-gates` 不执行 PR 文件，只从可信 base revision 的 `trusted/` checkout 执行 lint，并在 PR-head checkout 中读取 diff 与 head。base lint 缺少 `checkGates` 时明确失败，不会回退到 PR 自带的旧 lint。**信任边界**：此检查防止诚实失误、过期或矛盾证据，不能防御恶意 PR 作者；`pull_request` 的 workflow 来自 merge ref，PR 可以修改 `pr-body.yml` 本身，因此触及 `.github/workflows/` 的 PR 必须由 delegator 在合入前人工审查 workflow diff。不得为此改用 `pull_request_target` 或增加 token 权限。
- 已有真机证据显示的 `FAIL` 必须先修或经用户决定才能合入。`PENDING` 的规则同下文。

### Checker 变更确认（#471，#449 N1）

这条规则在包含它的 lint **合入 main 后**才约束 PR：`pr-body.yml` 从 `base.sha` 的 `trusted/` 执行检查，因此本规则自己的引入 PR 不会由旧 base lint 强制执行。

lint 从 merge-base 到 PR head 的 diff（含新增、删除、文件类型变化及重命名前后路径）识别两类 checker，范围与 pre-push 的 `checker_changed` 一致：`ledger` 对应 `scripts/ledger` 本身及其子路径，`design` 对应 `scripts/design` 本身及其子路径。任一类变化时，PR body 必须有且只有一条独立的确认行，不能只放在 fenced code block 或 HTML 注释里。格式为：

```text
Checker-Change: <40-hex-head-SHA> families=<family-list> — <rationale> — audits: <ref>,<ref>
```

- SHA 必须是当前 PR head 的完整 40 位 hex（大小写均可），每次更新 head 后重写此行。
- `family-list` 用逗号分隔小写 `ledger`、`design`，不得重复或写未知名称；必须覆盖所有发生变化的类别，顺序任意，允许多列另一个已知类别。例如 `families=ledger,design`。
- `rationale` 是同一行内的修改理由，去除空白及 `-`、`–`、`—` 分隔符后必须非空；用两侧各有至少一个空格或 tab 的 `—` 分隔三个字段，缺少任一侧空白都会失败。
- `audits` 至少列出两条规范化后不同、以逗号分隔的独立审计引用，因为 checker 变更仍须双独立 diff 审计。只接受以下两类（引用内部无空白）：
  - herdr 报告：`~/.picsee/herdr/<auditor>-auditor/<id>-audit<suffix>.md` 或同目录的 `<id>-confirm<suffix>.md`，使用这个与仓库路径无关的写法。`auditor` 为小写字母/数字组，以单个 `-` 连接；`id` 以字母或数字开头，余下及可为空的 `suffix` 只含字母、数字、`.`、`_`、`-`。可加由字母、数字、`_`、`-` 组成的非空 `#anchor`。先按 POSIX 规则折叠路径中的 `.`、`..` 和重复 `/`，再验证格式并去掉 anchor 比较身份；同一报告的不同段落不算两份报告。
  - 本仓库 PR review/comment：`https://github.com/anzchy/picsee/pull/<number>#pullrequestreview-<number>` 或 `https://github.com/anzchy/picsee/pull/<number>#issuecomment-<number>`；number 均为无前导零的正整数，URL 按完整字符串比较，不能附加 query 或其他路径。
- 不接受 issue 编号、普通网页 URL、任意 Markdown 文件名，或占位引用。报告路径中以 `. / _ -` 为边界的 `TBD`、`none`、`todo`、`x`、`n/a`、`n-a`（不区分大小写）均视为占位符。例如 `TBD.md,none.md`、`http://x,http://y`、同报告的 `#r1,#r2` 均失败。lint 用于拦截诚实误填；不访问网络或读取本地报告来证明真实性，审查者仍负责确认报告存在、审计者独立且明确覆盖 checker 修改。

缺失确认行、SHA 过期、类别不全、空理由、缺失或不完整的审计引用都会失败。没有 checker 变更的 PR 不要求此行；多余的确认行允许保留且不校验，避免无关 PR 因遗留说明被阻塞。`scripts/design-check.mjs`、`scripts/ledger-extra/` 等相邻名称不属于这两个范围。

pre-push 遇到 checker 变化仍将该类本地检查延迟给 CI，输出 `CI decides (local check deferred)` 并明确提醒 PR body 必须携带 `Checker-Change:` 供独立审查；消息直接给出 `families=ledger` 或 `design (shortcut)` 对应的 `families=design`。pre-push 比较 installed base 与 topic 的完整树，lint 比较 merge-base 到 PR head；陈旧 topic 可能只在本地触发 deferral，这是两种比较基线的预期差异。CI 执行 PR 自己的 ledger/design checker，因此绿色结果本身不能证明 checker 没有被削弱；本确认行把此事实和对应审计绑定到 head，不能替代两份独立审计或上文的 workflow diff 人工审查。

### 变更路径真机冒烟（每个用户可见改动的 PR 合入前，#175）

- **范围**：diff 改变了用户能看到或触发的 App 行为（通常即触及 UI/交互区的账簿行）。只改文档、测试或无 App 接线的模型代码的 PR 免做，PR 描述写一行 `Device-Smoke: n/a — <理由>`。
- **谁做**：不是实现者的角色（delegator，或有设备权限的审计者）。实现者仍不启动 App、不驱动 GUI。
- **怎么做**：按 `$macos-device-test`，对 **PR head** 运行 `scripts/device/build.sh`，取共享 GUI 锁，`launch.sh`，`doctor.sh` 全部通过；按 `features/` 里对应配方，经真实用户路径走**一条**变更路径（配方缺失先补写，见 #176）；记录动作与结果状态，`cleanup.sh` 后释放锁。证据留在 `~/.picsee/device-runs/<run-id>/`。
- **结论**：PR 描述写 `Device-Smoke: PASS|FAIL|NOT VERIFIED <head7> run=<id> — <走过的路径>`。`FAIL` 阻止合入，修复后重做；`NOT VERIFIED` 须写明具体阻碍（例如仅 @2x 可达）并经用户同意才能合入。
- **时效**：结论只覆盖那份补丁。rebase 后，`rebase-verify.sh` 把审计过的完整 full-index 补丁用 `git apply --cached --3way` 在新 base 的隔离 index 中重放，并要求所得树与 new head 精确一致（仅排除由 `rebase-ledger.sh` 重写、由 ledger gate 检查的 `docs/feature-ledger.md` 和 `docs/feature-ledger.html`），比较范围保留路径、重命名、删除、文件模式和二进制内容。`CODE same` 表示重放成功且树精确匹配，即使上游改了编辑附近的上下文也可保留结论；补丁 hash 只用于诊断，不决定相等。`CODE differ` 时重新做组合审计和 smoke。测试、文档、design 与依赖文件也在比较范围内；exit 4 表示任一比较补丁为空，不提供结论沿用证据，delegator 须检查两段范围并取得适用的新证据、重跑 gates。
- **不是升级**：冒烟不写 `docs/validation` 记录，不升级账簿行，也不替代批次真机对照；它只把「没人在真实 App 里走过这条路」挡在合入之前。

### 批次真机对照

- **时机**：累计约 4–6 个 UI 工作包，或一组相关页面能一起到达时（例如 P3-10 网格外壳 + P3-02 缩略图之后），以及 v0.0.1 发版前（#147）。delegator 记录每批覆盖的 PR、状态和 main SHA。
- **做法**：按上面「对照与审计」第 1–5 条，在**当前 main** 构建的签名、sandbox App 上，对照固定版 HTML，由独立设备验收者执行、当前独立审计者复核原图。批次覆盖自上一批以来所有 `AUTO-PASS` 状态。
- **结果**：发现的偏差逐条开 issue（标出处 PR 与工作包），按严重度排入修复；通过的状态在验证记录里记 `PASS`，账簿 owner 才可据此更新「限制：」或升级状态。
- 用户可以对某个工作包另行要求合入前真机对照；brief 里写明。

### 不变的规则

- `PENDING` 只用于本次工作包尚未实现且无法由当前 App 抵达、并明确归属后续工作包的状态；已经可达的状态不得用 `PENDING` 绕过。例外：计划 §1.3 已按引用用户原话或 ADR 的决定把某状态的原生归属改给后续工作包（例如 2026-10-25「先合入，page24 归 P3-10」）。此时本工作包拥有的部分仍是必验行，只有其余部分记 `PENDING(<WP>)`，并在 PR 中引用该决定。
- 原型目录里其余未受本次改动影响的状态仍逐项如实报告，不能借局部通过宣称 20 页、@2x 或所有交互已经一致。当前 #92 的历史偏移按其独立清单继续追踪。
- 证据目录留在 `~/.picsee/`，公开 PR 只写非敏感的 ID、哈希和结论。

CI 可检查构建、单元/渲染断言、manifest 和账簿同步；它不能单独证明签名 App 在所有窗口、显示倍率和交互状态下与设计一致。因此视觉通过只来自批次真机证据和独立审计，CI 绿灯与 `AUTO-PASS` 都不是视觉通过。

## #540 · Viewer Tools 不透明度变体（#351 固定输入）

14 `viewer-controls.html`、16 `viewer-inspector.html`、33 `viewer-filmstrip.html` 支持组合 `?theme=light|dark&tool-opacity=30|50|100`。省略或无效 opacity 回退 50%；默认外观仍为 dark。只改变外层工具材质比例，内衬保持现有 50%。100% 外层为实色 panel，blur 仍保留但被实色遮住。

| Selector | #351 应断言的属性和值 |
| --- | --- |
| `.viewer-floating-controls > [data-viewer-controls]` | 14/16 为 `leading/navigation/zoom`，33 为 `leading/zoom`；`background-color: color-mix(in srgb, var(--color-panel) var(--tool-background-opacity), transparent)`；token 随 URL 为 `30%/50%/100%`，computed alpha 为 `0.3/0.5/1` |
| 同上 | computed `backdrop-filter: blur(20px) saturate(1.6)`（作者源也声明 `-webkit-backdrop-filter`，Chromium computed 值为空，不断言它）；`border-radius: 6px`；`box-shadow: var(--shadow-soft)` |
| 同上，light | panel `#ffffff`；shadow `0 0 0 0.5px` 文字色 `#1a1a1a` 的 12%，加 `0 8px 24px` 同文字色的 8% |
| 同上，dark | panel `#141821`；shadow `0 0 0 0.5px` 文字色 `#e5e7eb` 的 16%，加 `0 8px 24px` 黑色的 45% |
| `[data-viewer-controls]::before` | 内衬继续 `inset: 2px`、radius `4px`、panel 50%；不随 URL 改变 |

16 `.inspector` 与 33 `.c-filmstrip` 的 HTML、computed styles（含后代）在同一页的不同不透明度下保持一致。`scripts/design/i540-frosted-tools.test.mjs` 在 Chromium 检查三页 × 两种外观 × 三档及默认/无效回退，并与同页默认渲染比较信息面板、胶片条和工具前景的所有非 custom computed 属性；每档都直接断言内衬 2px / 4px / panel 50%。检查无需 git 历史，也不固定旧页面以阻止后续合法设计改动。既有 glyph/text halo 与 50% 对比度检查继续有效；截图属于浏览器设计证据，不是 App 真机验收。
