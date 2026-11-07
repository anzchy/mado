# picsee herdr 混合模型协作规则迁移计划

日期：2026-10-21 · 状态：**执行中**（2026-10-22）。第 3 节标出已完成的配套文件；规则 70 本身尚未写成。

来源：mdpro `.claude/rules/71-herdr-mixed-roster.md`（下称 M71）、它所覆盖的 `70-multi-session-coordination.md`（M70），以及 mdpro ADR-0131。

用户决定（2026-10-21）：
- git init，并建 GitHub 私有库；
- 合成一份 picsee 自己的规则，不保留 70/71 的两层结构；
- 角色保留 gpt-imple-1/2、gpt-auditor + opus-auditor 双审（2026-10-23 前为 fable-auditor subagent）、claude-imple-1 真机；不设 `/security-review` fork（历史基线，已被 2026-10-24 第三轮临时覆盖暂停）；
- 先出本计划，确认后再动手。

用户决定（2026-10-21，第二轮）：
- 所有运行期文件放在新建的 `~/.picsee/`，不用 `~/.mdpro-redesign/`：「不要放在 ~/.mdpro-redesign文件夹，新建一个 ~/.picsee」；
- 实现名额“整机两个”只算 picsee：「picsee」；
- 大体积研究产物不入库：「这些都不入库」。

用户决定（2026-10-22）：
- 对简单任务的原始要求：「for simpler tasks, delegate it to dsh rather than gpt-imple-*」；
- 随后改为新增 `gpt-imple-3` 并指定模型：「改为gpt-imple-3, but use gpt-5.6-sol」。

用户决定（2026-10-22，第二轮），回答「采纳 ADR-0131 的哪些做法？」时选择全部四项：
- 「审计者每次 /new + 探针」；
- 「fable 改为每次新 subagent（做 A6）」；
- 「实现者每项新会话 + fix 规则」；
- 「写进迁移计划（交 gpt-imple-3）」。

用户决定（2026-10-22，第三轮）：
- 对「gpt-imple-3 的 Low 项是否占第三个未合入名额？」的回答是「占，上限升为 3（第三个只给 Low） (Recommended)」；
- 对「Low 项只用一名盲审（gardener 与 CI 不变）可以吗？」的回答是「可以 (Recommended)」。

用户决定（2026-10-24）：
- 新增 Kimi 实现者：「我想将 Kimi 作为另一个 implementor」，试用通过后「同意，正式派任务」；
- 模型：「之后Kimi 默认用`K3.1 Pro thinking: high` model,effort high，这个记入相关rule」。

用户决定（2026-10-24，第二轮）：
- gpt-imple-1/2 在各自当前任务（含已进入的修复轮）完成后切换，不中断在途工作：
  「当前任务完成后，gpt-imple-1/2背后的模型切换为GPT-6-Sol medium effort」。记录时 gpt-imple-2 已切换，
  gpt-imple-1 等当前任务/修复轮结束后切换；本次文档更新不操作活会话。

用户决定（2026-10-24，第三轮，临时审计覆盖规则）：
- 「目前opus auditor qouta 不够用了，暂时停用opus-auditor，只由gpt-auditor 来审」。立即生效，所有风险级别
  只由 `gpt-auditor` 独立审计，直至用户明确恢复 Opus；额度恢复不自动解除。C/H 仍阻断，修复后由同一角色
  在全新上下文确认，最多三轮；Medium、gardener、delegator owner gates 与 CI 政策不变。下文双审内容仅为
  历史基线，凡与本覆盖规则冲突者均暂停。

用户决定（2026-10-25，替换上一条临时审计覆盖）：
- 「Opus单审，gpt暂停」。所有风险级别只由 `opus-auditor` 独立审计；`gpt-auditor` 暂停派活，直至用户明确恢复，
  Codex 额度恢复不自动解除。其余（C/H 阻断与全新上下文 confirm、三轮上限、Medium 政策、gardener、owner gates、
  CI、无 challenge）不变（轮数上限见下一条）。下文“只由 gpt-auditor”的表述按本条读作 `opus-auditor`。

