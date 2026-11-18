# 「All Code Is Slop」对 Mado 的启发（综合）

日期：2026-11-17。来源：Lauren Tan（@poteto，Grok Bot 团队）的会议演讲，文字稿（机器转写，有识别错误）加 20 张幻灯片截图。两份独立评审：Fable（读过全部幻灯片）和 Codex（读过全文和幻灯片），原稿在 `~/.mado/herdr/delegator/research/slop-talk-{fable,codex}.md`，本文是综合，不是转抄。评审只读，未构建、未跑测试、未启动 GUI；仓库一侧的数字是 `b6a67153` 上的 grep 与文件阅读结果。

演讲材料不是仓库内容，不进 App、不进 `evidence/`；本文只引用论点和幻灯片上的公开数字，不转载稿件。

## 1. 演讲讲了什么，哪些站得住

| # | 观点 | 证据强度 |
|---|---|---|
| 1 | 信任来自环境约束，不来自 agent。倒金字塔：代码/API/架构 > 静态检查（lint、类型、测试）> 验证（运行时、形式化）> prose（AGENTS.md、skills）> 人工评审；越往下越贵 | 经验框架，无对照 |
| 2 | 每次纠正 agent，尽量变成一条确定性检查，报错信息指导怎么修根因，而不是再加一行 prose | 合理，但「每次」过强：产品意图、视觉取舍未必有可靠判定器 |
| 3 | 禁用需要细腻判断的 API（例：产品代码禁 `useEffect`，只在 API 层内允许） | 讲者称「整类消除」，无违规率数据 |
| 4 | 目录即上下文：`electron-main/` 与 `electron-renderer/` 互相禁止 import（连类型也不行），经 `shared/`；文件名带约束 | 具体设计例，不是目录名保证了性能 |
| 5 | 代码库要干净，因为 agent 会照抄现有写法（Cursor 例：一个带注释的 `setTimeout` 补丁 → 共享模块 → 183 个 timer） | 传播链可信，因果（GC/卡顿）无 profiling |
| 6 | 禁约 99% 注释和 agent 主动写 markdown | **弱**：例子证明的是「权宜补丁会被复制」，不是「注释有害」 |
| 7 | 评审改看验证产物（视频、截图、状态图），最终「没什么可审」，agent 自己合并 | **自相矛盾**：另一页写着「yes, you should read the code sometimes」 |
| 8 | feature map（功能 / 怎么到达 / 什么能证明）+ skill 里的自定义 CLI | 合理；省 token 无量化 |
| 9 | 形式化验证：TLA+ 查状态机、Lean 证明算法 | **弱**：讲者自称在试验；11 条 TLA+ bug 清单来自她的个人游戏项目 |
| 10 | UI 的性质测试（bombadil） | 「抓到几个 bug」，无样本数 |
| 11 | 约 70% token 花在验证上 | **轶事**：来自另一人的一条推文 |
| 12 | 月 1.1 万个 PR、revert 约 0.5%、性能「多项改善」 | **幸存者偏差**：自报；revert 不是缺陷率；性能页 15 项里有 5 项变差（空闲 CPU 0.40%→0.80%、resize 3.0→6.9 ms、js+css 2.0→7.7 MB、空闲内存、冷开长对话），与标题「不牺牲质量」不符 |
| 13 | 内循环产出好代码之前，不要把它自动化 | 本场最稳的一条 |

结论：站得住的是 1、2、5、13；4、8 是好设计例；6、7、9、11、12 不能当结论用。

## 2. 对照 Mado（两份评审一致的部分）

- **验证与产物评审，Mado 已不输甚至更严**：账簿就是 feature map（能力 / 位置 / 怎么确认，加封闭状态枚举、真机才算 Shipped）；RED receipt、mado-verify、双盲审计、签名构建上的 Device-Smoke。owner 看的本来就是产物。
- **真正的差距只有一处**：审计发现和 owner 的纠正落成 prose、memory 和 PR 的 Still open，没有落成产品代码上的确定性检查。流程类纠正已经变成 hook 和检查（`git-add-guard`、`heavy-lock-guard`、`ledger-pair-guard`、`name-checks`、`push-guard.py`、`test-integrity.mjs`），产品代码类只有 `scripts/ci/for-where-ban.mjs` 一条（由 `ci.yml` 的 `node --test scripts/ci/*.test.mjs` 覆盖）。仓库里约 3100 行 agent prose（AGENTS.md、rules、SKILL.md、`docs/agents/`）加 47 个 memory，金字塔最窄的两层反而最厚。
- **不该照搬**：agent 自动合并；禁 99% 注释（Mado 的 `///` 是 API 文档，D9 反而要求写 why）；TLA+/Lean 立即上；bombadil 式 UI fuzz（面向 DOM，原生 AppKit 要撞 TCC 弹窗、GUI 锁和串行限制）；把「70% token 用于验证」或 PR 数、revert 率当目标；直接禁框架 API（我们不拥有 AppKit/SwiftUI，只能包一层再禁直接调用）。

## 3. 两份评审的分歧，和我的取舍

