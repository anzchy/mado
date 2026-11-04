# 用本机 Mac mini 做功能验收：macos-device-test + doc gardener 使用指南

这份指南写给 picsee 的负责人（你）：一个功能开发完之后，怎么在**本机 Mac mini（@1x）**上用
`macos-device-test` 技能在真实 App 里验收，再用 doc gardener 检查功能账簿，最后带着证据开 PR。
只有 @2x 验收例外：从 mini 经 SSH 驱动 MacBook Pro，并把命令送进 MacBook 桌面启动的 tmux 会话。

设备脚本的完整契约见 [device runbook §15](../../.agents/skills/macos-device-test/references/device-runbook.md)；
已实现和已验收状态以[功能账簿](../feature-ledger.md)为准。

## 1. 三件东西各管什么

| 东西 | 位置 | 管什么 | 不管什么 |
|---|---|---|---|
| 功能账簿 | [`docs/feature-ledger.md`](../feature-ledger.md) | picsee **现在有什么**：每行一项能力的状态、验证强度、代码位置、「怎么确认」（验收） | 怎么一步步操作 |
| `macos-device-test` 技能 | `.agents/skills/macos-device-test/` | **怎么在真实 App 里验**：构建、启动、doctor 自检、按 `features/` 的步骤操作、取证、清理、结论表 | 改账簿、改代码 |
| doc gardener | [`docs/agents/doc-gardening.md`](../agents/doc-gardening.md) | 每个 PR 前**检查账簿有没有过时或被放宽**：只做更谨慎的修改，升级一律交给你 | 跑 App、写验证记录、提交 |

三者的关系：账簿里的「怎么确认」是验收标准 → 设备测试按它在 App 里操作，写进 `docs/validation/P<n>.md` →
你根据记录升级账簿行 → gardener 检查这次升级有没有证据、有没有偷偷放宽验收。

## 2. 全流程一览

```text
功能实现完成（/tdd-guardian:workflow，单元测试全绿）
  │
  ├─ ① 找出要验的账簿行和每个入口
  ├─ ② 写 brief
  ├─ ③ 在独立验收会话中跑 macos-device-test（本机 mini）
  ├─ ④ 读结论表，写/提交 docs/validation/P<n>.md
  ├─ ⑤ 你按记录更新账簿行，运行 npm run ledger:build，把 Markdown 与 HTML 一起提交
  ├─ ⑥ 跑 picsee-doc-gardener（pr 模式）
  └─ ⑦ 按 gardener 结果处理，把 Ledger-Gardener 行放进 PR 描述，开 PR
```

发现 FAIL 时，不在验收会话里顺手改代码：回到 `/tdd-guardian:workflow` 先写一个会失败的回归测试再修，
修完重新从 ③ 跑**整张**结论表。

## 3. 本机一次性准备

只需要做一次，做完在 `docs/validation/P0.md` 里记一笔。

| 项目 | 怎么做 | 怎么确认 |
|---|---|---|
| Xcode | 锁定 **Xcode 26.6（build 17F113）**。脚本依次检查 `/Applications/Xcode-26.6.app`、`/Applications/Xcode.app`；`PICSEE_XCODE` 可显式覆盖 | 选中路径的 `Contents/Developer/usr/bin/xcodebuild -version` 输出 `Build version 17F113` |
| XcodeGen | 本机已装（`/opt/homebrew/bin/xcodegen`） | `xcodegen --version` |
| 签名 | 钥匙串里已有团队 `GRT84NAK4T` 的 Apple Development 证书（2027-01-31 到期） | `security find-identity -v -p codesigning` 里能看到它 |
| 终端权限 | 运行验收会话的终端 App 已获所需的**屏幕录制**和**辅助功能**权限；验收时不自行更改隐私设置 | computer use 截图能看到桌面 |
| 输入法 | 验收前切到 **ABC** | 菜单栏输入法图标 |
| 运行目录 | `mkdir -p ~/.picsee/device-runs` | 目录存在 |
| 已安装的 Picsee | 用户自己的 Picsee 可保留安装，但验收时不能运行 | `pgrep -fl Picsee` 没有输出 |