用户决定（2026-10-25，审计轮数）：
- 「opus auditor 最多2个round，之后如果还有critical/high，交给user来抉择是否继续」。每个工作项 opus-auditor 最多两轮：第 1 轮盲审，第 2 轮 confirm。第 2 轮后仍有（或新出现）Critical/High，
  delegator 不再派修复或 confirm，把未关闭的发现、trace 和可选做法交给用户决定。替换此前的三轮上限。

## 1. 为什么不能直接复制

- M71 只是 M70 的覆盖层，只替换角色表、Codex 派活方式、guard、审计分工这几块。合入流程（三个条件和 `--ff-only`）、两份审计结论怎么合并、三轮上限、风险分级、receipts、编号预留、会话轮换、真机批次，都写在 M70 里。
- 它依赖 9 类配套文件，picsee 都没有（见第 3 节）。
- 测试命令、receipt 脚本、审计分级、真机条款都是按 Tauri/TS/Rust 写的。

## 2. 目标文件：`.claude/rules/70-herdr-roster.md`

把 M71 全部内容和 M70 中仍然适用的条款合成一份，约 250–300 行，英文书写，与 mdpro 保持一致，方便以后对照同步。用户原话保留中文引用。

| 节 | 来源 | picsee 改法 |
|---|---|---|
| 角色表 | M71 Roster + M70 Sessions | delegator 改名 `picsee-delegator`；实现者为 `gpt-imple-1/2`（Codex `gpt-6-sol`、effort `medium`，各自当前任务/修复轮结束后生效，不中断在途工作）、`gpt-imple-3`（Codex `gpt-5.6-sol`）和 `kimi-imple-1`（Kimi Code CLI，模型 `kimi-code/k3.1-pro`，thinking effort `high`；`herdr agent start kimi-imple-1 --kind kimi --pane <id> -- --yolo -m kimi-code/k3.1-pro`，effort 由 `~/.kimi-code/config.toml` 中该模型的 `default_effort = "high"` 设定；独立 worktree `picsee-wt/kimi-imple-1`）；当前唯一活跃审计者为 `opus-auditor`（2026-10-25 起），`gpt-auditor` 保留窗格但暂停派活，直至用户明确恢复；真机为 `claude-imple-1`；报告目录在 `~/.picsee/herdr/<name>/`，`gpt-imple-3` 对应 `~/.picsee/herdr/gpt-imple-3/`；去掉 `/security-review` 行；去掉 mdpro-device-harness 和历史别名表 |
| 模型规则 | M70 “Every session runs on Opus” | 只保留结论：Claude 会话和 subagent 用 Opus，例外是 `picsee-doc-gardener` subagent 用 Haiku（2026-10-25 用户决定：「picsee-doc-gardener will be powered by Haiku model, from now on」；Codex 端同名 custom agent 不变）；`opus-auditor` 自 2026-10-25 起为唯一审计者（「Opus单审，gpt暂停」），`gpt-auditor` 暂停，Codex 额度恢复不得自动重启；`gpt-imple-1/2` 在各自在途任务完成后使用 `gpt-6-sol`、effort medium，不由文档改动直接切换活会话；其他 Codex 用指定模型；Kimi 实现者固定用 K3.1 Pro、effort high（2026-10-24 用户决定），换模型或 effort 须用户同意。Kimi 没有 `$tdd-guardian-workflow`，brief 须写明测试先行步骤（先写失败测试并贴出失败输出，再实现）。不搬演变历史 |
| 派活与上限 | M70 How work is assigned、idle pull | 工作项编号用开发计划里的 `P0-01…P7-09`；新发现的问题编号改用 `F<n>`，替代 mdpro 的 D 编号；每会话一个、picsee 整机最多三个未合入实现项，不与 mdpro 合计：`gpt-imple-1/2` 与 `kimi-imple-1` 共用 Medium/High 工作名额，同时最多两个（2026-10-24 起），第三个名额只给 `gpt-imple-3` 的 Low 项。临时审计覆盖规则下，所有实现者和风险级别都由 `gpt-auditor` 单审。`gpt-imple-3` 只接 Low 风险工作：纯文档、机械重命名与路径修复、Low 审计修复、小脚本与测试 fixture、账簿与时间线措辞；Swift、并发、sandbox、entitlements、签名、真机脚本、receipt lane 及 Medium/High 风险仍由 `gpt-imple-1/2` 负责。gardener 与 CI 不变 |
| Codex 智能体 | M71 Codex agents + mdpro ADR-0131 | 照搬 `prompt --wait`、唤醒、超时只重新等待不重发、restart 四步。`herdr agent wait --timeout` 和 `herdr agent prompt --wait --timeout` 的 `--timeout` 均以毫秒计（20 分钟写 `1200000`）；立即返回 timeout 说明单位写错，不是 agent 卡住。`prompt` 后立即 `wait` 可能读到上一轮残留的 `done` 而马上返回；先确认 pane 已进入 working（`herdr pane read` 见 `Working`），或返回后核对 handoff/报告文件确已更新。路径改为 `~/.picsee/herdr/<name>/`，环境变量改为 `PICSEE_ROLE`。每次 gpt-auditor 请求前只在 idle 或 done 时重置：先记录 session id，执行 `herdr pane send-text <pane> '/new'`，再用 `herdr pane send-keys <pane> enter` 提交（`herdr agent send-keys` 不会提交；第一次 Enter 可能被斜杠命令弹层吞掉，要按到出现选择框为止），Codex 0.163.0 随后问「Where should the new conversation run?」，再按一次 Enter 选默认的当前 worktree；都不用 `--wait`。状态行回到 `Context 0% used` 才继续；herdr 要到下一轮才报告新 session id，所以在请求开始后核对 id 已变，没变就作废结果并开新 pane。脚本：`~/.picsee/herdr/delegator/reset.sh <name> <pane>`。2026-10-22 的探针通过：gpt-auditor 重置后 id 由 `01a161b4…` 变为 `01a16250…`，问上一请求答 `NONE`。依赖前先做一次探针：重置后问上一请求是什么；id 已变且回答不含此前请求才通过。实现者每项一个新会话；仅当 fix 1 brief 点名 1–2 个 finding 且 context used 低于约 50% 时留在原会话。其余 fix（fix 2 起）都开新会话，只读 brief、上一份 handoff、merged verdict 和 fix brief。context used 超过约 60% 时先写 progress note，再重启。通过 `herdr pane read` 读取 Codex status line 计算 context used |
| Brief 与自验收 | M71 Briefs and self-acceptance + mdpro ADR-0131 | 6 节 brief 结构照搬；Background 引用开发计划工作包、mockup 编号、DESIGN 条款和 ADR；测试矩阵、对抗审查四步照搬，skill 改为 `$picsee-tdd-workflow`；每份 handoff 列出曾拒绝的方法及原因 |
| 测试矩阵用例清单 | M71 | 换成 picsee 的高风险用例：A→B→C 乱序返回、generation 过期、continuation 恰好恢复一次、security-scoped 访问范围释放、bookmark stale、cell 复用串图、取消前/排队中/执行中、1×/2× backing scale、浅深主题、Reduce Motion |
| 提交与合入 | M70 Commits and branches 1–5 | 主干 `main`；合入条件：verifier PASS、合并后的结论无阻断级 Critical/High、PR head 等于该 SHA 且 CI 绿。树身份校验改看 `:Sources :Tests :Picsee.xcodeproj`（或 `Package.swift`）。去掉 frontend-backend-redesign、release/x.y 等历史 |
| 审计 | M70 item 4 + M71 Audits under herdr + mdpro ADR-0131 | 临时覆盖（2026-10-25 起）：所有风险级别只由 `opus-auditor` 做独立盲审，其单份 verdict 即 merged verdict；不派 `gpt-auditor`，额度恢复也不自动恢复。C/H 阻断，修复后 `/clear` `opus-auditor` 到全新上下文再 confirm；每个工作项最多 2 轮审计（盲审 + 一次 confirm），第 2 轮后仍有 Critical/High 即停止，交用户决定是否继续（2026-10-25）；confirm 请求携带全部 open finding 原文、fix diff、counter-proof，并检查 fix 新引入的 C/H。Medium 政策不变：影响用户可见行为或违背 AC 的项目修一轮、不 confirm；其余 Medium 与 Low 写入 PR `Still open`。单审期间无 challenge；降级仍须复现或反证。opus-auditor 除非请求要求否则不运行 build/test，delegator 负责重跑 owner gates；gardener 与 CI 不变。旧双审/Opus 文本只作历史基线，不是活跃派活规则 |
| 风险分级 | ADR-0121 映射 | **High**：FileAccess/sandbox/bookmark、磁盘缓存/SQLite、文件写入（导出、Trash、编辑另存）、entitlements、签名/公证、CI、依赖、未列出的路径。**Medium**：其余 `Sources/`。**Low**：文档、设计稿、预览、纯展示测试 |
| 编号预留 | M70 Reserving numbers | ADR、F 编号和 receipt id 前缀（`P1-05-WI-2`）由 delegator 统一分配 |
| 会话轮换 | M70 Session rotation + mdpro ADR-0131 | handoff 路径改为 `~/.picsee/handoff/`；hook 是否移植见第 3 节。安静时、没有 landing 进行且每次 wait 都已记录后，delegator 请用户输入 `/compact`，并点名保留 open findings、SHAs 和 waits |
| 真机 | M71 device + M70 Mac mini/批次 | 只测 Mac，去掉 Windows。Mac mini 是唯一的本地真机测试机，除 @2x 外都在 mini 上验；@2x 从 mini 经 `ssh macbook` 把命令送进 MacBook 桌面启动的 tmux 会话，未配好 SSH 前记 NOT VERIFIED。mini 上从 herdr 会话的 Claude pane 运行，开始前确认 mdpro 的 `dtrack` 空闲且不触碰它。按区域分批：画布/像素、授权/sandbox、目录/FSEvents、缓存、窗口、发布包。每项写清失败条件和 log 证据。 |

