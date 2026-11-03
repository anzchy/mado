# UI 工作包的 C 设计对照契约

本规程用于任何新增或改变原生 UI 的工作包。目的：让 `design/` 中已确认的 C · Quiet Image Canvas 规则成为可追溯的实现输入，并让「与 HTML 一致」有明确的状态、尺寸和证据范围。纯内部改动在 brief 中写 `无 UI 变化` 即可。

## 依据与范围

- 视觉和交互方向以用户决定及 [`design/DESIGN.md`](../../design/DESIGN.md) 为准；**具体状态的布局、内容、显隐和交互目标是该状态在 `design/prototypes/picsee-browser/states/` 中的 HTML**。SwiftUI/AppKit 的颜色、points/backing pixels、组件和系统边界按[原生映射](../../design/picsee-ui-system/native/README.md)。若原型与设计规范冲突，先修设计源并取得该设计变更所需的用户决定，再改原生实现；不在 Swift 里悄悄创造例外。
- 20 个正式状态的唯一目录是 [`states/manifest.json`](../../design/prototypes/picsee-browser/states/manifest.json)。开发计划 [§1.3](../PICSEE_DEVELOPMENT_PLAN.md) 决定每页归属的工作包；[功能账簿](../feature-ledger.md)决定当前实现状态及「怎么确认」。`viewer-v2.html` 只提供已写出的交互参考。HTML 中的按钮、示例文件名或静态蓝框不证明原生功能、权限或可访问性已实现。
- 原生系统标题栏、菜单、字体栅格化、真实文件内容等按原生映射处理。每个与 HTML 不同的选择都在 brief 的「原生例外」列写具体元素、依据和预期结果；原生映射没有规定的差异，应先修设计或实现，不把它事后称为系统例外。

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

