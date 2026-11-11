#!/usr/bin/env node
// Runs inside one heavy-lock admission. The #632 watchdog still supervises the
// same `swift test` command; #631 clears and evaluates its coverage there.
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../..', import.meta.url));
const watchdog = fileURLToPath(new URL('../ci/test-watchdog.mjs', import.meta.url));
const clear = fileURLToPath(new URL('../ci/package-coverage-clear.mjs', import.meta.url));
const coverage = fileURLToPath(new URL('../ci/package-coverage-local.mjs', import.meta.url));
const args = process.argv.slice(2);
if (args.length !== 10 || args[0] !== '--out' || args[2] !== '--timeout-seconds' ||
    args[4] !== '--capture-seconds' || args[6] !== '--grace-seconds' ||
    args[8] !== '--verify-coverage' || !['true', 'false'].includes(args[9])) {
  process.stderr.write('usage: unit-locked.mjs --out PATH --timeout-seconds N --capture-seconds N --grace-seconds N --verify-coverage true|false\n');
  process.exitCode = 64;
} else {
  const [out, timeout, capture, grace, verify] = [args[1], args[3], args[5], args[7], args[9] === 'true'];
  const run = (script, params) => {
    const result = spawnSync(process.execPath, [script, ...params], { cwd: root, env: process.env, stdio: 'inherit' });
    if (result.error) process.stderr.write(`unit-locked: ${result.error.message}\n`);
    return result.status ?? 1;
  };
  let status = verify ? run(clear, []) : 0;
  const notBefore = Math.floor(Date.now() / 1000);
  if (status === 0) status = run(watchdog, ['--out', out, '--timeout-seconds', timeout,
    '--capture-seconds', capture, '--grace-seconds', grace, '--',
    'swift', 'test', '--package-path', 'Packages/MadoKit', '--enable-code-coverage']);
  if (status === 0 && verify) status = run(coverage, ['--out', out, '--not-before', String(notBefore)]);
  process.exitCode = status;
}
