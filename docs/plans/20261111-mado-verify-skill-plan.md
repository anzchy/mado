# mado-verify：实现者「做完之前」的统一验证 skill（计划）

状态：草案。§7 第 2 项 owner 已决定（2026-11-11）；其余待决定。
日期：2026-11-11
起因：owner 要求参考 clay 项目的 `clay-verify`，为 Mado（原 picsee）设计一个 verify skill，覆盖 Swift App 的最佳验证实践，包括 UI 和 bug。

这是工具与流程改动，不改变 App 的用户可见行为，不走 grill → spec → tickets（`.claude/rules/10-spec-before-implementation.md`「不算」一栏）。如果最终要用它替代或改写现有的 Device-Smoke、UI-Parity 或账簿验收规则，那部分是验收变更，需要 owner 单独决定。

## 1. 要解决的问题

现在「改完了，怎么证明它对」散落在很多地方：

| 已有 | 管什么 | 缺什么 |
|---|---|---|
| tdd-guardian + `swift-red` receipt lane | 先 RED 后 GREEN 的证据 | 不检查 GREEN 之后有没有削弱断言、加跳过、加重试 |
| `owner-gates.sh` | delegator 复跑全部门禁 | 只有 delegator 用；实现者各自拼命令，常漏 lane（例如 #358 的 design 依赖缺失、旧 scheme 名） |
| `macos-device-test` skill + `scripts/device/*` | 独立真机验收、账簿升级 | 实现者不能用它自证；每个新问题都写一次性脚本（#637 的 `issue637-desktop.py` 用了 6 轮才稳定） |
| `diagnosing-bugs` skill、`docs/agents/ci-flake-repro.md` | 先复现 bug | 和「修好之后怎么证明」没有接起来 |
| UI 对照契约、PR 的 `UI-Parity` / `Device-Smoke` / `Gates` 表 | PR 级证据格式 | 证据由 delegator 事后拼；PR body lint 在 #646 一次失败三回 |

结果是：实现者交回「all green」，delegator 再花一轮重跑、补证据、发现漏掉的 lane。目标是让实现者在交回之前，就按一份固定清单跑完并留下可审计的证据。

## 2. 从 clay-verify 借什么

clay-verify（Go 项目）的骨架可以直接借用：

1. **门禁阶梯**：固定顺序，第一处失败就停，修好从头重跑；禁止为了变绿关掉随机顺序之类的检查。
2. **按改动类型加跑的检查**：纯函数跑 fuzz；并发改动证明没有残留 goroutine；日志改动跑敏感值扫描。
3. **跑真的产物**：从干净 clone 构建真二进制，在本机回环上对着桩服务跑，像客户端一样逐条对照预期。
4. **证据贴到 ticket 的 issue**：命令 + 关键输出、head SHA、「行为 · 预期 · 实际 · 结果」表、NOT VERIFIED 清单；贴之前扫描敏感值和个人路径。
5. **Skill 自己保持正确**：步骤错了，在同一分支改 skill，随审计一起过。
6. 两个实现者同一份文件：Claude 用斜杠命令，Codex 照文件执行。

不能照搬的：Mado 是签名的沙盒 GUI App，「跑真的产物」需要桌面会话、GUI 锁和 TCC 授权，不能在任意 shell 里做；重任务必须走 `scripts/heavy-lock.sh`。

## 3. Swift / macOS 验证的最佳实践（调研摘要）

标注：〔Apple〕Apple 文档或 WWDC；〔社区〕二手来源；〔推断〕没有出处的判断。

### 3.1 门禁

- Swift 6.2 SwiftPM 支持 `.treatAllWarnings(as: .error)`（SE-0480），但只在直接构建该 package 时生效；App target 要有自己的 warnings-as-errors `xcodebuild` lane。〔Apple / swift.org〕
- `swift format lint --strict` 随工具链提供；不加 `--strict` 时 lint 警告不会让退出码失败。〔swift.org〕
- Swift Testing 默认并行执行〔Apple〕；WWDC24 10195 称顺序随机，这一点只见于讲稿〔Apple 视频〕。`.serialized` 对非参数化测试无效。
- UI 测试、`measure`、无障碍审计、hitch 指标只能用 XCTest。〔Apple〕

### 3.2 不稳定测试

