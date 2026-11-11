#!/usr/bin/env node
// Shared Claude/Codex Stop decision: no network, no build, no filesystem scan.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { gateVerdict } from './gate-policy.mjs';

let input = {};
try { input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch { /* cwd fallback */ }
const cwd = input.cwd || process.cwd();
function git(at, ...args) { const r = spawnSync('git', args, { cwd: at, encoding: 'utf8', timeout: 500 }); return r.status === 0 ? r.stdout.trim() : null; }
function stopException(message) {
  const lines = message.split(/\r?\n/);
  const first = lines.find(line => line.trim());
  if (first && (first.trim() === 'BLOCKED' || first.trim().startsWith('BLOCKED:'))) return true;
  let fence = null, last = '';
  for (const line of lines) {
    const match = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (match) {
      const mark = match[1];
      if (!fence) fence = mark;
      else if (mark[0] === fence[0] && mark.length >= fence.length) fence = null;
      continue;
    }
    if (fence || /^\s*>/.test(line) || !line.trim()) continue;
    last = line.trim();
  }
  return /[?？]$/.test(last);
}
function overlay(root) {
  try { return fs.readFileSync(path.join(root, '.codex/rules/picsee-role.rules'), 'utf8').split(/\r?\n/, 1)[0] === '# Local picsee role: implementor'; }
  catch { return false; }
}
function namedMismatch(message, identity, target) {
  const fields = Object.fromEntries(message.split(/\r?\n/).map(line => line.match(/^(Worktree|Branch|HEAD):\s*(\S+)\s*$/)).filter(Boolean).map(match => [match[1], match[2].replace(/^`|`$/g, '')]));
  let namedWorktree = null;
  if (fields.Worktree) {
    try { namedWorktree = fs.realpathSync(fields.Worktree); } catch { return true; }
  }
  return (namedWorktree && namedWorktree !== target) || (fields.Branch && fields.Branch !== identity.branch) || (fields.HEAD && fields.HEAD !== git(target, 'rev-parse', 'HEAD'));
}
function block(reason) { process.stdout.write(JSON.stringify({ decision: 'block', reason })); }
const message = typeof input.last_assistant_message === 'string' ? input.last_assistant_message : '';
const exempt = input.stop_hook_active === true || stopException(message);
const claudeAgent = process.argv.slice(2).join(' ') === '--role-source claude-agent';
const root = exempt ? null : git(cwd, 'rev-parse', '--show-toplevel');
if (root) {
  const marker = path.join(root, '.build/mado-verify/target-worktree');
  let target = null, identity = null, invalidTarget = false;
  if (fs.existsSync(marker)) {
    try {
      identity = JSON.parse(fs.readFileSync(marker, 'utf8'));
      if (!identity || !path.isAbsolute(identity.worktree) || !identity.branch || !Number.isSafeInteger(identity.issue) || identity.issue < 1 || !identity.task) throw new Error('marker requires worktree, branch, issue and task');
      const real = fs.realpathSync(identity.worktree);
      const targetTop = git(real, 'rev-parse', '--show-toplevel');
      const currentCommon = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir');
      const targetCommon = git(real, 'rev-parse', '--path-format=absolute', '--git-common-dir');
      if (git(real, 'rev-parse', '--is-inside-work-tree') !== 'true' || !targetTop || fs.realpathSync(targetTop) !== real || !currentCommon || !targetCommon || fs.realpathSync(currentCommon) !== fs.realpathSync(targetCommon)) throw new Error('not a worktree of this repo');
      target = real;
    } catch { invalidTarget = true; }
  }
  if (!claudeAgent && !overlay(root) && !(target && overlay(target))) process.exit(0);
  if (!claudeAgent && !git(root, 'symbolic-ref', '-q', '--short', 'HEAD') && !git(root, 'status', '--porcelain', '--untracked-files=no')) process.exit(0);
  if (invalidTarget || !target) block('Missing or invalid mado-verify target worktree marker; dispatch must write JSON with worktree, branch, issue and task. Legacy one-line markers are invalid.');
  else if (git(target, 'symbolic-ref', '-q', '--short', 'HEAD') !== identity.branch) block('Mado-verify target branch differs from the dispatch marker.');
  else if (target === root && git(root, 'symbolic-ref', '-q', '--short', 'HEAD') !== identity.branch) block('Pane home is not the briefed target branch.');
  else if (namedMismatch(message, identity, target)) block('Handoff worktree, branch or HEAD differs from the dispatch target.');
  else for (const worktree of target !== root ? [root, target] : [root]) {
    const head = git(worktree, 'rev-parse', 'HEAD');
    const base = git(worktree, 'merge-base', 'origin/main', 'HEAD');
    if (!head || !base) continue;
    const dirty = git(worktree, 'status', '--porcelain', '--untracked-files=no');
    if (worktree === root && target !== root && head === base && !dirty) continue;
    if (worktree === root && target === root && head === base && !dirty) continue;
    let fresh = false;
    try {
      const record = JSON.parse(fs.readFileSync(path.join(worktree, '.build/mado-verify', `${head}.json`), 'utf8'));
      fresh = record.head === head && (worktree !== target || record.issue === identity.issue) && new RegExp(`^https://github\\.com/[^/]+/[^/]+/issues/${worktree === target ? identity.issue : '\\d+'}#issuecomment-\\d+$`).test(record.commentUrl) && gateVerdict(record.gates).complete;
    } catch { /* missing or malformed record */ }
    if (!fresh || dirty) {
      block(`Run mado-verify in the ${worktree === root ? 'session' : 'briefed target'} worktree and post evidence for its final HEAD before handoff.`);
      break;
    }
  }
}
