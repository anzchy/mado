#!/usr/bin/env node
// Bound the unchanged full-package unit run after heavy-lock admission (#632).
// Keep every invocation's log/stacks so a later pass cannot erase hang evidence.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runAttestedSync } from './status-channel.mjs';

export const UNIT_LIMITS = { timeoutSeconds: 600, captureSeconds: 90, graceSeconds: 15, lockWaitSeconds: 7200 };
const lock = fileURLToPath(new URL('../heavy-lock.sh', import.meta.url));

// Short budgets are available to process integration tests; the CLI always uses
// the production limits above, independently of filter/budget environment flags.
// `statusFault` corrupts the private status record in tests only (status-channel).
export function runUnit({ cwd = process.cwd(), env = process.env,
  timeoutSeconds = UNIT_LIMITS.timeoutSeconds, captureSeconds = UNIT_LIMITS.captureSeconds,
  graceSeconds = UNIT_LIMITS.graceSeconds, verifyCoverage = true, statusFault } = {}) {
  const base = path.join(cwd, '.build/unit-watchdog');
  fs.mkdirSync(base, { recursive: true });
  const out = fs.mkdtempSync(path.join(base, 'run-'));
  process.stderr.write(`unit-lane: retained evidence ${out}\n`);
  const locked = path.join(cwd, 'scripts/tdd/unit-locked.mjs');
  // #672: read heavy-lock's private status so a forced drain (a descendant that
  // outlived the run) can never leave a green package gate.
  const stdio = ['inherit', 'inherit', 'inherit'];
  if (env.PICSEE_HEAVY_LOCK_HELD === '1') {
    for (const name of ['PICSEE_HEAVY_CONTROL_FD', 'PICSEE_HEAVY_FLOCK_FD']) {
      const fd = Number(env[name]);
      if (!env[name] || !Number.isInteger(fd) || fd < 3 || fd > 64) continue;
      while (stdio.length <= fd) stdio.push('ignore');
      stdio[fd] = fd;
    }
  }
  const result = runAttestedSync(lock, [process.execPath, locked, '--out', out,
    '--timeout-seconds', String(timeoutSeconds), '--capture-seconds', String(captureSeconds),
    '--grace-seconds', String(graceSeconds), '--verify-coverage', String(verifyCoverage)], {
    cwd, env: { ...env, PICSEE_HEAVY_LOCK_WAIT_SECS: String(UNIT_LIMITS.lockWaitSeconds) }, stdio,
  }, { fault: statusFault });
  if (result.error) process.stderr.write(`unit-lane: ${result.error.message}\n`);
  if (result.drainExpired) {
    process.stderr.write('unit-lane: drain expired: a descendant outlived the run and was stopped by force; no green gate\n');
    return 70;
  }
  // Other statuses (124 watchdog, 65 coverage, 75 lock wait) keep their meaning.
  const status = result.supervisorStatus ?? (result.signal ? 128 + (os.constants.signals[result.signal] ?? 0) : 127);
  // #672 fix r2: a green run whose private cleanup status is missing, malformed,
  // stale or incomplete has unverified cleanup, so it is not a green gate.
  if (status === 0 && !result.attested) {
    const reason = /status-channel: (.*)\n?$/.exec(result.stderr ?? '')?.[1] ?? 'unknown';
    process.stderr.write(`unit-lane: cleanup status not attested (${reason}); no green gate\n`);
    return 70;
  }
  return status;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 2) {
    process.stderr.write('usage: node scripts/tdd/unit-lane.mjs\n');
    process.exitCode = 64;
  } else {
    process.exitCode = runUnit();
  }
}
