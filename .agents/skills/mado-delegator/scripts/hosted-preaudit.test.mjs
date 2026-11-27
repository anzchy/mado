import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { EXIT, appFacingPattern, dispatchAndEvaluate, evaluateFiles, evaluateRun, isAppFacing, main, parseCounts } from './hosted-preaudit.mjs';

// #912: the delegator's hosted App run before audit. Exports are shaped like `gh run view --json …`.
const root = fileURLToPath(new URL('../../../../', import.meta.url));
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
const HEAD = 'a'.repeat(40);
const OTHER = 'b'.repeat(40);
const step = (name, conclusion, status = 'completed') => ({ name, status, conclusion });
const appJob = (conclusion, runStep, extra = []) => ({
  name: 'App tests', status: 'completed', conclusion,
  steps: [step('Record repeat job start', 'skipped'), step('Validate App repeat input', 'success'),
    step('Build unsigned app', 'success'), step('Build App tests', runStep === 'skipped' ? 'skipped' : 'success'),
    step('Run App tests', runStep), step('Upload App repeat logs', 'skipped'), ...extra],
});
const runOf = (overrides = {}, job = appJob('success', 'success')) => ({
  headSha: HEAD, url: 'https://github.com/anzchy/mado/actions/runs/42', status: 'completed', conclusion: job.conclusion,
  event: 'workflow_dispatch', attempt: 1, databaseId: 42,
  jobs: [{ name: 'Native inputs', status: 'completed', conclusion: 'success', steps: [] }, job], ...overrides,
});
const PASS_LOG = 'noise\nTests run: 772, Failures: 0, Errors: 0, Skipped: 0\nTests run: 779, Failures: 0, Errors: 0, Skipped: 1\n';
const FAIL_LOG = 'Tests run: 779, Failures: 1, Errors: 0, Skipped: 0\n';
// app-lane's structured result for run 42 attempt 1 (MADO_APP_RESULT_ID), a full-bundle formal run.
const RESULT = { version: 1, runId: '42-1', complete: true, attempts: 1, status: 0, filter: null, retryEnabled: true,
  defaultQuarantine: true };

test('a completed dispatch with a passing App job and log counts is GREEN and records every field', () => {
  const judged = evaluateRun(runOf(), HEAD, { log: PASS_LOG, result: RESULT });
  assert.equal(judged.verdict, 'GREEN');
  assert.equal(judged.exit, EXIT.green);
  assert.equal(judged.line, `Hosted-Preaudit: GREEN head=${HEAD} run=42 attempt=1 event=workflow_dispatch app-job=success ` +
    'run-step=success counts=779/0 retried=no url=https://github.com/anzchy/mado/actions/runs/42');
});

test('a failing Run App tests step is RED, with the failure count when the log is there', () => {
  const judged = evaluateRun(runOf({}, appJob('failure', 'failure')), HEAD, { log: FAIL_LOG });
  assert.equal(judged.verdict, 'RED');
  assert.equal(judged.exit, EXIT.red);
  assert.match(judged.line, / counts=779\/1 /);
  assert.equal(evaluateRun(runOf({}, appJob('failure', 'failure')), HEAD).verdict, 'RED', 'red without artifacts is still red');
});