| 议题 | Fable | Codex | 取舍 |
|---|---|---|---|
| 产品代码 ban 表 | 把 for-where 推广成表（`@unchecked Sendable` 23、`Task.detached` 11、`Task.sleep` 11、`DispatchQueue.main.async` 6…）+ ratchet | 不要把 `Task`、Timer、`DispatchQueue` 一律禁；每批只固化一类**重复、可复现、可判定**的审计发现 | **先数后写**：先统计最近审计发现（D1–D12），出现 ≥3 次的才写检查；ban 表只对已有 ratchet 计数、不禁用（`Task.sleep` 做防抖是正当用法）。Fable 的计数我核对过，产品代码范围内准确（含测试会多得多） |
| `ledger:check` | 没提 | 优先级最高：账簿五条语义门禁迁移计划 A12 至今待建，建议先做最小版（枚举、重复 ID、Partial 限制、Shipped 真机链接、文件路径存在） | **采纳 Codex**。账簿是唯一事实源，它的校验现在靠人 |
| 目标依赖边界 | 锁住现在为 0 的边界：`MadoCore`、`MadoApplication` 不得 import AppKit/SwiftUI | 同意，另指出 `Package.swift` 第 34 行给 `MadoInfrastructure` 追加了对 `MadoApplication` 的依赖，与架构文档「Infrastructure 依赖 Core」不一致，规则固定前先澄清 | **都采纳**：先澄清再固定；规则只做窄的 import 检查，不扩成全文匹配 |
| feature map | 从账簿生成机器可读表（入口、证明） | 不要另造平行 feature map，选一个完整入口（如 VIEW-03）把账簿和 device 脚本接起来试点 | **采纳 Codex**：先单入口试点，不先写生成器（否则多一份事实源）。另：`scripts/device/device.py` 已是 `build`/`doctor`/`cleanup` 的统一入口，真正缺的是把 `issue637-*` 这类一次性驱动收成通用子命令，Fable 没核实到这点 |
| 形式化/状态图 | 状态图附进证据；TLA+ 暂不做，除非「过期结果送达」类 bug 反复出现 | 做一个有退出条件的试点（取消/过期完成或租约获取/释放） | **折中**：先做带固定种子的序列性质测试（两边都支持，已有 `AnnotationDocumentTests`、`BrowsingCurrentSuccessorTests` 可沿用）；TLA+ 只有在这类 bug 复发时才开 |
| 评审方式 | 状态图作为 owner 评审产物 | 评审先看证据索引，再读风险代码；保留双盲与 owner 权限 | 两者可并行，且都不减少审计维度 |
| 度量 | 瘦身 prose：每转成一个检查就删对应文字 | 用质量与成本评价自动化，不设 PR 数/token KPI，先拿两批基线 | 两条都采纳，且互不冲突 |

## 4. 建议（排序，每条都是后续单独的 ticket，本文不实施任何一条）

1. **最小 `ledger:check`**（成本低–中）。有效/无效 fixture 各覆盖：状态枚举、重复 ID、Partial 必须有限制、Shipped 必须有真机链接、引用的文件存在；先对 main 只报告，再对新增违规阻断。风险：历史脏数据、Markdown 解析误报、「文件存在」被误当成「行为真实」；真机和 gardener 继续保留。
2. **两条窄的边界门禁**（低–中）：`MadoCore`/`MadoApplication` 不得 import AppKit/SwiftUI（现在是 0 处，零迁移成本）；`Package.swift` 的实际依赖图做允许表，先决定 Infrastructure→Application 这条是改架构文档还是改依赖。风险：正则漏 `#if` 和导入变体，必要时改用语法工具。
3. **审计发现回流检查**（低，先统计）：数最近约 20 个 PR 的 Critical/High，按 D1–D12 分类；出现 ≥3 次的一类写成确定性检查，报错写明正确做法，例外清单要带理由（仿 `scripts/name-checks/exceptions.json`）。两批后看同类返工是否减少，零收益就收窄或撤回。风险：把一次情境判断变成永久禁令，检查本身变成要维护的 slop。
4. **产品代码 ratchet 表**（低，依赖 3 的统计）：只对计数设上限不许增加（`@unchecked Sendable`、`Task.detached`、`nonisolated(unsafe)`、`App/CanvasWindowController.swift` 的 2932 行等），不直接禁用。风险：行数 ratchet 会促使机械拆文件。
5. **序列性质测试试点**（中）：open → navigate → cancel → 过期完成/close 的受控序列，固定种子、失败时打印种子和完整操作序列并最小化；验收是故意引入旧结果覆盖的变体能被抓到。风险：oracle 复制实现、有限种子被说成穷尽证明、种子不固定变成新 flake。
6. **账簿 × device 脚本接通一个入口**（中）：选 VIEW-03 一个入口，证据索引含账簿 ID、head SHA、TestAssets、操作、断言、截图/日志和 NOT VERIFIED；顺带把 `issue637-*` 收成通用子命令。GUI 锁、TCC 规矩必须进脚本。风险：AX 合成输入冒充真实手势；单入口通过不得晋级整行。
7. **评审先看证据索引**（低）：handoff 里把验收标准 → 证据 → 未验项排前面，D3/D4 仍给代码 trace；双盲不减。比较两批审计耗时和漏检。
8. **度量与瘦身**（低–中）：记录已验验收标准数、合入后缺陷、返工、gate 等待、owner 时间、token 重读；性能用签名构建的固定场景记录并包含资源退步。每把一条规则变成检查，就删对应 prose（例：memory 里 `sync-main-after-merge` 已有 hook）。不设 PR 数 / token 占比 / revert 率目标。

延后（有触发条件才做）：TLA+（「过期结果送达」类 bug 复发）、Lean、UI 级随机驱动。

## 5. 没核实的

- 评审没有跑任何构建或测试，「已有」指读到机制，不保证历史上每个任务都遵守。
- 所谓「近 20 个 PR 的审计发现分布」还没统计；建议 3 的价值取决于它，没有数据前不要预设哪类会胜出。
- Fable 的 grep 计数是行数近似值（同一行多次出现算一次）；ratchet 落地时要用同一口径。
- 演讲里的性能与吞吐数字是自报；本文引用它们只为说明证据强度，不是 Mado 的基线。
