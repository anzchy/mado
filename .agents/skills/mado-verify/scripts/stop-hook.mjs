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
function identityFields(message) {
  return Object.fromEntries(message.split(/\r?\n/).map(line => line.match(/^\s*(?:-\s*)?\*\*(Worktree|Branch|HEAD)(?::\*\*|\*\*:)\s*(.*?)\s*$/) || line.match(/^\s*(?:-\s*)?(Worktree|Branch|HEAD):\s*(.*?)\s*$/)).filter(Boolean).map(match => [match[1], match[2].replace(/^`|`$/g, '')]));
}
function expandHome(value) { return value === '~' || value.startsWith('~/') ? path.join(process.env.HOME || '', value.slice(2)) : value; }
function namedMismatch(fields, identity, target, required = false) {
  if (required && (!fields.Worktree || !fields.Branch || !fields.HEAD)) return true;
  let namedWorktree = null;
  if (fields.Worktree) {
    try { namedWorktree = fs.realpathSync(expandHome(fields.Worktree)); } catch { return true; }
  }
  const head = git(target, 'rev-parse', 'HEAD');
  const namedHead = fields.HEAD;
  const headMatches = !namedHead || (/^[0-9a-f]{40}$/i.test(namedHead) ? namedHead.toLowerCase() === head : /^[0-9a-f]{7,39}$/i.test(namedHead) && git(target, 'rev-parse', '--verify', `${namedHead}^{commit}`) === head);
  return (namedWorktree && namedWorktree !== target) || (fields.Branch && fields.Branch !== identity.branch) || !headMatches;
}
function handoffIdentity(handoff, identity, target) {
  try { return namedMismatch(identityFields(fs.readFileSync(handoff, 'utf8')), identity, target, true) ? 'mismatch' : 'match'; }
  catch { return 'unreadable'; }
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
      if (!identity || !path.isAbsolute(identity.worktree) || !identity.branch || !Number.isSafeInteger(identity.issue) || identity.issue < 1 || !identity.task || !path.isAbsolute(identity.handoff)) throw new Error('marker requires worktree, branch, issue, task and handoff');
      const real = fs.realpathSync(identity.worktree);
      const targetTop = git(real, 'rev-parse', '--show-toplevel');
      const currentCommon = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir');
      const targetCommon = git(real, 'rev-parse', '--path-format=absolute', '--git-common-dir');
      if (git(real, 'rev-parse', '--is-inside-work-tree') !== 'true' || !targetTop || fs.realpathSync(targetTop) !== real || !currentCommon || !targetCommon || fs.realpathSync(currentCommon) !== fs.realpathSync(targetCommon)) throw new Error('not a worktree of this repo');
      target = real;
    } catch { invalidTarget = true; }
  }
  if (!claudeAgent && !overlay(root) && !(target && overlay(target))) process.exit(0);
  if (!claudeAgent && !target && !invalidTarget && !fs.existsSync(marker) && !git(root, 'symbolic-ref', '-q', '--short', 'HEAD') && !git(root, 'status', '--porcelain', '--untracked-files=no')) process.exit(0);
  const handoffStatus = target && message ? handoffIdentity(identity.handoff, identity, target) : null;
  if (invalidTarget || !target) block('Missing or invalid mado-verify target worktree marker; dispatch must write JSON with worktree, branch, issue, task and handoff. Legacy one-line markers are invalid.');
  else if (git(target, 'symbolic-ref', '-q', '--short', 'HEAD') !== identity.branch) block('Mado-verify target branch differs from the dispatch marker.');
  else if (handoffStatus === 'unreadable') block('Missing or unreadable handoff file at the dispatch path.');
  else if (handoffStatus === 'mismatch') block('Handoff worktree, branch or HEAD differs from the dispatch target.');
  else if (namedMismatch(identityFields(message), identity, target)) block('Handoff worktree, branch or HEAD differs from the dispatch target.');
  else for (const worktree of target !== root ? [root, target] : [root]) {
    const head = git(worktree, 'rev-parse', 'HEAD');
    const base = git(worktree, 'merge-base', 'origin/main', 'HEAD');
    if (!head || !base) continue;
    const dirty = git(worktree, 'status', '--porcelain', '--untracked-files=no');
    if (worktree === root && target !== root && head === base && !dirty) continue;
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