test('runs that do not count: stale, rerun, running, cancelled, skipped-native, build-only, repeated, wrong event', () => {
  const cases = [
    [runOf({ headSha: OTHER }), /^NOT COUNTED \(stale: run head b{12}\)$/],
    [runOf({ attempt: 2 }), /^NOT COUNTED \(attempt 2/],
    [runOf({ status: 'in_progress' }), /^NOT COUNTED \(run in_progress\)$/],
    [runOf({ conclusion: 'cancelled' }, appJob('cancelled', 'cancelled')), /^NOT COUNTED \(cancelled\)$/],
    [runOf({}, { name: 'App tests', status: 'completed', conclusion: 'skipped', steps: [] }), /^NOT COUNTED \(App job skipped: no native input\)$/],
    [runOf({}, appJob('success', 'skipped')), /^NOT COUNTED \(App tests not run: run-step=skipped\)$/],
    [runOf({}, { ...appJob('success', 'success'), steps: appJob('success', 'success').steps.map(s =>
      s.name === 'Record repeat job start' ? step(s.name, 'success') : s) }), /^NOT COUNTED \(filtered or repeated dispatch/],
    [runOf({ event: 'push' }), /^NOT COUNTED \(event push\)$/],
    [runOf({ jobs: [] }), /^NOT COUNTED \(App tests job absent\)$/],
    [runOf({ jobs: [appJob('success', 'success'), appJob('success', 'success')] }), /^NOT COUNTED \(App tests job ambiguous\)$/],
  ];
  for (const [run, expected] of cases) {
    const judged = evaluateRun(run, HEAD, { log: PASS_LOG, result: RESULT });
    assert.match(judged.verdict, expected, JSON.stringify(run).slice(0, 120));
    assert.equal(judged.exit, EXIT.notCounted, judged.verdict);
    assert.match(judged.line, new RegExp(`^Hosted-Preaudit: NOT COUNTED \\(.+\\) head=${HEAD} run=`));
  }
});

test('a pass without readable counts, or with counts or a result that contradict it, does not count', () => {
  assert.match(evaluateRun(runOf(), HEAD).verdict, /^NOT COUNTED \(counts unavailable/);
  assert.match(evaluateRun(runOf(), HEAD, { log: FAIL_LOG }).verdict, /^NOT COUNTED \(log counts 779\/1/);
  assert.match(evaluateRun(runOf(), HEAD, { log: PASS_LOG, result: { ...RESULT, status: 1 } }).verdict, /app-result\.json/);
  assert.match(evaluateRun(runOf(), HEAD, { log: PASS_LOG, result: { ...RESULT, attempts: 2 } }).line, / retried=yes /);
});

// #912 fix 1 (gpt F1, F2, opus M1): GREEN needs this run's own complete, unfiltered, formal result and a clean log.
test('a successful filtered run is a valid run but NOT COUNTED (filtered run)', () => {
  for (const judged of [evaluateRun(runOf(), HEAD, { log: PASS_LOG, result: { ...RESULT, filter: 'Issue218' } }),
    evaluateRun(runOf(), HEAD, { log: PASS_LOG, result: RESULT, filter: 'Issue218' })]) {
    assert.equal(judged.verdict, 'NOT COUNTED (filtered run)');
    assert.equal(judged.exit, EXIT.notCounted);
    assert.match(judged.line, / run-step=success counts=779\/0 /);
  }
  assert.equal(evaluateRun(runOf({}, appJob('failure', 'failure')), HEAD, { log: FAIL_LOG, filter: 'Issue218' }).verdict, 'RED',
    'a failing filtered run is still fix input');
});

test('a pass without this run\'s complete, formal app-result.json does not count', () => {
  const cases = [
    [null, /^NOT COUNTED \(app-result\.json missing\)$/],
    [{ ...RESULT, runId: '41-1' }, /^NOT COUNTED \(app-result\.json is from run 41-1, not 42-1\)$/],
    [{ ...RESULT, runId: '' }, /^NOT COUNTED \(app-result\.json is from run unknown, not 42-1\)$/],
    [{ ...RESULT, complete: false }, /^NOT COUNTED \(app-result\.json is not a complete pass\)$/],
    [{ ...RESULT, status: 70 }, /^NOT COUNTED \(app-result\.json is not a complete pass\)$/],
    [{ ...RESULT, version: 2 }, /^NOT COUNTED \(app-result\.json is not a complete pass\)$/],
    [{ ...RESULT, attempts: 0 }, /^NOT COUNTED \(app-result\.json is not a complete pass\)$/],
    [{ ...RESULT, retryEnabled: false }, /^NOT COUNTED \(app-result\.json is not a formal full-bundle result\)$/],
    [{ ...RESULT, defaultQuarantine: false }, /^NOT COUNTED \(app-result\.json is not a formal full-bundle result\)$/],
    [{ ...RESULT, filter: undefined }, /^NOT COUNTED \(app-result\.json is not a formal full-bundle result\)$/],
    ['{"version":1', /^NOT COUNTED \(app-result\.json unreadable\)$/],
    [[RESULT], /^NOT COUNTED \(app-result\.json unreadable\)$/],
  ];
  for (const [result, expected] of cases) {
    const judged = evaluateRun(runOf(), HEAD, { log: PASS_LOG, result });
    assert.match(judged.verdict, expected, JSON.stringify(result));
    assert.equal(judged.exit, EXIT.notCounted);
  }
});

test('evaluate reads a missing or corrupt result file as no evidence, and a present one from this run as GREEN', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-files-'));
  fs.writeFileSync(path.join(dir, 'run.json'), JSON.stringify(runOf()));
  fs.writeFileSync(path.join(dir, 'app-tests.log'), PASS_LOG);
  fs.writeFileSync(path.join(dir, 'corrupt.json'), '{"version":1,');
  fs.writeFileSync(path.join(dir, 'app-result.json'), JSON.stringify(RESULT));
  const files = result => evaluateFiles({ run: path.join(dir, 'run.json'), head: HEAD, log: path.join(dir, 'app-tests.log'),
    result: result && path.join(dir, result) }).verdict;
  assert.equal(files('absent.json'), 'NOT COUNTED (app-result.json missing)');
  assert.equal(files(undefined), 'NOT COUNTED (app-result.json missing)');
  assert.equal(files('corrupt.json'), 'NOT COUNTED (app-result.json unreadable)');
  assert.equal(files('app-result.json'), 'GREEN');
});

test('a log whose last Tests run line has Errors above zero does not count', () => {
  const log = 'Tests run: 779, Failures: 0, Errors: 1, Skipped: 0\n';
  assert.deepEqual(parseCounts(log), { run: 779, failed: 0, errors: 1, skipped: 0 });
  const judged = evaluateRun(runOf(), HEAD, { log, result: RESULT });
  assert.equal(judged.verdict, 'NOT COUNTED (log counts 779/0 errors 1 contradict a passing step)');
  assert.equal(judged.exit, EXIT.notCounted);
});

test('head must be a full SHA; field values cannot inject separators into the line', () => {
  assert.throws(() => evaluateRun(runOf(), HEAD.slice(0, 7)), /full 40-hex/);
  const judged = evaluateRun(runOf({ url: 'https://x | y\nz' }), HEAD, { log: PASS_LOG });
  assert.doesNotMatch(judged.line, /[|\n]/);
});

test('parseCounts reads the last combined Tests run line', () => {
  assert.deepEqual(parseCounts(PASS_LOG), { run: 779, failed: 0, errors: 0, skipped: 1 });
  assert.equal(parseCounts('no counts here'), null);
  assert.equal(parseCounts(null), null);
});

test('app-facing uses owner-gates.sh\'s own pattern', () => {
  const pattern = appFacingPattern();
  const declared = /^app_facing='([^']+)'$/m.exec(read('.agents/skills/mado-delegator/scripts/owner-gates.sh'))[1];
  assert.equal(pattern.source, new RegExp(declared).source);
  assert.equal(isAppFacing(['AppTests/Issue218LayoutFixTests.swift'], pattern), true);
  assert.equal(isAppFacing(['App/UI/SettingsPanelWindow.swift'], pattern), true);
  assert.equal(isAppFacing(['project.yml'], pattern), true);
  assert.equal(isAppFacing(['docs/x.md', 'scripts/ci/a.mjs', 'Packages/MadoKit/Sources/MadoCore/A.swift'], pattern), false);
  assert.throws(() => appFacingPattern('no pattern'), /app_facing/);
});

function repo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-'));
  const git = (...args) => spawnSync('git', ['-C', dir, ...args], { encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'base');
  const base = git('rev-parse', 'HEAD').stdout.trim();
  fs.mkdirSync(path.join(dir, 'AppTests'));
  fs.writeFileSync(path.join(dir, 'AppTests/A.swift'), 'x');
  git('add', 'AppTests/A.swift');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'app');
  const head = git('rev-parse', 'HEAD').stdout.trim();
  // A bare origin holding the branch at head.
  const origin = fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-origin-'));
  spawnSync('git', ['init', '-q', '--bare', origin]);
  git('remote', 'add', 'origin', origin);
  git('push', '-q', 'origin', 'HEAD:refs/heads/tooling/912-x');
  return { dir, base, head };
}

