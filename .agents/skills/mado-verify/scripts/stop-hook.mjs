#!/usr/bin/env node
// Shared Claude/Codex Stop decision: no network, no build, no filesystem scan.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

let input = {};
try { input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch { /* cwd fallback */ }
const cwd = input.cwd || process.cwd();
function git(...args) { const r = spawnSync('git', args, { cwd, encoding: 'utf8', timeout: 500 }); return r.status === 0 ? r.stdout.trim() : null; }
const root = git('rev-parse', '--show-toplevel');
if (root) {
  const head = git('rev-parse', 'HEAD');
  const base = git('merge-base', 'origin/main', 'HEAD');
  const dirty = git('status', '--porcelain', '--untracked-files=no');
  const changed = !base || head !== base || Boolean(dirty);
  const recordPath = path.join(root, '.build/mado-verify', `${head}.json`);
  let fresh = false;
  try {
    const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
    fresh = record.head === head && /^https:\/\/github\.com\/[^/]+\/[^/]+\/issues\/\d+#issuecomment-\d+$/.test(record.commentUrl) && Array.isArray(record.gates) && record.gates.length > 0 && record.gates.every(g => Number.isInteger(g.exitCode));
  } catch { /* missing or malformed record */ }
  if (changed && (!fresh || dirty)) {
    process.stdout.write(JSON.stringify({ decision: 'block', reason: 'Run mado-verify and post evidence for the final HEAD before handoff; then write its fresh record.' }));
  }
}
