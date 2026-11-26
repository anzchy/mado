// #901 (owner 2026-11-25): 「每个任务单独的worktree(对于implementor来说）」. One task, one worktree: every task runs in
// its own ~/Documents/mac-app/picsee-wt/<issue>-<slug>; a pane home (picsee-wt/<pane-name>) only holds the pane's
// identity and its dispatch marker. Shared by mark-target.mjs (dispatch) and evidence.mjs check (before audit/merge).
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const MARKER = '.build/mado-verify/target-worktree';
export const IDENTITY = '.build/mado-verify/task-identity.json';
// Pane names of the roster (gpt-imple-1, opus-imple-2, gpt-auditor, kimi-researcher, gpt-planner, resource-broker…).
export const PANE_NAME = /^[a-z][a-z0-9]*-(?:imple|implementor|implementer|auditor|planner|researcher|delegator|broker)(?:-[0-9]+)?$/;
export const taskName = issue => new RegExp(`^${Number(issue)}-[A-Za-z0-9][A-Za-z0-9._-]*$`);
export const HOW = issue => `create one with .agents/skills/mado-delegator/scripts/new-task-worktree.sh ${issue} <slug> (see the delegator SKILL, step 2)`;

// Why `dir` is a pane home, or null. A pane home is named after its pane, or holds a dispatch marker (only
// mark-target.mjs writes one, and only into a pane home).
export function paneHomeReason(dir) {
  const base = path.basename(dir);
  if (PANE_NAME.test(base)) return `${dir} is a pane home (picsee-wt/${base}); pane homes hold the pane identity only`;
  if (fs.existsSync(path.join(dir, MARKER))) return `${dir} holds a dispatch marker (${MARKER}), so it is a pane home`;
  return null;
}

function git(at, ...args) {
  const result = spawnSync('git', args, { cwd: at, encoding: 'utf8', timeout: 5000 });
  return result.status === 0 ? result.stdout.trim() : null;
}

// Checks a briefed worktree at dispatch. Returns { fixRound, identity } or throws with what to do.
// home/target are real paths of worktree roots; branch is the task branch (explicit, or the target's current branch).
export function checkTaskWorktree({ home, target, issue, branch }) {
  if (target === home) throw new Error(`${target} is the pane home; ${HOW(issue)}`);
  const pane = paneHomeReason(target);
  if (pane) throw new Error(`${pane}; ${HOW(issue)}`);
  if (!taskName(issue).test(path.basename(target)))
    throw new Error(`${target} is not a task worktree for #${issue} (expected picsee-wt/${issue}-<slug>); ${HOW(issue)}`);
  const file = path.join(target, IDENTITY);
  let identity = null;
  if (fs.existsSync(file)) {
    try { identity = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { throw new Error(`${file} is not valid JSON; inspect the worktree before dispatch`); }
    if (identity?.issue !== Number(issue) || identity?.branch !== branch)
      throw new Error(`${target} already holds task #${identity?.issue} (branch ${identity?.branch}); a second task needs its own worktree: ${HOW(issue)}`);
  }
  const current = git(target, 'symbolic-ref', '-q', '--short', 'HEAD');
  if (current && current !== branch)
    throw new Error(`${target} holds branch ${current}, not the task branch ${branch}; one task, one worktree: ${HOW(issue)}`);
  const fixRound = identity !== null;
  // A new task starts from a fully clean tree (untracked leftovers broke a device build, #882); a fix round keeps its
  // own untracked tool files (tdd-guardian receipts) but never uncommitted tracked changes.
  const status = git(target, 'status', '--porcelain', ...(fixRound ? ['--untracked-files=no'] : []));
  if (status === null) throw new Error(`git status failed in ${target}`);
  if (status) throw new Error(fixRound
    ? `${target} has tracked changes; commit or remove them before the fix round is dispatched`
    : `${target} is not clean (${status.split('\n').length} path(s) changed or untracked); a new task starts from a clean worktree: ${HOW(issue)}`);
  return { fixRound, identity };
}

export function writeIdentity(target, { issue, branch, task }) {
  const file = path.join(target, IDENTITY);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ issue: Number(issue), branch, task, markedAt: new Date().toISOString() }) + '\n');
}
