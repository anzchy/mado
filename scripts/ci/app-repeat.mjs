#!/usr/bin/env node
/** Dispatch-only reproduction. Normal CI continues to use app-lane directly. */
import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runAppLane } from '../tdd/app-lane.mjs';

export function runAppRepeat({ repeat = process.env.APP_REPEAT ?? 1, filter = process.env.APP_FILTER ?? '',
  out = '.build/app-repeat', summaryPath = process.env.GITHUB_STEP_SUMMARY,
  deadline = Number(process.env.APP_REPEAT_DEADLINE_MS || Date.now() + 6900000), now = Date.now,
  env = process.env, spawn = spawnSync, stdout = s => process.stdout.write(s) } = {}) {
  const count = Number(repeat);
  if (String(repeat).trim() === '' || !Number.isInteger(count) || count < 1 || count > 50) {
    stdout('app-repeat: app_repeat must be an integer from 1 to 50\n'); return 64;
  }
  if (!Number.isFinite(deadline)) { stdout('app-repeat: invalid deadline\n'); return 64; }
  mkdirSync(out, { recursive: true });
  const temporary = mkdtempSync(path.join(tmpdir(), 'app-repeat-'));
  const quarantinePath = path.join(temporary, 'empty-quarantine.json');
  writeFileSync(quarantinePath, '[]\n');
  const iterationEnv = { ...env, PICSEE_APP_LANE_NO_RETRY: '1' };
  // The lane deliberately rejects a blank filter. Omit it to select the full bundle.
  if (filter) iterationEnv.PICSEE_APP_FILTER = filter;
  else delete iterationEnv.PICSEE_APP_FILTER;
  const summarize = line => {
    stdout(line + '\n');
    if (summaryPath) appendFileSync(summaryPath, line + '\n');
  };
  let failures = 0;
  try {
    for (let iteration = 1; iteration <= count; iteration++) {
      const label = String(iteration).padStart(2, '0');
      let log = '', status = 70;
      const capture = s => { log += s; };
      try {
        if (now() >= deadline) throw new Error('job time budget exhausted');
        status = runAppLane({ env: iterationEnv, quarantinePath,
          evidencePath: path.join(temporary, 'attempt1.log'), stdout: capture, stderr: capture,
          spawn: (command, args, options) => {
            const remaining = deadline - now();
            if (remaining <= 0) throw new Error('job time budget exhausted');
            return spawn(command, args, { ...options, killSignal: 'SIGKILL', timeout: Math.max(1, Math.min(options.timeout ?? remaining, remaining)) });
          } });
      } catch (error) { capture(`app-repeat: ${error.message}\n`); }
      writeFileSync(path.join(out, `iter-${label}.log`), log);
      const failed = status !== 0;
      if (failed) failures++;
      // The lane names both XCTest and Swift Testing failures, including filtered runs.
      const names = [...log.matchAll(/^app-lane: first-attempt failures: (.+)$/gm)].map(m => m[1]);
      const detail = names.join(', ') || (log.includes('job time budget exhausted') ? 'job time budget exhausted' : 'environment/lane failure (see log)');
      summarize(`${label} ${failed ? `FAIL ${detail}` : 'PASS'}`);
    }
    summarize(`TOTAL ${count - failures} PASS, ${failures} FAIL`);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
  return failures ? 1 : 0;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = runAppRepeat();
