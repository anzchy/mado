#!/usr/bin/env node
// The required Walking skeleton check trusts the native-inputs classifier and
// requires every native job, the unsigned build, and the App run step to succeed.
// Only an explicit build-only manual dispatch may pass without App evidence;
// a trusted docs-only classification must skip every native job.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function verdict(env) {
  const { CHANGES, NATIVE, LEDGER, PACKAGE, MACUI, APP_JOB, UNSIGNED_BUILD,
    APP_TEST_STEP, APP_RETRIED, EVENT_NAME, APP_TESTS, APP_FORMAL, APP_DIAGNOSTIC, APP_FILTER, APP_REPEAT } = env;
  const facts = `changes=${CHANGES} native=${NATIVE} ledger=${LEDGER} package-tests=${PACKAGE} ` +
    `package-macui-tests=${MACUI} app-tests=${APP_JOB} unsigned-build-step=${UNSIGNED_BUILD || '(none)'} ` +
    `app-test-step=${APP_TEST_STEP || '(none)'} app-retried=${APP_RETRIED || '(none)'}`;
  const result = (ok, reason, formalAppEvidence = false) => ({ ok, facts, reason, formalAppEvidence });
  const fail = reason => result(false, reason);
  if (CHANGES !== 'success') return fail('native-inputs classifier did not succeed');
  if (LEDGER !== 'success') return fail('ledger HTML check did not succeed');
  if (NATIVE === 'true') {
    if (PACKAGE !== 'success') return fail('package tests (non-UI) did not succeed');
    if (MACUI !== 'success') return fail('package tests (MacUI) did not succeed');
    if (APP_JOB !== 'success') return fail('App tests job did not succeed');
    if (UNSIGNED_BUILD !== 'success') return fail('unsigned xcodebuild build step did not succeed');
    if (EVENT_NAME === 'workflow_dispatch' && APP_TESTS === 'false') {
      if (APP_TEST_STEP !== 'skipped' || APP_RETRIED === 'true') return fail('build-only dispatch reported inconsistent App execution');
      return result(true, 'diagnostic dispatch: tests not run');
    }
    if (APP_TEST_STEP !== 'success') return fail('App test run step did not succeed');
    const diagnostic = APP_DIAGNOSTIC === 'true' || Boolean(APP_FILTER) || (APP_REPEAT && APP_REPEAT !== '1');
    if (EVENT_NAME === 'workflow_dispatch' && diagnostic) return result(true, 'diagnostic App test run; excluded from formal App evidence');
    if (APP_FORMAL !== 'true' || diagnostic) return fail('structured evidence does not prove a formal full App run');
    if (!['true', 'false'].includes(APP_RETRIED)) return fail('App retry reporting is missing or invalid');
    return result(true, APP_RETRIED === 'true'
      ? 'native jobs succeeded; App tests passed after the one automatic retry'
      : 'native jobs succeeded; App tests passed directly', true);
  }
  if (NATIVE === 'false') {
    if ([PACKAGE, MACUI, APP_JOB].some(value => value !== 'skipped') || UNSIGNED_BUILD ||
        (APP_TEST_STEP && APP_TEST_STEP !== 'skipped') || APP_RETRIED === 'true') {
      return fail('classifier skipped native inputs but a native job did not skip');
    }
    return result(true, 'no native input changed; native jobs skipped');
  }
  return fail('classifier gave no native=true|false output');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = verdict(process.env);
  console.log(result.facts);
  console.log(`walking-skeleton: ${result.ok ? 'PASS' : 'FAIL'} (${result.reason})`);
  console.log(`formal App evidence: ${result.formalAppEvidence}`);
  process.exitCode = result.ok ? 0 : 1;
}