本机 mini 是 1920×1080 @1x，也是计划 §10.1 的性能基准；除 @2x 外，所有真机验收都只在这里跑。
mini 没有 HiDPI 模式。VIEW-02 有三个入口：mini 按 `1`、MacBook 按 `1`、从 2× 拖到 1×；账簿里涉及
2× 的行（P0-03、27 页）从 mini 使用待配置的
`ssh macbook`，把命令送进 MacBook 自己桌面启动的 tmux 会话。签名构建和启动也必须在那个会话里执行，
因为普通 SSH 会话读不到登录钥匙串并报 `errSecInternalComponent`。SSH 路径未配置前，@2x 一律记
NOT VERIFIED。mini 上由具备桌面与构建权限的独立验收会话执行；重任务按仓库规程使用
`scripts/heavy-lock.sh`。

## 4. 逐步操作

### ① 找出要验的行和每个入口

在账簿里按工作包 ID 找行，例如 P0-03 → `VIEW-02`、`VIEW-03`。逐行读「怎么确认」，**把每个入口拆出来**：

> VIEW-03：触控板捏合**或**按 +/−，光标下的那个像素始终停在光标下
> → 两个入口：`+/−`、`触控板捏合`。两个都要验；只验一个，这一行最多 `Partial`。

再打开 `.agents/skills/macos-device-test/features/` 里对应的运行步骤（例如 `canvas-pixels.md`）。
**没有步骤的行先写步骤**，按 `features/README.md` 的格式：子功能、入口、操作与结果、陷阱。

### ② 写 brief

brief 是给验收会话的任务单，放在 `~/.picsee/device-briefs/brief-<日期>-<ID>.md`（不进仓库）。至少写这些：

```markdown
# Brief 2026-11-05 VIEW-02-03

- 代码：分支 p0-03-canvas，HEAD <完整 SHA>，worktree <路径>
- 机器：本机 Mac mini，1920×1080 @1x
- @2x 机器：MacBook Pro；SSH：尚未配置
- 要验的行与入口：
  - VIEW-02：按 1（mini @1x，补充证据）；按 1（MacBook @2x）—— SSH 未配置，预期 NOT VERIFIED；
    窗口从 @2x 拖到 @1x —— 当前没有同时具备两种倍率的机器，预期 NOT VERIFIED
  - VIEW-03：+/−；触控板捏合（用户步骤）
- 运行步骤：features/canvas-pixels.md
- 沙盒容器：保持现状
- 需要用户动手的步骤：VIEW-03 触控板捏合 —— 到这一步停下来叫我
- 报告写到：~/.picsee/device-runs/<run-id>/report.md
```

需要冷启动状态时，在 brief 里写明涉及的存储文件、备份和恢复步骤，并记录这次运行获得的用户同意；
验收会话不能自行删除容器。

### ③ 开新会话跑 macos-device-test

在本机开一个**独立验收会话**，不要用写这段代码的会话：实现者不能给自己出验收记录。
先运行 `.agents/skills/picsee-delegator/scripts/gui-lock.sh status`；开始操作界面前获取共享 GUI 锁，
被占用时不要驱动桌面，也不要触碰 mdpro 的会话。然后调用技能：

```text
$macos-device-test 读 ~/.picsee/device-briefs/brief-2026-11-05-VIEW-02-03.md，按里面写的执行，报告写到 brief 指定的位置。brief 说需要我动手的时候停下来叫我。
```

Claude Code 使用同一份 brief，调用 `/macos-device-test`。

