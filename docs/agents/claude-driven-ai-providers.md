# Mado 多模型 roster 使用指南（草案）

探针 P1–P7 尚未运行；只有全部通过后，codex-auditor 才按第 6 节的跨厂商配对取代 gpt-auditor。
文中的 `scripts/install-shims.sh` 和 `scripts/start-roster.sh` 目前仅在本地 `~/.picsee/herdr/opus-auditor/roster-proposal/scripts/`，尚未入库。

日期：2026-10-28 · 作者：opus-auditor（应用户要求起草）· 状态：**提案，未实测**。
本指南说明怎样用 [xiaolai/claude-driven-ai-providers](https://github.com/xiaolai/claude-driven-ai-providers)（下称 clai）
让 Claude Code 驱动 Codex（ChatGPT 订阅）与 Kimi 模型，并在 Mado 现有 herdr 规程里加入五个角色：
researcher、planner、opus-implementor、codex-implementor、codex-auditor（doc gardener 沿用现有 `picsee-doc-gardener`）。

标 **【待验证】** 的步骤还没有在本机跑过，第一次执行时按「9. 首次探针」逐项确认，结果记进 handoff 日志。

---

## 1. 核心概念：模型按进程选，不按 subagent 选

- clai 的每个启动器（`clcd`、`clki`…）启动**一个独立的 Claude Code 进程**，并设置自己的 `CLAUDE_CONFIG_DIR`（profile）。
  进程里的所有 subagent 都用这个提供方；agent 文件里写 `model: opus` 只是映射到该提供方的某个模型。
- 所以「不同角色用不同厂商」= **不同 herdr pane 跑不同启动器**，角色之间仍靠文件交接（`~/.picsee/herdr/<pane>/`）。
- 新 agent 文件放在**项目级** `.claude/agents/`。各启动器的 profile 互相隔离，`~/.claude/agents/` 在 `clcd`/`clki` 进程里看不到；项目级目录都能读到。
- 「ChatGPT 网页版订阅」实际走的是 Codex 订阅通道：`codex login` 用 ChatGPT 账号登录，`clcd` 借 Codex 的认证后端
  （`chatgpt.com/backend-api/codex/responses`）。额度与网页版同一个订阅；不经过网页界面。该后端不是公开 API，随时可能变化。

## 2. 角色、模型与 pane

| 角色 | agent 文件 | pane | 启动器 · 模型 · effort | 写什么 |
|---|---|---|---|---|
| researcher | `researcher.md` | `kimi-researcher` | `clki` · kimi-k3（注册表默认） | `~/.picsee/herdr/kimi-researcher/<item>-research.md` |
| planner | `planner.md` | `gpt-planner` | `clcd` · gpt-6.1-sol（注册表默认）· xhigh | `~/.picsee/herdr/gpt-planner/<item>-plan.md`（草稿 brief） |
| opus-implementor | `opus-implementor.md` | `opus-imple-<n>` | 原生 `claude` · Opus | 代码 + `<item>-handoff.md` |
| codex-implementor | `codex-implementor.md` | `codex-imple-<n>` | `clcd` · gpt-6.1-sol · medium | 代码 + `<item>-handoff.md` |
| codex-auditor | `codex-auditor.md` | `codex-auditor` | `clcd` · gpt-6.1-sol · high | `~/.picsee/herdr/codex-auditor/<item>-r<round>.md` |
| opus-auditor | 现有 `picsee-opus-auditor.md` | `opus-auditor`（w1:p6） | 原生 `claude` · Opus | 不变 |
| doc gardener | 现有 `picsee-doc-gardener.md` | 不占 pane | delegator 调用的 Haiku subagent | 不变 |

模型 ID 以 `clai probe codex` / `clai probe kimi` 的输出为准；表中只是 2026-10-27 注册表默认值。
没有任何价格、速度、质量的实测数字；分配理由：

- researcher 用 Kimi：1M 上下文、读大量资料；只读，出错成本低。
- planner 用 ChatGPT 订阅、xhigh：与实现者不同厂商，计划多一层独立视角。
- 实现者两种：Opus 在原生 Claude Code 里工具调用最稳；codex-implementor 让 Codex 模型在 Claude Code 外壳里干活，
  Bash 不受 Codex 沙箱限制（mini 上 Codex CLI pane 不能跑 xcodebuild，这条可以）。
- 审计跨厂商（见第 6 节），盲点不重叠。
- 现有原生 Codex CLI pane（`gpt-imple-*`、`gpt-auditor`）和 `kimi-imple-1` 不受影响，继续可用。

## 3. 一次性准备

### 3.1 依赖
```sh
brew install jq socat                    # curl、openssl 系统自带
npm i -g @openai/codex && codex login    # 选 ChatGPT 账号登录
```
Kimi：在 platform.kimi.ai 申请 `MOONSHOT_API_KEY`（或 `KIMI_API_KEY`），**不要贴进聊天**。

### 3.2 安装 clai
```sh
git clone https://github.com/xiaolai/claude-driven-ai-providers.git ~/src/claude-driven-ai-providers
cd ~/src/claude-driven-ai-providers && claude
```
在这个 Claude Code 会话里：
```text
./clai skill install
/clai-setup codex
/clai-setup kimi
```
每次 `/clai-setup` 生成一个 600 权限的 `~/.config/claude-driven-ai-providers/setup/.env-<provider>`。
在编辑器里自己填 key（codex 不需要 key），然后对 Claude 说「Apply that setup file」。启动器装到 `~/.local/bin`。
Mac mini 和 MacBook 各自在本机跑 `./clai install`（启动器里是绝对路径，不能复制）。

### 3.3 验证
```sh
clai doctor codex --network && clai check codex --tools
clai doctor kimi  --network && clai check kimi  --tools   # Kimi 通道原 repo 未做真实凭据验证，必须过这一步
clai doctor codex | grep -A3 claude.executable            # 确认指向你要的 claude
clai probe codex; clai probe kimi                          # 看可用模型 ID
clai config set codex model <probe 里的 ID>                # 需要时再改，默认 gpt-6.1-sol
clai config set kimi  model <probe 里的 ID>
```
`check --tools` 会真的调一次模型（Kimi 计费、Codex 占订阅额度）。

### 3.4 把 agent 文件入库
五个 `.md` 放进 `.claude/agents/`，按 AGENTS.md 走一个 docs/agents 小 PR（gardener 结论应为
`无用户可见变化`）。入库后把每个 pane 的 worktree 移到新 main 再启动（`/clear` 不会重新加载 agent 文件）。

### 3.5 包装脚本（shim）
`herdr agent start --kind claude` 只会运行 PATH 上的 `claude`，不能直接指定 `clcd`。`scripts/install-shims.sh`
为每个非 Anthropic pane 写 `~/.picsee/shims/<pane>/claude`：
```sh
#!/bin/sh
exec env CLAI_CLAUDE_BIN=<真实 claude 绝对路径> CLCD_EFFORT=xhigh CLCD_PROFILE=$HOME/.claude-codex-planner <clcd 绝对路径> "$@"
```
- `CLAI_CLAUDE_BIN` 指向真实 `claude`，避免 shim 自己调自己。
- `CLCD_EFFORT`、`CLCD_PROFILE` 是 `clcd` 源码里的启动期覆盖：effort 按 pane 分档，每个 pane 一个独立 profile，会话互不串。
- 在**没有** shim 的新 shell 里运行 `sh scripts/install-shims.sh`；改了 effort 或 profile 就重跑。

### 3.6 新 profile 的首次设置 【待验证】
每个新 profile（`~/.claude-codex-planner` 等）第一次启动会走 Claude Code 首次设置（主题、信任目录）。
实现者 profile 还要装 tdd-guardian 插件（与 `~/.claude` 里同一版本 0.10.2）；没装时 `codex-implementor`
按文件里写的手动先写测试步骤执行，并在 handoff 里说明。receipt 脚本路径是绝对路径，不受 profile 影响。

## 4. 启动 roster

```sh
sh scripts/start-roster.sh w1:p2      # 参数是用来 split 的已有 pane
```
脚本对每个角色：建 detached worktree（若不存在）→ `herdr pane split` → `cd` 到 worktree →
（非 Anthropic 角色）把 shim 目录放到 PATH 最前 → `herdr agent start <pane> --kind claude -- --agent <agent>`。

单独启动某个角色（手动等价命令）：
```sh
herdr pane split w1:p2 --direction down                       # 记下新 pane id
herdr pane send-text <id> 'cd ~/Documents/mac-app/picsee-wt/gpt-planner'; herdr pane send-keys <id> enter
herdr pane send-text <id> 'export PATH=$HOME/.picsee/shims/gpt-planner:$PATH; hash -r'; herdr pane send-keys <id> enter
herdr agent start gpt-planner --kind claude --pane <id> -- --agent planner
```
- 原生 Opus 实现者：`herdr agent start opus-imple-1 --kind claude --pane <id> -- --agent opus-implementor --model opus --dangerously-skip-permissions`
- clai 启动器自己会加 `--dangerously-skip-permissions`，shim pane **不要**再传。
- 启动后看状态行：模型名应是 Codex / Kimi 模型；不是就停下排查（第 10 节）。

## 5. 每个角色怎么用

所有角色每个请求前都要 `/clear`：`herdr pane send-text <pane> '/clear'` + `send-keys enter`，状态行显示 `Context 0%` 才发请求。
请求一律是一个指向请求文件的单行 prompt，例如
`herdr agent prompt gpt-planner 'New request: read and follow ~/.picsee/herdr/delegator/p318-plan-request.md'`。
等结果用 `listen-notify.py --poll report`，`--task` 与报告首行 `Report-Task:` 相同。

### 5.1 researcher 请求文件
```text
Item: p318. Question: <一两句>.
May read beyond the repo: docs/PICVIEW_FEATURES.md, docs/PICVIEW_ANALYSIS.md, <URL>.
Output: ~/.picsee/herdr/kimi-researcher/p318-research.md, Report-Task: p318-research-r1.
```
输出：答案、证据（每条 CONFIRMED / INFERRED / UNKNOWN + 来源）、约束、开放问题。不读 `evidence/` 原始转储。

### 5.2 planner 请求文件
```text
Item: p318 · WP P3-18 · issue #210 · main 1a2b3c4 · main checkout ~/Documents/mac-app/picsee.
Research: ~/.picsee/herdr/kimi-researcher/p318-research.md.
User decisions (verbatim): 「…」.
Target implementer: opus | codex | kimi.
Output: ~/.picsee/herdr/gpt-planner/p318-plan.md, Report-Task: p318-plan-r1.
```
输出是按 `brief-template.md` 填满的草稿 brief + `Planner notes`（放弃的方案、审计要看的风险、开放问题）。
**delegator 审读后**再复制到实现者目录作为正式 brief；fence、tier、用户原话由 delegator 负责最终核对。

### 5.3 实现者
与现在一样：`herdr agent prompt opus-imple-1 'New task: P3-18. Read and follow ~/.picsee/herdr/opus-imple-1/p318-brief.md'`。
两个实现者文件的规则段相同：只改 brief 的 You own、每个 WI 先 RED、`--files` 只填该 WI 的测试文件、
改坏 fixture/素材得到的失败不算 RED、UI 断言看渲染几何、只把重任务放进 heavy lock、命名路径暂存、按 WI 提交、
不 push / 不开 PR、账簿只改「限制：」，handoff 首行 `Report-Task:`。

### 5.4 codex-auditor
请求文件与 opus-auditor 完全相同（`audit-request-template.md`），只换报告路径 `~/.picsee/herdr/codex-auditor/<item>-r<round>.md`。
它读 `~/.picsee/herdr/delegator/audit-brief.md` 与 main 上的 `docs/agents/audit-dimensions.md`，读屏障、三种模式、报告格式不变。

## 6. 审计配对（跨厂商）

| 实现者 | 审计者 |
|---|---|
| opus-imple-*、kimi-imple-* | codex-auditor（或原生 gpt-auditor） |
| codex-imple-*、gpt-imple-* | opus-auditor |

双审时 codex-auditor 取代 gpt-auditor，按上表跨厂商配对；探针 P1–P7 通过后才切换（见第 11 节）。
轮数上限、Medium 政策、C/H 阻断、owner gates、gardener、CI 不变。

## 7. 一个工作项的完整流程

1. delegator 建 issue（`ready-for-agent`），引用用户原话。
2. 需要调研 → researcher；delegator 读 `Answer` 与 `Open questions`，必要时问用户。
3. Medium/High：grill → spec → tickets 后由 planner 出草稿 brief；Low：delegator 写 brief。delegator 审读、`overlap-check.py claim`、定稿到实现者目录。
4. 实现者实现、交 handoff；delegator 用 listener 等结果。
5. 按第 6 节配对派审计；delegator 后台跑 `owner-gates.sh`。
6. 处理 verdict、rebase、gardener、Device-Smoke、PR、合并——与 `picsee-delegator` skill 第 5–10 步相同。

## 8. 额度与成本

- planner、codex-implementor、codex-auditor 都走**同一个 ChatGPT 订阅**，额度共用；高峰期优先给审计。
- 所有实现者（gpt-imple、opus-imple、codex-imple、kimi-imple）的 Medium/High 风险工作项共用 4 个名额；Low 不计入。
- `clcd` 没有自动转 API 计费（那是 `cloa`，单独付费）；额度用完就是失败。
- Kimi 按 API 计费；`check --tools`、`probe --check-tools` 都会产生真实调用。

## 9. 首次探针（第一次启动必须做，结果写进 handoff 日志）

| # | 探针 | 通过条件 |
|---|---|---|
| P1 | shim pane 里 `herdr agent start … --kind claude` | herdr 报告 agent ready，状态行显示 Codex/Kimi 模型 |
| P2 | `herdr agent prompt gpt-planner 'Reply with your model id only'` | 回复是 Codex 模型，不是 Claude |
| P3 | `/agents` 列出 `planner` 等 5 个项目 agent | 全部可见（证明项目级 `.claude/agents` 在独立 profile 下生效） |
| P4 | `/clear` 后问「上一个请求是什么」 | 回答 NONE |
| P5 | codex-implementor 在 worktree 里跑 `scripts/heavy-lock.sh xcodebuild -version` | 正常输出（证明没有 Codex 沙箱） |
| P6 | codex-implementor 里 `/tdd-guardian:workflow` | 可用；不可用就装插件或接受手动 RED |
| P7 | `herdr pane split` 的输出 | `start-roster.sh` 取到的 pane id 正确；否则改脚本的 awk 一行 |

P1 失败的备用方案：不用 `herdr agent start`，直接
`herdr pane send-text <id> '~/.picsee/shims/gpt-planner/claude --agent planner'` + Enter；
之后对该 pane 用 `herdr pane send-text/read` 按 pane id 操作，listener 用 `--route claude-pane`。

## 10. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 状态行仍是 Claude 模型 | PATH 没带 shim（`which claude` 应指向 `~/.picsee/shims/...`）；或 shim 里的 `CLAI_CLAUDE_BIN` 指错 |
| shim 无限递归 / 进程暴涨 | `CLAI_CLAUDE_BIN` 指向了 shim 本身；在干净 shell 重跑 `install-shims.sh`（脚本会拒绝这种情况） |
| `/agents` 看不到新 agent | 文件不在项目 `.claude/agents/`，或 pane 的 worktree 早于入库提交 |
| `clcd` 报认证错误 | `codex login` 过期，重新登录；不要换成 `cloa` |
| Kimi 工具调用失败 | 先 `clai check kimi --tools`；换 `clai probe kimi` 里的其他模型 |
| 超时 | `CLCD_HEADER_TIMEOUT`（1–600 秒，默认 120） |
| 图片 / 截图不可靠 | bridge 未验证图片往返；视觉检查交给 delegator 的 Opus subagent |

## 11. 安全与已确认的用户决定

- clai 启动器都带 `--dangerously-skip-permissions`。只在各自 detached worktree 里运行；只读角色的 `tools`
  已去掉 Edit/Write（researcher、planner、codex-auditor 只用 Bash heredoc 写自己的一份报告）。
- key 只放 clai 的私有文件或环境变量，不进 repo、不进聊天、不进报告。
- 「取代 gpt-auditor，跨厂商配对」：codex-auditor 在探针 P1–P7 通过后取代 gpt-auditor 参与双审；原生 gpt-auditor pane 留作备用。
- 「计入，总上限 4」：Medium/High 指任务风险级别，所有实现者共用 4 个名额；Low 不计入。
- 「Medium/High 必经，Low 不用」：planner 在 grill → spec → tickets 后为 Medium/High 起草 brief；Low brief 由 delegator 写。
- 「去掉，但单独一次改动」：`picsee-opus-auditor`、`picsee-doc-gardener` 的改名留待后续独立 PR。

## 12. 回退

停掉新 pane，删除 `~/.picsee/shims/<pane>/` 与对应 `~/.claude-codex-*` profile 即可；agent 文件入库后不被调用就没有影响。
现有 roster（gpt-imple-*、gpt-auditor、opus-auditor、opus-imple-1、kimi-imple-1）全程不改。
