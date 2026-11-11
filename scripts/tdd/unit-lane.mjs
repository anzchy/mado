#!/usr/bin/env node
// Bound the unchanged full-package unit run after heavy-lock admission (#632).
// Keep every invocation's log/stacks so a later pass cannot erase hang evidence.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const UNIT_LIMITS = { timeoutSeconds: 600, captureSeconds: 90, graceSeconds: 15, lockWaitSeconds: 7200 };
const lock = fileURLToPath(new URL('../heavy-lock.sh', import.meta.url));

// Short budgets are available to process integration tests; the CLI always uses
// the production limits above, independently of filter/budget environment flags.
export function runUnit({ cwd = process.cwd(), env = process.env,
  timeoutSeconds = UNIT_LIMITS.timeoutSeconds, captureSeconds = UNIT_LIMITS.captureSeconds,
  graceSeconds = UNIT_LIMITS.graceSeconds, verifyCoverage = true } = {}) {
  const base = path.join(cwd, '.build/unit-watchdog');
  fs.mkdirSync(base, { recursive: true });
  const out = fs.mkdtempSync(path.join(base, 'run-'));
  process.stderr.write(`unit-lane: retained evidence ${out}\n`);
  const locked = path.join(cwd, 'scripts/tdd/unit-locked.mjs');
  const result = spawnSync(lock, [process.execPath, locked, '--out', out,
    '--timeout-seconds', String(timeoutSeconds), '--capture-seconds', String(captureSeconds),
    '--grace-seconds', String(graceSeconds), '--verify-coverage', String(verifyCoverage)], {
    cwd, env: { ...env, PICSEE_HEAVY_LOCK_WAIT_SECS: String(UNIT_LIMITS.lockWaitSeconds) }, stdio: 'inherit',
  });
  if (result.error) process.stderr.write(`unit-lane: ${result.error.message}\n`);
  return result.status ?? (result.signal ? 128 + (os.constants.signals[result.signal] ?? 0) : 127);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 2) {
    process.stderr.write('usage: node scripts/tdd/unit-lane.mjs\n');
    process.exitCode = 64;
  } else {
    process.exitCode = runUnit();
  }
}
