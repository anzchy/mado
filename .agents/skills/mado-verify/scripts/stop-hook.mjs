#!/usr/bin/env node
// Shared Claude/Codex Stop decision: no network, no build, no filesystem scan.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { gateVerdict } from './gate-policy.mjs';

let input = {};
try { input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch { /* cwd fallback */ }
const cwd = input.cwd || process.cwd();
function git(...args) { const r = spawnSync('git', args, { cwd, encoding: 'utf8', timeout: 500 }); return r.status === 0 ? r.stdout.trim() : null; }
const message = typeof input.last_assistant_message === 'string' ? input.last_assistant_message.trim() : '';
const exempt = input.stop_hook_active === true || /(?:^|\n)\s*(?:status:\s*)?BLOCKED\b/i.test(message) || /[?？]\s*$/.test(message);
const claudeAgent = process.argv.slice(2).join(' ') === '--role-source claude-agent';
const root = exempt ? null : git('rev-parse', '--show-toplevel');
if (root) {
  if (!claudeAgent) {
    const overlay = path.join(root, '.codex/rules/picsee-role.rules');
    let firstLine = '';
    try { firstLine = fs.readFileSync(overlay, 'utf8').split(/\r?\n/, 1)[0]; } catch { /* missing overlay: other role */ }
    if (firstLine !== '# Local picsee role: implementor') process.exit(0);
  }
  const head = git('rev-parse', 'HEAD');
  const base = git('merge-base', 'origin/main', 'HEAD');
  if (!head || !base) process.exit(0);
  const dirty = git('status', '--porcelain', '--untracked-files=no');
  if (!claudeAgent && !dirty && !git('symbolic-ref', '-q', '--short', 'HEAD')) process.exit(0);
  const changed = head !== base || Boolean(dirty);
  const recordPath = path.join(root, '.build/mado-verify', `${head}.json`);
  let fresh = false;
  try {
    const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
    fresh = record.head === head && /^https:\/\/github\.com\/[^/]+\/[^/]+\/issues\/\d+#issuecomment-\d+$/.test(record.commentUrl) && gateVerdict(record.gates).complete;
  } catch { /* missing or malformed record */ }
  const covered = fresh && !dirty; // A tracked edit after the recorded HEAD needs new evidence.
  if (changed && !covered) {
    process.stdout.write(JSON.stringify({ decision: 'block', reason: 'Run mado-verify and post evidence for the final HEAD before handoff; then write its fresh record.' }));
  }
}
