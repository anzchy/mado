# CI 失败审计（截至 2026-11-03）

## 1. 结论摘要

- 统计范围：GitHub Actions 上 anzchy/picsee 的全部 585 次 workflow run（2026-10-22 03:08 至 2026-11-03 07:20 UTC），其中最终结论 failure 72 次、cancelled 35 次、success 476 次、仍在运行 2 次；没有 timed_out 结论的 run。
- 把被重跑（re-run）覆盖掉的早期 attempt 也算进来，共有 **113 个失败 job**，分布在 92 个 run 里。全部 113 个都找到了决定性的错误行并归了类，没有无法分类的 job。
- **最大的一类原因：对时间敏感的测试在 CI runner 上不稳定（flaky）**，共 70 个 job（61.9%），分布在 63 个 run。其中 App tests 侧 33 个（A 类），Swift 包测试侧 37 个（P 类）。main 分支上的 24 个失败 job 全都属于这一类。
- 按单个测试算，失败最多的是 App 测试 `t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves()`（`LostAccessRecoveryTests.swift`，180 s 时间上限超时）：15 个 job，2026-10-30 至 11-01。#352 在 2026-11-01 07:56 合并后，它就没有再失败过。
- 并列第二（各 15 个 job，13.3%）的有两类。一类是 **PR body Gates lint**：15 个 job，其中 9 个是 `<lane> PASS has a stale head without CODE same evidence`。这类失败修起来最快，中位数 4 分钟。但重跑 4 次全部失败，每次都只能改 PR 描述或推新提交才过。
- 另一类是 **在分支上稳定复现的失败**（R+D：真实缺陷、设计 pin 或 UI 对照断言）：15 个 job。它们都靠新提交修复，等待最久（中位数 101 分钟）。
- 共性因素：(1) 时间上限和墙钟断言写死，而 CI runner 的负载比本地高；(2) 有几项检查只在 CI 里跑，本地 `owner-gates.sh` 不跑：App tests、`design:check` 和 `scripts/design/*.test.mjs`、PR body lint；(3) 生成物或哈希需要随改动重新 pin，比如 PR 描述里的 Gates SHA、设计源哈希、快捷键页。

## 2. 方法与覆盖

数据全部来自 `gh` CLI，只读：

1. `gh run list -L 1000` 和 `gh api repos/anzchy/picsee/actions/runs`（分页）列出全部 585 个 run。`gh run list` 只显示每个 run 的最后一次 attempt，所以又用 API 读出 `run_attempt`。有 39 个 run 被重跑过，共 42 个早期 attempt，对每个早期 attempt 用 `actions/runs/<id>/attempts/<n>/jobs` 取出失败 job。
2. 失败 job 来源：72 个 failure run 的最后一次 attempt 中有 79 个 failure job；早期 attempt 中有 34 个 failure job，其中 19 个（18 个 run）在重跑后通过。合计 113 个。
3. 每个失败 job 用 `gh api repos/anzchy/picsee/actions/jobs/<id>/logs` 下载日志，只用脚本抽取以下内容：Swift Testing 的 `✘ Test … recorded an issue` 行、`Time limit was exceeded` 行、`##[error]Process completed` 之前的最后一行，以及 node test 的断言 diff。
4. 被取消的 job 不计入失败，单独统计。失败 run 里另有 7 个 cancelled job：2 个 Walking skeleton（最后一次 attempt）、2 个 Agent tooling、2 个 PR body Gates、1 个 Walking skeleton（早期 attempt）。
5. 级联失败单独记为 W 类，不算根因。2026-11-02 #394 拆分 lane 之后，Walking skeleton 只汇总 package-tests、package-macui-tests、unsigned-build 三个 job 的结果。在那之前，Walking skeleton 本身就跑 ledger 检查、Swift 包测试、unsigned build（早期还包括 design:check）。所以 54 个 Walking skeleton 失败里，51 个是它自己步骤的失败，按实际失败的步骤归类，只有 3 个是级联。
6. 「损失时间」的定义：从失败 job 所在 attempt 结束，到同一 workflow、同一分支上第一个更晚结束的成功 run。它包含排队和等人的时间，是上限，不是纯 CI 耗时。找不到后续绿灯（4 个）的记为 unknown。
7. 「不改代码就过了」的判定：重跑后通过（rerun-pass），或者同一 head SHA 上更晚的 run 通过（same-sha-pass，PR body 类通常是改了 PR 描述）。main 上每次 push 都是新 SHA，所以 main 的 flaky 失败在这一列里不会被算作「不改代码通过」，这一列对 main 偏低。

覆盖情况：113/113 个失败 job 都已分类。归类有判断成分的地方在正文里注明，例如 R 类和 P 类的边界。

### 被取消的 run

35 个 cancelled run 全部是 `pull_request` 事件：PR body 23 个，CI 12 个。两个 workflow 都配置了 `cancel-in-progress`，其中 CI 只对 pull_request 取消。有 23 个能直接看到：在它结束前，同一分支、同一 workflow 已经开始了更新的 run，也就是被新推送或 PR 描述编辑顶替。其余 12 个查不到当时的触发者，无法判定。

## 3. 原因总表

「不改代码即通过」指重跑通过或同 SHA 后续 run 通过；「损失时间」是到同分支下一个绿灯的分钟数（中位数，括号内为最小–最大），定义见 §2。份额以 113 个失败 job 为分母。