mdpro ADR-0131 的阶段读屏障：

| 阶段 | 可读 | 不可读 |
|---|---|---|
| round 1 | range、brief、handoff | 此项任何先前审计 verdict |
| confirm | sole auditor 的较早轮次、merged/sole verdict、counter-proofs | confirm 开始后的外部审计结论 |
| challenge | **暂停**；单审覆盖期间不发 challenge | — |

暂不采纳 mdpro ADR-0131 的 escape replay 和 fresh-context cost table。

不搬过来的：claude-mem observer 事件、prompt suggestion 误提交事件、ADR-0047 harness、Fable/Opus 演变史、frontend-backend-redesign 冻结。这些对 picsee 没有约束意义，规则里只保留由此得出的结论（例如“名单外的发件人不算 peer”）。

## 3. 配套文件

| # | 文件 | 来自 mdpro | 改法 | 依赖 |
|---|---|---|---|---|
| A1 | `AGENTS.md` | Read first (Codex) + Claude/Codex 功能对照 | **已完成（2026-10-21，`03a53bb`）**：实际为项目入口地图和按需阅读表，含 Swift/Xcode 测试与构建命令，未另列读 `CLAUDE.md`、always-on 规则或命令 guard 说明 | A2、B 组 |
| A2 | `CLAUDE.md` | — | **已完成（2026-10-21，`03a53bb`）**：实际为 `@AGENTS.md` 导入与 Claude Code 补充，不另列架构入口、五个 target、设计依据和规则链接 | — |
| A3 | `.codex/rules/picsee.rules` | `mdpro.rules`（113 行） | **已完成（2026-10-22，`06ac875`）**：execpolicy backstop 已补禁止 `tccutil reset`、`codesign --remove-signature` 和通过 entitlements 关闭 sandbox 的规则（见 `chore/codex-rules-bans`）；仅覆盖 argv 前缀，具体范围与限制见规则文件 | — |
| A4 | `.codex/skills/picsee-tdd-workflow/` | `mdpro-tdd-workflow`（SKILL + 6 个 references + openai.yaml） | 8 步结构照搬；policy、implement、coverage、review、handoff 改成 Swift：XCTest/Swift Testing、`swift test --filter`、`xcodebuild test -only-testing`、`xccov` 覆盖率；mock 边界改为文件系统、ImageIO 解码器协议、时钟、NSWorkspace/NSPasteboard | P0-01 |
| A5 | `.codex/agents/picsee-spec-adversary.toml`、`picsee-tdd-reviewer.toml` | 同名 mdpro 文件 | 改项目路径和 review 的 critical pass（见 B3） | A4 |
| A6 | `.claude/agents/picsee-opus-auditor.md`（原 `picsee-fable-auditor.md`）、`picsee-landing-verifier.md`、`picsee-number-registrar.md` | 同名 mdpro 文件 | 仓库路径、lanes、verify worktree 目录 `picsee-wt/verify-<sha7>`；registrar 扫描 `docs/adr/` 和 F 编号表。按 2026-10-22 第二轮决定，`picsee-fable-auditor.md` 必须建立，写明阶段读屏障并保持 read-only。**部分完成（2026-10-22，`cff345a`）**：`picsee-fable-auditor.md` 已建立（2026-10-23 改名 `picsee-opus-auditor.md`，起写一份报告文件，其余仍只读）；`picsee-landing-verifier.md`、`picsee-number-registrar.md` 未做 | A1 |
| A7 | `.claude/hooks/role-guard.sh` 及 python 模块 | 约 1.5k 行 | 先只移植实现者的 git 限制和禁止 `AskUserQuestion`，读 `PICSEE_ROLE`；真机测试者的写入限制同步移植 | git init |
| A8 | `.claude/hooks/session-size-guard.sh` | 原样 | 只改 handoff 路径 | — |
| A9 | `scripts/tdd/swift-lane.mjs`、`scripts/heavy-lock.sh` | mdpro `scripts/cargo-test-lane.mjs`、`scripts/heavy-lock.sh` @ `9f133f1d` | **已完成**（2026-10-22，#3）：原样复制 `4a8df7f`；锁 `64f93cf`；真实输出测试 `7d47ae9`；适配 `d207e5b`；HUP 信号补齐 `e027d2f`；审计修复：完成性/同名测试 `6b4f20c`，内核锁 `08989fe`。用途及偏差见 3.1；真实插件 drill 已验证 | P0-01 + tdd-guardian init |
| A10 | `.claude/tdd-guardian/config.json` | — | **已完成**（2026-10-22）：用户已运行 `/tdd-guardian:init`；#3 在 `d207e5b` 增加手动 `swift-red`，保留 `unit`；两个 probe 在 `cba8fa5` 统一加锁；插件 loader/probe 验证见 handoff。尚无 UITests/xcodebuild lane | P0-01 |

