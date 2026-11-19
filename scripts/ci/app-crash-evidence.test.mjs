// #732: when the App test process dies mid-run, the App tests job states the signal or status, the last test that
// started but did not finish, and the uncaught exception text, and keeps the log, crash reports and result bundle.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crashSummary } from './app-crash-evidence.mjs';

const fixture = name => fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));
const read = name => readFileSync(fixture(name), 'utf8');
const script = fileURLToPath(new URL('./app-crash-evidence.mjs', import.meta.url));
const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');

// Run 43871888435 attempt 2 (PR #730): the full App lane's first-attempt artifact, ending mid-test.
const FULL_LANE = read('i732-app-43871888435.txt');
// Run 43882248877 iteration 1: the filtered repeat of the same test, which kept the uncaught exception text.
const REPEAT = read('i732-repeat-43882248877.txt');
const CRASHED_TEST = 'viewerRecogniseTextNoticeOpensEditablePanelCopyAndEscape()';
const EXCEPTION = 'NSInternalInconsistencyException: Invalid parameter not satisfying: itemSize.width > 0 && itemSize.height > 0';
const report = name => ({ name, text: read(name) });
const FINISHED = FULL_LANE.split('\n').slice(0, 30).join('\n');

const line = (summary, key) => summary.lines.find(entry => entry.startsWith(`crash.${key}=`));

test('#732 the real full-lane mid-run exit names status 70 and the unfinished test, with no invented signal', () => {
  const summary = crashSummary({ log: FULL_LANE, status: 70 });
  assert.equal(summary.crashed, true);
  assert.equal(line(summary, 'status'), 'crash.status=70');
  assert.equal(line(summary, 'signal'), 'crash.signal=unknown');
  assert.equal(line(summary, 'last_test'), `crash.last_test=${CRASHED_TEST}`);
  assert.equal(line(summary, 'unfinished'), 'crash.unfinished=1');
  assert.equal(line(summary, 'exception'), 'crash.exception=none');
  assert.equal(line(summary, 'reports'), 'crash.reports=0');
});

test('#732 the uncaught exception text the repeat run kept is stated with the unfinished test', () => {
  const summary = crashSummary({ log: REPEAT, status: 70 });
  assert.equal(summary.crashed, true);
  assert.equal(line(summary, 'last_test'), `crash.last_test=${CRASHED_TEST}`);
  assert.equal(line(summary, 'exception'), `crash.exception=${EXCEPTION}`);
});

test('#732 a real xctest SIGABRT crash report supplies the signal; abort() called is not an exception', () => {
  const summary = crashSummary({ log: FULL_LANE, status: 70, reports: [report('i732-xctest-sigabrt.ips')] });
  assert.equal(line(summary, 'signal'), 'crash.signal=SIGABRT (Abort trap: 6)');
  assert.equal(line(summary, 'exception'), 'crash.exception=none');
  assert.equal(line(summary, 'reports'), 'crash.reports=1');
  assert.ok(summary.lines.includes('crash.report=i732-xctest-sigabrt.ips process=xctest signal=SIGABRT'), summary.lines.join('\n'));
});

test('#732 a crash report with an uncaught NSException supplies the exception text when the log lost it', () => {
  // Derived: the real SIGABRT report with the exception text of run 43882248877 in its application-specific info.
  const summary = crashSummary({ log: FULL_LANE, status: 70, reports: [report('i732-xctest-nsexception-derived.ips')] });
  assert.equal(line(summary, 'exception'), `crash.exception=${EXCEPTION}`);
  assert.equal(line(summary, 'last_test'), `crash.last_test=${CRASHED_TEST}`);
});

test('#732 a legacy .crash text report supplies its signal and application-specific exception', () => {
  // Derived text in the legacy crash-report layout.
  const text = [
    'Process:               xctest [4242]',
    'Exception Type:        EXC_CRASH (SIGABRT)',
    'Application Specific Information:',
    "*** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 3 beyond bounds'",
    '',
    'Thread 0 Crashed:',
  ].join('\n');
  const summary = crashSummary({ log: FULL_LANE, status: 70, reports: [{ name: 'xctest_2026-11-16.crash', text }] });
  assert.equal(line(summary, 'signal'), 'crash.signal=SIGABRT');
  assert.equal(line(summary, 'exception'), 'crash.exception=NSRangeException: index 3 beyond bounds');
});