会话会按技能顺序做：选机器 → 检查没有别的 Picsee 在跑 → 用锁定的 Xcode 构建并检查签名团队 →
`open -n -W` 启动（`-W` 让脚本及时发现 App 退出），按 bundle 内可执行路径及晚于启动时间的出生时间识别唯一新 PID 并记录 → doctor 自检（每一行都要通过）→ 若工具要求授权，仅申请 brief 需要的 App →
按运行步骤操作 → 存日志和截图 → 按 PID 清理、释放 GUI 锁并确认证据还在。

若 brief 含 @2x，mini 上的会话改用 `ssh macbook` 把命令送进 MacBook 桌面启动的 tmux 会话；不能在普通
SSH shell 里签名或启动。该路径未配置时不要换验收标准，直接把 @2x 项记为 NOT VERIFIED。

你需要做的：

- 弹出 computer use 权限申请时，核对 App 列表后允许；
- 会话停下来叫你时（例如触控板捏合、按物理 Esc），照做后告诉它继续；
- 运行期间别动鼠标键盘，别切到别的 App。

截图和日志都在 `~/.picsee/device-runs/<run-id>/`，**永远不进仓库**（仓库是公开的）。

### ④ 读结论表，写验证记录

报告里的结论表一行对应“一行账簿 × 一个入口”：

| # | 账簿行 | 验收 | 入口 | 结果 |
|---|---|---|---|---|
| 1 | VIEW-02 | 1:1 时棋盘格清晰 | 按 1（mini @1x，补充证据） | pass |
| 2 | VIEW-02 | 同上 | 按 1（MacBook @2x） | **NOT VERIFIED** — SSH/tmux 路径尚未配置 |
| 3 | VIEW-02 | 拖到 @1x 后仍是 1:1 | 窗口从 @2x 拖到 @1x | **NOT VERIFIED** — 没有同时具备两种倍率的机器 |
| 4 | VIEW-03 | 光标下像素不动 | +/− | pass |
| 5 | VIEW-03 | 同上 | 触控板捏合 | pass（用户步骤） |

核对三点：

1. 每个入口都有自己的一行；没验的写 NOT VERIFIED 和原因，不能空着，也不能被别的入口“顺带”算通过。
2. 写着“保留/退出重开/记住”的，要有退出重开后的证据；写文件的，要有读文件本身的证据；写“释放”的，要有日志行。
3. 报告开头的 doctor 全部通过，git SHA 等于要验的 HEAD。

然后由**验收会话**把记录写进 `docs/validation/P<n>.md`（一个运行一节：日期、机器/芯片/内存/macOS、屏幕与缩放、
App 路径、git SHA 及核对方式、素材、结论表、偏差、NOT VERIFIED 原因、运行 ID），并在节里写出每个账簿行 ID——
gardener 靠这些 ID 把记录对应到行。单独提交：

```text
docs(validation): P0-03 device run VIEW-02, VIEW-03 on Mac mini @1x

Validated-by: <设备测试角色> run=20261105-143012-VIEW-02-03
```

这次提交只改 `docs/` 下的文件，不能夹带代码。最后的 `Validated-by:` trailer 必须有：gardener 靠它确认记录来自设备测试角色、
而不是实现者，缺了它，这条记录不能让任何账簿行升级。对应地，实现代码的提交带 `Implemented-by: <角色>`
（例如 `Implemented-by: gpt-imple-1`；在主对话里直接实现时写实际角色）。

### ⑤ 你更新账簿行（单独提交）

只有你（owner）升级账簿行，gardener 和验收会话都不升级。按记录决定：

| 记录里的结果 | 这一行可以记成 |
|---|---|
| 所有入口 pass，含 1× 与 2× 两种屏（显示类） | 验证 `真机`；状态可到 `Shipped`，「怎么确认」末尾链接这份记录 |
| 部分入口 NOT VERIFIED | 状态最多 `Partial`，「怎么确认」加 `限制：`写明没验的入口 |
| 有 FAIL | 不升级；回到 tdd-guardian 修 |

改完 `docs/feature-ledger.md` 后运行 `npm run ledger:build`，把生成的 `docs/feature-ledger.html` 与 Markdown
放在同一个提交里；不要手改 HTML。

