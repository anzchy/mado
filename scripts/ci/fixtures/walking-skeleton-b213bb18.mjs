#!/usr/bin/env node
// The required `Walking skeleton` check. It passes only when
//   - the native-inputs classifier and the ledger check both succeeded, and
//   - either native jobs were required and both package suites succeeded and the unsigned `xcodebuild build` step in
//     the App tests job succeeded and that job ended in success or failure (a failing App test step is allowed: App
//     tests are not a required check; a cancelled or missing job is not), or
//   - the classifier said no native input changed and every native job was skipped.
//
//   CHANGES=… NATIVE=… LEDGER=… PACKAGE=… MACUI=… APP_JOB=… UNSIGNED_BUILD=… node scripts/ci/walking-skeleton.mjs
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function verdict(env) {
  const { CHANGES, NATIVE, LEDGER, PACKAGE, MACUI, APP_JOB, UNSIGNED_BUILD } = env;
  const facts = `changes=${CHANGES} native=${NATIVE} ledger=${LEDGER} package-tests=${PACKAGE} ` +
    `package-macui-tests=${MACUI} app-tests=${APP_JOB} unsigned-build-step=${UNSIGNED_BUILD || '(none)'}`;
  const fail = reason => ({ ok: false, facts, reason });
  if (CHANGES !== 'success') return fail('native-inputs classifier did not succeed');
  if (LEDGER !== 'success') return fail('ledger HTML check did not succeed');
  if (NATIVE === 'true') {
    if (PACKAGE !== 'success') return fail('package tests (non-UI) did not succeed');
    if (MACUI !== 'success') return fail('package tests (MacUI) did not succeed');
    // A failed App test step is allowed (App tests are not a required check); a cancelled,
    // skipped or missing job is not, because its build output can no longer be trusted to describe this run.
    if (!['success', 'failure'].includes(APP_JOB)) return fail('App tests job neither succeeded nor failed');
    if (UNSIGNED_BUILD !== 'success') return fail('unsigned xcodebuild build step did not succeed');
    return { ok: true, facts, reason: 'native jobs ran and the required ones succeeded' };
  }
  if (NATIVE === 'false') {
    if ([PACKAGE, MACUI, APP_JOB].some(result => result !== 'skipped') || UNSIGNED_BUILD) {
      return fail('classifier skipped native inputs but a native job did not skip');
    }
    return { ok: true, facts, reason: 'no native input changed; native jobs skipped' };
  }
  return fail('classifier gave no native=true|false output');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = verdict(process.env);
  console.log(result.facts);
  console.log(`walking-skeleton: ${result.ok ? 'PASS' : 'FAIL'} (${result.reason})`);
  process.exitCode = result.ok ? 0 : 1;
}
