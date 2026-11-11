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
function block(reason) { process.stdout.write(JSON.stringify({ decision: 'block', reason })); }
const message = typeof input.last_assistant_message === 'string' ? input.last_assistant_message : '';
const exempt = input.stop_hook_active === true || stopException(message);
const claudeAgent = process.argv.slice(2).join(' ') === '--role-source claude-agent';
const root = exempt ? null : git(cwd, 'rev-parse', '--show-toplevel');
if (root) {
  const marker = path.join(root, '.build/mado-verify/target-worktree');
  let target = null, invalidTarget = false;
  if (fs.existsSync(marker)) {
    try {
      const raw = fs.readFileSync(marker, 'utf8');
      const line = raw.match(/^([^\r\n]+)\r?\n?$/)?.[1];
      if (!line || !path.isAbsolute(line)) throw new Error('marker must be one absolute path');
      const real = fs.realpathSync(line);
      const targetTop = git(real, 'rev-parse', '--show-toplevel');
      const currentCommon = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir');
      const targetCommon = git(real, 'rev-parse', '--path-format=absolute', '--git-common-dir');
      if (git(real, 'rev-parse', '--is-inside-work-tree') !== 'true' || !targetTop || fs.realpathSync(targetTop) !== real || !currentCommon || !targetCommon || fs.realpathSync(currentCommon) !== fs.realpathSync(targetCommon)) throw new Error('not a worktree of this repo');
      target = real;
    } catch { invalidTarget = true; }
  }
  if (!claudeAgent && !overlay(root) && !(target && overlay(target))) process.exit(0);
  if (invalidTarget) block('Invalid mado-verify target worktree marker; set it to the absolute path of the briefed worktree.');
  else for (const worktree of target && target !== root ? [root, target] : [root]) {
    const head = git(worktree, 'rev-parse', 'HEAD');
    const base = git(worktree, 'merge-base', 'origin/main', 'HEAD');
    if (!head || !base) continue;
    const dirty = git(worktree, 'status', '--porcelain', '--untracked-files=no');
    if (!target && !claudeAgent && !dirty && !git(worktree, 'symbolic-ref', '-q', '--short', 'HEAD')) continue;
    if (head === base && !dirty) continue;
    let fresh = false;
    try {
      const record = JSON.parse(fs.readFileSync(path.join(worktree, '.build/mado-verify', `${head}.json`), 'utf8'));
      fresh = record.head === head && /^https:\/\/github\.com\/[^/]+\/[^/]+\/issues\/\d+#issuecomment-\d+$/.test(record.commentUrl) && gateVerdict(record.gates).complete;
    } catch { /* missing or malformed record */ }
    if (!fresh || dirty) {
      block(`Run mado-verify in the ${worktree === root ? 'session' : 'briefed target'} worktree and post evidence for its final HEAD before handoff.`);
      break;
    }
  }
}
