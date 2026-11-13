# Mado — 给 agent 的入口

Mado 是一个 macOS 原生看图应用（Swift 6 + SwiftUI + AppKit，最低 macOS 14，sandbox 开启）。参考对象是 Picview，设计方向是用户确认的 **C · Quiet Image Canvas**。

**当前状态（2026-10-22）**：原生工程骨架已建立（`P0-01`/`P0-02`），ADR-002…007、Swift receipt lane 和真机测试脚本已合入；`P0-03`（#7）与 `P0-07`（#6）正在进行。

这份文件只是地图，不是手册：每一节告诉你去哪里读，细节以被链接的文件为准。这里与被链接文件说法不一致时，以被链接文件为准，这份文件需要修正。

## 最重要的一份文件：功能账簿

[`docs/feature-ledger.md`](docs/feature-ledger.md) 是 **Mado 现在实际有什么** 的唯一记录：每项能力的状态、代码位置、在 App 里怎么确认。

- 开始任何工作前，先在账簿里找到与任务相关的行（按 ID 或「计划」列里的工作包 ID）。行里的「怎么确认」就是这项能力的验收。
- **改变用户可见行为的提交，同时改它的那一行。** 状态只能升到证据支持的程度：`Shipped` 需要真机记录。
- 状态升级的那次提交，可以追加或修改「限制：」文本，但不得改写「怎么确认」中的验收本身。确需改验收时，单独提交并在提交说明里引用用户原话或 ADR。
- 不要因为浏览器原型或 mockup 里有某个功能，就认为 Mado 有它。
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

