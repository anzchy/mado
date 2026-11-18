# /mado-verify 复查：是否过时、是否过严、业界怎么做

日期：2026-11-17。两份独立的只读调查：Fable（有网络，读了脚本、gate 历史和 GitHub 记录）和 Codex（模型 gpt-6-astra，无网络，读了脚本和历史日志）。本文是综合，不是转抄；原稿在 `~/.mado/herdr/delegator/research/mado-verify-review-{fable,codex}.md`（Codex 的沙箱只读，全文只在它的回复里）。我自己核对过的数字和缺陷在下面标「已核对」。调查没有改仓库，没有跑构建、测试或 GUI。

## 结论一句话

mado-verify 的底线（每个代码 head 一份全绿的门禁记录）是对的，要保留；但它**严在不准的地方，松在该严的地方**：近期大面积红灯主要来自本机负载下的计时测试和环境，而不是被验的改动；同时它漏掉了 CI 真正会跑的几组 node 测试，且有三处文档过时、两处脚本缺陷。

## 1 是否过时

| 项 | 证据 | 状态 |
|---|---|---|
| App lane 的描述 | `SKILL.md:22` 写「完整 App lane，含 hosted，delegator 桌面运行有约束力」；`owner-gates.sh:101,113,129` 只跑 `^MadoAppTests\.`，hosted 默认跳过并写 `hosted CI binding` | 过时（两份都指出） |
| TSan lane | `SKILL.md:34` 要求「TSan lane when available」，`scripts/`、`.github/`、`docs/agents/` 里没有这条 lane | 过时（Fable） |
| diffcheck 顺序和「遇红即停」 | `SKILL.md:22` 对 `owner-gates.sh:153`：脚本总是跑完所有 lane | 不一致（Fable） |
| 已知偶发例外 | `SKILL.md:24` 描述「单个已知失败、定向重跑两次通过」；`gate-policy.mjs` 拒绝任何非零 node/swift gate，`evidence.mjs` 不读 `known-flakes.json` | 这条例外**无法兑现**；规则在 81 次红灯里只适用 3 次（Fable） |
| `known-flakes.json` | 6 条，出现次数 17、8、6、6、1、0；最常见的失败不在名单里（`appExecutionTimeoutHasNoValidRed` 35 次等）；条目没有 issue、owner、期限 | 与现实脱节 |
| 改名 | skill 内没有功能性的 Picsee 残留；`evidence.mjs:24` 已固定 `anzchy/mado` | 不是主要问题 |

**两处脚本缺陷**（**已核对**）：
- `test-integrity.mjs:14` 的计数正则 `\b(?:…|@Test\b|…)` 里 `\b` 在 `@` 前面：`@` 前通常不是单词字符，所以 `@Test` 在行首或空格后永远不匹配，Swift Testing 的测试数量不可信，SKILL.md 第 2 步「比较前后测试数」对 Swift 没有意义。
- `test-integrity.mjs:18-20` 对新增行直接匹配 `skip`、`timeout` 这两个词，注释、`spawnSync(…, {timeout})` 和 #742 这类合理的预算修改都会命中，于是 delegator 要逐条解释「几十个命中」。

另外 `owner-gates.sh:92` 裸跑 `xcodegen`，没有走 `scripts/heavy-lock.sh`，违反我们自己的重任务取锁规则（**已核对**）。

**本地梯子和 CI 的差别**（Fable，比工单 #750 写的更宽）：CI 跑而本地 node lane（`owner-gates.sh:140-151`）不跑的有 `scripts/ci/*.test.mjs`、`scripts/device/tests/*`、`scripts/release/*.test.mjs`、`scripts/perf`、`scripts/hooks`、`code-name.mjs`、PR body Gates；本地跑而 CI 不跑的是 delegator 的 `*.test.mjs`；哪里都不跑的是 mado-verify 自己的测试和 delegator 的 Python 测试（11-17 记录 `OwnerGatesAppTestsTests` 本地 13 个失败）。

## 2 是否过于严苛

**口径：** `~/.mado/herdr/delegator/*-summary.txt` 共 468 份，446 份有 `DONE`（**已核对**，包含 delegator 和 implementer 的运行，没有区分；时间用文件修改时间，不是可靠的启动时间）。

