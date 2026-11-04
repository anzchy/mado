# picsee — 给 agent 的入口

picsee 是一个 macOS 原生看图应用（Swift 6 + SwiftUI + AppKit，最低 macOS 14，sandbox 开启）。参考对象是 Picview，设计方向是用户确认的 **C · Quiet Image Canvas**。

**当前状态（2026-10-22）**：原生工程骨架已建立（`P0-01`/`P0-02`），ADR-002…007、Swift receipt lane 和真机测试脚本已合入；`P0-03`（#7）与 `P0-07`（#6）正在进行。

这份文件只是地图，不是手册：每一节告诉你去哪里读，细节以被链接的文件为准。这里与被链接文件说法不一致时，以被链接文件为准，这份文件需要修正。

## 最重要的一份文件：功能账簿

[`docs/feature-ledger.md`](docs/feature-ledger.md) 是 **picsee 现在实际有什么** 的唯一记录：每项能力的状态、代码位置、在 App 里怎么确认。

- 开始任何工作前，先在账簿里找到与任务相关的行（按 ID 或「计划」列里的工作包 ID）。行里的「怎么确认」就是这项能力的验收。
- **改变用户可见行为的提交，同时改它的那一行。** 状态只能升到证据支持的程度：`Shipped` 需要真机记录。
- 状态升级的那次提交，可以追加或修改「限制：」文本，但不得改写「怎么确认」中的验收本身。确需改验收时，单独提交并在提交说明里引用用户原话或 ADR。
- 不要因为浏览器原型或 mockup 里有某个功能，就认为 picsee 有它。
- [`docs/feature-ledger.html`](docs/feature-ledger.html) 是它的渲染视图，由账簿生成，不要手改；改账簿后运行 `npm run ledger:build`，两者一起提交。`npm run ledger:html-check` 检查是否同步。

## doc gardener 每天跑一次

用户 2026-11-04：「之后picsee-doc-gardener 每天跑一次，当前跑得太频繁了」，选择「每天在 main 上统一扫一次」。规程见 [`docs/agents/doc-gardening.md`](docs/agents/doc-gardening.md)「When it runs」。

1. **每天一次**：delegator 在 `origin/main` 的干净 detached worktree 里，对 `<上次扫到的 main>..origin/main` 先跑 `node scripts/ledger/garden-gate.mjs`；输出 `RUN` 时运行 **picsee-doc-gardener**（Claude Code：subagent；Codex：custom agent），模式 `pr`。
2. 按结果处理：

   | 结果 | 怎么做 |
   |---|---|
   | `SKIP` / `CLEAN` | 只记下这次扫到的 main head |
   | `UPDATED` | 检查 `git diff -- docs/feature-ledger.md docs/feature-ledger.html`，提交为 `docs(ledger): garden <base7>..<head7>`，开一个小 PR |
   | `NEEDS-OWNER` | 改账簿里被点名的行，或问用户；同一个小 PR |
   | `BLOCK` | 已合入 main 的验收改动或无证据升级：告诉用户，开 issue，修正后再扫 |

3. **PR 不再等 gardener**：打开或重新推送 PR 时不运行 gardener，PR 描述写 `Ledger-Gardener: DAILY <base7>..<head7> (covered by the daily sweep)`。改变用户可见行为的提交仍要同时改它的账簿行（见上一节），这条不变。

## 按需阅读

| 你要做的事 | 先读 |
|---|---|
| 任何实现工作 | [开发计划](docs/PICSEE_DEVELOPMENT_PLAN.md) 里对应的工作包与验收；[架构](docs/PICSEE_ARCHITECTURE.md) 里的 target 分工 |
| UI、颜色、间距、组件 | [`design/DESIGN.md`](design/DESIGN.md)、[原生映射](design/picsee-ui-system/native/README.md)、[状态稿](design/prototypes/picsee-browser/states/README.md)、[UI 对照契约](docs/agents/ui-parity-contract.md)（20 页 mockup，开发计划 §1.3 有页面到工作包的映射） |
| 参考 Picview 的某个功能 | 功能清单 `docs/PICVIEW_FEATURES.md`、技术分析 `docs/PICVIEW_ANALYSIS.md`（本地研究资料，不在公开仓库）。这些只是静态证据，不是已测行为 |
| 多 agent 协作、brief、审计 | [迁移计划](docs/plans/20261021-herdr-roster-migration-plan.md)、[多模型 roster 使用指南](docs/agents/claude-driven-ai-providers.md)；接手 delegator 先用 skill [`picsee-delegator`](.agents/skills/picsee-delegator/SKILL.md)（`.claude/skills/` 下为指向它的软链接）。协作规则 `.claude/rules/70-herdr-roster.md` 尚未写成 |
| 功能做完后在真机验收、更新账簿、跑 gardener | [功能验收指南](docs/guide/feature-verification-guide.md) |
| 性能与验证记录 | `docs/validation/P*.md`，从 P0 开始创建；指标定义见开发计划 §10 |
| 架构决定 | `docs/adr/`，从 P0-07 开始创建 |
| 为什么这样做、怎样运作（owner 问过的 why/how/what） | [`docs/knowledge/owner-questions.md`](docs/knowledge/owner-questions.md)；新的同类问答追加到这里，进度类问题不记 |