两条硬规矩：

- **状态升级的那次提交，可以追加或修改「限制：」文本，但不得改写「怎么确认」中的验收本身。确需改验收时，单独提交并在提交说明里引用用户原话或 ADR。**
- **不能靠删掉「怎么确认」里的入口让它升级**，删入口也算改验收。

上面例子里 VIEW-02 的 2× 和从 @2x 拖到 @1x 两个入口都没验；mini 上按 `1` 只是补充 @1x 证据，
不能替代拖窗入口。因此 VIEW-02 记 `Partial`，限制同时写明 `@2x MacBook SSH/tmux 未验` 和
`从 @2x 拖到 @1x 未验`；VIEW-03 两个入口在 @1x 都过了，但 2× 未验，仍记 `Partial`。

### ⑥ 跑 doc gardener

gardener 不再随 PR 运行（用户 2026-11-04：「之后picsee-doc-gardener 每天跑一次，当前跑得太频繁了」）。验证记录 PR 的描述写 `Ledger-Gardener: DAILY <base7>..<head7> (covered by the daily sweep)`；合入 main 后，delegator 每天的扫描会覆盖它（规程「When it runs」）。
每日扫描时，先跑 `node scripts/ledger/garden-gate.mjs <上次扫到的 main> origin/main`，输出 RUN 才调用 gardener。在 Claude Code 用 `picsee-doc-gardener` subagent，或在 Codex 用同名 custom agent，提供这些参数：

```text
用 picsee-doc-gardener 跑 pr 模式：worktree picsee-wt/owner-gates（detached 在 origin/main），base <上次扫到的 main>，head <origin/main SHA>。
```

它读这次改动、对应到账簿行、检查证据，报告写到 `~/.picsee/gardening/<分支>-<head7>.md`，最后一行是 PR 用的结论行。

### ⑦ 按结论处理，开 PR

| 结论 | 意思 | 你做什么 |
|---|---|---|
| `CLEAN` | 没有过时的行 | 把 `Ledger-Gardener:` 行放进 PR 描述，开 PR |
| `UPDATED` | 它只做了允许的谨慎修改（路径改名、证据丢失降级、审查日期） | 看 `git diff -- docs/feature-ledger.md docs/feature-ledger.html`，确认 gardener 已运行 `npm run ledger:build`，把两者提交为 `docs(ledger): garden <base7>..<head7>`，再开 PR |
| `NEEDS-OWNER` | 有需要你决定的事：升级缺入口、缺第二次确认、可能的自我认证、该加新行 | 改它点名的行，或在 PR 描述里逐条写 `无用户可见变化：<ID> <理由>`，然后用 `--since <该 head> --verdict NEEDS-OWNER` 跑判定脚本，RUN 才重跑 |
| `BLOCK` | 有升级没有证据，或升级的同时改写了「怎么确认」中的验收本身（只追加或修改「限制：」不算） | 不开 PR：把验收改动拆成单独提交，或补齐真机记录 |

没有 `Ledger-Gardener:` 行的 PR 不进入审查。

## 5. 常见问题

**本地 mini 验和远端 MacBook 验有什么不同？**
本机就是 Mac mini：@1x、16 GiB，是唯一的本地真机测试机和性能基准，验收从独立会话运行。
任何界面操作前先查共享 GUI 锁状态，运行时获取并持有本次锁；不触碰 mdpro 的会话。MacBook 只承担 @2x：从 mini 经 `ssh macbook`
把命令送进 MacBook 桌面启动的 tmux 会话。SSH 未设置好时，@2x 记 NOT VERIFIED。记录里永远写清楚是哪台机器。

**computer use 做不到的操作怎么办？**
触控板捏合等工具不能完成的入口，在 brief 里预先标成“用户步骤”。原生 Esc 可用 `kc.sh 53`；
computer-use 的直接 Escape 路径仍未验证。
你不在的时候，这一项记 NOT VERIFIED（工具限制），不能记 FAIL，也不能记 pass。第一次真实运行查清 Esc 后，
结论写进 `features/README.md` 的「已知工具行为」。