test('#732 completed runs, including ordinary test failures, are not reported as crashes', () => {
  for (const status of [0, 1]) {
    const summary = crashSummary({ log: FINISHED, status });
    assert.equal(summary.crashed, false, `status ${status}`);
    assert.deepEqual(summary.lines, [`crash.detected=no status=${status}`]);
  }
});

test('#732 a missing status with the supervisor marker still counts as a crash and never as a pass', () => {
  const summary = crashSummary({ log: FULL_LANE });
  assert.equal(summary.crashed, true);
  assert.equal(line(summary, 'status'), 'crash.status=unknown');
  assert.ok(!summary.lines.some(entry => /pass/i.test(entry)));
});

test('#732 parameterized tests end with their test-case count; their case lines are not tests', () => {
  // Lines 6743-6746 of run 43871888435 attempt 2 (GitHub timestamps and step prefixes removed), then a crash.
  const log = [
    '◇ Test sidebar425TeardownJoinsDuplicateCancelEvenForCancelledCaller(cancelled:) started.',
    '◇ Test case passing 1 argument cancelled → false to sidebar425TeardownJoinsDuplicateCancelEvenForCancelledCaller(cancelled:) started.',
    '◇ Test case passing 1 argument cancelled → true to sidebar425TeardownJoinsDuplicateCancelEvenForCancelledCaller(cancelled:) started.',
    '✔ Test sidebar425TeardownJoinsDuplicateCancelEvenForCancelledCaller(cancelled:) with 2 test cases passed after 0.255 seconds.',
    '◇ Test issue690RegrantFallsBackToThePanel(_:) started.',
    '◇ Test case passing 1 argument answer → "cancel" to issue690RegrantFallsBackToThePanel(_:) started.',
    'status-channel: invalid supervisor exit',
  ].join('\n');
  const summary = crashSummary({ log, status: 70 });
  assert.equal(line(summary, 'last_test'), 'crash.last_test=issue690RegrantFallsBackToThePanel(_:)');
  assert.equal(line(summary, 'unfinished'), 'crash.unfinished=1');
});

test('#732 XCTest-style cases and several unfinished tests name the most recently started one', () => {
  const log = [
    "Test Case '-[MadoAppTests.SmokeTests testOpens]' started.",
    "Test Case '-[MadoAppTests.SmokeTests testOpens]' passed (0.101 seconds).",
    '◇ Test slowTest() started.',
    "Test Case '-[MadoAppTests.SmokeTests testCloses]' started.",
    'Fatal error: Unexpectedly found nil while unwrapping an Optional value',
  ].join('\n');
  const summary = crashSummary({ log, status: 70 });
  assert.equal(line(summary, 'last_test'), 'crash.last_test=-[MadoAppTests.SmokeTests testCloses]');
  assert.equal(line(summary, 'unfinished'), 'crash.unfinished=2');
  assert.equal(line(summary, 'exception'), 'crash.exception=Fatal error: Unexpectedly found nil while unwrapping an Optional value');
});

test('#732 a child killed by SIGABRT mid-test produces a summary with the signal and the last started test', () => {
  const child = spawnSync(process.execPath, ['-e', [
    "process.stdout.write('◇ Test run started.\\n◇ Test finishes() started.\\n✔ Test finishes() passed after 0.001 seconds.\\n');",
    "process.stdout.write('◇ Test abortsMidway() started.\\n');",
    "process.kill(process.pid, 'SIGABRT');",
    'setTimeout(() => {}, 10000);',
  ].join('\n')], { encoding: 'utf8', timeout: 20000 });
  assert.equal(child.signal, 'SIGABRT', 'the child really died from SIGABRT');
  const summary = crashSummary({ log: child.stdout + child.stderr, status: child.status, signal: child.signal });
  assert.equal(summary.crashed, true);
  assert.equal(line(summary, 'signal'), 'crash.signal=SIGABRT');
  assert.equal(line(summary, 'last_test'), 'crash.last_test=abortsMidway()');
  assert.equal(line(summary, 'status'), 'crash.status=unknown');
});

