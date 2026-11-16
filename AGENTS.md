# Mado — 给 agent 的入口

Mado 是一个 macOS 原生看图应用（Swift 6 + SwiftUI + AppKit，最低 macOS 14，sandbox 开启）。参考对象是 Picview，设计方向是用户确认的 **C · Quiet Image Canvas**。

这份文件只是地图，不是手册：每一节告诉你去哪里读，细节以被链接的文件为准。这里与被链接文件说法不一致时，以被链接文件为准，这份文件需要修正。

## 最重要的一份文件：功能账簿

[`docs/feature-ledger.md`](docs/feature-ledger.md) 是 **Mado 现在实际有什么** 的唯一记录：每项能力的状态、代码位置、在 App 里怎么确认。

- 开始任何工作前，先在账簿里找到与任务相关的行（按 ID 或「计划」列里的工作包 ID）。行里的「怎么确认」就是这项能力的验收。
- **改变用户可见行为的提交，同时改它的那一行。** 状态只能升到证据支持的程度：`Shipped` 需要真机记录。
- 状态升级的那次提交，可以追加或修改「限制：」文本，但不得改写「怎么确认」中的验收本身。确需改验收时，单独提交并在提交说明里引用用户原话或 ADR。
- 不要因为浏览器原型或 mockup 里有某个功能，就认为 Mado 有它。
- [`docs/feature-ledger.html`](docs/feature-ledger.html) 是它的渲染视图，由账簿生成，不要手改；改账簿后运行 `npm run ledger:build`，两者一起提交。`npm run ledger:html-check` 检查是否同步。

## doc gardener 每天跑一次

PR 描述写 `Ledger-Gardener: DAILY <base7>..<head7> (covered by the daily sweep)`；打开或推送 PR 时不运行 gardener。每日扫描由 delegator 负责，步骤见下表「每日 gardener 扫描」。

## 按需阅读

| 你要做的事 | 先读 |
|---|---|
| 任何实现工作 | [开发计划](docs/PICSEE_DEVELOPMENT_PLAN.md) 里对应的工作包与验收；[架构](docs/PICSEE_ARCHITECTURE.md) 里的 target 分工 |
| UI、颜色、间距、组件 | [`design/DESIGN.md`](design/DESIGN.md)、[原生映射](design/picsee-ui-system/native/README.md)、[状态稿](design/prototypes/picsee-browser/states/README.md)、[UI 对照契约](docs/agents/ui-parity-contract.md)（20 页 mockup，开发计划 §1.3 有页面到工作包的映射） |
| 参考 Picview 的某个功能 | 功能清单 `docs/PICVIEW_FEATURES.md`、技术分析 `docs/PICVIEW_ANALYSIS.md`（本地研究资料，不在公开仓库）。这些只是静态证据，不是已测行为 |
| 多 agent 协作、brief、审计 | [迁移计划](docs/plans/20261021-herdr-roster-migration-plan.md)、[多模型 roster 使用指南](docs/agents/claude-driven-ai-providers.md)；接手 delegator 先用 skill [`picsee-delegator`](.agents/skills/picsee-delegator/SKILL.md)（`.claude/skills/` 下为指向它的软链接） |
| Linux CI 预检、Linux-only 失败复现 | [`ci-linux-preflight`](.agents/skills/ci-linux-preflight/SKILL.md)；仅补充证据，GitHub CI 仍是唯一约束结果 |
| 功能做完后在真机验收、更新账簿、跑 gardener | [功能验收指南](docs/guide/feature-verification-guide.md) |
| 性能与验证记录 | `docs/validation/P*.md`；指标定义见开发计划 §10 |
| 架构决定 | `docs/adr/` |
| 为什么这样做、怎样运作（owner 问过的 why/how/what） | [`docs/knowledge/owner-questions.md`](docs/knowledge/owner-questions.md)；新的同类问答追加到这里，进度类问题不记 |
| 每日 gardener 扫描（delegator） | [`docs/agents/doc-gardening.md`](docs/agents/doc-gardening.md)「When it runs」 |
| 生成/检查测试素材 | [`TestAssets/README.md`](TestAssets/README.md) |
| 看浏览器原型、状态稿（预览命令） | [`docs/guide/commands.md`](docs/guide/commands.md) |
| 写 RED receipt、跑单个测试 | [`docs/agents/test-lanes.md`](docs/agents/test-lanes.md) |

## 仓库结构

- `evidence/`：Picview 研究证据，只在本地，不在公开仓库。
- `.agents/skills/` 是项目级 skills（Codex）。`.claude/skills/` 里 apple-developer-setup、ci-linux-preflight、macos-device-test、mado-verify、picsee-delegator 是指向它的软链接，其余是复制件：改一份要同步另一份；`in-your-own-words` 只在 `.agents/skills/`。
- `.claude/agents/` 是 Claude Code subagents；`.codex/agents/` 是 Codex 的。

## 命令

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

重任务走锁：`swift test`、`xcodebuild`、`xcodegen` 和其他重任务一律 `scripts/heavy-lock.sh <命令>`，前台，一次一个；`scripts/tdd/*-lane.mjs` 和 receipt lane 自己取锁，直接运行，不要再包一层。卡锁、超时或要动锁目录前先读 [`docs/agents/heavy-lock.md`](docs/agents/heavy-lock.md)；不删 heavy.lock。

## 必须遵守的规则

- **测试先行（先红）。** 行为改动要有先失败、后通过的测试，RED receipt 记录在实现之前，record 与 verify 用同一个过滤器（[test-lanes](docs/agents/test-lanes.md)）。Claude Code 用 `/tdd-guardian:workflow`；从 P1 第三波起，Codex 用 tdd-guardian 的官方 Codex 移植 `$tdd-guardian-workflow`。workflow 不提交；实现者通过 green gates 后按 WI 提交。config 已关闭 mutation。
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