**doctor 没通过怎么办？**
看失败的那一行：有别的 Picsee 在跑 → 退出它（不要让会话去杀你自己的 Picsee）；构建比源码旧 → 重建；
签名团队不对 → 检查 `project.yml` 的签名设置；SHA 不一致 → 你验的不是你以为的代码，重建并重启。

**验证记录能不能由写代码的会话写？**
不能。账簿要求真机记录来自设备测试角色，gardener 会把“实现者给自己出记录”报成 `NEEDS-OWNER`。
本机所有提交的 git 作者都是同一个人，所以 gardener 不看作者，而看 trailer。出现下面任何一种，它报自我认证：

- 验证记录的提交没有 `Validated-by: <角色> run=<运行 ID>`；
- `Validated-by` 的角色，同时出现在这次改动里实现提交的 `Implemented-by` 上；
- 验证记录和代码改动在同一次提交里。

trailer 只是声明，真正的保证仍是流程：验收一定在新会话里跑，运行 ID 对应 `~/.picsee/device-runs/` 里真实存在的报告。

**截图能不能放进 PR 或 issue？**
不建议。截图会暴露桌面内容，而仓库与 issue 都是公开的。PR 里放验证记录的链接和结论表即可；确实需要图时，
只用 computer use 的局部放大图，并确认画面里没有个人信息。

## 6. 相关文件

- 功能账簿规则：[`docs/feature-ledger.md`](../feature-ledger.md)「验证」「防止验收被悄悄放宽」
- 设备验收技能：`.agents/skills/macos-device-test/SKILL.md`，运行步骤在同目录 `features/`
- gardener 规程：[`docs/agents/doc-gardening.md`](../agents/doc-gardening.md)
- 开发计划与验收门槛：[`docs/PICSEE_DEVELOPMENT_PLAN.md`](../PICSEE_DEVELOPMENT_PLAN.md)
- 术语：[`GLOSSARY.md`](../../GLOSSARY.md)

## #499 首页按钮的可选原生渲染检查

`Issue499PrimaryFrameTests.issue499RealHomePrimaryFrame` 会激活真实原生窗口，因此普通
`swift test` 明确跳过它，不获取共享 GUI 锁；桌面被 picsee 或 mdpro 占用也不会导致这项测试失败。
现有 `gui-lock.sh` 只支持 acquire/release，没有随测试进程退出释放的租约，本测试选择仅借用调用者
已持有的租约，不自行获取或释放，避免 routine 测试被 kill、崩溃或挂起后留下它自己的锁。

由已持锁的调用者传入当前 picsee owner 中的 acquisition_id：

```sh
PICSEE_I499_GUI_ACQUISITION='<当前调用者的 acquisition_id>' \
  ~/.picsee/device/ram/with-ram.sh i499-render scripts/heavy-lock.sh \
  swift test --package-path Packages/PicseeKit --filter issue499RealHomePrimaryFrame
```

调用者须在测试进程结束、窗口关闭后按原规程释放自己的锁；不要传入其他运行的 token。
显式 token 无效、owner 读不到或不匹配时，测试在创建窗口前报环境错误，不退回自行获取。
测试覆盖普通、按下、键盘焦点三态及浅色→深色→浅色的自动外观传播、原生辅助功能标题和尺寸。
首页按钮仅在隐藏并拆除时禁用（`ViewerStateHost.swift`），没有可见禁用态。

默认不写 PNG。需要调试图像时，在上述调用增加 `PICSEE_I499_EVIDENCE=1`，输出写入系统临时目录
下唯一的 `i499-evidence-*` 子目录，测试日志打印实际路径；文件名标明外观与按钮状态。
这些 cacheDisplay 渲染断言不是签名真机验收记录。
