#!/usr/bin/env node
/** Machine result provenance comes only from runAppLane's dedicated JSON.
 * Human logs remain useful diagnostics, never the direct/retried oracle. */
import { appendFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function reportAppEvidence(env = process.env) {
  let record;
  try { record = JSON.parse(readFileSync(env.APP_RESULT_PATH || '.build/app-result.json', 'utf8')); } catch { /* unknown */ }
  const repeat = env.APP_REPEAT === undefined || env.APP_REPEAT === '' ? 1 : Number(env.APP_REPEAT);
  const repeated = !Number.isSafeInteger(repeat) || repeat !== 1;
  const eventProvenance = ['push', 'pull_request'].includes(env.EVENT_NAME) ||
    (env.EVENT_NAME === 'workflow_dispatch' && env.APP_TESTS === 'true');
  const requestedDiagnostic = !eventProvenance || Boolean(env.APP_FILTER) || repeated || env.PICSEE_APP_LANE_NO_RETRY === '1';
  const valid = record && record.version === 1 && typeof record.runId === 'string' && record.runId.length > 0 &&
    record.runId === env.APP_RESULT_ID && record.complete === true &&
    [1, 2].includes(record.attempts) && [0, 1, 70].includes(record.status) &&
    (record.filter === null || (typeof record.filter === 'string' && record.filter.trim().length > 0)) &&
    typeof record.retryEnabled === 'boolean' && typeof record.defaultQuarantine === 'boolean' &&
    (record.attempts !== 2 || record.retryEnabled);
  const stepMatches = valid && ((env.APP_TEST_STEP === 'success' && record.status === 0) ||
    (env.APP_TEST_STEP === 'failure' && record.status !== 0));
  // Repeat children each produce a lane record; no individual child's attempts
  // establish direct/retry classification for the complete repeated experiment.
  const known = Boolean(stepMatches && !repeated);
  const diagnostic = requestedDiagnostic || Boolean(valid &&
    (record.filter !== null || !record.retryEnabled || !record.defaultQuarantine));
  const retried = known ? String(record.attempts === 2) : 'unknown';
  const formal = known && env.APP_TEST_STEP === 'success' && !diagnostic;
  let status;
  if (env.EVENT_NAME === 'workflow_dispatch' && env.APP_TESTS === 'false' && env.APP_TEST_STEP === 'skipped') {
    status = 'tests not run (diagnostic dispatch)';
  } else if (env.APP_TEST_STEP !== 'success') {
    status = `failed or not completed (step=${env.APP_TEST_STEP || '(none)'})`;
  } else if (!known) {
    status = `${diagnostic ? 'diagnostic run completed; ' : ''}unknown structured App evidence; retry evidence unknown`;
  } else {
    status = `${diagnostic ? 'diagnostic: ' : ''}${record.attempts === 2 ? 'passed after the one automatic retry' : 'passed directly'}`;
  }
  return { known, retried, formal, diagnostic, status };
}

export function main(env = process.env) {
  const result = reportAppEvidence(env);
  const outputs = `retried=${result.retried}\nformal=${result.formal}\ndiagnostic=${result.diagnostic}\nknown=${result.known}\n`;
  let facts = '';
  try { facts = readFileSync(env.APP_LOG_PATH || '.build/app-tests.log', 'utf8').split('\n')
    .filter(line => /^app-lane(?: quarantine | known-flaky |: (?:known flaky |first-attempt failures:))/.test(line)).join('\n'); } catch { /* missing human logs do not establish a pass */ }
  const summary = `App tests: ${result.status}\nformal App evidence: ${result.formal}\n` +
    'First-attempt log: app-lane-attempt1 (uploaded when produced)\n' + (facts ? `\x60\x60\x60text\n${facts}\n\x60\x60\x60\n` : '');
  if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, outputs);
  if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, summary);
  process.stdout.write(summary);
  return 0;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main();
