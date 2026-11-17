# 测试 lane 与 RED receipt

从 AGENTS.md 原样挪来（2026-11-15）。写 RED receipt、跑单个 Swift 或 App 测试、维护 App 隔离清单、跑 Trash 集成 lane 时读这里。重任务的锁见 [heavy-lock.md](heavy-lock.md)。

Swift RED 使用手动 lane `swift-red`，只跑指定测试。先写能编译的失败断言，再记录；`--files` 只选指纹文件，不选择测试。record 和 verify 必须传相同的过滤器（环境变量不会写入 receipt）：

```sh
# 固定使用已验收的 tdd-guardian 0.10.2；测试可用 MADO_TDD_PLUGIN_ROOT 覆盖
plugin_root="$HOME/.claude/plugins/cache/xiaolai/tdd-guardian/0.10.2"
export MADO_SWIFT_FILTER='测试函数名'
node "$plugin_root/scripts/tdd-guardian/receipt.js" record --id P0-XX-WI-1 --lane swift-red --files Packages/MadoKit/Tests/MadoCoreTests/ItemIDTests.swift
# 实现后，保留相同 MADO_SWIFT_FILTER
node "$plugin_root/scripts/tdd-guardian/receipt.js" verify --id P0-XX-WI-1
node "$plugin_root/scripts/tdd-guardian/receipt.js" show
node --test scripts/tdd/*.test.mjs
```

也可直接用 `node scripts/tdd/swift-lane.mjs itemIDSurvivesJSONRoundTrip` 跑单测。所有已启动框架均须完成根运行；编译失败、零测试、崩溃或不完整输出退出 70，不输出计数。正常断言失败退出 1；计数前打印 `swift-lane filter=<f>` 供输出 tail 审计，verify 仍须传相同过滤器。

App RED 也可只跑指定测试：`node scripts/tdd/app-lane.mjs [filter]`，或在 receipt 的 record **和** verify 前设置同一个 `MADO_APP_FILTER`。参数优先于环境变量；filter 是匹配运行时完整 ID 的正则表达式（例如 `issue512ChildReadKeepsTitleCurrentRowAndFailureDash`，多个测试用 `nameA|nameB`）。环境变量不会写入 receipt，`--files` 仍只选指纹文件。设置 `MADO_APP_LANE_NO_RETRY=1` 记录 RED；先 build-for-testing 到 `.build/dd-ci`。成功解析后、计数前打印 `app-lane filter=<f>`；零匹配或执行集合不符退出 70，不输出计数。从环境变量读取 filter 时会在 stderr 提示；完整运行前先执行 `unset MADO_APP_FILTER`。未传 filter 时先跑保留的 MadoAppTests bundle（应用隔离清单），再用 `xcodebuild test-without-building` 跑 MadoHostedFocusTests 组；合并结果，环境错误退出 70、测试失败退出 1、成功退出 0。`MADO_APP_DERIVED_DATA_PATH` 可覆盖默认的 `.build/dd-ci`。过滤后的保留组精确 ID 通过 `xcrun xctest -XCTest` 传入，Swift Testing 路径已有真实 bundle 运行证据；XCTest 过滤路径仅有 Node 假进程覆盖（真实 App bundle 没有 XCTestCase）。过滤选择中的每个测试必须通过或失败；任何跳过均退出 70，不输出计数。隔离清单中的保留组测试始终排除。

App lane：`node scripts/tdd/app-lane.mjs` 读取 `scripts/tdd/app-quarantine.json`（默认 `[]`）。隔离时添加 `{"id":"MadoAppTests.someTest()","issue":411,"reason":"具体原因","owner":"负责人","expires":"2026-11-22"}`；每条必须有正整数 issue、非空 reason 和 owner，以及真实的 YYYY-MM-DD 格式 expires。expires 按本次隔离期限填写，在该 UTC 日期当天仍有效；早于当前 UTC 日期时，lane 退出 70。修复后删除对应条目。XCTest 标识用 `Class/method`，Swift Testing 用运行时列举的模块限定形式 `Module.func()` 或 `Module.Suite/method()`。实测 `XCTestInvertScope` 不会排除目标；非空清单因此先从编译 bundle 枚举两类测试，再由原来的 `xcrun xctest -XCTest` 只运行剩余标识，并逐项核对执行集合。hosted 测试 ID 不能隔离；只选 hosted 组且隔离清单非空时退出 70。未指定 filter 时，非空清单必须保留至少一个 Swift Testing 测试，否则以明确的不支持提示退出 70。选定运行的完整一致输出中，测试失败退出 1；环境失败或输出不完整、不一致退出 70。清单无效、枚举失败、标识不支持或有歧义均退出 70；已不存在的标识先警告再退出 70。CI 会逐条打印标识与 issue；未指定 filter 且清单为空时，保留组保持原运行参数和解析规则。
本地在 `~/Documents` 下的 worktree 运行时，`.build/dd-ci` 中的 Mado.app 可能触发文件夹访问授权提示；即使把 DerivedData 放到 Documents 外，也可能拿不到目标 key window。这类本地失败不能当作 hosted CI 的测试结论。
升级 Xcode 后，重跑混合 XCTest + Swift Testing probe，确认枚举 ABI 与控制台标签仍兼容。

新 API 按此流程先写可编译桩，桩在 record 时是未提交的实现改动，Swift receipt 总会带 `implementation-already-present` MEDIUM；审计仍须核对桩与 RED。断言消息含 “No such file or directory” 时，插件会把失败升级为环境失败并拒收有效 RED。

Trash 集成 lane（#672）：真实 `FileManager.trashItem` 测试只在 `#if MADO_TRASH_INTEGRATION` 内编译，默认包 lane 不运行，名单在 `scripts/tdd/trash-integration.json`。`node scripts/tdd/trash-lane.mjs` 自行取锁：先单独编译（`.build/trash-integration`），再在一次锁内逐个场景运行，每个场景 120 秒，随后 TERM、10 秒、KILL、5 秒；整条命令预算 10 分钟（不含编译）。首个超时或存活进程即停止，不重试；缺前置条件（Swift、`~/.Trash`）或场景被跳过时退出 70 且不输出计数。`node scripts/tdd/trash-lane.mjs --discover` 双向证明默认 lane 不含这些场景、集成 lane 恰好多出它们。不要用外层 `scripts/heavy-lock.sh` 包它。