| A11 | `docs/feature-ledger.md` | mdpro 同名文件 | **已建账**（2026-10-21），102 行全部 `Absent`；规则 70 的 brief 模板在 Background 里引用账簿 ID，B3 加一条“用户可见行为变化须同次提交改账簿行” | — |
| A12 | `scripts/ledger/check.mjs` | mdpro `scripts/ledger/` | 按账簿「门禁」五条实现；`npm run ledger:check` 进 CI 和 landing verifier 的 lanes | P0-01 + tdd-guardian init |
| A13 | doc gardener：`docs/agents/doc-gardening.md`、`.claude/agents/picsee-doc-gardener.md`、`.codex/agents/picsee-doc-gardener.toml` | 新增，参考 OpenAI doc-gardening agent 和 Anthropic feature list | **已建立**（2026-10-21）。规则 70 的合入流程加一步：delegator 推送 PR head 前在分支 worktree 跑 `pr` 模式，提交 ledger diff，把 `Ledger-Gardener:` 行写进 PR 描述 | — |
| A14 | gardener 的机械约束 | 新增 | 两处：CI 检查 PR 描述里的 `Ledger-Gardener:` 行，且其中的 head 是 PR 的提交之一；Claude PreToolUse hook 在 `gh pr create` 时检查 `~/.picsee/gardening/` 有当前 HEAD 的报告。两者都是代码，走 tdd-guardian | P0-01 + tdd-guardian init |