- WWDC21 10296：重试「可能掩盖产品里的真实问题」。需要重试才通过的测试应记为不稳定，而不是通过。〔Apple〕
- 找不稳定测试用 `-test-iterations N -run-tests-until-failure`，不用 `-retry-tests-on-failure`。〔Apple〕
- 这和仓库现有规则一致：不加重试、不加隔离（quarantine）、不放宽超时（#631 / #642 / #647）。

### 3.3 Sanitizer

- UBSan 只支持 C 系代码，不支持 Swift。〔Apple〕
- 开销（Apple 文档）：ASan 慢 2–5 倍；TSan 慢 2–20 倍、内存多 5–10 倍；Main Thread Checker 约 1–2% CPU。
- 测试用的 sanitizer 在 test plan 里设，不在 scheme 里设；ASan 与 TSan 分开 lane。〔Apple；「不能同时开」在 Apple 页面上未证实〕
- 对 Mado：TSan lane 适合并发改动（扫描、缓存、预取、监听），不适合每个 PR 都跑——16 GiB 的 mini 有过 OOM（见 heavy-lock 规则）。

### 3.4 覆盖率

- 已在 #631 里落地：逐条 DA/FN 校验、≥2^63 的计数视为无效证据、文件与函数例外按路径和 sha256 冻结。
- #358 的教训：`for … where` 会让 LLVM 计数回绕；现在有禁用检查。覆盖率数字本身也要校验，不能只看百分比。

### 3.5 UI

- **无障碍审计**：macOS 上 `performAccessibilityAudit` 只跑父子关系和 Action 类检查，不含 Dynamic Type、裁切文字；Apple 明说审计干净不等于可访问。〔Apple〕
- **快照测试**（pointfreeco/swift-snapshot-testing）：首次运行会录制参考图并通过，所以门禁必须确认参考图已提交；固定尺寸、外观、backing scale 和色彩空间；`perceptualPrecision` 不能抹平所有机器间 GPU 差异。〔社区 / 维护者文档〕
- **真截图取色**：ScreenCaptureKit 可指定色彩空间；Display P3 → sRGB 转换后再比较并带容差。〔Apple API；容差做法为推断〕#637 已经按这个做（sRGB 截图、样本点在图像内部、先检查背后确实是指定颜色）。
- **设计对照**：沿用 `docs/agents/ui-parity-contract.md`——从固定版本的 CSS 推出断言（几何、颜色、截断、可见状态），PR 里先变成自动断言（AUTO-PASS），真机对照按批次做。
- **外观变体**：浅色 / 深色、Reduce Transparency、Increase Contrast 要列为显式状态；没测的写 NOT VERIFIED（#637 已注明自绘背景失去系统材质的 Reduce Transparency 自动回退）。

### 3.6 只有真 App 才能验证的行为

- 窗口恢复只能用 ⌘Q 正常退出来测，强制退出会丢弃保存的状态。〔Apple〕
- TCC 授权跟 bundle ID 和签名走，所以只有签名构建的结果才算数。〔Apple〕
- 书签解析为「not stale」不代表访问一定恢复，要真的打开文件确认。〔Apple〕
- 自动化手段：AX / JXA、CGEvent、`scripts/device/*`；Finder 授权弹窗仍需 owner 手动点击（现有规则）。
- `-ApplePersistenceIgnoreState` 这类参数 Apple 没有文档，只有社区帖子，不要依赖。

### 3.7 性能

- 基线按机器保存，`xcodebuild` 不能录制基线；不要在 GitHub 托管 runner 上做性能门禁。〔Apple / 社区〕
- `xctrace record … --launch` 必须是最后一个参数；Xcode 26 上 `--template` 失效的说法未证实。
- 对 Mado：性能数字只来自本机签名 Release 构建 + signpost，写进 `docs/validation/`，不写就不报数字（「不伪造数据」规则）。

### 3.8 证据

- `xcrun xcresulttool get test-results summary|tests|activities`、`export attachments`（Xcode 16+）；旧的 `get --format json` 需要 `--legacy`；输出 schema 不再公开发布，用 `xcresulttool help …` 查看。〔Apple 手册〕
- 一条好的验证记录：head SHA、工具链、确切命令 + 退出码 + 关键行、RED/GREEN 输出、产物路径、NOT VERIFIED 清单。

## 4. Claude Code 与 Codex 的 verify 实践（调研摘要）

### 4.1 Claude Code