test('app-facing CLI classifies a real diff', () => {
  const { dir, base, head } = repo();
  let out = '';
  assert.equal(main(['app-facing', '--worktree', dir, '--base', base, '--head', head], { stdout: t => { out += t; } }), 0);
  assert.equal(out, 'app-facing=yes\n');
});

test('dispatch refuses unless origin has exactly the verified head', () => {
  const { dir, base } = repo();
  const calls = [];
  let err = '';
  const exit = main(['dispatch', '--worktree', dir, '--ref', 'tooling/912-x', '--head', base.padEnd(40, '0').slice(0, 40)],
    { stderr: t => { err += t; }, gh: args => { calls.push(args); return { status: 0, stdout: '' }; } });
  assert.equal(exit, EXIT.notCounted);
  assert.match(err, /push the verified head first/);
  assert.deepEqual(calls, [], 'no dispatch for a branch that is not at the head');
});

test('dispatch runs ci.yml with app_tests=true on the ref, finds that head\'s new run, exports and evaluates it', () => {
  const { dir, head } = repo();
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-out-'));
  const calls = [];
  let clock = Date.parse('2026-11-27T00:00:00Z');
  const run = { ...runOf(), headSha: head, databaseId: 77 };
  const gh = args => {
    calls.push(args);
    if (args[0] === 'run' && args[1] === 'list') {
      // First poll: only an older run for the same head; second poll: the new one.
      const older = { databaseId: 70, headSha: head, createdAt: '2026-11-26T00:00:00Z' };
      const fresh = { databaseId: 77, headSha: head, createdAt: '2026-11-27T00:00:10Z' };
      return { status: 0, stdout: JSON.stringify(calls.filter(c => c[1] === 'list').length > 1 ? [fresh, older] : [older]) };
    }
    if (args[0] === 'run' && args[1] === 'view') return { status: 0, stdout: JSON.stringify(run) };
    if (args[0] === 'run' && args[1] === 'download') {
      const dest = args[args.indexOf('-D') + 1];
      fs.mkdirSync(dest, { recursive: true });
      fs.writeFileSync(path.join(dest, 'app-tests.log'), PASS_LOG);
      fs.writeFileSync(path.join(dest, 'app-result.json'), JSON.stringify(RESULT));
      fs.writeFileSync(path.join(dest, 'app-result.json'), JSON.stringify({ ...RESULT, runId: '77-1' }));
    }
    return { status: 0, stdout: '' };
  };
  const judged = dispatchAndEvaluate({ worktree: dir, ref: 'tooling/912-x', head, out, gh, sleep: () => { clock += 5000; },
    now: () => clock, log: () => {} });
  const beforeDispatch = calls.splice(0, calls.findIndex(c => c[0] === 'workflow'));
  assert.deepEqual(beforeDispatch.map(c => c.slice(0, 2).join(' ')), ['run list'], 'the runs are listed once before the dispatch');
  assert.deepEqual(calls[0], ['workflow', 'run', 'ci.yml', '--ref', 'tooling/912-x', '-f', 'app_tests=true', '-f', 'app_filter=', '-f', 'app_repeat=1']);
  assert.ok(calls.some(c => c.join(' ') === 'run watch 77 --interval 30'), 'waits on the new run, not the older one');
  assert.equal(judged.verdict, 'GREEN');
  assert.match(judged.line, / run=77 .* counts=779\/0 /);
  assert.equal(JSON.parse(fs.readFileSync(path.join(out, 'run.json'), 'utf8')).databaseId, 77);
});