### 3.1 Swift receipt 包装脚本的用途

receipt 是 RED-before-GREEN 的证据：实现者在改生产代码**之前**跑一次指定测试，确认它因断言失败而变红，把结果、测试文件指纹和 SHA 写进 `.claude/tdd-guardian/receipts.json`；改完后 `verify` 再跑，确认变绿并且测试没被削弱。landing verifier 和审计者凭它判断测试真的能抓到这个缺陷，不是事后补写的、断言空洞的测试。

插件 `receipt.js` 本身是通用的，任何 lane 命令都能跑，但它只认得 Vitest/Jest/pytest/cargo/Maven/dotnet 的计数行（`lib/exec.js` COUNT_PARSERS），不认得 XCTest（`Executed 12 tests, with 1 failure`）和 Swift Testing 的输出。直接用会有两个问题：
1. 每个 Swift RED 都被记为 `opaque-failure`（弱证据），landing verifier 要求 `assertion-failure`，等于每次都要 delegator 特批；
2. Swift 最常见的“假红”是编译失败：测试引用了还不存在的类型或方法，`swift test` 非零退出，同样被记成 `opaque-failure`，和真正的断言失败分不出来。

所以只写一个薄包装 `swift-lane.sh`，作为 tdd-guardian 的 lane 命令：
- 只跑指定测试（`swift test --filter` 或 `xcodebuild test -only-testing`），不跑整套；
- 编译失败时以“环境失败”退出，不输出计数，让插件判为 `environment` 拒收，迫使实现者先写能编译的桩（返回错误值），再让断言失败；
- 测试真正运行后，把 XCTest/Swift Testing 结果折算成插件认得的一行 `Tests run: N, Failures: F, Errors: 0, Skipped: S`。分工已定（2026-10-21 grilling）：包内单元测试是 Swift Testing，`UITests/` 与性能采样是 XCTest，所以两种输出都要解析，解析规则在 P0-01 后对照真实输出写；
- 走 `heavy-lock.sh`，避免两个实现者同时用 DerivedData。