| #347 设计变体（后续 #349 / #351 固定输入） | Selector | Property → Value |
|---|---|---|
| 14 `viewer-controls`、16 `viewer-inspector`、33 `viewer-filmstrip`，`?theme=light`，1280×800 | `.viewer-floating-controls > [data-viewer-controls]`；14/16 的 `leading/navigation/zoom`，33 的 `leading/zoom` | `background-color` → `color-mix(in srgb, var(--color-panel) var(--tool-background-opacity), transparent)`（panel `#fff`，opacity `50%`）；`backdrop-filter` 与 `-webkit-backdrop-filter` → `blur(20px) saturate(1.6)` |
| 同三页 `?theme=dark`（无参数默认），1280×800 | 同上 | 同上，panel `#141821`，仍为 `50%`、`blur(20px) saturate(1.6)` |
| 同三页浅 / 深 | 同上；后代 `.ds-icon-button`、`svg` | `border-radius` → `var(--radius-control)` = `6px`；`box-shadow` → 既有 `var(--shadow-soft)`；图标 `color` → `var(--color-text)` = 浅 `#1a1a1a` / 深 `#e5e7eb`；SVG `filter` → `drop-shadow(var(--tool-icon-halo))`（`0 0 1px var(--color-panel)`） |
| 11 `grid-light` / 12 `grid-dark`，`?thumbnail-size=140`，1280×800 | `.photo-grid`；`.thumbnail-wrap` | `--thumb-min` → `140px`；`height` → `100.8px` |
| 同 11/12，`?thumbnail-size=220`（无参数 / 无效参数默认） | 同上 | `--thumb-min` → `220px`；`height` → `158.4px` |
| 同 11/12，`?thumbnail-size=280` | 同上 | `--thumb-min` → `280px`；`height` → `201.6px` |
| 同 11/12，全三档、浅 / 深 | `.photo-grid`；`.photo-name`；`.grid-bottom-bar` | 列 → `repeat(auto-fill,minmax(min(var(--thumb-min),100%),1fr))`（最小列宽，余宽均分；实际 frame 推导见状态稿 README）；名称 → `nowrap/hidden/ellipsis`；Bottom Bar → 原位置、高 `40px`、`--color-bg` 的 `80%`、无顶线 |
| #347 共用输入与不变区域 | `viewer-grid-variants.css`、`_ds/picsee-ui-system/tokens/viewer-grid.css`；16 `.inspector`、33 `.c-filmstrip` | opacity / blur / saturation 与尺寸值只在 token 文件定义；信息面板和胶片条 DOM / 既有样式不变。网页 blur 数值是设计参考；原生材质按 #346 选平台 blur，不照抄 CSS 数字。固定版本时同时 pin HTML、manifest 与两个共用 CSS 的 SHA256 |

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
- 每个 PR 描述都必须有 `## Gates` 表格（`Lane | Status | SHA | Source`），固定 lanes 为 `package-tests`、`package-coverage`、`app-tests`、`unsigned-build`、`node-tooling`、`ledger`、`diff-check`、`audit`、`device-smoke`，各出现一次；额外 lane 也按相同规则检查。状态只能是 `PASS`、`FAIL`、`NOT RUN`、`N/A`、`NOT VERIFIED`：有结果的状态需要 7–40 位 hex SHA 和来源，`NOT RUN`/`N/A` 的 SHA 为 `—` 或空且必须写理由；任何 `FAIL` 都拒绝合入。`PASS` 的 SHA 必须是 PR head 的前缀，否则 Source 必须含 `rebase-verify.sh` 的 `CODE same <40-hex>`。若有 `Device-Smoke:` 行，其状态和 SHA 必须与 `device-smoke` 行一致。
- `app-tests` 行由 `gates-rows.mjs --ci` 从保存的 CI run 生成，run 的 `headSha` 必须是 `gh run view` 导出的 40 位 hex SHA；按决定，owner-gates 不设本地 App lane。App tests 在 2026-10-29 的 OOM crash 后移到 CI（821c870f）。main 的 required checks 是 `Walking skeleton`、`PR body Gates`、`Agent tooling`（2026-10-31 设置）；`Design check` 也运行，但不是 required check。#391 起 `Walking skeleton` 只是汇总 job：`Package tests (non-UI)`、`Package tests (MacUI)`（单进程串行）和 `Build unsigned app` 三个 job 都成功它才通过；两个测试 job 的日志、xunit 结果和超时时的 `sample` 栈作为 artifact 上传。
- 写好 PR 描述后，在本地运行 `node scripts/agents/ui-parity-pr-body-lint.mjs --base main --body-file /path/to/pr-body.md`。若 `main` 与 `HEAD` 间改动了 `App/` 或 `Packages/PicseeKit/Sources/PicseeMacUI/`，脚本要求描述有含数据行的 `## UI-Parity` Markdown 表格、每行合法且非 `FAIL` 的状态，以及有效的 `Device-Smoke` 结论或带理由的 `n/a`；其他 PR 若写了 `Device-Smoke` 行，也检查其格式与理由。它不替代独立审计。独立 `pr-body.yml` workflow 在 `pull_request` 的 opened、edited、synchronize、reopened 事件上运行同一检查，并拆成没有 `needs:` 依赖的两个 fresh-runner jobs：`agent-tests` 只在 PR head 上运行测试；`pr-body-gates` 不执行 PR 文件，只从可信 base revision 的 `trusted/` checkout 执行 lint，并在 PR-head checkout 中读取 diff 与 head。base lint 缺少 `checkGates` 时明确失败，不会回退到 PR 自带的旧 lint。**信任边界**：此检查防止诚实失误、过期或矛盾证据，不能防御恶意 PR 作者；`pull_request` 的 workflow 来自 merge ref，PR 可以修改 `pr-body.yml` 本身，因此触及 `.github/workflows/` 的 PR 必须由 delegator 在合入前人工审查 workflow diff。不得为此改用 `pull_request_target` 或增加 token 权限。
- 已有真机证据显示的 `FAIL` 必须先修或经用户决定才能合入。`PENDING` 的规则同下文。

### 变更路径真机冒烟（每个用户可见改动的 PR 合入前，#175）

- **范围**：diff 改变了用户能看到或触发的 App 行为（通常即触及 UI/交互区的账簿行）。只改文档、测试或无 App 接线的模型代码的 PR 免做，PR 描述写一行 `Device-Smoke: n/a — <理由>`。
- **谁做**：不是实现者的角色（delegator，或有设备权限的审计者）。实现者仍不启动 App、不驱动 GUI。
- **怎么做**：按 `$macos-device-test`，对 **PR head** 运行 `scripts/device/build.sh`，取共享 GUI 锁，`launch.sh`，`doctor.sh` 全部通过；按 `features/` 里对应配方，经真实用户路径走**一条**变更路径（配方缺失先补写，见 #176）；记录动作与结果状态，`cleanup.sh` 后释放锁。证据留在 `~/.picsee/device-runs/<run-id>/`。
- **结论**：PR 描述写 `Device-Smoke: PASS|FAIL|NOT VERIFIED <head7> run=<id> — <走过的路径>`。`FAIL` 阻止合入，修复后重做；`NOT VERIFIED` 须写明具体阻碍（例如仅 @2x 可达）并经用户同意才能合入。
- **时效**：结论只覆盖那份补丁。之后 App 代码有任何改动就重做；只改测试、文档、账簿，或 rebase 后 `rebase-verify.sh` 报 `CODE same`，结论保留。
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
