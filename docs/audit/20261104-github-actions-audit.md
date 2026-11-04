# GitHub Actions 耗时审计（截至 2026-11-04）

## 1. 结论摘要

- 统计范围：anzchy/picsee 最近 100 个 workflow run（2026-11-03 05:36 至 2026-11-04 03:53 UTC，run [41584895280](https://github.com/anzchy/picsee/actions/runs/41584895280) 至 [41769817523](https://github.com/anzchy/picsee/actions/runs/41769817523)），共 CI 60 个、PR body 40 个。计时只用成功的 job。
- 一次 PR 推送的 CI 墙钟时间中位数 **8.0 分钟**（p90 10.9），计费 macOS 分钟中位 **22.5**（p90 25），用 4 个 macOS job。main 推送 8.2 分钟（p90 10.6），macOS 21 分钟。PR body workflow 只要 0.4 分钟。
- **慢在编译，不在测试，也不在环境准备。** 环境准备（checkout、选 Xcode、下载预编译的 XcodeGen、generate）每个 job 只要几秒。两个 Swift 包测试 job 每次都从零编译同一份 `.build`，各花 259–295 s，测试本身只跑 92 s（non-UI）和 137 s（MacUI）。仓库里没有任何缓存。
- Build unsigned app 做的事基本被 App tests 的 `build-for-testing` 包含，还多占一个 macOS 名额。账户最多同时跑 5 个 macOS job（和 mdpro 共用）：233 个 macOS job 里有 28 个排队超过 60 s，最长 353 s。这 28 个里有 23 个，在它们创建时已经有 3–5 个 macOS job 在跑。
- 本地两次构建（§5）：增量构建配置正确，第二次 `xcodebuild build` 只要 1.3 s，XcodeGen 输出稳定。但新 checkout 会把所有文件的 mtime 改掉，这时即使有缓存，SwiftPM 也要重编 277 个文件。加上 `-enable-incremental-file-hashing` 后，同样的情形 0 个文件重编，只要 7.8 s。也就是说，缓存只有配合文件哈希才有用。
- 建议（§6）：C1 缓存 SwiftPM `.build` 并开启文件哈希；C2 把 unsigned build 并进 App tests job，ledger 检查移到 ubuntu；C3 只改文档、agent 文件的 PR 跳过 macOS job，必需检查照常报告；C4 修复 main 推送的 concurrency 漏洞。预计代码 PR 从 8 分钟降到约 4–4.5 分钟、macOS 分钟从 22.5 降到约 10–11；约 23% 的纯文档 PR 降到 1 分钟以内、不用 macOS。
- 不删、不弱化任何测试或检查（§7）。

## 2. 方法与覆盖

数据全部来自 `gh` CLI，只读，没有修改任何设置：

1. `gh run list --limit 100 --json databaseId,workflowName,event,headBranch,status,conclusion,createdAt,updatedAt,headSha` 列出 run；对每个 run 调 `gh api repos/anzchy/picsee/actions/runs/<id>/jobs`。
2. 每个 job 拆成三段：排队（`created_at`→`started_at`）、准备（Set up job、各 checkout、Record job start、Set up Xcode、Set up Node、npm ci、Playwright 安装）、运行（其余步骤，不含 Post/Complete job）。按 workflow/job 取中位数和 p90。
3. 墙钟时间：从 run 的 `createdAt` 到最后一个 job 结束，只统计所有 job 都成功的 run。macOS 计费分钟：每个 macOS job 的运行时间向上取整到分钟后求和。
4. 编译和测试的分界：下载 main run [41761253694](https://github.com/anzchy/picsee/actions/runs/41761253694) 各 job 日志，读 `Build complete!`、`Test run with … passed`、`** TEST BUILD SUCCEEDED **` 的时间戳。
5. 必需检查：`gh api repos/anzchy/picsee/branches/main/protection`（可读）；`gh api repos/anzchy/picsee/rulesets` 返回空。
6. 纯文档 PR 的比例：`gh pr list --state all --limit 100 --json number,files`，按 §6 C3 的白名单判定。
7. 本地两次构建在 origin/main f4b028e4 的一个全新的 detached worktree 里做，Xcode 26.6（17F113），所有重任务都走 `scripts/heavy-lock.sh`，一次只跑一个，等锁时间不计入。

## 3. 基线

单位分钟，中位 / p90。

| Workflow | Job | Runner | n | 排队 | 准备 | 运行 | Job 合计 |
|---|---|---|---|---|---|---|---|
| CI | Package tests (MacUI) | macos-26 | 58 | 0.1 / 1.7 | 0.1 / 0.1 | 6.8 / 7.9 | **7.1 / 9.1** |
| CI | Package tests (non-UI) | macos-26 | 58 | 0.1 / 2.0 | 0.1 / 0.1 | 6.6 / 7.4 | 6.9 / 8.9 |
| CI | App tests | macos-26 | 55 | 0.1 / 1.1 | 0.1 / 0.1 | 4.6 / 5.8 | 5.0 / 6.3 |
| CI | Build unsigned app | macos-26 | 59 | 0.1 / 0.8 | 0.1 / 0.1 | 1.6 / 2.1 | 1.9 / 3.2 |
| CI | Design check | ubuntu-latest | 58 | 0.1 / 0.1 | 0.5 / 0.7 | 0.4 / 0.6 | 1.0 / 1.3 |
| CI | Walking skeleton | ubuntu-latest | 58 | 0.1 / 0.1 | 0 / 0 | 0 / 0 | 0.1 / 0.1 |
| PR body | Agent tooling | ubuntu-latest | 34 | 0.1 / 0.1 | 0.1 / 0.1 | 0.2 / 0.3 | 0.4 / 0.8 |
| PR body | PR body Gates | ubuntu-latest | 34 | 0.1 / 0.1 | 0.1 / 0.5 | 0.0 / 0.0 | 0.2 / 0.6 |

| 事件 | 墙钟 中位 / p90 | macOS 计费分钟 中位 / p90 |
|---|---|---|
| CI · pull_request（n=28） | 8.0 / 10.9 | 22.5 / 25.0 |
| CI · push main（n=25） | 8.2 / 10.6 | 21 / 23.6 |
| PR body · pull_request（n=32） | 0.4 / 0.8 | 0 |

### 运行段里的编译和测试（run 41761253694）

| Job | 编译 | 测试 | 其他 |
|---|---|---|---|
| Package tests (non-UI) | `Build complete! (258.63s)` | 91.8 s，1040 个测试 | watchdog 脚本测试 19 s；manifest/解析约 18 s |
| Package tests (MacUI) | `Build complete! (294.65s)` | 136.8 s，593 个测试，串行 | manifest/解析约 22 s |
| App tests | build-for-testing 中位 140 s（含约 23 s 克隆、解析 Sparkle） | app-lane 中位 131 s | |
| Build unsigned app | 中位 95 s（含约 23 s 克隆、解析 Sparkle） | – | ledger HTML 检查 1 s |

关键路径是 MacUI job，其中约三分之二是编译。

### 必需检查

branch protection（main）：`Walking skeleton`、`PR body Gates`、`Agent tooling`，`strict: false`，没有 ruleset。**App tests 和 Design check 不是必需检查。** Walking skeleton 要求 package-tests、package-macui-tests、unsigned-build 三个 job 都是 `success`（`ci.yml:100-113`）。

## 4. 发现

以下行号以 origin/main f4b028e4 为准。

| # | 发现 | 证据 |
|---|---|---|
| F1 | **main 推送有可能丢 CI run。** 所有 main 推送共用一个 concurrency 组，又不取消：GitHub 在组里只留一个运行中、一个等待中的 run，第三个到来时会取消先前那个等待中的。8 分钟内合并三个 PR，中间那个 main 提交就没有 CI。目前还没发生（最近 100 个合并 PR 的 head 都有 push run），但违反了「每个 main 提交都要完整跑一次」。PR 的取消行为是对的。 | `.github/workflows/ci.yml:18-20` |
| F2 | 两个包测试 job 编译同一份 `.build`（`--skip` 只在运行时生效），都从零开始，也没有缓存。 | `ci.yml:29-84`；run 41761253694 两份 `Build complete!` |
| F3 | unsigned build 和 App tests 的构建重复。scheme `Picsee` 的 build 动作是 `PicseeApp: all`，所以 `build-for-testing` 也会编 PicseeApp（日志里的 target 图有 PicseeApp），Sparkle 每次 run 要克隆两遍。unsigned-build 剩下的唯一一步是 1 s 的 ledger HTML 检查，纯 node。 | `ci.yml:86-98`、`ci.yml:115-126`；`project.yml` schemes |
| F4 | macOS 排队来自账户 5 个并发的上限。每个 CI run 占 4 个 macOS job，两个 run 重叠（合并到 main 加下一个 PR 推送）就必然排队。 | 排队最长：[41620182081](https://github.com/anzchy/picsee/actions/runs/41620182081)（353 s、335 s、281 s）、[41708491565](https://github.com/anzchy/picsee/actions/runs/41708491565)（346 s）、[41605474412](https://github.com/anzchy/picsee/actions/runs/41605474412)（253 s）、[41598730445](https://github.com/anzchy/picsee/actions/runs/41598730445)（246 s） |
| F5 | 没有路径过滤。最近 100 个 PR 里有 23 个只改了文档、agent 或工具路径（如 #469、#467、#440、#439、#435、#433、#421、#420、#419、#409、#380、#357、#356、#326），每个照样花约 22 macOS 分钟。 | `ci.yml:2-7` |
| F6 | 原生测试会读源码以外的仓库文件，这些都算原生输入：`design/**`（PinnedDesign、DesignRegistry/DesignColor 测试）、`scripts/perf/fixtures/**`、`TestAssets/**`、`App/Resources/**`、`project.yml`，以及 **`THIRD_PARTY_NOTICES.md`**（AppTests `Issue220*`）。现有的输入超集 `codeInputs` **漏了 `THIRD_PARTY_NOTICES.md`**。这个缺口和本次提速无关，但会让 Gates 的「输入未变」判断出错。 | `scripts/agents/ui-parity-pr-body-lint.mjs:45-47`；`AppTests/Issue220*.swift` |
| F7 | watchdog 脚本测试在 macOS 上跑，**必须留在 macOS**：真实挂起的测试离开 darwin 会跳过（需要 `ps`/`sample`）。这一步不在关键路径上。 | `ci.yml:38-39`；`scripts/ci/test-watchdog.test.mjs:14-16` |
| F8 | Design check：setup-node 没开 `cache: npm`，每次重新下载 Playwright Chromium（中位 18 s）。在 ubuntu 上跑，不是必需检查，也不在关键路径上。 | `ci.yml:150-157` |
| F9 | 准备阶段已经很精简：XcodeGen 是带 sha256 校验的预编译 zip，没有 brew、mint、go install、cargo install。除了汇总用的 Walking skeleton，没有被 `needs` 串起来的 job。 | `.github/actions/xcode-setup/action.yml:15-24` |
| F10 | pr-body.yml 没有问题：跑在 ubuntu 上，按 PR 分 concurrency 组并取消旧 run，耗时 0.4 分钟。两个 checkout 用 `fetch-depth: 0` 是有意的（merge-base 和祖先判断要用）。 | `pr-body.yml:9-11`、`pr-body.yml:19-50` |
| F11 | 有几个仓库脚本解析 ci.yml 的结构或 job 名，改 workflow 时要一起改：`flaky-gate.test.mjs` 按步骤名找 "Run App tests" 和 "Upload first App attempt"；`gates-rows.mjs` 按 job 名找 "App tests"，并把 unsigned-build 映射到 xcodebuild。 | `scripts/ci/flaky-gate.test.mjs:205-219`；`scripts/agents/gates-rows.mjs:7`、`:93-109` |

## 5. 本地两次构建

全新的 detached worktree（origin/main f4b028e4），Xcode 26.6（17F113），所有重任务走 heavy-lock，一次只跑一个。

| 步骤 | 耗时 | 说明 |
|---|---|---|
| `xcodebuild build` 冷构建 | 约 25 s（Xcode 日志 16.7 s） | 258 个编译任务 |
| 第二次 `xcodebuild build` | **1.3 s** | 只重跑了 `Stamp build Git SHA`（有意设为 `basedOnDependencyAnalysis: false`）、ProcessInfoPlistFile、Validate |
| 再次 `xcodegen generate`，然后构建 | 约 1 s，`project.pbxproj` 哈希不变 | XcodeGen 输出稳定，不会因重新生成而让构建失效 |
| `build` 之后跑 `build-for-testing` | 19.6 s | 测试版本要重编 4 个 PicseeKit target，加 87 个 PicseeAppTests 文件；PicseeApp 不重编 |
| `swift build --build-tests` 冷构建 | 63.8 s（`Build complete! (48.51s)`） | |
| 再跑一次 | 0.5 s | |
| touch Packages 下所有受跟踪文件（等同于新 checkout 后的 mtime），再构建 | 53.6 s（构建 34.9 s），重编 277 个文件 | **只缓存 `.build` 几乎没用** |
| 同上，加 `-Xswiftc -enable-incremental-file-hashing` | **7.8 s，重编 0 个** | mtime 变了时，driver 改为比较内容哈希 |
| touch App/AppTests/Packages/project.yml，跑 `build-for-testing` | 30.7 s，重编 323 个 | |
| 同上，加 `OTHER_SWIFT_FLAGS='$(inherited) -enable-incremental-file-hashing'` | **7.6 s，重编 0 个** | |
| 体积 | PicseeKit `.build` 591 MB；DerivedData 505 MB（含 Sparkle checkout） | |

结论：增量构建本身配置正确，没有每次都重跑的昂贵阶段，XcodeGen 也不会重复生成。CI 每次全量编译只有两个原因：没有缓存，checkout 又改了 mtime。CI 冷编译比本机慢约 5.5 倍（259 s 对 48.5 s），按这个比例，CI 上一次带哈希的热构建预计约 40–60 s。

## 6. 建议（按优先级）

下面的数字是按上面的比例估算的，每项改动合并后要用之后 5 个 run 核实。

### C1 SwiftPM `.build` 缓存加文件哈希（收益最大）

- 两个包测试 job 的 `swift test` 都加 `-Xswiftc -enable-incremental-file-hashing`。两个 job 的编译参数相同，产出的 `.build` 一致。
- `pull_request` 和 `workflow_dispatch` 用 `actions/cache/restore`（固定 SHA）恢复 `Packages/PicseeKit/.build`。key：runner OS + Xcode build 号 + `Package.swift` 哈希 + 包源码与资源的哈希；restore-keys 退到 `Package.swift` 哈希这一级。
- **只在 push main 时**由 non-UI job 调 `actions/cache/save`，且只在 key 没命中时保存。main 推送不恢复缓存、冷构建，保证 main 始终是一次干净的完整构建。
- 预计收益：PR 上每个包测试 job 少 3–4 分钟。MacUI 从 7.1 降到约 3.5–4 分钟，non-UI 从 6.9 降到约 2.5–3 分钟。
- 缓存预算：每条约 600 MB（压缩后约 200–300 MB），每个改了源码的 main 提交存一条，靠 LRU 淘汰保持在 10 GB 以内。PR 不存缓存。
- 风险：增量产物过期。缓解：main 始终冷构建；key 包含 Xcode build 号和 manifest 哈希；给 `workflow_dispatch` 加 `cold` 输入用来跳过恢复。测试内容一个不变。

### C2 unsigned build 并进 App tests job，ledger 检查移到 ubuntu

- App tests job 的步骤依次是：`xcodebuild build …`（命令与现在完全相同，步骤名 "Build unsigned app"）→ `build-for-testing` → app-lane。job 输出 `unsigned_build=<build 步骤的 outcome>`。
- Walking skeleton 改为 `needs: [package-tests, package-macui-tests, app-tests, node-checks]`，检查的是 `needs.app-tests.outputs.unsigned_build == 'success'`，**不看 App tests job 的结论**。这样 App tests 和现在一样不是必需检查；要不要把它设为必需由 owner 决定（参考 #379 的 flaky 历史）。
- App tests 的 `if:` 从 job 级移到测试步骤上，这样 `workflow_dispatch app_tests=false` 时仍然会构建。
- 新增 ubuntu job `node-checks` 跑 `node scripts/ledger/build.mjs --check`，通过 Walking skeleton 成为必需检查。它在 push main 时也会跑，Agent tooling 不会。
- 给这个 job 加 DerivedData 缓存，同样只在 main 保存、PR 恢复，并加 `OTHER_SWIFT_FLAGS='$(inherited) -enable-incremental-file-hashing'`；把 `-clonedSourcePackagesDirPath` 指到缓存目录里，可以省掉约 23 s 的 Sparkle 克隆。
- 预计收益：每个 run 少占一个 macOS 名额（4 个降到 3 个），两个 run 重叠时只排队 1 个 job 而不是 3 个；少约 2–3 macOS 计费分钟和一次 Sparkle 克隆。不加 DerivedData 缓存的话，App job 会涨到约 6–6.5 分钟（`build-for-testing` 要按测试版本重编 PicseeKit）；加了缓存约 3–3.5 分钟。
- 同一个 PR 里要一起改：`scripts/agents/gates-rows.mjs`、`ui-parity-pr-body-lint.mjs` 的 `gateInputs`，并保持 `flaky-gate.test.mjs` 依赖的步骤名不变（F11）。

### C3 只改文档、agent 文件的 PR 跳过 macOS job，必需检查照常报告

- 新增 ubuntu job `changes`，只在 pull_request 上判断；push 和 dispatch 一律 `native=true`。它用 `gh api repos/<repo>/pulls/<n>/files --paginate` 列出改动文件（不用 checkout，权限 `pull-requests: read`）。**只有所有路径**都落在下面这个窄白名单里，才设 `native=false`：
  `docs/**`、`.agents/**`、`.claude/**`、`.codex/**`、`AGENTS.md`、`CLAUDE.md`、`README.md`、`CHANGELOG.md`、`GLOSSARY.md`、`scripts/agents/**`、`scripts/codex-rules/**`、`scripts/ledger/**`、`.github/ISSUE_TEMPLATE/**`、`.github/workflows/pr-body.yml`、`.github/workflows/release.yml`。
- 出问题一律当作原生改动：API 出错、文件数达到 3000、重命名（`previous_filename` 也要检查）。不能用根目录 `*.md` 通配，因为 `THIRD_PARTY_NOTICES.md` 是原生输入（F6）。
- macOS job 加 `needs: changes` 和 `if: needs.changes.outputs.native == 'true'`。Walking skeleton 保留 `if: always()`，通过条件是：`changes` 成功，并且要么 native=true 且原生 job 全部 success，要么 native=false 且这些 job 是 `skipped`；node-checks 始终必需。这样必需检查每次都会报告结果，不用 workflow 级的 `paths-ignore`（那会让被跳过的必需检查一直 pending，挡住合并）。
- 在检测脚本旁边加 node 测试：断言白名单与 `codeInputs` 不相交，并且 `App/ AppTests/ UITests/ Packages/` 下没有文件引用白名单里的路径。
- `gates-rows.mjs` 遇到被跳过的 App tests，要写成 `N/A … no native inputs changed`，不能写成 `app_tests=false`。
- 预计收益：约 23% 的 PR 从约 8 分钟、22 macOS 分钟降到约 0.5–1 分钟、0 macOS 分钟，还给其他 run 让出 4 个 macOS 名额。代价：代码 PR 的 macOS job 要晚约 10–15 s 才开始。
- main 推送照样全跑，所以就算误判，也会在 main 上、在任何发布之前被发现。

### C4 main 推送的 concurrency（安全修复，不影响耗时）

- 把 `ci.yml:18-20` 改为 `group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}`，`cancel-in-progress` 仍然只在 pull_request 上为 true。这样每次 main 推送和每次 dispatch 都在自己的组里，既不会被取消，也不会在等待时被顶替。

### C5 ubuntu 上的小项（收益低，可选）

- Design check：setup-node 加 `cache: npm`；按 playwright 版本缓存 `~/.cache/ms-playwright`，apt 依赖仍用 `npx playwright install-deps chromium` 安装。省约 10–15 s，不在关键路径上。

### 预期前后对比（每次 PR 推送，中位数）

| | 现在 | C1+C2+C4 之后 | C3 之后的纯文档 PR |
|---|---|---|---|
| 墙钟 | 8.0 分钟（p90 10.9） | 约 4–4.5 分钟 | 约 0.5–1 分钟 |
| 每个 run 的 macOS job | 4 | 3 | 0 |
| macOS 计费分钟 | 22.5 | 约 10–11 | 0 |
| main 推送 | 8.2 分钟 | 约 8 分钟（有意冷构建），3 个 macOS job | 不变（全跑） |

上线顺序：先 C4 + C2（一个 PR，结构调整），再 C1 + DerivedData 缓存（要等一次 main 推送存好缓存，然后量 5 个 run），最后 C3（连同它的测试）。ci.yml 和 pr-body.yml 都是 `pull_request` 触发、用 PR head 的版本，所以每个 PR 自己的 CI run 就是证据。

### 合并后才生效的部分

- `PR body Gates` 跑的是 **base** 上的 `scripts/agents/ui-parity-pr-body-lint.mjs`（`pr-body.yml:39-65`），所以对 `gateInputs`/`codeInputs` 的修改（包括补上 `THIRD_PARTY_NOTICES.md`）只对合并之后开的 PR 生效。
- C1/C2 的缓存：要等合并后第一次 main 推送存好缓存，之后的 PR 才用得上。
- 三个必需检查的名字都不改，不需要动 branch protection。

## 7. 不改的部分和原因

- 不删、不弱化任何测试或检查：四个 Swift 测试 target、App lane（包括它唯一一次经过授权的 flaky 重试）、unsigned `xcodebuild build`、ledger HTML 检查、watchdog 脚本测试、design check、Agent tooling、PR body Gates 全部保留。
- MacUI 仍然单进程 `--no-parallel` 运行（#391），也不在同一台机器上同时跑 non-UI 和 MacUI。
- watchdog 脚本测试留在 macOS（F7）。
- MacUI 不分片：测试只要 137 s，多一个分片就要多一次约 1 分钟的构建，还要再占一个 macOS 名额。
- main 推送始终冷构建、全部检查都跑，不做路径跳过。
- pr-body.yml 的可信 base checkout、`fetch-depth: 0`、各 job 的超时和 test-watchdog 的截止时间都不变。
- 不改 branch protection、ruleset 或任何仓库设置。App tests 和 Design check 是否设为必需由 owner 决定。
- `release.yml` 只由 tag 触发，不在这次范围内，不动。

## 8. 附带发现：`codeInputs` 漏了 `THIRD_PARTY_NOTICES.md`（与提速无关）

- `scripts/agents/ui-parity-pr-body-lint.mjs:45-47` 的 `codeInputs` 是 package-tests、package-macui-tests、app-tests、unsigned-build、walking-skeleton 这几个 lane 的「输入超集」，PR body Gates 用它判断：一个较早 SHA 上的 PASS 对当前 head 是否仍然有效。
- AppTests 的 `Issue220*` 测试通过 `repository.appendingPathComponent("THIRD_PARTY_NOTICES.md")` 读取这个根目录文件，但它不在 `codeInputs` 里。只改 `THIRD_PARTY_NOTICES.md` 的提交会被当作「输入没变」，旧 SHA 上的 App tests PASS 会被接受，而实际上这次改动可能让 App tests 失败。
- 建议：单独开一个修复，把 `THIRD_PARTY_NOTICES.md` 加进 `codeInputs`，并加一条测试，扫描 `App/ AppTests/ UITests/ Packages/` 里出现的仓库相对路径，断言每个都被 `codeInputs` 覆盖。PR body Gates 用的是 base 上的 lint，所以这个修复合并后才生效。§6 C3 的跳过白名单同样不能包含这个文件。

## 9. 审查

- gpt-auditor 审查了 §6 的计划，结论 **APPROVE WITH CHANGES**（4 条：0 高、2 中、2 低）。C4 照原样通过，C5 作为可选项通过；C1、C2、C3 带修改通过。
- 中 1（C1/C2）：缓存 key 要写清楚并且完整：OS/架构、Xcode build（17F113）和 Swift toolchain、缓存格式版本、`Package.swift`、`Package.resolved`（如有）、全部源码和资源输入；只有证明 SwiftPM/xcodebuild 会重建改动、新增、删除的输入时，才允许按前缀回退；并且要在 CI 上证明增量失效是对的（PR 里推一个改 Swift 源码的提交，日志里能看到这个文件被重编、测试跑在它上面）。
- 中 2（C3）：纯文档判定必须在 API 出错、文件列表为空或只解析了一部分、分页出问题、触到 GitHub 上限时一律判为原生；解析出的文件数要和事件的 `changed_files` 比对，不一致就全跑。
- 低：提速数字是估算，要用之后 5 个 run（含一次冷构建的 main run）核实，并盯住 10 GB 缓存预算；§8 的 `codeInputs` 缺口另行修复（#474），这次不改 `ui-parity-pr-body-lint.mjs`。
- 实现时比计划多做的一点：`Native inputs` job 从 base 提交 checkout 判定脚本再运行，PR 改不了评判自己的规则；base 里还没有这个脚本时（也就是引入它的那个 PR）一律判为原生。ledger 检查的 job 名是 `Ledger HTML check`。