record/verify、指纹、防削弱检查仍由插件完成，不像 mdpro 那样另写一套 300 行的 CLI。

2026-10-22 #3 实现记录（A9/A10）：最终用 `swift-lane.mjs`；先将源脚本原样提交（`4a8df7f`），再适配（`64f93cf`、`d207e5b`、`e027d2f`）。`.mjs` 保留逐流 UTF-8 解码、原始字节透传、背压与信号转发。第一轮审计指出旧实现会把 XCTest 类小计当成整轮完成，并合并同名 Swift 测试；该旧完成性声明已撤回，`6b4f20c` 改为：每个已启动框架均须到达根完成（XCTest 的 All tests/Selected tests/选中 bundle，Swift Testing 的最终 run summary），任一流出现崩溃标记、未完成框架或不一致计数均退出 70、不输出计数。XCTest 用稳定 case identity 核对根汇总；第二轮修复 `53165cb` 将 failure events 与 failed cases 分开，计数行只输出 failed cases，根 executed 数须等于 case 数且 failure events 至少等于 failed cases；Swift 普通输出缺少稳定 identity 时，按每条 terminal event 计数，绝不按 display name 去重，并与框架总数交叉检查，不一致即拒收。真实 crash-after-subtotal 与两个同名失败/两个同名跳过的 fixtures 已加入测试。第二轮 `8cea6aa` 只匹配锚定的 runner/runtime 崩溃诊断行，不扫描名称或断言消息中的词；新增真实的双断言 XCTest case 和 does not crash 的通过/失败 fixtures。

`PICSEE_SWIFT_FILTER` 由 record/verify 的环境继承，也可直接传一个参数给 wrapper；`--files` 只选指纹文件。计数前输出 `swift-lane filter=<f>`，使运行输出 tail 可见过滤器；插件仍不会约束两个调用的过滤器相等，verify 必须传相同值。正常断言失败是 exit 1 / `fail` / `assertion-failure`；编译、崩溃或不可靠运行是 exit 70 / `runner-error` / `environment`（插件保留无效诊断，不接受为有效 RED）；通过是 exit 0 / `pass` / `green`。新 API 按此流程在 record 时已有未提交的可编译桩，因此总带 `implementation-already-present` MEDIUM，须由审计核对。断言消息含 “No such file or directory” 会被插件升级为环境失败。初次真实插件 drill：DRILL-1 为 assertion RED → specification held，DRILL-2 编译错误为 environment；临时 Swift 改动已恢复，诊断 receipt 在 fix round 1 清理，原始证据留在 handoff。