// #912 fix 1 (gpt F3, opus L5, M1, L3): the judged run is the one this dispatch created, its artifact is downloaded
// into a directory of its own, and a runtime failure is one NOT COUNTED line (exit 3), never a usage error.
const T0 = Date.parse('2026-11-27T00:00:00Z');
const at = seconds => new Date(T0 + seconds * 1000).toISOString();
/**
 * A fake gh. `before` is what `run list` shows before the dispatch; `after(poll)` what it shows on the n-th list after
 * it (1-based; the list after `run watch` is the last poll). Every listed run uses the repo head unless it says otherwise.
 */
function fakeGh(head, { before = [], after = () => [], download = 'pass', dispatch = 0, view = 0 } = {}) {
  const calls = [];
  let dispatched = false, polls = 0;
  const gh = args => {
    calls.push(args);
    const key = args.slice(0, 2).join(' ');
    if (key === 'workflow run') { dispatched = true; return { status: dispatch, stdout: '', stderr: dispatch ? 'HTTP 422' : '' }; }
    if (key === 'run list') {
      const listed = dispatched ? after(++polls) : before;
      return { status: 0, stdout: JSON.stringify(listed.map(r => ({ headSha: head, ...r }))) };
    }
    if (key === 'run view') {
      const id = Number(args[2]);
      return { status: view, stdout: view ? '' : JSON.stringify({ ...runOf(), headSha: head, databaseId: id }), stderr: view ? 'HTTP 502' : '' };
    }
    if (key === 'run download') {
      if (download !== 'pass') return { status: 1, stdout: '', stderr: 'no artifact' };
      const dest = args[args.indexOf('-D') + 1];
      fs.mkdirSync(dest, { recursive: true });
      fs.writeFileSync(path.join(dest, 'app-tests.log'), PASS_LOG);
      fs.writeFileSync(path.join(dest, 'app-result.json'), JSON.stringify({ ...RESULT, runId: `${args[2]}-1` }));
    }
    return { status: 0, stdout: '' };
  };
  return { gh, calls };
}
function dispatchWith(fake, extra = {}) {
  const { dir, head } = extra.repo ?? repo();
  const out = extra.out ?? fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-out-'));
  let clock = T0;
  let judged;
  try {
    judged = dispatchAndEvaluate({ worktree: dir, ref: 'tooling/912-x', head, out, gh: fake.gh, log: () => {},
      sleep: ms => { clock += ms; }, now: () => clock, findTimeoutMs: 60_000 });
  } catch (error) {
    judged = { verdict: `threw: ${error.message}`, exit: null, line: '' }; // a throw is a wrong answer, not a crash
  }
  return { judged, out, head };
}
const watched = calls => calls.filter(c => c[0] === 'run' && c[1] === 'watch').map(c => c[2]);