| lane | 10-25..11-10 红/跑 | 11-11..11-17 红/跑 | 说明 |
|---|---|---|---|
| node | 12/293 | **81/151**（11-14..16 为 73/91） | 全历史 93 红（**已核对**） |
| swift | 20/292 | 19/151 | 其中 3 次 exit 124 |
| apptests | 无此 lane | 41/70 | 25 次 exit 70（环境，11-16 起 hosted 默认跳过） |
| 全绿 | 237/294 | 53/152 | |

- **近期恶化是真的，全历史恶化不是。** 11-14 起 97 次 node 里 75 次红（77%）（**已核对**）；整个历史只有约 21% 红。两个分母不能混着说。
- **与被验改动无关：** 81 次 node 红灯里 72 次的 diff 没有碰失败测试所在的目录；同一个 head 跑两次以上的 19 个里，swift 翻转 11 个、lcov 10 个、apptests 4 个。同一份代码时绿时红，按 Google 的定义就是 flaky。
- **成本：** 一次 owner-gates 中位数约 8.4 分钟（含等锁）；11-11 之后 148 次合计约 30.6 小时；只有 node 红、其余全绿的 28 次合计约 5.4 小时的锁内时间，是下限（每次红灯还有 implementer 重跑、新证据评论、delegator 复查，没有可靠时间戳）。失败的 node 运行墙钟合计约 4.07 小时（Codex）。没有统一的取锁和释放时间记录，**算不出完整的人工和锁成本**，这两个数字不要相加。
- **CI 也不稳：** 11-12 之后 main 的 push 运行 49 次里 10 次红（App tests 6、Package tests non-UI 3、Watchdog 1），都是合入前 PR 检查为绿的提交；这是推断（失败日志没有下载）。
- **门禁抓到真缺陷：** 能确认的只有 #748 的 `for-where-ban`（本地没跑那组测试，CI 抓到，返工约半天，#750）。「node lane 抓到过多少真回归」答不出来：日志里没有标注红灯后来被证实是不是真缺陷。

**分三类：**
- **要求对、实现脆**（该修，不该放宽）：node 工具测试的真实时间预算（#742、#745 已处理）、读本机真实锁状态的测试、`apptests` hosted 组依赖 key window、负载下 swift 超时、`test-integrity.mjs` 的正则。
- **要求对、必须保持严格：** 每个代码 head 一份记录；`evidence.mjs check` 不读 flake 名单；不许削弱测试、加重试或隔离来转绿；lcov 100%；全量 App 测试；拒绝脏树和进行中的 rebase；隐私扫描。
- **成本可能超过价值**（待验证，不是结论）：纯文档提交和 `rebase-verify.sh` 判定 `CODE same` 的 rebase 也要重跑整个梯子并新发评论；逐条解释词法噪声的命中；在别的重任务同时跑时照常开跑（#735 记录过 load 22 下 1155 个假失败）。

## 3 业界实践

**有数据的证据**（Fable 取得，部分只读到镜像或二手引用，已逐条标注）：
- Google，《Flaky Tests at Google and How We Mitigate Them》：约 1.5% 的测试运行 flaky，近 16% 的测试有某种 flakiness；只对已标记的测试重跑，过高的自动隔离并给 owner 开 bug。https://testing.googleblog.com/2016/05/flaky-tests-at-google-and-how-we.html
- GitHub，《Reducing flaky builds by 18x》：因 flaky 变红的提交从 1/11 降到 1/200；用「同进程、时间前移、换主机」三种重跑判定并分类。https://github.blog/engineering/infrastructure/reducing-flaky-builds-by-18x/
- Slack，《Handling Flaky Tests at Scale》：main 稳定率 19.82% 升到 96%；一次失败就在 main 上自动禁用并开工单。https://slack.engineering/handling-flaky-tests-at-scale-auto-detection-suppression/
- Luo 等，《An Empirical Analysis of Flaky Tests》(FSE 2014)：201 个修复里 async wait 占 45%，修法是改成等待条件。https://mir.cs.illinois.edu/lamyaa/publications/fse14.pdf
- Fowler，《Eradicating Non-Determinism in Tests》（观点）：隔离区要有数量和时间上限，异步测试用回调或轮询加高上限，不用裸 sleep。https://martinfowler.com/articles/nonDeterminism.html
- SLSA provenance：证据应由可信的一方生成，租户自己提供的参数不可信。https://slsa.dev/spec/v1.0/provenance