`08989fe` 以 Python 3 标准库 `fcntl.flock` 取代目录锁/PID 回收：持久文件 `~/.picsee/locks/heavy.lock`（不删除/移动），job 经 `pass_fds` 继承描述符，只有最后一次 close 才解锁。选择 Python 是因为 macOS 支持该标准库，并能明确控制继承和进程组；没有额外包依赖。保留嵌套、超时 75、退出码与信号转发。SIGKILL holder 后其存活子进程仍持锁，两个 waiter 与三方竞争均有自动化测试。`unit` 原测试/coverage 命令不变，整个 lane 可由外层 heavy lock 串行；两个 discovery probe 都加锁。测试临时目录在 `os.tmpdir()`，由 `after()` 清理，测试插件固定为 0.10.2（保留 env override），fixtures 仅把 scratch/home 前缀改为中性路径。暂不实现 UITests/xcodebuild lane，XCTest 使用真实 scratch SwiftPM 输出验证。

2026-11-07 #195：App RED 使用 `node scripts/tdd/app-lane.mjs [filter]` 或 `PICSEE_APP_FILTER`，record/verify 必须保留相同过滤表达式（环境变量不写入 receipt）；具体命令和隔离规则见 [AGENTS.md 的 App RED 段](../../AGENTS.md)。运行时枚举精确 ID 后交给 `xcrun xctest -XCTest`，并核对完整执行集合；零匹配退出 70，无 filter 保持原有全 bundle 路径。

### B. 规则 70 引用到、picsee 也需要的基础规则

| # | 规则 | 内容 |
|---|---|---|
| B1 | `10-tdd.md` | Swift 测试放置、RED 先于实现、receipt id 前缀、heavy lock（`scripts/heavy-lock.sh` 同步移植，避免两个 xcodebuild 抢 DerivedData） |
| B2 | `25-careful-mode.md` | 可直接复制，`master` 改为 `main` |
| B3 | `60-review-checklist.md` | 新写 Swift critical pass：security-scoped 资源未释放、MainActor 违规、continuation 恢复两次或零次、旧 generation 结果覆盖新图、cell 复用串图、无界队列或缓存、主线程同步解码、sandbox 绕过、对原文件静默写入 |

## 4. 还需要你定的事

1. ~~名字前缀~~：沿用原名，目录隔离到 `~/.picsee/`。注意：如果 mdpro 的 Codex 智能体和 picsee 的在同一个 herdr server 里同时运行，`herdr agent prompt gpt-imple-1` 会有歧义；届时 picsee 一侧临时改名并在规则别名表记录。
2. ~~实现名额~~：只算 picsee。
3. ~~**Mac mini 是否参与真机测试**~~：已决定（2026-10-22）。「现在mac os device test 只需要在mac mini，也就是本机进行测试，看看相关rule哪些需要更新」；Mac mini 是唯一的本地真机测试机。显示验收仍保留 1× 与 2× 两档；「2x 验收，到时候ssh 接macbook」，即 @2x 从 mini 经 SSH 驱动 MacBook 桌面启动的 tmux 会话，接通前记 NOT VERIFIED。
4. ~~入库范围~~：不入库。`.gitignore` 增加 `evidence/deep-*`、`evidence/*-assembly.txt`、`.stitch/`、`design/` 中的大体积导出、`.playwright-cli/`；具体清单在 git init 前列出给用户确认，建 GitHub 私有库前再确认一次。

## 5. 执行顺序（确认后）

1. ~~审 `.gitignore` → `git init` → 首次提交 → push~~ 已完成（2026-10-21）：用户改为**公开**库 `anzchy/picsee`，Picview 逆向资料与 `evidence/` 不入库。
2. 写 B2、B3、B1 和规则 70，再写 A2、A1、A3。
3. 写 A6、A7、A8，确认 hooks 在 settings.json 中生效。
4. 写 A4、A5，Swift 命令先按架构文档里的 target 名填写，标注“P0-01 后校准”。
5. 历史基线原定由 gpt-auditor 加 Opus plan reviewer 盲审；2026-10-25 起的覆盖期间只交 opus-auditor，gpt-auditor 不派活。
6. P0-01 是唯一记录在案的 bootstrap 例外（2026-10-21 grilling 决定）：在主对话里做，仍先写一个会失败的 Swift Testing 测试、看它变红再实现，红/绿输出贴进 PR，PR 描述写明“bootstrap：tdd-guardian 尚不可用”；没有 receipt，但照常走审计与合入。
7. P0-01 合入后：用户运行 `/tdd-guardian:init`，再写 A9、A10，然后用一个真实 P0 工作项完整跑一遍 brief → matrix → attack → RED → handoff → 审计 → 合入。P0-02 起不再有例外。
