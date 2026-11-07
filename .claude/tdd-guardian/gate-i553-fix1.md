# Fix1 gates

The fix brief requires all Node suites in the full worktree and an actual depth-one clone, ledger HTML synchronization, design checks, whitespace and an explicit one-shot preservation report. Final statuses and immutable range/clone HEAD are in the external handoff/logs after this commit.

Before commit: targeted 30 tests PASS; all Node suites 1,168 tests / 1,166 pass / 0 fail / 2 optional real-mdpro interop skips (PICSEE_MDPRO_SCRIPT unset). Receipt i553-fix1-WI-1 recorded assertion RED (5/15 failing) before implementation and verified SEPARATION-HELD.

No Swift source, native metadata, ledger/ADR/validation file, bundle or manifest changes in fix1. Per the explicit fix brief's conditional native gate, Swift unit/coverage was not rerun. No new native or Node coverage percentage is claimed. Mutation remains disabled. Native unit/coverage config and thresholds are unchanged.

Historical preservation checks moved out of the permanent suite into explicit check-living-docs-range.mjs --base <commit> --head <commit>. Tests operate on synthetic Git trees and the lasting scanner permits future sanctioned history/acceptance edits. No missing-base skip or default fixed baseline exists.

Evidence directory: ~/.picsee/herdr/gpt-imple-2/i553-fix1-logs/. See the handoff for post-commit depth-one/full suite outputs, one-shot range counts, final replay and release-template hash comparison.