test('a passing run on the same head 10 s before the dispatch is never the judged run', () => {
  const prior = { databaseId: 70, createdAt: at(-10) };
  const fresh = { databaseId: 77, createdAt: at(12) };
  for (const before of [[prior], []]) { // listed before the dispatch, or missing from that list (no early window)
    const r = repo();
    const fixed = fakeGh(r.head, { before: before.map(b => ({ ...b })), after: poll => poll === 1 ? [prior] : [fresh, prior] });
    const { judged } = dispatchWith(fixed, { repo: r });
    assert.deepEqual(watched(fixed.calls), ['77'], JSON.stringify(before));
    assert.equal(judged.verdict, 'GREEN');
    assert.match(judged.line, / run=77 /);
  }
});

test('two new runs for one dispatch are NOT COUNTED (ambiguous dispatch), whenever the second one shows', () => {
  const a = { databaseId: 77, createdAt: at(5) };
  const b = { databaseId: 78, createdAt: at(6) };
  const r1 = repo();
  const together = fakeGh(r1.head, { after: () => [b, a] });
  const first = dispatchWith(together, { repo: r1 }).judged;
  assert.equal(first.verdict, 'NOT COUNTED (ambiguous dispatch: runs 77, 78)');
  assert.equal(first.exit, EXIT.notCounted);
  assert.deepEqual(watched(together.calls), [], 'no wait on a run that may not be ours');
  const r2 = repo();
  const later = fakeGh(r2.head, { after: poll => poll === 1 ? [a] : [b, a] });
  const second = dispatchWith(later, { repo: r2 }).judged;
  assert.equal(second.verdict, 'NOT COUNTED (ambiguous dispatch: runs 77, 78)');
  assert.match(second.line, / run=77 /);
});

