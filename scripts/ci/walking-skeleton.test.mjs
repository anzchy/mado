import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verdict } from './walking-skeleton.mjs';

const nativeRun = { LEDGER: 'success', PACKAGE: 'success', MACUI: 'success', APP_JOB: 'success', UNSIGNED_BUILD: 'success' };
const ok = env => verdict(env).ok;

test('passes when both suites, the ledger check and the unsigned build step succeed', () => {
  assert.equal(ok(nativeRun), true);
});

test('App test failure after a successful unsigned build does not fail the required check', () => {
  assert.equal(ok({ ...nativeRun, APP_JOB: 'failure' }), true);
  assert.equal(ok({ ...nativeRun, APP_JOB: 'cancelled' }), true);
});

test('app_tests=false dispatch: the job ran only the build, which is what is required', () => {
  assert.equal(ok({ ...nativeRun, APP_JOB: 'success', UNSIGNED_BUILD: 'success' }), true);
});

test('unsigned build failure, or a missing or skipped build step, fails', () => {
  for (const build of ['failure', 'cancelled', 'skipped', '', undefined]) {
    assert.equal(ok({ ...nativeRun, APP_JOB: 'failure', UNSIGNED_BUILD: build }), false, String(build));
  }
});

test('either package suite not succeeding fails', () => {
  for (const key of ['PACKAGE', 'MACUI']) {
    for (const result of ['failure', 'cancelled', 'skipped', '']) {
      assert.equal(ok({ ...nativeRun, [key]: result }), false, `${key}=${result}`);
    }
  }
});

test('ledger check not succeeding fails', () => {
  for (const result of ['failure', 'cancelled', 'skipped', '']) {
    assert.equal(ok({ ...nativeRun, LEDGER: result }), false, `ledger=${result}`);
  }
});

test('CLI exit status follows the verdict', () => {
  const script = fileURLToPath(new URL('./walking-skeleton.mjs', import.meta.url));
  const run = env => spawnSync(process.execPath, [script], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });
  const pass = run(nativeRun);
  assert.equal(pass.status, 0);
  assert.match(pass.stdout, /walking-skeleton: PASS/);
  const fail = run({ ...nativeRun, UNSIGNED_BUILD: 'failure' });
  assert.equal(fail.status, 1);
  assert.match(fail.stdout, /walking-skeleton: FAIL \(unsigned xcodebuild build step did not succeed\)/);
});
