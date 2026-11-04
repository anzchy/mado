import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verdict } from './walking-skeleton.mjs';

const nativeRun = { CHANGES: 'success', NATIVE: 'true', LEDGER: 'success', PACKAGE: 'success', MACUI: 'success',
  APP_JOB: 'success', UNSIGNED_BUILD: 'success' };
const skippedRun = { CHANGES: 'success', NATIVE: 'false', LEDGER: 'success', PACKAGE: 'skipped', MACUI: 'skipped',
  APP_JOB: 'skipped', UNSIGNED_BUILD: '' };
const ok = env => verdict(env).ok;

test('native run passes when both suites and the unsigned build step succeed', () => {
  assert.equal(ok(nativeRun), true);
});

test('App test failure after a successful unsigned build does not fail the required check', () => {
  assert.equal(ok({ ...nativeRun, APP_JOB: 'failure' }), true);
});

test('an App tests job that was cancelled, skipped or gave no result fails, whatever the build step reported', () => {
  for (const result of ['cancelled', 'skipped', '', undefined, 'neutral']) {
    assert.equal(ok({ ...nativeRun, APP_JOB: result }), false, String(result));
    assert.equal(ok({ ...nativeRun, APP_JOB: result, UNSIGNED_BUILD: 'success' }), false, String(result));
  }
});

test('app_tests=false dispatch: job ran only the build, which is what is required', () => {
  assert.equal(ok({ ...nativeRun, APP_JOB: 'success', UNSIGNED_BUILD: 'success' }), true);
});

test('unsigned build failure, missing or skipped build step fails', () => {
  for (const build of ['failure', 'cancelled', 'skipped', '', undefined]) {
    assert.equal(ok({ ...nativeRun, APP_JOB: 'failure', UNSIGNED_BUILD: build }), false, String(build));
  }
});

test('either package suite not succeeding fails', () => {
  for (const key of ['PACKAGE', 'MACUI']) {
    for (const result of ['failure', 'cancelled', 'skipped']) {
      assert.equal(ok({ ...nativeRun, [key]: result }), false, `${key}=${result}`);
    }
  }
});

test('ledger check or classifier not succeeding fails, native or not', () => {
  for (const base of [nativeRun, skippedRun]) {
    for (const result of ['failure', 'cancelled', 'skipped']) {
      assert.equal(ok({ ...base, LEDGER: result }), false, `ledger=${result}`);
      assert.equal(ok({ ...base, CHANGES: result }), false, `changes=${result}`);
    }
  }
});

test('docs-only run passes only when every native job skipped', () => {
  assert.equal(ok(skippedRun), true);
  for (const key of ['PACKAGE', 'MACUI', 'APP_JOB']) {
    for (const result of ['success', 'failure', 'cancelled']) {
      assert.equal(ok({ ...skippedRun, [key]: result }), false, `${key}=${result}`);
    }
  }
  assert.equal(ok({ ...skippedRun, UNSIGNED_BUILD: 'success' }), false);
});

test('a missing or unexpected classifier output fails', () => {
  for (const native of ['', undefined, 'TRUE', 'yes']) {
    assert.equal(ok({ ...nativeRun, NATIVE: native }), false, String(native));
    assert.equal(ok({ ...skippedRun, NATIVE: native }), false, String(native));
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