test('the artifact is downloaded into a fresh directory per run; stale files from an earlier dispatch are never read', () => {
  const r = repo();
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-out-'));
  const stale = path.join(out, 'app-crash-evidence');
  fs.mkdirSync(stale);
  fs.writeFileSync(path.join(stale, 'app-tests.log'), PASS_LOG);
  fs.writeFileSync(path.join(stale, 'app-result.json'), JSON.stringify({ ...RESULT, runId: '77-1' }));
  const failing = fakeGh(r.head, { after: () => [{ databaseId: 77, createdAt: at(5) }], download: 'fail' });
  const { judged } = dispatchWith(failing, { repo: r, out });
  const download = failing.calls.find(c => c[1] === 'download');
  assert.equal(download[download.indexOf('-D') + 1], path.join(out, 'run-77', 'app-crash-evidence'));
  assert.equal(judged.verdict, 'NOT COUNTED (counts unavailable: app-tests.log missing from app-crash-evidence)');
  // A directory left for that run id is refused, not reused.
  const again = fakeGh(r.head, { after: () => [{ databaseId: 77, createdAt: at(5) }] });
  const reused = dispatchWith(again, { repo: r, out }).judged;
  assert.equal(reused.verdict, `NOT COUNTED (evidence directory ${path.join(out, 'run-77')} already exists)`);
  assert.equal(again.calls.filter(c => c[1] === 'download').length, 0);
});