## 仓库结构

```text
docs/                  计划、架构、功能账簿、agent 规程（docs/agents/）
design/                设计规范、原生映射、浏览器原型与 20 页状态稿
evidence/              Picview 研究证据（本地研究资料，不在公开仓库）
scripts/               研究与设计工具脚本（Python / Node）
.agents/skills/        项目级 skills（Codex）；.claude/skills/ 是 Claude Code 的同一批
.claude/agents/        Claude Code subagents；.codex/agents/ 是 Codex 的
```

原生工程的目录结构按 [架构 §2.2 建议目录树](docs/PICSEE_ARCHITECTURE.md) 在 P0-01 建立：`App/`、`Packages/PicseeKit/Sources/{PicseeCore,PicseeApplication,PicseeInfrastructure,PicseeMacUI}`、`UITests/`、`TestAssets/`。

## 命令

素材生成/检查：`python3 scripts/testassets/generate.py --output TestAssets`；`python3 scripts/testassets/check.py`。
全量确定性/照片下载：`scripts/heavy-lock.sh python3 scripts/testassets/determinism.py --tier all`；`python3 scripts/testassets/download.py`（详见 `TestAssets/README.md`）。

研究和设计预览命令：

```sh
npm ci --ignore-scripts          # 安装 REA、Stitch CLI（不运行生命周期脚本）
npm run preview:prototype        # 浏览器原型，http://127.0.0.1:4311
npm run preview:states           # 20 页状态稿，http://127.0.0.1:4313
```

原生工程使用 Xcode 26.6（17F113），先生成再构建；产物留在当前 worktree：

```sh
xcodegen generate
swift test --package-path Packages/PicseeKit
xcodebuild build -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci
# 本机手动签名（Apple Development，团队 GRT84NAK4T）并启动
xcodebuild build -scheme Picsee -destination 'platform=macOS' -derivedDataPath .build/dd-signed
open -n .build/dd-signed/Build/Products/Debug/Picsee.app
```

`*.xcodeproj` 由 `project.yml` 生成，不入库。账簿 HTML 用 `npm run ledger:build` 生成、用 `npm run ledger:html-check` 检查；五条规则门禁 `ledger:check` 仍按迁移计划 A12 待建。

Swift RED 使用手动 lane `swift-red`，只跑指定测试。先写能编译的失败断言，再记录；`--files` 只选指纹文件，不选择测试。record 和 verify 必须传相同的过滤器（环境变量不会写入 receipt）：

```sh
# 固定使用已验收的 tdd-guardian 0.10.2；测试可用 PICSEE_TDD_PLUGIN_ROOT 覆盖
plugin_root="$HOME/.claude/plugins/cache/xiaolai/tdd-guardian/0.10.2"
export PICSEE_SWIFT_FILTER='测试函数名'
node "$plugin_root/scripts/tdd-guardian/receipt.js" record --id P0-XX-WI-1 --lane swift-red --files Packages/PicseeKit/Tests/PicseeCoreTests/ItemIDTests.swift
# 实现后，保留相同 PICSEE_SWIFT_FILTER
node "$plugin_root/scripts/tdd-guardian/receipt.js" verify --id P0-XX-WI-1
node "$plugin_root/scripts/tdd-guardian/receipt.js" show
node --test scripts/tdd/*.test.mjs
```

也可直接用 `node scripts/tdd/swift-lane.mjs itemIDSurvivesJSONRoundTrip` 跑单测。所有已启动框架均须完成根运行；编译失败、零测试、崩溃或不完整输出退出 70，不输出计数。正常断言失败退出 1；计数前打印 `swift-lane filter=<f>` 供输出 tail 审计，verify 仍须传相同过滤器。

新 API 按此流程先写可编译桩，桩在 record 时是未提交的实现改动，Swift receipt 总会带 `implementation-already-present` MEDIUM；审计仍须核对桩与 RED。断言消息含 “No such file or directory” 时，插件会把失败升级为环境失败并拒收有效 RED。

