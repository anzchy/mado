#!/usr/bin/env node
// The required `Walking skeleton` check. It passes only when the ledger check and both package suites succeeded and
// the unsigned `xcodebuild build` step in the App tests job succeeded, whatever the later App test steps did (App
// tests are not a required check).
//
//   LEDGER=… PACKAGE=… MACUI=… APP_JOB=… UNSIGNED_BUILD=… node scripts/ci/walking-skeleton.mjs
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function verdict(env) {
  const { LEDGER, PACKAGE, MACUI, APP_JOB, UNSIGNED_BUILD } = env;
  const facts = `ledger=${LEDGER} package-tests=${PACKAGE} package-macui-tests=${MACUI} app-tests=${APP_JOB} ` +
    `unsigned-build-step=${UNSIGNED_BUILD || '(none)'}`;
  const fail = reason => ({ ok: false, facts, reason });
  if (LEDGER !== 'success') return fail('ledger HTML check did not succeed');
  if (PACKAGE !== 'success') return fail('package tests (non-UI) did not succeed');
  if (MACUI !== 'success') return fail('package tests (MacUI) did not succeed');
  if (UNSIGNED_BUILD !== 'success') return fail('unsigned xcodebuild build step did not succeed');
  return { ok: true, facts, reason: 'ledger check, both package suites and the unsigned build succeeded' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = verdict(process.env);
  console.log(result.facts);
  console.log(`walking-skeleton: ${result.ok ? 'PASS' : 'FAIL'} (${result.reason})`);
  process.exitCode = result.ok ? 0 : 1;
}
