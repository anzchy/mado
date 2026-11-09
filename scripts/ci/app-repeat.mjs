#!/usr/bin/env node
/** Dispatch-only reproduction. Normal CI continues to use app-lane directly. */
import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const supervisor = fileURLToPath(new URL('./app-repeat-process.mjs', import.meta.url));
const worker = fileURLToPath(new URL('./app-repeat-worker.mjs', import.meta.url));

export function runAppRepeat({ repeat = process.env.APP_REPEAT ?? 1, filter = process.env.APP_FILTER ?? '',
  out = '.build/app-repeat', summaryPath = process.env.GITHUB_STEP_SUMMARY,
  deadline = Number(process.env.APP_REPEAT_DEADLINE_MS || Date.now() + 6900000), now = Date.now,
  env = process.env, spawn = spawnSync, stdout = s => process.stdout.write(s), validateOnly = false } = {}) {
  const count = Number(repeat);
  if (String(repeat).trim() === '' || !Number.isInteger(count) || count < 1 || count > 50) {
    stdout('app-repeat: app_repeat must be an integer from 1 to 50\n'); return 64;
  }
  if (validateOnly) return 0;
  if (env.PICSEE_HEAVY_LOCK_HELD !== '1') {
    stdout('app-repeat: repeat execution requires PICSEE_HEAVY_LOCK_HELD=1 (CI machine ownership)\n'); return 64;
  }
  if (!Number.isFinite(deadline)) { stdout('app-repeat: invalid deadline\n'); return 64; }
  mkdirSync(out, { recursive: true });
  const temporary = mkdtempSync(path.join(tmpdir(), 'app-repeat-'));
  const quarantinePath = path.join(temporary, 'empty-quarantine.json');
  writeFileSync(quarantinePath, '[]\n');
  const iterationEnv = { ...env, PICSEE_APP_LANE_NO_RETRY: '1' };
  // The lane deliberately rejects a blank filter. Omit it to select the full bundle.
  if (filter.trim()) iterationEnv.PICSEE_APP_FILTER = filter;
  else delete iterationEnv.PICSEE_APP_FILTER;
  const summarize = line => {
    stdout(line + '\n');
    if (summaryPath) appendFileSync(summaryPath, line + '\n');
  };
  let failures = 0, previousGroupDrained = true;
  try {
    for (let iteration = 1; iteration <= count; iteration++) {
      const label = String(iteration).padStart(2, '0');
      let log = '', status = 70;
      const logPath = path.join(out, `iter-${label}.log`);
      writeFileSync(logPath, '');
      try {
        if (!previousGroupDrained) throw new Error('previous iteration process group did not drain; refusing to overlap');
        if (now() >= deadline) throw new Error('job time budget exhausted');
        // The async supervisor remains outside the worker's private process group. It owns the
        // deadline, TERM/KILL escalation and drain confirmation, including after a leader exits.
        previousGroupDrained = false;
        const run = spawn(process.execPath, [supervisor, String(deadline), logPath,
          process.execPath, worker, quarantinePath, path.join(temporary, 'attempt1.log')], {
          env: iterationEnv, encoding:'utf8', maxBuffer:1024*1024 });
        log = readFileSync(logPath,'utf8');
        if (run.error || run.signal || run.status !== 0) {
          previousGroupDrained = false;
          throw new Error(`iteration supervisor failed: ${run.error?.message ?? run.signal ?? run.stderr ?? run.status}`);
        }
        const result = JSON.parse(run.stdout);
        previousGroupDrained = result.drained === true;
        status = previousGroupDrained && Number.isInteger(result.status) ? result.status : 70;
      } catch (error) { log += `app-repeat: ${error.message}\n`; }
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
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = runAppRepeat({validateOnly:process.argv[2] === '--validate'});