| 类 | 原因 | Job | Run | 份额 | 首次 | 最后 | 不改代码即通过 | 损失时间 中位（范围）分钟 | 示例 |
|---|---|---|---|---|---|---|---|---|---|
| **A** | **App tests 不稳定（合计）** | **33** | **30** | **29.2%** | 10-29 | 11-03 | 11 | 21 | |
| A1 | `t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves` 180 s 超时 | 15 | 13 | 13.3% | 10-30 | 11-01 | 4 | 33（4–254） | [41043459948](https://github.com/anzchy/picsee/actions/runs/41043459948)、[41273898355](https://github.com/anzchy/picsee/actions/runs/41273898355)、[41283797808](https://github.com/anzchy/picsee/actions/runs/41283797808) |
| A3 | `issue281RetryAfterFailedReadShowsTheReadingFooter` 侧栏计数 "2" ≠ "0" | 6 | 5 | 5.3% | 10-30 | 11-02 | 2 | 147（3–275） | [41069115657](https://github.com/anzchy/picsee/actions/runs/41069115657)、[41394303574](https://github.com/anzchy/picsee/actions/runs/41394303574) |
| A2 | `t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores` 恢复网格未显示 | 5 | 5 | 4.4% | 10-31 | 11-01 | 3 | 8（5–99） | [41151044034](https://github.com/anzchy/picsee/actions/runs/41151044034)、[41319485390](https://github.com/anzchy/picsee/actions/runs/41319485390/attempts/1) |
| A4 | `sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild` 等待超时 | 5 | 5 | 4.4% | 10-29 | 11-03 | 2 | 18（5–21） | [40925649249](https://github.com/anzchy/picsee/actions/runs/40925649249)、[41562256618](https://github.com/anzchy/picsee/actions/runs/41562256618/attempts/1) |
| A5 | `t229Fix2RecoveryFollowsRootMovedWhileReadable` 180 s 超时 | 2 | 2 | 1.8% | 10-30 | 10-30 | 0 | 22.5（19–26） | [40993675568](https://github.com/anzchy/picsee/actions/runs/40993675568) |
| **P** | **Swift 包测试时序不稳定（合计）** | **37** | **34** | **32.7%** | 10-25 | 11-02 | 8 | 46 | |
| P2 | 单个测试的墙钟/轮询断言失败（`dispatchWatchSchedulerFiresWithinRealTimeBound`、`sidebarSlowCounterDoesNotDelayRows`、`watchedRefreshReconciles…`、`diagnosticsPanel…` 等） | 20 | 19 | 17.7% | 10-25 | 10-31 | 4 | 43.5（5–906） | [40464026412](https://github.com/anzchy/picsee/actions/runs/40464026412)、[40688597266](https://github.com/anzchy/picsee/actions/runs/40688597266)、[41151989082](https://github.com/anzchy/picsee/actions/runs/41151989082) |
| P1 | `.timeLimit`（60/120 s）超时：一次运行里 1–96 个测试超时，多数是多个互不相关的测试同时超时 | 17 | 16 | 15.0% | 10-26 | 11-02 | 4 | 46（7–636） | [40831377585](https://github.com/anzchy/picsee/actions/runs/40831377585)、[41315211327](https://github.com/anzchy/picsee/actions/runs/41315211327)、[41388439000](https://github.com/anzchy/picsee/actions/runs/41388439000) |
| **G** | **PR body Gates lint（合计）** | **15** | **11** | **13.3%** | 10-30 | 11-03 | 9 | 4 | |
| G1 | `<lane> PASS has a stale head without CODE same evidence` | 9 | 6 | 8.0% | 10-31 | 11-03 | 6 | 4（0–46） | [41186143024](https://github.com/anzchy/picsee/actions/runs/41186143024)、[41319485311](https://github.com/anzchy/picsee/actions/runs/41319485311)、[41589290591](https://github.com/anzchy/picsee/actions/runs/41589290591) |
| G2 | `missing ## Gates table` | 2 | 2 | 1.8% | 10-31 | 11-01 | 1 | 8（另 1 个 unknown） | [41271074703](https://github.com/anzchy/picsee/actions/runs/41271074703)、[41186855191](https://github.com/anzchy/picsee/actions/runs/41186855191) |
| G3 | `UI files changed; PR body needs a populated ## UI-Parity table` | 2 | 1 | 1.8% | 11-01 | 11-01 | 2 | 8.5（4–13） | [41283797785](https://github.com/anzchy/picsee/actions/runs/41283797785) |
| G4 | `UI files changed; PR body needs a Device-Smoke: line` | 1 | 1 | 0.9% | 11-01 | 11-01 | 0 | 11 | [41286004139](https://github.com/anzchy/picsee/actions/runs/41286004139) |
| G5 | `trusted PR-body lint lacks checkGates`（引入 Gates lint 的 PR 本身） | 1 | 1 | 0.9% | 10-30 | 10-30 | 0 | unknown | [41143680858](https://github.com/anzchy/picsee/actions/runs/41143680858) |
| **R** | **分支上稳定复现、靠新提交修复的测试失败** | **8** | **6** | **7.1%** | 10-27 | 10-31 | 0 | 103.5（31–195） | [40453300974](https://github.com/anzchy/picsee/actions/runs/40453300974)、[41173251359](https://github.com/anzchy/picsee/actions/runs/41173251359)、[40931059324](https://github.com/anzchy/picsee/actions/runs/40931059324) |
| **D2** | **UI 对照断言（pinned CSS／设计稿几何、颜色）失败** | **5** | **4** | **4.4%** | 10-26 | 10-31 | 0 | 119（26–1334） | [40307488398](https://github.com/anzchy/picsee/actions/runs/40307488398)、[40998496072](https://github.com/anzchy/picsee/actions/runs/40998496072)、[41172039082](https://github.com/anzchy/picsee/actions/runs/41172039082) |
| **D1** | **设计源/manifest 哈希 pin 失配** | **2** | **2** | **1.8%** | 10-27 | 11-03 | 0 | 32.5（20–45） | [40527964158](https://github.com/anzchy/picsee/actions/runs/40527964158)、[41584895034](https://github.com/anzchy/picsee/actions/runs/41584895034) |
| **K** | **design:check／快捷键检查（合计）** | **6** | **6** | **5.3%** | 10-28 | 11-03 | 0 | 84 | |
| K1 | 快捷键页与代码同步检查（`KEY_SITES`、`CommandMenu.swift` 正则、keyCode 写法解析） | 4 | 4 | 3.5% | 10-29 | 11-03 | 0 | 30.5（9–122） | [41381549535](https://github.com/anzchy/picsee/actions/runs/41381549535)、[41577227514](https://github.com/anzchy/picsee/actions/runs/41577227514) |
| K2 | design:check 页面版式：孤行（orphan line） | 1 | 1 | 0.9% | 10-28 | 10-28 | 0 | 244 | [40634141593](https://github.com/anzchy/picsee/actions/runs/40634141593) |
| K3 | design:check 启动失败：本地 http.server 未应答 | 1 | 1 | 0.9% | 10-28 | 10-28 | 0 | 285 | [40630233760](https://github.com/anzchy/picsee/actions/runs/40630233760) |
| **T** | **CI 工具／基础设施（合计）** | **4** | **4** | **3.5%** | 10-29 | 11-02 | 0 | 21 | |
| T1 | Node 测试依赖本机 tdd-guardian 插件缓存，runner 上不存在 | 1 | 1 | 0.9% | 10-29 | 10-29 | 0 | 25 | [40918011062](https://github.com/anzchy/picsee/actions/runs/40918011062) |
| T2 | 新 watchdog 的自测在 runner 上失败 | 1 | 1 | 0.9% | 11-02 | 11-02 | 0 | 17 | [41413949890](https://github.com/anzchy/picsee/actions/runs/41413949890) |
| T3 | 有意复现挂起的 throwaway 运行（watchdog exit 124） | 1 | 1 | 0.9% | 11-02 | 11-02 | 0 | unknown | [41413668861](https://github.com/anzchy/picsee/actions/runs/41413668861) |
| T4 | Release：`GitHub Actions is not permitted to create or approve pull requests` | 1 | 1 | 0.9% | 10-31 | 10-31 | 0 | unknown | [41186517202](https://github.com/anzchy/picsee/actions/runs/41186517202) |
| **W** | **级联：Walking skeleton 只因上游 job 失败而失败（不计根因）** | **3** | **3** | **2.7%** | 11-02 | 11-03 | 0 | 31（17–45） | [41584895034](https://github.com/anzchy/picsee/actions/runs/41584895034) |
| | **合计** | **113** | **92** | 100% | | | 28 | | |

另有 4 个 job 同时挂了第二个原因，表中只按主因计一次：41169362149 和 41174226346 第 2 次 attempt 的 A1 job 同时有 A3 失败；41268174744 第 2 次 attempt 的 A3 job 同时有 A2 失败；40307488398 的两个 D2 job 同时有 P2（`watchedRefreshReconciles…`）失败。

## 4. 分原因分析

### A. App tests 不稳定（33 个 job，29.2%）

- App tests 从 2026-10-29 起进入 CI（分支 `ci/app-tests-job`）。之后 A 类只有 5 个测试反复出现，而且全部是异步或时序相关：等 `condition()`、180 s 时间上限、恢复后的网格可见性、侧栏计数。
- 不是代码回归的证据：A 类 33 个里有 13 个发生在 main 上。11 个 job 重跑或同 SHA 再跑一次就过了。重跑过的早期 attempt 里，A 类有 14 个，其中 11 个重跑后通过。
- A1 是失败最多的单个测试，有 15 个 job。修复它的 PR #352（`fix/333-t231fix2-flake`，"await complete foreground passes between moves"）在 2026-11-01 07:56 合并。最后一次 A1 失败是 07:53，之后再没有出现。
- A2 和 A3 就是 #379 里的两个 flaky App 测试。owner 在 2026-11-01 决定暂停修复，把它们写进 CHANGELOG 的 Known issues（#380）。合并之后 A3 仍在 11-02 出现了一次（[41394303574](https://github.com/anzchy/picsee/actions/runs/41394303574)）。
- A4 跨度最长（10-29 至 11-03），11-03 仍有一次（[41562256618 attempt 1](https://github.com/anzchy/picsee/actions/runs/41562256618/attempts/1)，`wait timed out after 100.0 seconds`），说明它还没有修好。
- 损失时间：A3 中位 147 分钟，是 A 类里最高的。A2 中位 8 分钟，A4 中位 18 分钟，说明重跑基本就能过。

### P. Swift 包测试时序不稳定（37 个 job，32.7%）

- **P2：单个测试的墙钟断言失败，20 个 job。** 典型例子：
  - `FSEventSourceTests.swift:104` 要求 `elapsed < .seconds(10)`；
  - `SidebarFolderLoadSessionTests.swift:49`，`sidebarSlowCounterDoesNotDelayRows`，2026-10-28 一天内失败 7 个 job；
  - `ThumbnailDiskCacheTests.swift:142` 断言 `firstHitDraw < forced*4+0.002`；
  - `DiagnosticsPanelModelTests.swift:312`，`reads 4 == stopped 3`。

  #252（`test/ci-timing-flakes`，"make CI timing tests robust on a loaded runner"）在 10-28 16:47 合并。`sidebarSlowCounter…` 和 `dispatchWatchScheduler…` 最后一次失败都在合并之前。之后只有 `diagnosticsPanelDefaultClockRefreshesUntilHidden` 在 10-30 和 10-31 又失败了 3 次。
- **P1：Swift Testing 的 `.timeLimit` 成批超时，17 个 job。** 同一次运行里多个互不相关的测试一起报 `Time limit was exceeded: 60.000 seconds` 或 `120.000 seconds`，最多一次有 96 个测试、607 个 issue（[41315211327 attempt 2](https://github.com/anzchy/picsee/actions/runs/41315211327/attempts/2)）。这说明问题出在 runner 整体负载或执行器排队，而不是某个测试的逻辑。修复按时间线分了几轮：
  - #271（10-29 09:32，"allow for main actor queue time"）；
  - #278（10-29 19:57，"await conditions instead of one-minute limits"）；
  - 11-01 在 `fix/332-footer-status` 和 `feat/316-wall-drift` 上又集中爆发（每次 128–607 个 issue）；
  - 之后的修复是 #394（11-02 09:09，拆分 package lane、MacUI 串行、加挂起 watchdog）、#397（watch timing 改成确定性）和 #401（等待不再设墙钟截止）。

  #394 合并后没有再出现 P1。
- 边界说明：40932813794 的 Walking skeleton job 里，有 10 个超时测试，还有 1 个非超时失败（`t229SidebarParentFailureReportsFailureAndKeepsKnownRows`），按超时占多数归入 P1。同一分支的下一个 run（40936369269）只剩超时，重跑后通过。
- P 类 11 个 job 在 main 上。重跑过的早期 attempt 里 P 类有 13 个，其中 8 个重跑后通过。

### G. PR body Gates lint（15 个 job，13.3%）

- 这个检查从 2026-10-30 的 #318 开始启用。G5 是 #318 自己的 PR：它的可信基线（main）里还没有 `checkGates`，所以 lint 拒绝运行，这是一次性的引导失败。
- **G1 stale head，9 个 job，是 G 类主因。** PR 描述 Gates 表里某个 lane 标了 PASS，记录的 SHA 却不是当前 head，也没有附 `CODE same <sha>` 证据（规则见 `scripts/agents/ui-parity-pr-body-lint.mjs:118`）。涉及的 lane 有 ledger、package-tests、app-tests。原因是推送了新提交（常见的是 gardener 的 `docs(ledger)` 提交或 rebase）之后没有同步更新 Gates 表。
- **重跑这个 job 没用。** 41186143024、41268174719、41317730847、41283797785 四个 run 的第 2 次 attempt 都以同样的原因失败。lint 读的是 `github.event.pull_request.body`，而重跑使用原事件的数据。真正让检查通过的，都是之后由 `edited` 或 `synchronize` 触发的新 run。
- G2：appcast PR 是手工建的，没有 Gates 表（41186855191，后来也没有出现绿灯）；文档 PR `docs/131-macbook-runbook` 后来补了表，8 分钟后通过。G3 和 G4 是 UI 文件有改动时，缺少 UI-Parity 表或 Device-Smoke 行。
- G 类修复最快（中位 4 分钟），但每次都需要人或 delegator 再改一次 PR 描述。

### R. 分支上稳定复现的失败（8 个 job，7.1%）

同一 SHA 上重跑仍然失败，或者只在该分支出现，最后靠新提交修复。不能确定是产品代码缺陷还是新测试本身有问题，这里只按「需要改代码或测试」归类。

| Run | 分支 | 失败 |
|---|---|---|
| [40453300974](https://github.com/anzchy/picsee/actions/runs/40453300974) ×2 | `p3/p3-06-memory-budget` | `warmDiskLoadCancelledWhileWaitingLeavesNoStaging`（两次 attempt 都失败） |
| [40912111411](https://github.com/anzchy/picsee/actions/runs/40912111411) | `ci/app-tests-job` | issue140 两个测试：窗口上出现了 `_NSAlertPanel`。这是 App tests 第一次在 CI 上跑 |
| [40931059324](https://github.com/anzchy/picsee/actions/runs/40931059324) | `p2/p2-08c-lost-access-tracer` | t229 磁盘挂载/卸载事件顺序 |
| [40932813794](https://github.com/anzchy/picsee/actions/runs/40932813794)（App） | 同上 | `issue136CombinedWindowWatchedSearchRefreshUpdatesInspectorSynchronously` |
| [41041228587](https://github.com/anzchy/picsee/actions/runs/41041228587)（App） | `p3/p3-10-parity-281-282` | `t231AppFreshRebindMergeAndUndoRestoreLostPosition`：`strip.frame.minY 0 >= grid.frame.maxY 572` |
| [41173251359](https://github.com/anzchy/picsee/actions/runs/41173251359) ×2 | `feat/331-home-hides-controls` | 4 个 `i331…` 测试，两次 attempt 都 60 s 超时 |

R 类没有一个是不改代码就过的，中位损失 103.5 分钟。main 上 0 个，说明这类问题都在合并前被 CI 拦住了。

### D. 设计 pin 与 UI 对照断言（7 个 job，6.2%）

- **D1 哈希 pin，2 个 job。**
  - `designRegistryPinsSources`（`DesignRegistryTests.swift:22`，`docs/first-launch-b4`）：设计源改了，`DesignRegistry.sourcesSHA256` 没有重新 pin。
  - `t229LostAccessPinnedSourceRemainsExact`（`LostAccessPinnedDesignTests.swift:45`，`feat/348-cmd-zoom-keys`）：manifest.json 的 SHA-256 和测试里写死的值不一致。这次失败还引起了 W 类的一次级联。
- **D2 UI 对照，5 个 job。** 包括：
  - Inspector 值列偏了 2 pt，容差 1 pt（两次 attempt 都失败）；
  - B4 首启 `--color-accent-soft` 颜色、尺寸与 pinned CSS 不符；
  - page 23 页脚 alpha 差 0.2；
  - issue282 阅读环动画为 nil。

  这些都是设计稿或 CSS 被 pin 后，原生实现没有对上，属于确定性失败。其中 40307488398 修了 1334 分钟，是全表最长的一次等待（分支 `p3/p3-13-inspector`）。

### K. design:check 与快捷键同步检查（6 个 job，5.3%）

- K1 的 4 次都发生在改了键盘处理的功能分支上：
  - `feat/settings-window`：检查自己的测试期望出错，fixture 和新代码冲突；
  - `fix/viewer-chrome-b-362`：检查读不懂 `CanvasView.swift` 里 `![36, 49, 76].contains(event.keyCode)` 这种写法；
  - `feat/114-grid-display`：新增的 key code 53/48 没有在 `KEY_SITES` 声明；
  - `feat/348-cmd-zoom-keys`：`CommandMenu.swift` 改写后不再匹配检查的正则，19/19 个子测试全部失败。

  后两次是检查本身的解析器跟不上代码的写法（regex 漂移），前两次是它确实拦下了未声明的快捷键或 fixture 冲突。
- K2 是状态稿中文孤行（22/26 个子用例），K3 是 design:check 启动时本地 http.server 没有应答，两者都在 2026-10-28 的 `design/journeys-22-26` 上。
- `owner-gates.sh` 本地跑的 node 测试只包括 `scripts/agents`、`scripts/tdd`、`scripts/ledger`，不跑 `npm run design:check` 和 `scripts/design/*.test.mjs`。所以 K 类只能在 CI 上第一次被发现。

### T. 工具与基础设施（4 个 job，3.5%）

- T1：`scripts/tdd/swift-lane.test.mjs` 要从本机用户目录下的 tdd-guardian 插件缓存加载 `exec.js`，runner 上没有这个目录。这是只在本地成立的环境假设。
- T2 和 T3 都是 #391 调查挂起时的产物：T3 是 `workflow_dispatch` 触发的、有意复现挂起的 throwaway 运行，watchdog 按设计以 124 退出；T2 是新 watchdog 的自测第一次在 runner 上跑时失败，17 分钟后修好。
- T4：Release workflow 签名、推送 appcast 分支成功，但 `gh pr create` 被仓库设置拒绝（Actions 无权创建 PR），之后 appcast PR 改为手工创建（这又引出了 G2 的 41186855191）。
- 没有发现 runner 分配失败、网络失败或 Xcode 安装失败。所有失败的 macOS job 都失败在测试或检查步骤，没有失败在 checkout、Xcode 设置或构建步骤。

### W. 级联（3 个 job）

#394 之后，Walking skeleton 只检查三个上游 job 的结论。41413668861 和 41413949890 是因为 package-tests 失败，41584895034 是因为 package-macui-tests 失败（D1）。这 3 个不算根因。

## 5. 共性因素

1. **测试写死了时间预算，CI runner 比本地慢且负载高。** A 类和 P 类共 70 个 job（61.9%），而且 main 上全部 24 个失败 job 都属于这两类。具体表现是：60/120/180 s 的 `.timeLimit`、`elapsed < 10 s`、`firstHitDraw < forced*4`、`reads == stopped`，以及成批同时超时。有 19 个早期 attempt 失败的 job 在重跑后通过，这直接说明结果不确定。每一轮修复（#252、#271、#278、#352、#394、#397、#401）都是把墙钟等待换成条件等待，或者降低 runner 上的并发，修完之后对应的失败就消失了。
2. **有几项检查只在 CI 里跑，本地门禁覆盖不到。** 本地 `owner-gates.sh` 跑的是 `swift test`（包）、`xcodebuild build`、`scripts/{agents,tdd,ledger}` 的 node 测试和 ledger 检查。以下几项本地都不跑：
   - App tests（A 类 33 个、R 类 4 个 App job）；
   - `design:check` 和 `scripts/design/*.test.mjs`（K 类 6 个）；
   - PR body lint（G 类 15 个）。

   这几项加起来是 58 个 job。其中 G 类和 K 类共 21 个是确定性失败，本可以在推送前就发现。
3. **生成物、证据、哈希需要随改动重新 pin。**
   - G1：推送新提交后，Gates 表里的 SHA 就过期了；
   - D1：设计源或 manifest 改了，哈希要重新 pin；
   - K1：快捷键页或 `KEY_SITES` 要随命令一起更新；
   - D2：pinned CSS 和原生实现要对齐。

   合计 20 个 job，全部是确定性失败，重跑不会过。
4. **重跑对确定性失败无效，对 PR body 尤其无效。** G 类 4 次重跑全部以同样的原因失败。R、D 类的重跑也都失败（40453300974、40307488398、41173251359 三个 run 的两次 attempt 都失败）。
5. **rebase 到移动后的 main。** 证据是间接的：G1 的 stale head 都出现在推送了新提交之后，规则要求附 `rebase-verify.sh` 的 `CODE same` 证据。日志里看不出每次具体是 rebase 还是普通提交，所以无法再细分。

## 6. 建议

1. **先修还在出现的 App 不稳定测试**（证据：A 类 33 个 job，main 上 13 个；A3 和 A4 在 11-02、11-03 仍然失败）。参考 #352 修 A1 的做法（等前台处理全部完成，而不是等固定时间），对 A2、A3（#379）和 A4 做同样的处理。修好之前，CI 失败时如果只有这几个测试失败，可以按已知 flaky 处理并允许重跑一次，但要在 #379 里记录 run 链接。
2. **禁止新增墙钟断言，把 `.timeLimit` 当兜底，而不是当断言**（证据：P 类 37 个、A1/A5 共 17 个超时类失败；#401「no wall-clock cutoff below the time limit」合并后没有再出现 P 类失败）。可以在 review 或 lint 里查新增的 `elapsed <`、`.seconds(` 比较和小于 120 s 的 `.timeLimit`。
3. **推送前在本地跑和 CI 相同的检查**（证据：G 类和 K 类共 21 个 job 都是确定性的，只能在 CI 上被发现）：
   - `owner-gates.sh` 加上 `npm run design:check` 和 `node --test scripts/design/*.test.mjs`，这类检查跑得快：CI 里失败的 shortcut 测试只用了 73–520 ms；
   - 开 PR 或改 PR 描述之前，在本地对 PR 描述跑 `node scripts/agents/ui-parity-pr-body-lint.mjs --base origin/main --body-file <file>`。
4. **每次推送后自动刷新 Gates 表的 SHA，或者推送前先跑 `rebase-verify.sh` 并写入 `CODE same`**（证据：G1 有 9 个 job，涉及 ledger、package-tests、app-tests 三个 lane）。gardener 提交之后最容易漏掉，所以 `docs(ledger)` 提交之后要同步更新 Gates 表。
5. **PR body 失败不要点重跑，改 PR 描述即可**（证据：4 次重跑全部失败）。也可以在 lint 的报错信息里直接写明「编辑 PR 描述触发重新检查」。
6. **降低 pin 的脆性**（证据：D1 2 个、K1 4 个）：
   - D1：哈希 pin 只放在一个地方，配一个重新 pin 的脚本，并在设计文件变更时由 owner gates 提示；
   - K1：`CommandMenu.swift` 的正则漂移和 keyCode 写法解析失败，说明快捷键检查依赖源码文本形态。可以让代码导出命令表（比如生成 JSON），检查读这份数据，而不是用正则解析 Swift 源码。
7. **去掉测试对本机环境的假设**（证据：T1）。不要让 node 测试依赖用户目录下的插件缓存，找不到依赖时应当显式跳过或失败并说明原因。
8. **Release 流程**（证据：T4 和随后的 G2）：在仓库设置里允许 Actions 创建 PR，或者改用带权限的 token。手工建的 appcast PR 也要带 Gates 表，或者让 lint 豁免 `appcast/*` 分支，这需要 owner 决定。

## 附录：全部失败 job（113 个，按时间排序）

Run 列为 `run id#attempt`。链接带 `/attempts/N` 的是早期 attempt 或重跑后的 attempt。

| # | 日期 (UTC) | Workflow | Job | 分支 | 原因 | 失败测试/错误 | Run |
|---|---|---|---|---|---|---|---|
| 1 | 2026-10-25 03:39 | CI | Walking skeleton | `p3/p3-0304-cache-fix` | P2 包测试时序断言 flaky | p303DiskCacheHitIsMaterializedBeforeDraw | [40159044646#1](https://github.com/anzchy/picsee/actions/runs/40159044646) |
| 2 | 2026-10-26 06:06 | CI | Walking skeleton | `p2/p2-05-metadata-sort` | P1 包测试 timeLimit 成批超时 | p303ViewerRetriesSourceChangedStoreWithoutInstallingOldPixels, loaderHostCloseDuringDetailInstallReleasesBothP | [40277867713#1](https://github.com/anzchy/picsee/actions/runs/40277867713/attempts/1) |
| 3 | 2026-10-26 06:54 | CI | Walking skeleton | `p2/p2-07-folder-watch` | P2 包测试时序断言 flaky | watchedRefreshReconcilesMultiSelectionAndCancelsRemovedThumbnails | [40282550043#1](https://github.com/anzchy/picsee/actions/runs/40282550043) |
| 4 | 2026-10-26 10:26 | CI | Walking skeleton | `p3/p3-13-inspector` | D2 UI 对照（pinned CSS）断言失败 | issue136PinnedInspectorValueColumnStartsAtCSSGap, watchedRefreshReconcilesMultiSelectionAndCancelsRemovedThumb | [40307488398#1](https://github.com/anzchy/picsee/actions/runs/40307488398/attempts/1) |
| 5 | 2026-10-26 10:26 | CI | Walking skeleton | `p3/p3-13-inspector` | D2 UI 对照（pinned CSS）断言失败 | issue136PinnedInspectorValueColumnStartsAtCSSGap, watchedRefreshReconcilesMultiSelectionAndCancelsRemovedThumb | [40307488398#2](https://github.com/anzchy/picsee/actions/runs/40307488398/attempts/2) |
| 6 | 2026-10-26 13:06 | CI | Walking skeleton | `fix/issue123-no-match-after-scan` | P2 包测试时序断言 flaky | watchedRefreshReconcilesMultiSelectionAndCancelsRemovedThumbnails | [40327759443#1](https://github.com/anzchy/picsee/actions/runs/40327759443) |
| 7 | 2026-10-27 05:05 | CI | Walking skeleton | `p3/p3-06-memory-budget` | R 分支上稳定复现的缺陷 | warmDiskLoadCancelledWhileWaitingLeavesNoStaging | [40453300974#1](https://github.com/anzchy/picsee/actions/runs/40453300974/attempts/1) |
| 8 | 2026-10-27 05:05 | CI | Walking skeleton | `p3/p3-06-memory-budget` | R 分支上稳定复现的缺陷 | warmDiskLoadCancelledWhileWaitingLeavesNoStaging | [40453300974#2](https://github.com/anzchy/picsee/actions/runs/40453300974/attempts/2) |
| 9 | 2026-10-27 06:46 | CI | Walking skeleton | `main` | P2 包测试时序断言 flaky | watchedRefreshReconcilesMultiSelectionAndCancelsRemovedThumbnails | [40463077043#1](https://github.com/anzchy/picsee/actions/runs/40463077043) |
| 10 | 2026-10-27 06:55 | CI | Walking skeleton | `main` | P2 包测试时序断言 flaky | dispatchWatchSchedulerFiresWithinRealTimeBound | [40464026412#1](https://github.com/anzchy/picsee/actions/runs/40464026412) |
| 11 | 2026-10-27 15:08 | CI | Walking skeleton | `docs/first-launch-b4` | D1 设计哈希 pin 失配 | designRegistryPinsSources | [40527964158#1](https://github.com/anzchy/picsee/actions/runs/40527964158) |
| 12 | 2026-10-27 15:18 | CI | Walking skeleton | `p3/p3-07-diagnostics` | P2 包测试时序断言 flaky | diagnosticsPanelViewLaysOutUnknownAndMeasuredRows | [40529705342#1](https://github.com/anzchy/picsee/actions/runs/40529705342) |
| 13 | 2026-10-28 04:04 | CI | Walking skeleton | `design/journeys-22-26` | K3 design:check 本地 http.server 未就绪 | design:check could not start：states 的 http.server 未应答 | [40630233760#1](https://github.com/anzchy/picsee/actions/runs/40630233760) |
| 14 | 2026-10-28 04:22 | CI | Walking skeleton | `docs/v001-release-prep` | P2 包测试时序断言 flaky | gridViewResumesPrefetchWhenPressureEnds | [40631975978#1](https://github.com/anzchy/picsee/actions/runs/40631975978) |
| 15 | 2026-10-28 04:45 | CI | Walking skeleton | `design/journeys-22-26` | K2 design:check 版式（孤行） | design:check FAIL 22/26：empty-folder / permission-denied 页孤行 | [40634141593#1](https://github.com/anzchy/picsee/actions/runs/40634141593) |
| 16 | 2026-10-28 11:06 | CI | Walking skeleton | `feat/store-schema-version` | P2 包测试时序断言 flaky | dispatchWatchSchedulerFiresWithinRealTimeBound, gridViewPinsLoadedThumbnailsUntilStopped | [40677415351#1](https://github.com/anzchy/picsee/actions/runs/40677415351) |
| 17 | 2026-10-28 11:36 | CI | Walking skeleton | `design/settings-shortcuts-states` | P1 包测试 timeLimit 成批超时 | dispatchWatchSchedulerFiresWithinRealTimeBound, issue108HeldMetadataHeadersLeaveCooperativeExecutorResponsive | [40681325841#1](https://github.com/anzchy/picsee/actions/runs/40681325841/attempts/1) |
| 18 | 2026-10-28 11:36 | CI | Walking skeleton | `design/settings-shortcuts-states` | P2 包测试时序断言 flaky | dispatchWatchSchedulerFiresWithinRealTimeBound | [40681325841#2](https://github.com/anzchy/picsee/actions/runs/40681325841/attempts/2) |
| 19 | 2026-10-28 11:41 | CI | Walking skeleton | `feat/store-schema-version` | P2 包测试时序断言 flaky | dispatchWatchSchedulerFiresWithinRealTimeBound | [40681901597#1](https://github.com/anzchy/picsee/actions/runs/40681901597) |
| 20 | 2026-10-28 11:57 | CI | Walking skeleton | `main` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40683891834#1](https://github.com/anzchy/picsee/actions/runs/40683891834) |
| 21 | 2026-10-28 12:21 | CI | Walking skeleton | `feat/store-schema-version` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40687184386#1](https://github.com/anzchy/picsee/actions/runs/40687184386/attempts/1) |
| 22 | 2026-10-28 12:32 | CI | Walking skeleton | `main` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40688597266#1](https://github.com/anzchy/picsee/actions/runs/40688597266) |
| 23 | 2026-10-28 12:45 | CI | Walking skeleton | `main` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40690470792#1](https://github.com/anzchy/picsee/actions/runs/40690470792) |
| 24 | 2026-10-28 12:48 | CI | Walking skeleton | `docs/knowledge-backlog` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40690904745#1](https://github.com/anzchy/picsee/actions/runs/40690904745/attempts/1) |
| 25 | 2026-10-28 12:48 | CI | Walking skeleton | `docs/knowledge-backlog` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40690904745#2](https://github.com/anzchy/picsee/actions/runs/40690904745/attempts/2) |
| 26 | 2026-10-28 12:57 | CI | Walking skeleton | `probe/lost-access-causes` | P2 包测试时序断言 flaky | sidebarSlowCounterDoesNotDelayRows | [40692101178#1](https://github.com/anzchy/picsee/actions/runs/40692101178/attempts/1) |
| 27 | 2026-10-29 05:26 | CI | Walking skeleton | `p2/p2-08b-empty-folder-opus` | P1 包测试 timeLimit 成批超时 | twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth, cacheTwoSessionsSharePinsOnRealPipeline | [40823417291#1](https://github.com/anzchy/picsee/actions/runs/40823417291) |
| 28 | 2026-10-29 06:38 | CI | Walking skeleton | `feat/settings-window` | K1 快捷键页/KEY_SITES 同步检查 | shortcut-model.test.mjs：预期 CacheSettingsWindow key code 51 未声明，实际 no problems | [40830397616#1](https://github.com/anzchy/picsee/actions/runs/40830397616) |
| 29 | 2026-10-29 06:47 | CI | Walking skeleton | `main` | P1 包测试 timeLimit 成批超时 | loaderFailureRetryAndLimitedPreviewPins, loaderPinsAcceptedTiersAndBalancesAtoBtoClose | [40831377585#1](https://github.com/anzchy/picsee/actions/runs/40831377585) |
| 30 | 2026-10-29 07:12 | CI | Walking skeleton | `main` | P1 包测试 timeLimit 成批超时 | twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth, gridPinOrderSurvivesRapidScrolling | [40833932713#1](https://github.com/anzchy/picsee/actions/runs/40833932713) |
| 31 | 2026-10-29 07:52 | CI | Walking skeleton | `main` | P1 包测试 timeLimit 成批超时 | twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth, gridPinOrderSurvivesRapidScrolling | [40838183311#1](https://github.com/anzchy/picsee/actions/runs/40838183311) |
| 32 | 2026-10-29 08:33 | CI | Walking skeleton | `docs/interface-language` | P1 包测试 timeLimit 成批超时 | twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth, gridPinOrderSurvivesRapidScrolling | [40842951007#1](https://github.com/anzchy/picsee/actions/runs/40842951007/attempts/1) |
| 33 | 2026-10-29 08:38 | CI | Walking skeleton | `fix/device-sign-identity` | P1 包测试 timeLimit 成批超时 | twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth, cacheTwoSessionsSharePinsOnRealPipeline | [40843540948#1](https://github.com/anzchy/picsee/actions/runs/40843540948/attempts/1) |
| 34 | 2026-10-29 08:52 | CI | Walking skeleton | `main` | P1 包测试 timeLimit 成批超时 | gridPinOrderSurvivesRapidScrolling | [40845336903#1](https://github.com/anzchy/picsee/actions/runs/40845336903) |
| 35 | 2026-10-29 16:29 | CI | App tests | `ci/app-tests-job` | R 分支上稳定复现的缺陷 | issue140NativeOrdinaryDotTrashMoveKeepsViewerLive, issue140DisplayedFileGrantTrashClearsWithoutReconnectSheet | [40912111411#1](https://github.com/anzchy/picsee/actions/runs/40912111411) |
| 36 | 2026-10-29 17:05 | CI | App tests | `ci/app-tests-job` | T1 测试依赖本机插件缓存 | swift-lane.test.mjs：找不到 tdd-guardian 插件缓存里的 exec.js | [40918011062#1](https://github.com/anzchy/picsee/actions/runs/40918011062) |
| 37 | 2026-10-29 17:12 | CI | App tests | `ci/app-tests-job` | A4 App flaky：sidebarCancelRestoresPriorTree… | sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild | [40919126085#1](https://github.com/anzchy/picsee/actions/runs/40919126085) |
| 38 | 2026-10-29 17:24 | CI | Walking skeleton | `ci/app-tests-job` | P1 包测试 timeLimit 成批超时 | issue58LoaderSettlesAfterSingleReplacementAndDelayedOldLookup, issue122DisplayedCurrentRevisionSurvivesDelayed | [40921065499#1](https://github.com/anzchy/picsee/actions/runs/40921065499/attempts/1) |
| 39 | 2026-10-29 17:53 | CI | App tests | `main` | A4 App flaky：sidebarCancelRestoresPriorTree… | sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild | [40925649249#1](https://github.com/anzchy/picsee/actions/runs/40925649249) |
| 40 | 2026-10-29 18:27 | CI | Walking skeleton | `p2/p2-08c-lost-access-tracer` | R 分支上稳定复现的缺陷 | t229SystemDiskMountPortUsesRememberedUUIDOnUnmountAndFreshUUIDOnMount, t229DiskPortMissingURLDiffEmitsOnlyRemo | [40931059324#1](https://github.com/anzchy/picsee/actions/runs/40931059324) |
| 41 | 2026-10-29 18:39 | CI | App tests | `p2/p2-08c-lost-access-tracer` | R 分支上稳定复现的缺陷 | issue136CombinedWindowWatchedSearchRefreshUpdatesInspectorSynchronously | [40932813794#1](https://github.com/anzchy/picsee/actions/runs/40932813794) |
| 42 | 2026-10-29 18:39 | CI | Walking skeleton | `p2/p2-08c-lost-access-tracer` | P1 包测试 timeLimit 成批超时 | t229SidebarParentFailureReportsFailureAndKeepsKnownRows, watchedRefreshReconcilesMultiSelectionAndCancelsRemov | [40932813794#1](https://github.com/anzchy/picsee/actions/runs/40932813794) |
| 43 | 2026-10-29 19:02 | CI | Walking skeleton | `p2/p2-08c-lost-access-tracer` | P1 包测试 timeLimit 成批超时 | diagnosticsPanelTicksDoNotScanTheDiskIndexEachTime, diagnosticsPanelRunsOneLoopHoweverVisibilityToggles | [40936369269#1](https://github.com/anzchy/picsee/actions/runs/40936369269/attempts/1) |
| 44 | 2026-10-30 01:07 | CI | App tests | `main` | A4 App flaky：sidebarCancelRestoresPriorTree… | sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild | [40983955765#1](https://github.com/anzchy/picsee/actions/runs/40983955765) |
| 45 | 2026-10-30 02:47 | CI | App tests | `main` | A5 App flaky：t229Fix2RecoveryFollowsRootMoved… 超时 | t229Fix2RecoveryFollowsRootMovedWhileReadable | [40993675568#1](https://github.com/anzchy/picsee/actions/runs/40993675568) |
| 46 | 2026-10-30 03:38 | CI | App tests | `p3/p3-16-b4-first-launch` | A5 App flaky：t229Fix2RecoveryFollowsRootMoved… 超时 | t229Fix2RecoveryFollowsRootMovedWhileReadable | [40998496072#1](https://github.com/anzchy/picsee/actions/runs/40998496072) |
| 47 | 2026-10-30 03:38 | CI | Walking skeleton | `p3/p3-16-b4-first-launch` | D2 UI 对照（pinned CSS）断言失败 | p316B4FrontPhotoFollowsPinnedDragTransform, p316B4AppearanceDragAndAccessibilityPresentation | [40998496072#1](https://github.com/anzchy/picsee/actions/runs/40998496072) |
| 48 | 2026-10-30 08:07 | CI | App tests | `test/shortcut-coverage-284` | A4 App flaky：sidebarCancelRestoresPriorTree… | sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild | [41024347388#1](https://github.com/anzchy/picsee/actions/runs/41024347388/attempts/1) |
| 49 | 2026-10-30 09:20 | CI | App tests | `p2/p2-08c-t4-not-found-231` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41032769242#1](https://github.com/anzchy/picsee/actions/runs/41032769242/attempts/1) |
| 50 | 2026-10-30 09:20 | CI | Walking skeleton | `p2/p2-08c-t4-not-found-231` | P2 包测试时序断言 flaky | diagnosticsPanelDefaultClockRefreshesUntilHidden | [41032769242#1](https://github.com/anzchy/picsee/actions/runs/41032769242/attempts/1) |
| 51 | 2026-10-30 10:30 | CI | App tests | `p3/p3-10-parity-281-282` | R 分支上稳定复现的缺陷 | t231AppFreshRebindMergeAndUndoRestoreLostPosition | [41041228587#1](https://github.com/anzchy/picsee/actions/runs/41041228587) |
| 52 | 2026-10-30 10:30 | CI | Walking skeleton | `p3/p3-10-parity-281-282` | D2 UI 对照（pinned CSS）断言失败 | issue282ReadingRingSpinsAroundTheHeadingCentreAfterLateFrames, issue281ThumbnailFramesAndPitchUseWindowViewpor | [41041228587#1](https://github.com/anzchy/picsee/actions/runs/41041228587) |
| 53 | 2026-10-30 10:48 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41043459948#1](https://github.com/anzchy/picsee/actions/runs/41043459948) |
| 54 | 2026-10-30 13:54 | CI | App tests | `p2/p2-08c-t5-sidebar-lost-232` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41067095899#1](https://github.com/anzchy/picsee/actions/runs/41067095899/attempts/1) |
| 55 | 2026-10-30 14:07 | CI | App tests | `main` | A3 App flaky：issue281RetryAfterFailedRead… | issue281RetryAfterFailedReadShowsTheReadingFooter | [41069115657#1](https://github.com/anzchy/picsee/actions/runs/41069115657) |
| 56 | 2026-10-30 15:10 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41078314154#1](https://github.com/anzchy/picsee/actions/runs/41078314154) |
| 57 | 2026-10-30 15:33 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41081734979#1](https://github.com/anzchy/picsee/actions/runs/41081734979/attempts/1) |
| 58 | 2026-10-30 23:18 | PR body | PR body Gates | `tooling/309-pr-gates-table` | G5 Gates：可信基线 lint 缺 checkGates | trusted PR-body lint lacks checkGates; refusing to use a pre-Gates validator | [41143680858#1](https://github.com/anzchy/picsee/actions/runs/41143680858) |
| 59 | 2026-10-31 00:29 | CI | App tests | `tooling/309-ci-rows` | A2 App flaky：t231ExplicitTrashRebind… | t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores | [41150425319#1](https://github.com/anzchy/picsee/actions/runs/41150425319) |
| 60 | 2026-10-31 00:35 | CI | App tests | `main` | A2 App flaky：t231ExplicitTrashRebind… | t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores | [41151044034#1](https://github.com/anzchy/picsee/actions/runs/41151044034) |
| 61 | 2026-10-31 00:38 | CI | App tests | `tooling/309-ci-rows` | A3 App flaky：issue281RetryAfterFailedRead… | issue281RetryAfterFailedReadShowsTheReadingFooter | [41151255885#1](https://github.com/anzchy/picsee/actions/runs/41151255885/attempts/1) |
| 62 | 2026-10-31 00:46 | CI | Walking skeleton | `main` | P2 包测试时序断言 flaky | diagnosticsPanelDefaultClockRefreshesUntilHidden | [41151989082#1](https://github.com/anzchy/picsee/actions/runs/41151989082) |
| 63 | 2026-10-31 01:06 | CI | Walking skeleton | `tooling/garden-frequency` | P2 包测试时序断言 flaky | diagnosticsPanelDefaultClockRefreshesUntilHidden | [41153657705#1](https://github.com/anzchy/picsee/actions/runs/41153657705/attempts/1) |
| 64 | 2026-10-31 01:25 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41155255539#1](https://github.com/anzchy/picsee/actions/runs/41155255539) |
| 65 | 2026-10-31 02:26 | CI | App tests | `feat/313-home-no-bar` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41160050099#1](https://github.com/anzchy/picsee/actions/runs/41160050099/attempts/1) |
| 66 | 2026-10-31 04:37 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | issue281RetryAfterFailedReadShowsTheReadingFooter, t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiv | [41169362149#1](https://github.com/anzchy/picsee/actions/runs/41169362149) |
| 67 | 2026-10-31 05:18 | CI | App tests | `feat/314-bar-80` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41172039082#1](https://github.com/anzchy/picsee/actions/runs/41172039082) |
| 68 | 2026-10-31 05:18 | CI | Walking skeleton | `feat/314-bar-80` | D2 UI 对照（pinned CSS）断言失败 | pinnedSearchFooterFramesAndPage23AtBothSizesAndAppearances, page23GeometryTypographyAndResolvedColorsFollowPin | [41172039082#1](https://github.com/anzchy/picsee/actions/runs/41172039082) |
| 69 | 2026-10-31 05:36 | CI | Walking skeleton | `feat/331-home-hides-controls` | R 分支上稳定复现的缺陷 | i331TwoOverlaysDecideIndependently, i331ShowingImageShowsControls | [41173251359#1](https://github.com/anzchy/picsee/actions/runs/41173251359/attempts/1) |
| 70 | 2026-10-31 05:36 | CI | Walking skeleton | `feat/331-home-hides-controls` | R 分支上稳定复现的缺陷 | i331ShowingImageShowsControls, i331FocusedControlMovesToCanvasOnEnteringHome | [41173251359#2](https://github.com/anzchy/picsee/actions/runs/41173251359/attempts/2) |
| 71 | 2026-10-31 05:51 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41174226346#1](https://github.com/anzchy/picsee/actions/runs/41174226346/attempts/1) |
| 72 | 2026-10-31 05:51 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | issue281RetryAfterFailedReadShowsTheReadingFooter, t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiv | [41174226346#2](https://github.com/anzchy/picsee/actions/runs/41174226346/attempts/2) |
| 73 | 2026-10-31 08:49 | PR body | PR body Gates | `feat/331-home-hides-controls` | G1 Gates：stale head 无 CODE same | ledger PASS has a stale head without CODE same evidence | [41186143024#1](https://github.com/anzchy/picsee/actions/runs/41186143024/attempts/1) |
| 74 | 2026-10-31 08:49 | PR body | PR body Gates | `feat/331-home-hides-controls` | G1 Gates：stale head 无 CODE same | ledger PASS has a stale head without CODE same evidence | [41186143024#2](https://github.com/anzchy/picsee/actions/runs/41186143024/attempts/2) |
| 75 | 2026-10-31 08:54 | Release | Notarised DMG and draft release | `v0.0.1-rc.1` | T4 Release：Actions 无权建 PR | pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (creat | [41186517202#1](https://github.com/anzchy/picsee/actions/runs/41186517202) |
| 76 | 2026-10-31 09:00 | PR body | PR body Gates | `appcast/v0.0.1-rc.1` | G2 Gates：缺 ## Gates 表 | missing ## Gates table | [41186855191#1](https://github.com/anzchy/picsee/actions/runs/41186855191) |
| 77 | 2026-11-01 03:11 | PR body | PR body Gates | `fix/333-t231fix2-flake` | G1 Gates：stale head 无 CODE same | package-tests PASS has a stale head without CODE same evidence | [41268174719#1](https://github.com/anzchy/picsee/actions/runs/41268174719/attempts/1) |
| 78 | 2026-11-01 03:11 | PR body | PR body Gates | `fix/333-t231fix2-flake` | G1 Gates：stale head 无 CODE same | package-tests PASS has a stale head without CODE same evidence | [41268174719#2](https://github.com/anzchy/picsee/actions/runs/41268174719/attempts/2) |
| 79 | 2026-11-01 03:11 | CI | App tests | `fix/333-t231fix2-flake` | A3 App flaky：issue281RetryAfterFailedRead… | issue281RetryAfterFailedReadShowsTheReadingFooter | [41268174744#1](https://github.com/anzchy/picsee/actions/runs/41268174744/attempts/1) |
| 80 | 2026-11-01 03:11 | CI | App tests | `fix/333-t231fix2-flake` | A3 App flaky：issue281RetryAfterFailedRead… | issue281RetryAfterFailedReadShowsTheReadingFooter, t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoR | [41268174744#2](https://github.com/anzchy/picsee/actions/runs/41268174744/attempts/2) |
| 81 | 2026-11-01 03:55 | PR body | PR body Gates | `docs/131-macbook-runbook` | G2 Gates：缺 ## Gates 表 | missing ## Gates table | [41271074703#1](https://github.com/anzchy/picsee/actions/runs/41271074703) |
| 82 | 2026-11-01 04:38 | CI | App tests | `main` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41273898355#1](https://github.com/anzchy/picsee/actions/runs/41273898355) |
| 83 | 2026-11-01 07:11 | PR body | PR body Gates | `perf/146-mvp-scale` | G3 Gates：缺 UI-Parity 表 | UI files changed; PR body needs a populated ## UI-Parity table | [41283797785#1](https://github.com/anzchy/picsee/actions/runs/41283797785/attempts/1) |
| 84 | 2026-11-01 07:11 | PR body | PR body Gates | `perf/146-mvp-scale` | G3 Gates：缺 UI-Parity 表 | UI files changed; PR body needs a populated ## UI-Parity table | [41283797785#2](https://github.com/anzchy/picsee/actions/runs/41283797785/attempts/2) |
| 85 | 2026-11-01 07:11 | CI | App tests | `perf/146-mvp-scale` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41283797808#1](https://github.com/anzchy/picsee/actions/runs/41283797808/attempts/1) |
| 86 | 2026-11-01 07:11 | CI | App tests | `perf/146-mvp-scale` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41283797808#2](https://github.com/anzchy/picsee/actions/runs/41283797808/attempts/2) |
| 87 | 2026-11-01 07:30 | CI | App tests | `p3/p3-17c-d3-read-failed-238` | A2 App flaky：t231ExplicitTrashRebind… | t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores | [41285078984#1](https://github.com/anzchy/picsee/actions/runs/41285078984/attempts/1) |
| 88 | 2026-11-01 07:39 | CI | App tests | `fix/333-t231fix2-flake` | A3 App flaky：issue281RetryAfterFailedRead… | issue281RetryAfterFailedReadShowsTheReadingFooter | [41285638792#1](https://github.com/anzchy/picsee/actions/runs/41285638792/attempts/1) |
| 89 | 2026-11-01 07:44 | PR body | PR body Gates | `fix/sparkle-front-359` | G4 Gates：缺 Device-Smoke 行 | UI files changed; PR body needs a Device-Smoke: line for the changed path | [41286004139#1](https://github.com/anzchy/picsee/actions/runs/41286004139) |
| 90 | 2026-11-01 07:53 | CI | App tests | `perf/146-mvp-scale` | A1 App flaky：t231Fix2…OverlappingInactiveMoves 超时 | t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves | [41286598622#1](https://github.com/anzchy/picsee/actions/runs/41286598622) |
| 91 | 2026-11-01 09:11 | CI | App tests | `perf/146-mvp-scale` | A2 App flaky：t231ExplicitTrashRebind… | t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores | [41287776460#1](https://github.com/anzchy/picsee/actions/runs/41287776460/attempts/1) |
| 92 | 2026-11-01 13:41 | CI | Design check | `fix/viewer-chrome-b-362` | K1 快捷键页/KEY_SITES 同步检查 | shortcut 检查读不懂 CanvasView.swift 的 keyCode 写法（2/17 失败） | [41312458897#1](https://github.com/anzchy/picsee/actions/runs/41312458897) |
| 93 | 2026-11-01 14:14 | CI | Walking skeleton | `fix/332-footer-status` | P1 包测试 timeLimit 成批超时 | i331ShowingImageShowsControls, i331LoadingShowsControlsAndCancelReturnsHomeHidden | [41315211327#1](https://github.com/anzchy/picsee/actions/runs/41315211327/attempts/1) |
| 94 | 2026-11-01 14:14 | CI | Walking skeleton | `fix/332-footer-status` | P1 包测试 timeLimit 成批超时 | issue108MetadataSortPendingInvalidatesStaleRepliesAndKeepsBaseList, issue124Fix2ChangedBackAndUnchangedExitsDo | [41315211327#2](https://github.com/anzchy/picsee/actions/runs/41315211327/attempts/2) |
| 95 | 2026-11-01 14:45 | CI | Walking skeleton | `fix/332-footer-status` | P1 包测试 timeLimit 成批超时 | p308FastScrollNeverShowsAnotherItemsThumbnail, twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth | [41317730740#1](https://github.com/anzchy/picsee/actions/runs/41317730740) |
| 96 | 2026-11-01 14:45 | PR body | PR body Gates | `fix/332-footer-status` | G1 Gates：stale head 无 CODE same | ledger PASS has a stale head without CODE same evidence | [41317730847#1](https://github.com/anzchy/picsee/actions/runs/41317730847/attempts/1) |
| 97 | 2026-11-01 14:45 | PR body | PR body Gates | `fix/332-footer-status` | G1 Gates：stale head 无 CODE same | ledger PASS has a stale head without CODE same evidence | [41317730847#2](https://github.com/anzchy/picsee/actions/runs/41317730847/attempts/2) |
| 98 | 2026-11-01 15:06 | PR body | PR body Gates | `fix/332-footer-status` | G1 Gates：stale head 无 CODE same | package-tests PASS has a stale head without CODE same evidence | [41319485311#1](https://github.com/anzchy/picsee/actions/runs/41319485311) |
| 99 | 2026-11-01 15:06 | CI | App tests | `fix/332-footer-status` | A2 App flaky：t231ExplicitTrashRebind… | t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores | [41319485390#1](https://github.com/anzchy/picsee/actions/runs/41319485390/attempts/1) |
| 100 | 2026-11-01 16:32 | CI | Walking skeleton | `feat/316-wall-drift` | P1 包测试 timeLimit 成批超时 | issue233R2InspectorCurrentFailureCallbackFollowsMappedStateAndIsOptional, watchedCoordinatorCancelsItsSubscrip | [41326810637#1](https://github.com/anzchy/picsee/actions/runs/41326810637/attempts/1) |
| 101 | 2026-11-02 03:09 | CI | Design check | `feat/114-grid-display` | K1 快捷键页/KEY_SITES 同步检查 | GridDisplayPanelView/GridShellView 处理 key code 53/48，KEY_SITES 未声明（2/19 失败） | [41381549535#1](https://github.com/anzchy/picsee/actions/runs/41381549535) |
| 102 | 2026-11-02 04:26 | CI | Walking skeleton | `main` | P1 包测试 timeLimit 成批超时 | watchedCoordinatorUpdatesWithinTwoSecondsOfQuiescenceOnOneFakeClock | [41388439000#1](https://github.com/anzchy/picsee/actions/runs/41388439000) |
| 103 | 2026-11-02 05:29 | CI | App tests | `fix/142-honest-scan-status` | A3 App flaky：issue281RetryAfterFailedRead… | issue281RetryAfterFailedReadShowsTheReadingFooter | [41394303574#1](https://github.com/anzchy/picsee/actions/runs/41394303574) |
| 104 | 2026-11-02 08:31 | CI | Package tests (non-UI) | `throwaway/391-hang-evidence` | T3 有意复现挂起（throwaway） | watchdog: exit 124 (timed out) | [41413668861#1](https://github.com/anzchy/picsee/actions/runs/41413668861) |
| 105 | 2026-11-02 08:31 | CI | Walking skeleton | `throwaway/391-hang-evidence` | W 级联（Walking skeleton 汇总） | package-tests package-macui-tests unsigned-build: failure success success | [41413668861#1](https://github.com/anzchy/picsee/actions/runs/41413668861) |
| 106 | 2026-11-02 08:33 | CI | Package tests (non-UI) | `ci/391-split-lane` | T2 新 watchdog 自测在 runner 上失败 | test-watchdog.test.mjs：killed well before the child would finish | [41413949890#1](https://github.com/anzchy/picsee/actions/runs/41413949890) |
| 107 | 2026-11-02 08:33 | CI | Walking skeleton | `ci/391-split-lane` | W 级联（Walking skeleton 汇总） | package-tests package-macui-tests unsigned-build: failure success success | [41413949890#1](https://github.com/anzchy/picsee/actions/runs/41413949890) |
| 108 | 2026-11-03 01:49 | CI | App tests | `fix/354-page26-parity` | A4 App flaky：sidebarCancelRestoresPriorTree… | sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild | [41562256618#1](https://github.com/anzchy/picsee/actions/runs/41562256618/attempts/1) |
| 109 | 2026-11-03 04:17 | CI | Design check | `feat/348-cmd-zoom-keys` | K1 快捷键页/KEY_SITES 同步检查 | CommandMenu.swift 不再匹配正则 /keyEquivalent: id\.defaultKey\)/（19/19 失败） | [41577227514#1](https://github.com/anzchy/picsee/actions/runs/41577227514) |
| 110 | 2026-11-03 05:36 | CI | Package tests (MacUI) | `feat/348-cmd-zoom-keys` | D1 设计哈希 pin 失配 | t229LostAccessPinnedSourceRemainsExact | [41584895034#1](https://github.com/anzchy/picsee/actions/runs/41584895034) |
| 111 | 2026-11-03 05:36 | CI | Walking skeleton | `feat/348-cmd-zoom-keys` | W 级联（Walking skeleton 汇总） | package-tests package-macui-tests unsigned-build: success failure success | [41584895034#1](https://github.com/anzchy/picsee/actions/runs/41584895034) |
| 112 | 2026-11-03 05:36 | PR body | PR body Gates | `feat/348-cmd-zoom-keys` | G1 Gates：stale head 无 CODE same | app-tests PASS has a stale head without CODE same evidence | [41584895280#1](https://github.com/anzchy/picsee/actions/runs/41584895280) |
| 113 | 2026-11-03 06:20 | PR body | PR body Gates | `feat/348-cmd-zoom-keys` | G1 Gates：stale head 无 CODE same | app-tests PASS has a stale head without CODE same evidence | [41589290591#1](https://github.com/anzchy/picsee/actions/runs/41589290591) |