原生工程的目录结构按 [架构 §2.2 建议目录树](docs/PICSEE_ARCHITECTURE.md) 在 P0-01 建立：`App/`、`Packages/MadoKit/Sources/{MadoCore,MadoApplication,MadoInfrastructure,MadoMacUI}`、`UITests/`、`TestAssets/`。

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
swift test --package-path Packages/MadoKit
xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci
# 本机手动签名（Apple Development，团队 GRT84NAK4T）并启动
xcodebuild build -scheme Mado -destination 'platform=macOS' -derivedDataPath .build/dd-signed
open -n .build/dd-signed/Build/Products/Debug/Mado.app
```

`*.xcodeproj` 由 `project.yml` 生成，不入库。账簿 HTML 用 `npm run ledger:build` 生成、用 `npm run ledger:html-check` 检查；五条规则门禁 `ledger:check` 仍按迁移计划 A12 待建。

Swift RED 使用手动 lane `swift-red`，只跑指定测试。先写能编译的失败断言，再记录；`--files` 只选指纹文件，不选择测试。record 和 verify 必须传相同的过滤器（环境变量不会写入 receipt）：

```sh
# 固定使用已验收的 tdd-guardian 0.10.2；测试可用 PICSEE_TDD_PLUGIN_ROOT 覆盖
plugin_root="$HOME/.claude/plugins/cache/xiaolai/tdd-guardian/0.10.2"
export PICSEE_SWIFT_FILTER='测试函数名'
node "$plugin_root/scripts/tdd-guardian/receipt.js" record --id P0-XX-WI-1 --lane swift-red --files Packages/MadoKit/Tests/MadoCoreTests/ItemIDTests.swift
# 实现后，保留相同 PICSEE_SWIFT_FILTER
node "$plugin_root/scripts/tdd-guardian/receipt.js" verify --id P0-XX-WI-1
node "$plugin_root/scripts/tdd-guardian/receipt.js" show
node --test scripts/tdd/*.test.mjs
```

也可直接用 `node scripts/tdd/swift-lane.mjs itemIDSurvivesJSONRoundTrip` 跑单测。所有已启动框架均须完成根运行；编译失败、零测试、崩溃或不完整输出退出 70，不输出计数。正常断言失败退出 1；计数前打印 `swift-lane filter=<f>` 供输出 tail 审计，verify 仍须传相同过滤器。

App RED 也可只跑指定测试：`node scripts/tdd/app-lane.mjs [filter]`，或在 receipt 的 record **和** verify 前设置同一个 `PICSEE_APP_FILTER`。参数优先于环境变量；filter 是匹配运行时完整 ID 的正则表达式（例如 `issue512ChildReadKeepsTitleCurrentRowAndFailureDash`，多个测试用 `nameA|nameB`）。环境变量不会写入 receipt，`--files` 仍只选指纹文件。设置 `PICSEE_APP_LANE_NO_RETRY=1` 记录 RED；先 build-for-testing 到 `.build/dd-ci`。成功解析后、计数前打印 `app-lane filter=<f>`；零匹配或执行集合不符退出 70，不输出计数。从环境变量读取 filter 时会在 stderr 提示；完整运行前先执行 `unset PICSEE_APP_FILTER`。未传 filter 时先跑保留的 MadoAppTests bundle（应用隔离清单），再用 `xcodebuild test-without-building` 跑 MadoHostedFocusTests 组；合并结果，环境错误退出 70、测试失败退出 1、成功退出 0。`PICSEE_APP_DERIVED_DATA_PATH` 可覆盖默认的 `.build/dd-ci`。过滤后的保留组精确 ID 通过 `xcrun xctest -XCTest` 传入，Swift Testing 路径已有真实 bundle 运行证据；XCTest 过滤路径仅有 Node 假进程覆盖（真实 App bundle 没有 XCTestCase）。过滤选择中的每个测试必须通过或失败；任何跳过均退出 70，不输出计数。隔离清单中的保留组测试始终排除。

App lane：`node scripts/tdd/app-lane.mjs` 读取 `scripts/tdd/app-quarantine.json`（默认 `[]`）。隔离时添加 `{"id":"MadoAppTests.someTest()","issue":411,"reason":"具体原因","owner":"负责人","expires":"2026-11-22"}`；每条必须有正整数 issue、非空 reason 和 owner，以及真实的 YYYY-MM-DD 格式 expires。expires 按本次隔离期限填写，在该 UTC 日期当天仍有效；早于当前 UTC 日期时，lane 退出 70。修复后删除对应条目。XCTest 标识用 `Class/method`，Swift Testing 用运行时列举的模块限定形式 `Module.func()` 或 `Module.Suite/method()`。实测 `XCTestInvertScope` 不会排除目标；非空清单因此先从编译 bundle 枚举两类测试，再由原来的 `xcrun xctest -XCTest` 只运行剩余标识，并逐项核对执行集合。hosted 测试 ID 不能隔离；只选 hosted 组且隔离清单非空时退出 70。未指定 filter 时，非空清单必须保留至少一个 Swift Testing 测试，否则以明确的不支持提示退出 70。选定运行的完整一致输出中，测试失败退出 1；环境失败或输出不完整、不一致退出 70。清单无效、枚举失败、标识不支持或有歧义均退出 70；已不存在的标识先警告再退出 70。CI 会逐条打印标识与 issue；未指定 filter 且清单为空时，保留组保持原运行参数和解析规则。
本地在 `~/Documents` 下的 worktree 运行时，`.build/dd-ci` 中的 Mado.app 可能触发文件夹访问授权提示；即使把 DerivedData 放到 Documents 外，也可能拿不到目标 key window。这类本地失败不能当作 hosted CI 的测试结论。
升级 Xcode 后，重跑混合 XCTest + Swift Testing probe，确认枚举 ABI 与控制台标签仍兼容。

新 API 按此流程先写可编译桩，桩在 record 时是未提交的实现改动，Swift receipt 总会带 `implementation-already-present` MEDIUM；审计仍须核对桩与 RED。断言消息含 “No such file or directory” 时，插件会把失败升级为环境失败并拒收有效 RED。

receipt lane 和两个 discovery probe 均走 `scripts/heavy-lock.sh`；其他重任务用 `scripts/heavy-lock.sh <命令…>`。只有重任务本身放进 `scripts/heavy-lock.sh`，每次调用只运行一个命令；不要包装交互式或裸 shell（不带脚本和 `-c` 的 `zsh`、`bash` 或 `sh`）、REPL、sleep/wait 或持久会话，也不要在阅读、思考或编辑时持锁（参见 mdpro `docs/reference/20261023-heavy-lock-incident.md`，“Heavy-lock incident, 2026-10-23”；以及 mdpro `docs/adr/0135-one-heavy-lock-tool-serves-every-project-queues-in-arrival-order-and-admits-by-memory.md`，ADR-0135 “One heavy-lock tool serves every project, queues in arrival order, and admits by memory”）。先取持久 flock `~/.picsee/locks/heavy.lock`，再取 mdpro 目录锁 `~/.cache/mdpro-heavy.lock`，两项目通常不会同时运行重任务（**best effort**）。已知限制：mdpro 自身的 stale-lock reclaim 有竞争窗口；picsee holder 被 SIGKILL 或进程组在 KILL 后仍存活时，mdpro 可能在 workers 仍存活时回收死 owner；picsee 从不回收 stale 目录，超时退出 75 后须先核对 owner 的 `pid`，用 `ps` 检查该进程及其进程组、子进程确已消失，再手动删除目录；`cmd` 只记录参数个数，不能用于匹配进程。若 flock 持续被占用，检查 `~/.picsee/locks/heavy.lock.guardian-*.owner` 的 `pid`、`cmd`、`started`、`supervisor`、`job`，用 `ps -p <pid> -o pid=,ppid=,lstart=,command=` 核对实际进程，再用 `lsof -p <pid>` 核对其打开的 `heavy.lock`；同名 `.log` 记录 guardian 异常。owner 的 `job` 只记录参数个数；仅确认实际 worker 进程组及已注册 host 全部消失后，才对该 PID 手动恢复；不要删除 `heavy.lock` 文件。`PICSEE_MDPRO_LOCK` 覆盖共享路径（`off` 跳过），互操作测试用 `PICSEE_MDPRO_SCRIPT` 指定 mdpro 脚本，未设则显式 skip。反向嵌套时 `MDPRO_HEAVY_LOCK_HELD=1` 尚无可验证的 handoff，此路径暂不可用，在取 flock 或启动任务前退出 70；后续由 #665 恢复。只有实际取得共享锁才向子进程新增此标记。`PICSEE_HEAVY_LOCK_HELD=1` 只是嵌套提示；必须有可验证的父控制 FD，CI 入口由 workflow 提供一次性顶层模式输入并在启动子进程前移除。父 supervisor 与 guardian 保持 flock，直至已注册的进程组和 App host 确认清空；不要删除锁文件。`PICSEE_HEAVY_LOCK` 覆盖 flock 路径，`PICSEE_HEAVY_LOCK_WAIT_SECS` 默认 1800 秒，两次等待共用预算。正常结束须等进程组清空，5 秒后打印存活进程并每 60 秒重复；`PICSEE_HEAVY_LOCK_DRAIN_SECS` 默认 30 秒；启动后的执行预算按任务为 discovery 5 分钟、过滤 Swift 10 分钟、全包 20 分钟、其他重任务 30 分钟，可在启动前用有限且可表示的 `PICSEE_HEAVY_LOCK_EXEC_SECS` 覆盖。执行超时立即 TERM，默认 10 秒后 KILL，再观察最多 5 秒；清理确认完成时超时退出 124，清理不完整、未知或状态未发布退出 70，取锁超时退出 75。`unit` 测试和覆盖率配置不变。顶层持锁任务超过执行预算时（#672），supervisor 写 `~/.picsee/herdr/delegator/lock-alerts/<id>.json`（`PICSEE_HEAVY_ALERT_DIR` 覆盖目录；0600；含命令、截止时间、PID/PGID、存活进程状态与 RSS、保留的锁路径），并向同目录 `attention.log` 追加一行；`listen-notify.py status` 会一直报 attention，直到把该文件移入 `lock-alerts/acked/`。嵌套 supervisor 和 guardian 路径不发 alert。私有状态记录带 `drainExpired`：Trash lane 与 swift-red receipt 拒收 leader 已退出但仍有后代存活的运行，heavy-lock 自身退出码不变。

Trash 集成 lane（#672）：真实 `FileManager.trashItem` 测试只在 `#if MADO_TRASH_INTEGRATION` 内编译，默认包 lane 不运行，名单在 `scripts/tdd/trash-integration.json`。`node scripts/tdd/trash-lane.mjs` 自行取锁：先单独编译（`.build/trash-integration`），再在一次锁内逐个场景运行，每个场景 120 秒，随后 TERM、10 秒、KILL、5 秒；整条命令预算 10 分钟（不含编译）。首个超时或存活进程即停止，不重试；缺前置条件（Swift、`~/.Trash`）或场景被跳过时退出 70 且不输出计数。`node scripts/tdd/trash-lane.mjs --discover` 双向证明默认 lane 不含这些场景、集成 lane 恰好多出它们。不要用外层 `scripts/heavy-lock.sh` 包它。

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