- 官方最佳实践：给 Claude 一个能跑的通过/失败检查；要求它给出证据——「它运行的命令和输出，或截图」。〔code.claude.com/docs/en/best-practices〕
- CLAUDE.md 里的指令「大多数时候」被遵守，不是每次；必须始终成立的规则放进 command / http hook。Stop hook 可以阻止结束（exit 2），但连续 8 次后 Claude Code 会放行。〔code.claude.com/docs/en/hooks〕
- **命名冲突**：Claude Code 自带 `/verify` skill（构建并运行 App 确认改动，不退回到测试）；没有启动配方时，它会把配方写到 `.claude/skills/verify/SKILL.md`。仓库根目录下这个路径的 skill 会替换自带的 `/verify`。所以 Mado 的 skill 不叫 `verify`，叫 `mado-verify`。〔code.claude.com/docs/en/skills〕
- Skill 格式：`name` ≤64 字符，`description` ≤1024 字符，正文 <500 行，引用只深入一层；附带脚本是被执行而不是被读进上下文；推荐「清单 + 验证—修复—重复」模式。〔platform.claude.com agent-skills best practices〕
- 计算机操作（computer use）可以操作 Mac App，但只在交互会话里；截图会被缩小，不能当像素证据。〔code.claude.com/docs/en/computer-use〕

### 4.2 Codex

- 提示里要有「Done when」一节；AGENTS.md 要写清楚「完成意味着什么、怎么验证」。AGENTS.md 默认上限 32 KiB。〔developers.openai.com/codex/learn/best-practices〕
- Skill 放在 `.agents/skills`，只需要 `name` 和 `description`。〔developers.openai.com/codex/skills〕——与本仓库现有布局一致（`.claude/skills/` 是软链接）。
- Hook 也有 `Stop`（阻止意味着继续，带 `stop_hook_active`），必须先被信任才会运行。
- `codex exec` 默认只读沙盒；`workspace-write` 默认断网，测试失败可能其实是沙盒失败——验证记录要写明沙盒模式。`--output-schema` 可以强制结构化报告。
- Codex 的计算机操作只在桌面 App 有文档，CLI 没有。Mado 的 Codex 面板本来也不能跑 xcodebuild 签名构建（见 mini 配置记录），GUI 验证仍归 delegator / `macos-device-test`。

### 4.3 共同模式：防止「为了变绿而改测试」

- METR（2025-06）观察到模型修改测试和评分代码；告诉它「不要作弊」几乎没有效果。OpenAI（2025-03）和 Anthropic（2025-11）都记录了用 `sys.exit(0)` 让测试通过的案例。
- 结论：靠措辞没用，要机械检查：
  - 删除或削弱的断言；
  - 新增的 skip、重试、quarantine、放宽的超时；
  - 前后测试数量；
  - RED 在 GREEN 之前被记录；
  - 独立审计员读证据和 diff。
- 实现者与验证者分开；审计员用新上下文、只读工具。这些在本仓库已有（双盲审计、`/clear`、只读 auditor worktree）。

### 4.4 Xcode 与 agent 集成

- Apple 文档描述了通过 `xcrun mcpbridge` 让外部 agent 连接 Xcode，要求 Xcode 打开并加载工程；Apple 页面没有列出工具清单，`BuildProject`、`RenderPreview` 等名字只见于社区来源。
- XcodeBuildMCP 已改名 getsentry/MobileBuildMCP，能构建、测试、启动 macOS App，但 UI 自动化只支持 iOS 模拟器。
- 对 Mado：暂不引入。现有的 `xcodebuild` + heavy-lock + `scripts/device/*` 已覆盖，新增依赖要单独评估。

## 5. mado-verify 设计草案

### 5.1 定位

- 名字：`mado-verify`，位置 `.agents/skills/mado-verify/SKILL.md`，`.claude/skills/` 下软链接（与现有 skill 一致）。
- 谁用：实现者（gpt-imple-*、opus-imple-1），在交回 handoff 之前。Claude 用 `/mado-verify`，Codex 读文件逐步执行。
- 不做：审计别人的 diff（审计员读证据，不构建）；真机验收和账簿升级（仍归 `macos-device-test`，执行者必须不是实现者）。
- 正文 <500 行；确切命令集中在 AGENTS.md 和附带脚本里，skill 只引用，避免两处漂移。

### 5.2 流程

**第 0 步 · 定范围。** 读 brief、账簿行的「怎么确认」、改动文件列表，决定下面哪些层适用。不适用的层写「n/a + 理由」，不是静默跳过。

**第 1 步 · 门禁阶梯**（每个改动都跑，固定顺序，第一处失败就停）：

