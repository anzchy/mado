import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verdict } from './walking-skeleton.mjs';

const nativeRun = { CHANGES: 'success', NATIVE: 'true', LEDGER: 'success', PACKAGE: 'success', MACUI: 'success',
  APP_JOB: 'success', UNSIGNED_BUILD: 'success', APP_TEST_STEP: 'success', APP_RETRIED: 'false', EVENT_NAME: 'push' };
const skippedRun = { CHANGES: 'success', NATIVE: 'false', LEDGER: 'success', PACKAGE: 'skipped', MACUI: 'skipped',
  APP_JOB: 'skipped', UNSIGNED_BUILD: '', APP_TEST_STEP: '' };
const ok = env => verdict(env).ok;
const unsuccessful = ['failure', 'cancelled', 'skipped', '', undefined, 'neutral'];

test('native run requires successful App tests and distinguishes direct from retry success', () => {
  for (const event of ['pull_request', 'push']) {
    const direct = verdict({ ...nativeRun, EVENT_NAME: event });
    assert.equal(direct.ok, true);
    assert.equal(direct.formalAppEvidence, true);
    assert.match(direct.reason, /passed directly/);
    const retried = verdict({ ...nativeRun, EVENT_NAME: event, APP_RETRIED: 'true' });
    assert.equal(retried.ok, true);
    assert.equal(retried.formalAppEvidence, true);
    assert.match(retried.reason, /passed after the one automatic retry/);
  }
});

test('App assertion failure after a successful unsigned build fails the required check', () => {
  for (const retried of ['false', 'true']) {
    const result = verdict({ ...nativeRun, APP_JOB: 'failure', APP_RETRIED: retried });
    assert.equal(result.ok, false);
    assert.equal(result.formalAppEvidence, false);
  }
});

test('every required native result must succeed on PR and main, including App job and run step', () => {
  for (const event of ['pull_request', 'push']) {
    for (const key of ['CHANGES', 'LEDGER', 'PACKAGE', 'MACUI', 'APP_JOB', 'UNSIGNED_BUILD', 'APP_TEST_STEP']) {
      for (const value of unsuccessful) {
        const result = verdict({ ...nativeRun, EVENT_NAME: event, [key]: value });
        assert.equal(result.ok, false, `${event}: ${key}=${value}`);
        assert.equal(result.formalAppEvidence, false, `${event}: ${key}=${value}`);
      }
    }
  }
});

test('missing or invalid retry reporting cannot claim a direct App pass', () => {
  for (const value of ['', undefined, 'unknown', 'TRUE']) {
    const result = verdict({ ...nativeRun, APP_RETRIED: value });
    assert.equal(result.ok, false, String(value));
    assert.equal(result.formalAppEvidence, false);
  }
});

test('app_tests=false manual dispatch is explicitly diagnostic with tests not run', () => {
  const diagnostic = { ...nativeRun, EVENT_NAME: 'workflow_dispatch', APP_TESTS: 'false', APP_TEST_STEP: 'skipped' };
  const result = verdict(diagnostic);
  assert.equal(result.ok, true);
  assert.equal(result.formalAppEvidence, false);
  assert.match(result.reason, /tests not run/);
  for (const event of ['pull_request', 'push', '', undefined]) {
    assert.equal(ok({ ...diagnostic, EVENT_NAME: event }), false, String(event));
  }
  for (const input of ['true', '', undefined]) {
    assert.equal(ok({ ...diagnostic, APP_TESTS: input }), false, String(input));
  }
  for (const key of ['APP_JOB', 'UNSIGNED_BUILD', 'PACKAGE', 'MACUI', 'CHANGES', 'LEDGER']) {
    for (const value of unsuccessful) assert.equal(ok({ ...diagnostic, [key]: value }), false, `${key}=${value}`);
  }
  for (const value of ['success', 'failure', 'cancelled', '', undefined]) {
    assert.equal(ok({ ...diagnostic, APP_TEST_STEP: value }), false, `step=${value}`);
  }
  assert.equal(ok({ ...diagnostic, APP_RETRIED: 'true' }), false);
});

test('ledger check or classifier not succeeding fails docs-only as well as native runs', () => {
  for (const base of [nativeRun, skippedRun]) {
    for (const result of unsuccessful) {
      assert.equal(ok({ ...base, LEDGER: result }), false, `ledger=${result}`);
      assert.equal(ok({ ...base, CHANGES: result }), false, `changes=${result}`);
    }
  }
});

test('docs-only run passes only when every native job and App execution skipped', () => {
  const result = verdict(skippedRun);
  assert.equal(result.ok, true);
  assert.equal(result.formalAppEvidence, false);
  assert.equal(ok({ ...skippedRun, APP_TEST_STEP: 'skipped' }), true);
  for (const key of ['PACKAGE', 'MACUI', 'APP_JOB']) {
    for (const value of ['success', 'failure', 'cancelled', '', undefined]) {
      assert.equal(ok({ ...skippedRun, [key]: value }), false, `${key}=${value}`);
    }
  }
  for (const key of ['UNSIGNED_BUILD', 'APP_TEST_STEP']) {
    for (const value of ['success', 'failure', 'cancelled']) {
      assert.equal(ok({ ...skippedRun, [key]: value }), false, `${key}=${value}`);
    }
  }
  assert.equal(ok({ ...skippedRun, APP_RETRIED: 'true' }), false);
});

test('a missing or unexpected classifier output fails', () => {
  for (const native of ['', undefined, 'TRUE', 'yes']) {
    assert.equal(ok({ ...nativeRun, NATIVE: native }), false, String(native));
    assert.equal(ok({ ...skippedRun, NATIVE: native }), false, String(native));
  }
});

test('CLI exit status and summary follow App execution evidence', () => {
  const script = fileURLToPath(new URL('./walking-skeleton.mjs', import.meta.url));
  const run = env => spawnSync(process.execPath, [script], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });
  const pass = run(nativeRun);
  assert.equal(pass.status, 0);
  assert.match(pass.stdout, /walking-skeleton: PASS.*passed directly/);
  assert.match(pass.stdout, /formal App evidence: true/);
  const fail = run({ ...nativeRun, APP_JOB: 'failure', APP_TEST_STEP: 'failure' });
  assert.equal(fail.status, 1);
  assert.match(fail.stdout, /walking-skeleton: FAIL/);
  assert.match(fail.stdout, /formal App evidence: false/);
  const diagnostic = run({ ...nativeRun, EVENT_NAME: 'workflow_dispatch', APP_TESTS: 'false', APP_TEST_STEP: 'skipped' });
  assert.equal(diagnostic.status, 0);
  assert.match(diagnostic.stdout, /tests not run/);
  assert.match(diagnostic.stdout, /formal App evidence: false/);
});
