# 复盘：GitHub Actions 提速（2026-11-04）

这次提速的目标是：**不删、不弱化任何必要的测试或检查**，让 Mado 的 CI 变快、少占 macOS 名额。

- 审计报告：[`docs/audit/20261104-github-actions-audit.md`](../audit/20261104-github-actions-audit.md)
- 追踪 issue：#483
- 实施 issue：#478–#482
- 实施 PR：#485
- 后续修复：#474、#488

本文记录过程、结果，以及可以拿到别的项目复用的经验。

## 1. 结果

| 场景 | 墙钟 | macOS job 分钟 | 相比基线 |
|---|---|---|---|
| 基线（58 次运行的中位数，4 个 macOS job） | 8.0 min | 约 20.9 | — |
| 只改文档/agent 文件的 PR（probe #487） | 0.75 min | 0 | 墙钟 −91%，macOS −100% |
| 改了 Swift、缓存已就绪（probe #486） | 5.0 min | 10.7 | −38% / −49% |
| 真实代码 PR #489（改了测试） | 5.5 min | 12.6 | |
| 真实代码 PR #490 | 4.9 min | 10.7 | |
| 真实代码 PR #491（大量 Swift 改动） | 6.3 min | 14.6 | |
| 3 个真实代码 PR 平均 | 约 5.6 min | 约 12.6 | 约 −30% / −40% |

- 一个 run 占用的 macOS job 从 4 个降到 3 个。账户的 macOS 并发上限是 5 个，和 mdpro 共用，所以少占一个就能明显减少排队。
- 测试数量没变：non-UI 1040、MacUI 609、App 236，都和改前一致。三个必需检查照常报告。
- 缓存总量约 0.7 GB，仓库上限是 10 GB。
- 审计预测改完后代码 PR 约 4–4.5 min，实际是 4.9–6.3 min，**预测偏乐观**。原因是 App tests 成了新的关键路径（约 4.5 min），而且改动面大时，有缓存也要重编不少文件。
- 第 8 步计划采 5 个代码 PR 的样本，目前只有 3 个，上表的平均数是暂定值。

## 2. 过程

1. **先审计，不动手。** 由一个 subagent 只读地拉取最近 100 个 run，把每个 job 的耗时拆成排队、准备、运行三段，再从日志里读出编译和测试各占多少时间。然后在本机的全新 worktree 里做两次构建实验。gpt-auditor 对审计和计划给了独立意见。
2. **拆成 issue。** 按收益排出 C1–C5 五项，一项一个 issue（#478–#482），另开追踪 issue #483，并在上面贴出排期。owner 决定把这批 issue 排到最前面实施。
3. **一个 PR 实施。** 五项都改 `ci.yml` 以及解析它的脚本，分成多个 PR 会互相冲突，所以合成一个 PR #485。
4. **双盲审计。** gpt-auditor 和 opus-auditor 互不看对方的报告，审完后有一轮修复，再由两位各自确认（两轮封顶）。
5. **合并后实测。** 合并之前 main 上还没有缓存，热缓存路径无法验证，所以合并后另开两个 probe PR：#486 改一个 Swift 文件，#487 只改文档。之后的真实 PR 继续记录样本。
6. **后续 issue。** 实测中发现的问题都开成单独的 issue（#488），不在原 PR 里继续加改动。

## 3. 做了什么，为什么

| 项 | 改动 | 关键理由 |
|---|---|---|
| C1 | SwiftPM `.build` 缓存，加上 `-enable-incremental-file-hashing` | 本机实验：新 checkout 会改掉所有文件的 mtime，只缓存 `.build` 时仍要重编 277 个文件；加上文件哈希后重编 0 个（7.8 s） |
| C2 | Build unsigned app 并进 App tests job；ledger 检查移到 ubuntu | 两者的构建基本重复，Sparkle 每次 run 要克隆两遍；合并后少占一个 macOS 名额 |
| C3 | 只改文档/agent 文件的 PR 跳过 macOS job，必需检查照常报告 | 最近 100 个 PR 里有 23 个是这类，每个照样花约 22 macOS 分钟 |
| C4 | 每个 main push 用自己的 concurrency 组 | 原来的共用组会丢掉排在中间的 main run，使某个 main 提交没有跑过 CI |
| C5 | Design check 缓存 npm 和 Playwright Chromium | 每次都重新下载，约 18 s；收益小，标为可选 |

## 4. 经验（可迁移）