**不适用于 Mado：** 换主机重跑、按团队自动开工单、预测式选测试（需要机群和大量历史）；merge queue（个人账号仓库，且每天几个 PR）；自动禁用测试（我们的规则禁止为转绿而隔离，测试数量小到可以直接修）。**可以搬的：** 轮询加高上限（#742 已是这个方向）、「同一代码既绿又红即 flaky」的判定、隔离名单要有期限（`app-quarantine.json` 已有 `expires`，`known-flakes.json` 没有）、证据由可信的一方生成。

## 4 建议（两份一致的部分，按顺序）

1. **本地 node lane 与 CI 对齐**（扩大 #750）：加入 perf、hooks、release、device 测试，以及 `scripts/ci` 里能在预算内跑完的文件，再加一个测试从两个 workflow 解析 `node --test` 路径并断言本地清单是超集或有写明的例外。风险：`app-compare`、`app-repeat` 在 main 本地就是红的，要先修或列为例外。
2. **修 `test-integrity.mjs`**：去掉 `@Test` 前的 `\b`；`skip`、`timeout` 只匹配测试 API 形式。验证：#742 的 diff 命中数降到 0，真删断言的 fixture 仍命中。
3. **改 `SKILL.md` 与 `owner-gates.sh` 一致**（hosted、diffcheck 顺序、TSan），并让 `xcodegen` 走 heavy-lock。文档修正，不改验收标准。
4. **重写 `known-flakes.json`**：#742、#745 之后在空闲机器上连续跑若干次，把仍翻转的测试修掉后清空名单；每条加 `issue` 和 `expires`，过期即失败；不批量加条目，`evidence.mjs check` 仍不读名单。
5. **开跑前检查负载**（#735 第 2 项）：超过阈值 exit 2 并写原因，不产出假失败；阈值需要 owner 定。
6. **把 mado-verify 自己的测试和 delegator 的 Python 测试放进某条 lane**（先修那 13 个失败）。
7. **记录每次红灯的归因**（真缺陷 / flaky / 环境），否则下次仍答不出「门禁抓到多少真问题」。
8. **代码相同的 head 不重跑**（见下，需要 owner 明确同意）。

## 5 待 owner 评估：代码相同的 head 不重跑梯子（规则不变，本节只是方案）

现行规则：每个新 head 都要新的 mado-verify 记录和评论，包括纯文档提交和 `rebase-verify.sh` 判定 `CODE same` 的 rebase。今天的例子：#688 因为加了一行台账文字和一次 rebase 各多跑了一轮完整梯子（约每次 25 分钟的 heavy-lock）。

**方案：** `evidence.mjs check` 接受一条「指向原记录的链接记录」，条件全部满足才有效：(a) 新 head 与原 head 的**被测输入树相同**（用 tree 哈希比较，不是人工声明；文档类路径可排除）；(b) 工具链和配置指纹（`owner-gates.sh`、`project.yml`、CI 工作流哈希）相同；(c) 原记录是全绿；(d) 链接记录写明原 head、新 head、比较方式。任何一条不满足就走完整重跑。最终合并结果仍由 CI 验证。
**风险：** 「相同」判错会放过未验证的代码，所以必须用 tree 比较；rebase 改变了依赖（比如上游改了被测代码的依赖）时 `CODE same` 的判断要保守。**验收：** 反例测试（配置变了、依赖变了、tree 不同）都拒绝复用。**这条不改变现行规则，需要 owner 同意后单独开工单。**

## 6 没核实的

- CI 失败运行的日志没有下载，所以「main 的 10 次红灯都是 flaky」是推断；#749、#751 的正文是依据。
- node 红灯与 diff 的关系按目录判断，9 次「同目录」可能是真回归，没有逐个读。
- 运行时长用 summary 文件的创建和修改时间估算，前缀被复用时偏大；没有锁遥测。
- 11-17 的 2 次 node 红（`i688-rs1-fix1` 3 个失败、`i688-rs1-fix1v` 1 个）当时分支是否已含 #742，没有确认。
- Google、Meta、GitHub merge queue、OpenAI 的原文没有直接读到，已逐条标注；Codex 没有网络，外部来源完全依赖 Fable。
- 「TSan 一直没有 lane」「diffcheck 顺序」等文件行号级的说法是 Fable 的，我没有逐条复核（核对了 `@Test` 正则、`xcodegen` 和 gate 汇总数字）。