receipt lane 和两个 discovery probe 均走 `scripts/heavy-lock.sh`；其他重任务用 `scripts/heavy-lock.sh <命令…>`。只有重任务本身放进 `scripts/heavy-lock.sh`，每次调用只运行一个命令；不要包装交互式或裸 shell（不带脚本和 `-c` 的 `zsh`、`bash` 或 `sh`）、REPL、sleep/wait 或持久会话，也不要在阅读、思考或编辑时持锁（参见 mdpro `docs/reference/20261023-heavy-lock-incident.md`，“Heavy-lock incident, 2026-10-23”；以及 mdpro `docs/adr/0135-one-heavy-lock-tool-serves-every-project-queues-in-arrival-order-and-admits-by-memory.md`，ADR-0135 “One heavy-lock tool serves every project, queues in arrival order, and admits by memory”）。先取持久 flock `~/.picsee/locks/heavy.lock`，再取 mdpro 目录锁 `~/.cache/mdpro-heavy.lock`，两项目通常不会同时运行重任务（**best effort**）。已知限制：mdpro 自身的 stale-lock reclaim 有竞争窗口；picsee holder 被 SIGKILL 或进程组在 KILL 后仍存活时，mdpro 可能在 workers 仍存活时回收死 owner；picsee 从不回收 stale 目录，超时退出 75 后须先对 owner 的 `cmd` 用 `pgrep -f` 确认该任务无进程存活，再手动删除目录。`PICSEE_MDPRO_LOCK` 覆盖共享路径（`off` 跳过），互操作测试用 `PICSEE_MDPRO_SCRIPT` 指定 mdpro 脚本，未设则显式 skip。反向嵌套时 `MDPRO_HEAVY_LOCK_HELD=1` 表示父 mdpro 已持锁，只取 picsee flock，若已被占用立即退出 75；只有实际取得共享锁才向子进程新增此标记。`PICSEE_HEAVY_LOCK_HELD=1` 直接运行并保留父环境。flock 描述符由子进程继承，最后关闭才解锁；不要删除锁文件。`PICSEE_HEAVY_LOCK` 覆盖 flock 路径，`PICSEE_HEAVY_LOCK_WAIT_SECS` 默认 1800 秒，两次等待共用预算。正常结束须等进程组清空，5 秒后打印存活进程并每 60 秒重复；`PICSEE_HEAVY_LOCK_DRAIN_SECS` 默认 300 秒，到期与 INT/TERM 共用 TERM、grace、KILL 流程，再最多等 5 秒；组清空则正常释放，否则警告并保留共享目录；drain 到期仍返回原任务状态。`unit` 测试和覆盖率配置不变。

## 必须遵守的规则

- **测试先行。** 行为改动先写会失败的测试，再写实现。Claude Code 用 `/tdd-guardian:workflow`；从 P1 第三波起，Codex 用 tdd-guardian 的官方 Codex 移植 `$tdd-guardian-workflow`：plan → 经 spec adversary 的 design-tests → 按 WI implement 并留下 RED receipts → coverage；上方 receipt lane 是 Swift RED 机制。workflow 不提交；实现者通过 green gates 后按 WI 提交。config 已关闭 mutation。测试框架还没有时，说明这一点，不要跳过。
- **sandbox 不关。** 不添加 Full Disk Access 依赖，不用 entitlement 绕过授权。遇到冲突，记录复现步骤，写 ADR，问用户。
- **研究资料不进 App。** App target 不打包 REA、npm、`evidence/`、HTML/CSS 或 Stitch 产物。
- **不入库的内容**：`.gitignore` 里列出的大体积反汇编和字符串转储（其中含第三方 API key）、`.stitch/` 工作区、本地工具状态。不要用 `git add -A` 把它们带进来，只暂存你能逐个说出名字的路径。
- **不伪造数据。** 没测过的性能不写数字；读不到的元数据显示“未知”；后续版本功能的可见入口按用户原话「显示但置灰」「置灰显示，改规则」标注「即将推出」，不可点击、不可聚焦、不显示快捷键，VoiceOver 读出「即将推出」。
- **提交信息** 用 `<type>(<scope>): <summary>`，例如 `feat(viewer): anchor zoom at cursor`。在提交说明里写相关的账簿 ID 和工作包 ID，gardener 靠它们把改动对应到账簿行。实现提交加 trailer `Implemented-by: <角色>`；真机验证记录单独提交，加 `Validated-by: <角色> run=<运行 ID>`（见[功能验收指南](docs/guide/feature-verification-guide.md)）。
- **危险命令先问**：`rm -r`、`git reset --hard`、`git push --force`、删除分支或 worktree。

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on anzchy/picsee (gh CLI). Issue titles carry the plan WP ID and ledger IDs. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily. See `docs/agents/domain.md`.

## Claude Code 与 Codex 的差别

- Claude Code 通过 [`CLAUDE.md`](CLAUDE.md) 加载这份文件，并自动加载 `.claude/rules/`。
- Codex 只加载这份文件，不会自己去读链接，需要你按上面的表格主动去读。
- Codex 没有 `AskUserQuestion` 和 `SendMessage`：需要人决定的事，停下来写在最终回复里。