1. `git diff --check`；
2. `xcodegen generate`；
3. `swift test --package-path Packages/MadoKit`（经 heavy-lock）+ Package 覆盖率评估（#631 的评估器，合并后启用）；
4. unsigned `xcodebuild build -scheme Mado`（经 heavy-lock）；
5. `node --test scripts/{tdd,ci,release}/*.test.mjs`；
6. 改了账簿：`npm run ledger:build` + `ledger:html-check`；
7. 改了设计 / 原型：`npm run design:check`（先确认 `npm ci --ignore-scripts` 已装依赖）；
8. 改了 App target：相关 App 测试过滤器（经 `scripts/ui-tests.sh` / App lane）。

最省事的做法：附带脚本直接调用 `owner-gates.sh`，让实现者和 delegator 跑的是同一套命令（注意：要调用当前分支里的那份；2026-11-11 用一份过期的本地主 checkout 里的副本时，因为还是改名前的包名和 scheme 名，门禁假失败了一次）。

**第 2 步 · 测试完整性检查**（每个改动都跑，脚本化）：

- 对 `base..HEAD` 的测试 diff 扫描：删除或削弱的 `#expect` / `XCTAssert`、新增的 `.disabled` / `XCTSkip` / 重试 / quarantine / 放宽超时、`exit(0)`；
- 前后测试数量；
- tdd-guardian receipt：每个 WI 有 RED，且记录了 SEPARATION 状态；SEPARATION-BROKEN 必须在 handoff 里逐条说明；
- 任何一项命中：不是自动失败，而是必须在证据里逐条解释，供审计员判断。

**第 3 步 · 按改动类型加跑的检查：**

| 改动类型 | 加跑 | 证据 |
|---|---|---|
| 并发、取消、扫描、缓存、监听 | TSan lane（单独、经 heavy-lock）；`-test-iterations` 重复跑相关测试 | 迭代次数、0 失败；不允许重试 |
| 修 bug | 复现先行：旧代码上 RED 的回归测试（与 `diagnosing-bugs` 接上），修后 GREEN；不能自动化的复现写成步骤 + 真机证据 | RED/GREEN 两段输出，旧 SHA 与新 SHA |
| UI（新状态、布局、颜色） | 从固定版本的 CSS 推出的断言先变成 RED；浅色/深色；需要时快照测试（参考图必须已提交） | 每个状态一行，AUTO-PASS / NOT VERIFIED |
| 不稳定的 CI 测试 | 按 `docs/agents/ci-flake-repro.md` 先复现 | 复现命令与次数 |
| 性能敏感路径 | 只报本机签名 Release + signpost 测得的数字，否则写 NOT VERIFIED | 数字 + 构建配置 + 机器 |
| 只有真 App 才能验证的（沙盒授权、重启恢复、菜单快捷键、窗口） | 实现者只做 dry-run（例如 AX 控件能否找到、脚本离线测试）；真机运行交给 delegator 在 picsee-dtrack 里执行 | 交回可直接运行的命令和输出目录 |

**第 4 步 · 证据。** owner 决定（2026-11-11）：「verify相关的证据要提交到对应github ticket(issue)中comment，如果涉及到UI修改，要在comment中上传修复前后的截图。」

- 写成固定格式（下方），作为评论贴到对应 ticket 的 GitHub issue；handoff 里放评论链接和它覆盖的 head SHA。
- 证据必须对应 handoff 的最终 head；之后再提交就再贴一条新评论。
- **涉及 UI 修改时**，评论里必须上传修复前、修复后的截图：同一状态、同一窗口尺寸、同一外观（浅色/深色）和缩放，修复前用 base SHA 的构建，修复后用 head SHA 的构建；每张图注明状态名、SHA 和机器（@1x / @2x）。截图只上传到 issue 评论，不进仓库（「不入库」规则不变）。
- 贴之前扫描：文字不含 `/Users/`、`/private/`、`/var/folders/`、密钥；截图里不出现个人文件名、私人照片、通知、其他 App 的窗口——只用 `TestAssets` 里的素材，截取 App 窗口而不是整个桌面。
- 截图的产生方式：签名构建只能在桌面会话里运行，所以 UI 截图由能操作桌面的一方（delegator 在 picsee-dtrack 里，或 owner）拍摄；实现者交回可直接运行的截图命令。实现者自己贴的文字证据和 delegator 补贴的截图可以是同一 issue 的两条评论。
- 上传方式待 V2 确定：`gh` CLI 不能给评论上传附件，候选是通过浏览器（`/browse`）在评论框里上传，或其他不把图片放进 git 历史的方式。

