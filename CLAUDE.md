@AGENTS.md

## Claude Code 补充

- doc gardener 每天在 main 上统一跑一次（用户 2026-11-04），打开或推送 PR 时不运行。每日扫描用 `Agent` 调用 `picsee-doc-gardener`（`.claude/agents/picsee-doc-gardener.md`），模式 `pr`、range `<上次扫到的 main>..origin/main`。按 AGENTS.md「doc gardener 每天跑一次」处理结果。
- 实现工作走 `/tdd-guardian:workflow`。`.claude/tdd-guardian/config.json` 还不存在，P0-01 建好工程后由用户运行 `/tdd-guardian:init`。P0-01 本身是唯一的 bootstrap 例外（先写失败测试、红/绿输出进 PR、无 receipt，见开发计划 P0-01）；除 P0-01 外，init 之前不做代码实现。