### 测量

- **先拆开看时间花在哪。** 把 job 耗时拆成排队、准备、运行，运行再拆成编译和测试（读日志里的 `Build complete!`、`Test run … passed` 时间戳）。Mado 的运行时间约三分之二花在编译上；测试本身和环境准备都不慢。不拆开看，很容易去优化不该优化的地方。
- **缓存有没有用，先在本机做实验。** 在全新的 worktree 里把所有受跟踪文件 touch 一遍，模拟新 checkout 把 mtime 全部改掉的情况，再构建，数一数重编了多少个文件。很多增量编译器按 mtime 判断文件有没有变。这一步实验决定了 C1 能不能起作用；不做的话，缓存上线后可能毫无效果。
- **排队也算进耗时。** 先确认账户的并发上限，以及和哪些项目共用。Mado 和 mdpro 共用 5 个 macOS 名额，减少每个 run 占用的 job 数，比让单个 job 变快更能减少排队。
- **预测数字要合并后实测核对。** 审计里的估算比实际快约 1–2 分钟。之后只认实测数据，并注明样本数，不把单次结果写成中位数。

### 缓存设计

- **只在 main push 时保存缓存，PR 只读取。** PR 写不了缓存，就无法污染它。
- **main 每次都从零构建，不读缓存。** 这样每个 main 提交始终经过一次干净的完整构建，缓存出问题只会影响 PR 的速度，不会影响 main 上的结论。
- **cache key 要包含工具链版本**（Xcode 的 build 号）和 manifest 的哈希。`workflow_dispatch` 留一个跳过缓存（cold）的选项，用来排查。

### 跳过检查，但不让必需检查消失

- **不要在 workflow 级别用 `paths` 过滤。** 那样被跳过的必需检查会一直停在 pending，PR 无法合并。正确做法是：先跑一个很快的分类 job，按结果在 job 级别用 `if:` 跳过，再用一个汇总 job（Walking skeleton）把结果报告给 branch protection。
- **分类脚本从可信的 base 分支取。** 否则 PR 可以改掉分类脚本，把自己伪装成只改了文档。
- **分类规则 fail closed。** 判断不了时按原生改动处理，宁可多跑也不漏跑。
- **原生输入的清单要从测试实际读了哪些文件来定。** 审计发现，App tests 会读 `THIRD_PARTY_NOTICES.md`，原来的输入清单却漏了它（#474）。漏一个文件，就可能误跳过一次本该跑的测试。

### 改 workflow 时连带要改的东西

- **有脚本按名字解析 workflow。** Mado 的 `gates-rows.mjs` 按 job 名和步骤名找结果，`flaky-gate.test.mjs` 按步骤名找。改 job 名或步骤名时，这些脚本要在同一个 PR 里一起改，并保持既定的步骤名不变。
- **合并 job 后，"job 成功"不再等于"测试跑过了"。** unsigned build 并进 App tests 后，手动触发且 `app_tests=false` 的 run 里，App tests job 仍然成功，但测试步骤其实被跳过了；按 job 结论写 PASS 就会出错（#488 的 High）。判断要看具体的步骤，不看 job。
- **被跳过的 job 如果名字含表达式，GitHub 会显示原始表达式**（#488）。job 名尽量用静态字符串。

### 验收与审计

- **验收条件写到命令级别。** C2 的验收写的是「unsigned build 用与基线完全相同的命令」。实现时多加了一个 hashing 参数，gpt-auditor 判为 High。最后的处理是只允许这一个参数，并由测试锁定整条命令。宽松的前缀匹配测试会把这类偏差放过去。
- **"取消"和"失败"要分开处理。** opus-auditor 指出，汇总 job 只看 unsigned build 的输出时，App job 被取消也能通过。是否接受这种情况要明确决定，并写进测试。
- **合并前证明不了的路径，要说明，并安排合并后验证。** 热缓存在合并前不存在。我们在 PR 描述里写明了这一点，合并后立刻用 probe PR 补上证据，而不是声称已经验证过。

## 5. 下一步

- App tests 现在约 4.5 min，是关键路径。第二轮优化看这里：`build-for-testing` 的缓存命中率，以及 app-lane 本身。
- 再采集 2 个代码 PR 的样本，然后在 #483 贴最终的前后对比并关闭它。
- probe 分支 `probe/ci-warm-swift`、`probe/ci-docs-only` 等 owner 确认后删除。