```markdown
<!-- mado-verify issue=<N> task=<Report-Task> head=<40 位 SHA> -->
### mado-verify：#<N> · `<task>` · `<branch>` @ `<sha7>`

工具链：Xcode … / Swift … ；机器：…；沙盒模式（Codex）：…

#### 门禁
<每条命令 + 退出码 + 关键行（测试数、覆盖率、swift-lane filter= 行）>

#### 测试完整性
<扫描结果；每个命中逐条解释>

#### 按类型加跑
| 行为（brief / 账簿行） | 预期 | 实际 | 结果 |
|---|---|---|---|

#### 截图（仅 UI 修改）
| 状态 | 修复前（base `<sha7>`） | 修复后（head `<sha7>`） | 机器 |
|---|---|---|---|
| … | <上传的图> | <上传的图> | @1x / @2x |

#### NOT VERIFIED
- <项>：<原因>（或「无」）
```

**第 5 步 · Skill 自我修正。** 某一步命令跑不通（scheme 改名、依赖缺失、参数变了），在同一分支修 skill 或脚本，并在 handoff 里说明；随审计一起过。

### 5.3 强制方式

- 第一版：靠 brief 要求 + delegator 检查 handoff 里有证据链接（delegator 本来就复跑 owner-gates）。
- 第二版（可选）：附带脚本生成机器可读记录（`.build/mado-verify/<sha>.json`）；Claude 的 `Stop` / `SubagentStop` command hook 和 Codex 的 `Stop` hook 检查当前 HEAD 有新记录，否则不让结束。注意 Claude 连续 8 次阻止后会放行，hook 只是兜底，审计员仍是最终把关。

## 6. 分步落地

| 步骤 | 内容 | 依赖 |
|---|---|---|
| V1 | `owner-gates.sh`：缺 npm 依赖时给出明确提示（不是只报 design=1）；提醒从被测分支自己的副本运行 | 无 |
| V2 | 写 `mado-verify` SKILL.md + 证据模板 + 测试完整性扫描脚本（带 RED-first 的 fixture 测试） | V1 |
| V3 | brief 模板加「Done when：mado-verify 证据链接」；delegator skill 里写明检查 | V2 |
| V4 | 在下一个真实 ticket 上试跑，按结果修 skill | V3 |
| V5（可选） | Stop hook 强制；TSan lane；快照测试基础设施 | V4 + owner 决定 |

V1–V3 是工具改动，走正常 PR + 双审计；V5 涉及新的门禁或依赖，先问 owner。

## 7. 需要 owner 决定的事

1. **命名**：用 `mado-verify`（推荐，避免覆盖 Claude Code 自带的 `/verify`），还是有意接管 `verify`？
2. ~~证据贴在哪~~ **已决定**（2026-11-11）：贴到对应 ticket 的 GitHub issue 评论；UI 修改要在评论里上传修复前后的截图。见 §5.2 第 4 步。
3. **强制程度**：第一版只靠 brief + delegator 检查，还是一开始就加 Stop hook？
4. **TSan / 快照测试**：要不要作为 V5 引入？TSan 在 16 GiB mini 上内存开销大；快照测试要新增 pointfreeco 依赖。
5. **与 Device-Smoke 的关系**：mado-verify 只做实现者自证，Device-Smoke 仍由 delegator 做（推荐，不改现有验收），还是让实现者的 dry-run 证据部分替代？

## 8. 来源

调研全文（含逐条来源和可信度标注）由两个调研 subagent 于 2026-11-11 完成，主要来源：

- Apple：WWDC21 10296、WWDC24 10195、WWDC23 10035、WWDC25 344；Diagnosing memory, thread, and crash issues early；Performing accessibility audits；Restoring your app's state with AppKit；xcresulttool / xctrace 手册；Giving external agents access to Xcode。
- swift.org：SE-0443、SE-0480、swift-format。
- pointfreeco/swift-snapshot-testing。
- Claude Code 文档：best-practices、skills、hooks、sub-agents、computer-use；Agent Skills best practices；Anthropic 关于 reward hacking 的研究。
- OpenAI Codex 文档：best practices、skills、hooks、非交互模式、agent approvals & security。
- METR, “Recent frontier models are reward hacking”（2025-06）。
- clay 项目 `clay-verify` SKILL.md（本地，owner 的另一个仓库）。