test('runtime failures print one NOT COUNTED line and exit 3', () => {
  const cases = [
    [{ dispatch: 1, after: () => [] }, /^NOT COUNTED \(gh workflow run failed: HTTP 422\)$/, 'unknown'],
    [{ after: () => [] }, /^NOT COUNTED \(dispatched run did not appear within 60 s\)$/, 'unknown'],
    [{ after: () => [{ databaseId: 77, createdAt: at(5) }], view: 1 }, /^NOT COUNTED \(gh run view failed: HTTP 502\)$/, '77'],
  ];
  for (const [options, expected, run] of cases) {
    const r = repo();
    const fake = fakeGh(r.head, options);
    const { judged } = dispatchWith(fake, { repo: r });
    assert.match(judged.verdict, expected);
    assert.equal(judged.exit, EXIT.notCounted);
    assert.equal(judged.line, `Hosted-Preaudit: ${judged.verdict} head=${r.head} run=${run} attempt=unknown event=unknown ` +
      'app-job=unknown run-step=unknown counts=unknown retried=unknown url=unknown');
  }
  // A failed list before the dispatch stops before anything is dispatched.
  const r = repo();
  const calls = [];
  const { judged } = dispatchWith({ gh: args => { calls.push(args); return { status: 1, stdout: '', stderr: 'HTTP 401' }; } }, { repo: r });
  assert.equal(judged.exit, EXIT.notCounted);
  assert.equal(judged.verdict, 'NOT COUNTED (gh run list failed: HTTP 401)');
  assert.equal(calls.filter(c => c[0] === 'workflow').length, 0);
  // Through the CLI: the line goes to stdout, the exit is 3, and the remote-head refusal is a line too.
  const cli = repo();
  let out = '';
  assert.equal(main(['dispatch', '--worktree', cli.dir, '--ref', 'tooling/912-x', '--head', cli.head, '--out',
    fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-out-'))],
  { stdout: t => { out += t; }, stderr: () => {}, gh: fakeGh(cli.head, { dispatch: 1 }).gh }), EXIT.notCounted);
  assert.match(out, /^Hosted-Preaudit: NOT COUNTED \(gh workflow run failed: HTTP 422\) head=[0-9a-f]{40} run=unknown /);
  out = '';
  assert.equal(main(['dispatch', '--worktree', cli.dir, '--ref', 'tooling/912-x', '--head', OTHER],
    { stdout: t => { out += t; }, stderr: () => {}, gh: () => ({ status: 0, stdout: '[]' }) }), EXIT.notCounted);
  assert.match(out, new RegExp(`^Hosted-Preaudit: NOT COUNTED \\(origin/tooling/912-x is [0-9a-f]{40}, not ${OTHER}: push the verified head first`));
  assert.equal(main(['dispatch', '--worktree', cli.dir, '--ref', 'tooling/912-x', '--head', 'abc'],
    { stdout: () => {}, stderr: () => {}, gh: () => ({ status: 0, stdout: '[]' }) }), EXIT.usage, 'a bad --head is a usage error');
});

test('evaluate CLI exits by verdict and reports usage errors', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hosted-preaudit-cli-'));
  fs.writeFileSync(path.join(dir, 'run.json'), JSON.stringify(runOf({}, appJob('failure', 'failure'))));
  let out = '';
  assert.equal(main(['evaluate', '--run', path.join(dir, 'run.json'), '--head', HEAD], { stdout: t => { out += t; } }), EXIT.red);
  assert.match(out, /^Hosted-Preaudit: RED /);
  let err = '';
  assert.equal(main(['evaluate', '--run'], { stderr: t => { err += t; } }), EXIT.usage);
  assert.match(err, /usage:/);
});

// The delegator flow names the rule where the delegator reads it (SKILL step 4, the audit request, guide §5.8).
test('SKILL, audit request and PR-body guide state the dispatch-before-audit rule and its record', () => {
  const skill = read('.agents/skills/mado-delegator/SKILL.md');
  const step4 = skill.slice(skill.indexOf('4. **Audit**'), skill.indexOf('5. **Apply verdict**'));
  assert.match(step4, /hosted-preaudit\.mjs dispatch/);
  assert.match(step4, /before (?:the )?audits?/i);
  assert.match(step4, /RED.*no audit/i);
  assert.match(step4, /hosted-only failure.*not audit-ready/i);
  assert.match(step4, /head change/i);
  assert.match(step4, /diagnostic/i);
  const request = read('.agents/skills/mado-delegator/references/templates/audit-request-template.md');
  assert.match(request, /^Hosted App before audit: `Hosted-Preaudit: GREEN head=<40-hex head> run=<id> attempt=1 /m);
  assert.match(request, /`n\/a — not App-facing`/);
  const guide = read('.agents/skills/mado-delegator/references/guide.md');
  const pr = guide.slice(guide.indexOf('### 5.8 PR and merge'));
  assert.match(pr, /Hosted-Preaudit:/);
  assert.match(pr, /diagnostic: it never becomes the `app-tests` Gates row/);
  assert.match(step4, /`retried=yes`.*not enough.*hosted-only failure/is, 'a pass after the automatic retry does not clear a hosted-only fix');
  assert.match(step4, /`--filter`.*NOT COUNTED \(filtered run\)/is);
  const fix = read('.agents/skills/mado-delegator/references/templates/confirm-and-fix-templates.md');
  assert.match(fix, /hosted-only failure/i);
});