const runCli = (args, env = {}) => spawnSync(process.execPath, [script, ...args],
  { encoding: 'utf8', env: { ...process.env, GITHUB_STEP_SUMMARY: '', ...env } });

test('#732 the CLI keeps reports from the job window, writes the summary and always exits 0', () => {
  const dir = mkdtempSync(join(tmpdir(), 'i732-cli-'));
  try {
    const reports = join(dir, 'reports'), out = join(dir, 'out'), stepSummary = join(dir, 'step-summary.md');
    mkdirSync(reports);
    copyFileSync(fixture('i732-xctest-sigabrt.ips'), join(reports, 'xctest-2026-11-16-132755.ips'));
    copyFileSync(fixture('i732-xctest-sigabrt.ips'), join(reports, 'xctest-2026-11-01-000000.ips'));
    copyFileSync(fixture('i732-xctest-sigabrt.ips'), join(reports, 'Safari-2026-11-16-132755.ips'));
    copyFileSync(fixture('i732-xctest-nsexception-derived.ips'), join(reports, 'Mado-2026-11-16-132756.ips'));
    const since = Date.now() - 60_000;
    const old = (since - 3_600_000) / 1000;
    utimesSync(join(reports, 'xctest-2026-11-01-000000.ips'), old, old);
    writeFileSync(join(dir, 'app-tests.log'), FULL_LANE);
    writeFileSync(join(dir, 'app-result.json'), JSON.stringify({ version: 1, complete: false, status: 70 }));
    writeFileSync(stepSummary, '');
    const run = runCli(['--log', join(dir, 'app-tests.log'), '--result', join(dir, 'app-result.json'),
      '--since-ms', String(since), '--out', out, '--reports-dir', reports, '--reports-dir', join(dir, 'missing')],
    { GITHUB_STEP_SUMMARY: stepSummary });
    assert.equal(run.status, 0, run.stderr);
    for (const expected of ['crash.status=70', 'crash.signal=SIGABRT (Abort trap: 6)', `crash.last_test=${CRASHED_TEST}`,
      `crash.exception=${EXCEPTION}`, 'crash.reports=2']) {
      assert.ok(run.stdout.split('\n').includes(expected), `stdout has ${expected}`);
      assert.ok(readFileSync(stepSummary, 'utf8').includes(expected), `job summary has ${expected}`);
    }
    assert.ok(existsSync(join(out, 'xctest-2026-11-16-132755.ips')));
    assert.ok(existsSync(join(out, 'Mado-2026-11-16-132756.ips')));
    assert.ok(!existsSync(join(out, 'xctest-2026-11-01-000000.ips')), 'reports from before the job are not kept');
    assert.ok(!existsSync(join(out, 'Safari-2026-11-16-132755.ips')), 'other processes are not kept');
    assert.match(readFileSync(join(out, 'crash-summary.txt'), 'utf8'), /^crash\.last_test=viewerRecogniseText/m);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('#732 the CLI states a clean run in one line and still exits 0 when inputs are missing', () => {
  const dir = mkdtempSync(join(tmpdir(), 'i732-cli-'));
  try {
    writeFileSync(join(dir, 'app-result.json'), JSON.stringify({ version: 1, complete: true, status: 0 }));
    writeFileSync(join(dir, 'app-tests.log'), FINISHED);
    const clean = runCli(['--log', join(dir, 'app-tests.log'), '--result', join(dir, 'app-result.json'),
      '--since-ms', '0', '--out', join(dir, 'out'), '--reports-dir', join(dir, 'none')]);
    assert.equal(clean.status, 0, clean.stderr);
    assert.match(clean.stdout, /^crash\.detected=no status=0$/m);
    const missing = runCli(['--log', join(dir, 'nope.log'), '--result', join(dir, 'nope.json'), '--outcome', 'failure',
      '--since-ms', '0', '--out', join(dir, 'out2'), '--reports-dir', join(dir, 'none')]);
    assert.equal(missing.status, 0, missing.stderr);
    assert.match(missing.stdout, /^crash\.status=unknown$/m);
    assert.match(missing.stdout, /^crash\.last_test=unknown$/m);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// Workflow shape: thin YAML around the module, evidence only, no retry, placed before Save DerivedData.
const jobBlock = id => {
  const match = workflow.match(new RegExp(`^  ${id}:\\n([\\s\\S]*?)(?=^  [a-z][a-z0-9-]*:\\n|(?![\\s\\S]))`, 'm'));
  assert.ok(match, `job ${id} exists`);
  return match[1];
};
const steps = job => jobBlock(job).split(/^      - name: /m).slice(1);
const stepNames = job => steps(job).map(step => step.split('\n')[0]);
const stepNamed = (job, name) => {
  const found = steps(job).find(step => step.startsWith(`${name}\n`));
  assert.ok(found, `${job} has step ${name}`);
  return found;
};

test('#732 the App tests job records the crash window start before the App run', () => {
  const names = stepNames('app-tests');
  const start = names.indexOf('Record App crash window start');
  assert.ok(start >= 0 && start < names.indexOf('Run App tests'), names.join(' | '));
  const step = stepNamed('app-tests', 'Record App crash window start');
  assert.doesNotMatch(step, /^        if:/m, 'recorded for every App tests run');
  assert.ok(step.includes(`echo "APP_CRASH_SINCE_MS=$(node -p 'Date.now()')" >> "$GITHUB_ENV"`));
});

test('#732 crash evidence is summarized and uploaded on every outcome, directly before Save DerivedData', () => {
  const names = stepNames('app-tests');
  const save = names.indexOf('Save DerivedData');
  assert.deepEqual(names.slice(save - 2, save), ['Summarize App crash evidence', 'Upload App crash evidence']);

  const summarize = stepNamed('app-tests', 'Summarize App crash evidence');
  assert.match(summarize, /^        if: always\(\)$/m);
  assert.match(summarize, /^        continue-on-error: true$/m);
  assert.match(summarize, /^          APP_TEST_STEP: \$\{\{ steps\.app-run\.outcome \}\}$/m);
  for (const arg of ['node scripts/ci/app-crash-evidence.mjs', '--log .build/app-tests.log',
    '--result .build/app-result.json', '--since-ms "$APP_CRASH_SINCE_MS"', '--outcome "$APP_TEST_STEP"',
    '--out .build/crash-evidence', '--reports-dir "$HOME/Library/Logs/DiagnosticReports"',
    '--reports-dir /Library/Logs/DiagnosticReports']) assert.ok(summarize.includes(arg), arg);
  assert.doesNotMatch(summarize, /app-lane\.mjs|app-repeat\.mjs|heavy-lock|GITHUB_OUTPUT/, 'evidence only: no re-run, no outputs');

  const upload = stepNamed('app-tests', 'Upload App crash evidence');
  assert.match(upload, /^        if: always\(\)$/m);
  assert.match(upload, /^        continue-on-error: true$/m);
  assert.match(upload, /^        uses: actions\/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4\.6\.2$/m);
  assert.match(upload, /^          if-no-files-found: ignore$/m);
  assert.match(upload, /^          retention-days: 7$/m);
  for (const path of ['.build/app-tests.log', '.build/app-result.json', '.build/crash-evidence',
    '.build/hosted-*/result.xcresult']) assert.ok(upload.split('\n').includes(`            ${path}`), path);
});

test('#732 a mid-run exit still fails the App run step: no retry and no continue-on-error were added there', () => {
  const run = stepNamed('app-tests', 'Run App tests');
  assert.doesNotMatch(run, /continue-on-error/);
  assert.doesNotMatch(run, /app-crash-evidence|retry/i);
});
