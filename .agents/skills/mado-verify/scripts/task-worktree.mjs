// #901 (owner 2026-11-25): one task, one worktree. Shared rules for mark-target.mjs and evidence.mjs check.
// Stub: signatures only (Stub-For: i901-WI-1, i901-WI-2).
export const MARKER = '.build/mado-verify/target-worktree';
export const IDENTITY = '.build/mado-verify/task-identity.json';
export function paneHomeReason(_dir) { throw new Error('not implemented: paneHomeReason (#901)'); }
export function checkTaskWorktree(_options) { throw new Error('not implemented: checkTaskWorktree (#901)'); }
