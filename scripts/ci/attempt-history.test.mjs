// #788 item 4: failed job attempts hidden by reruns, listed per PR or head SHA, and the failing tests without a ticket.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  parseFailingTests, collectHistory, fixtureGetter, classify, loadTicketLists, render,
} from './attempt-history.mjs';

const FIX = 'scripts/ci/fixtures/attempt-history';
const pr799 = JSON.parse(readFileSync(`${FIX}/pr799.json`, 'utf8'));
const sha796 = JSON.parse(readFileSync(`${FIX}/sha-39eda32e.json`, 'utf8'));
const SCRIPT = 'scripts/ci/attempt-history.mjs';
const run = (args, opts = {}) => spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', ...opts });

// An empty ticket-list root, so the repo's own lists never decide a test's outcome by accident.
function emptyLists() {
  const root = mkdtempSync(join(tmpdir(), 'attempt-history-'));
  mkdirSync(join(root, 'scripts/tdd'), { recursive: true });
  mkdirSync(join(root, '.agents/skills/mado-verify'), { recursive: true });
  mkdirSync(join(root, 'scripts/ci'), { recursive: true });
  writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), '[]\n');
  writeFileSync(join(root, '.agents/skills/mado-verify/known-flakes.json'), '{"flakes":[]}\n');
  writeFileSync(join(root, 'scripts/ci/known-flaky.mjs'), 'export const knownFlaky = [];\n');
  return root;
}

test('node spec log: each failing test once, from the failing-tests section', () => {
  const log = [
    '2026-11-20T14:47:59.4555730Z ✖ ownership integration hosted step preserves crash runner outcome and report (656.47925ms)',
    '2026-11-20T14:48:38.6319120Z ✖ failing tests:',
    '2026-11-20T14:48:38.6319950Z test at scripts/ci/app-compare.test.mjs:50:1',
    '2026-11-20T14:48:38.6320980Z ✖ ownership integration hosted step preserves crash runner outcome and report (656.47925ms)',
    '2026-11-20T14:48:38.6322050Z   AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:',
  ].join('\n');
  assert.deepEqual(parseFailingTests(log), ['ownership integration hosted step preserves crash runner outcome and report']);
});

test('node spec log without a failing-tests section still yields the ✖ test lines, not suite totals', () => {
  const log = '✔ a passes (1ms)\n✖ b fails (2.5ms)\n✖ c fails (3s)\nℹ fail 2\n';
  assert.deepEqual(parseFailingTests(log), ['b fails', 'c fails']);
});

test('TAP log: not ok names, de-duplicated, skipping todo and skip directives', () => {
  const log = [
    '2026-11-20T14:49:41.1483922Z # Subtest: AC-4 INT and TERM keep shared lock through group kill grace',
    '2026-11-20T14:49:41.1486339Z not ok 892 - AC-4 INT and TERM keep shared lock through group kill grace',
    '    not ok 3 - nested case',
    'not ok 893 - later one # TODO not done',
    'not ok 894 - skipped one # SKIP no zsh',
    'not ok 895 - AC-4 INT and TERM keep shared lock through group kill grace',
    'ok 896 - fine',
  ].join('\n');
  assert.deepEqual(parseFailingTests(log), ['AC-4 INT and TERM keep shared lock through group kill grace', 'nested case']);
});

test('Swift Testing and XCTest logs: failed tests, not issue lines or the whole-run line', () => {
  const log = [
    '2026-11-20T10:07:11.6840380Z ✘ Test issue507FolderPathsComplete(legacyScanner:) recorded an issue with 1 argument legacyScanner → false at Issue507AliasFolderScanTests.swift:125:9: Expectation failed',
    '2026-11-20T10:07:11.6853500Z ✘ Test issue507FolderPathsComplete(legacyScanner:) with 2 test cases failed after 12.069 seconds with 5 issues.',
    '2026-11-20T09:08:22.7017040Z ✘ Test issue606CancelledBackgroundWaitDoesNotHopToBusyMainActor() failed after 15.132 seconds with 1 issue.',
    '2026-11-20T09:08:55.9554470Z ✘ Test run with 1607 tests in 38 suites failed after 55.155 seconds with 3 issues (including 2 known issues).',
    '✘ Suite SidebarTreeControllerTests failed after 3.0 seconds with 1 issue.',
    "Test Case '-[MadoMacUITests.ViewerUITests testZoomAnchors]' failed (4.210 seconds).",
  ].join('\n');
  assert.deepEqual(parseFailingTests(log), [
    'issue507FolderPathsComplete(legacyScanner:)',
    'issue606CancelledBackgroundWaitDoesNotHopToBusyMainActor()',
    'ViewerUITests.testZoomAnchors',
  ]);
});

test('a log with no test failure (aggregate or upload step) yields no names', () => {
  assert.deepEqual(parseFailingTests('formal App evidence: false\n##[error]Process completed with exit code 1.\n'), []);
  assert.deepEqual(parseFailingTests(''), []);
});

test('PR #799 recording: every failed attempt-1 job of both workflows, hidden by the green attempt 2', async () => {
  const h = await collectHistory({ get: fixtureGetter(pr799), repo: 'anzchy/mado', pr: 799 });
  assert.equal(h.pr.number, 799);
  assert.equal(h.headSha, 'baf1eae59309c47c0a185585ffcf9a238f148bbf');
  const failed = h.runs.flatMap(r => r.failed.map(f => ({ run: r.id, workflow: r.name, ...f })));
  const key = f => `${f.run}/${f.attempt}/${f.job}`;
  assert.deepEqual(failed.map(key).sort(), [
    '44756846149/1/Agent tooling',
    '44756846987/1/Package tests (non-UI)',
    '44756846987/1/Walking skeleton',
  ]);
  const byJob = Object.fromEntries(failed.map(f => [f.job, f]));
  assert.deepEqual(byJob['Package tests (non-UI)'].steps, ['Watchdog script tests']);
  assert.deepEqual(byJob['Package tests (non-UI)'].tests, ['ownership integration hosted step preserves crash runner outcome and report']);
  assert.deepEqual(byJob['Agent tooling'].tests, ['AC-4 INT and TERM keep shared lock through group kill grace']);
  assert.deepEqual(byJob['Walking skeleton'].tests, []);
  for (const f of failed) {
    assert.equal(f.hidden, true, `${key(f)} is hidden by the later green attempt`);
    assert.equal(f.log, 'ok');
  }
  for (const r of h.runs) { assert.equal(r.attempts, 2); assert.equal(r.conclusion, 'success'); }
});

test('head SHA recording (PR #796): the Swift Testing failure in App tests attempt 1', async () => {
  const h = await collectHistory({ get: fixtureGetter(sha796), repo: 'anzchy/mado', sha: '39eda32e23a862b98dadd919dce716dbebd277b6' });
  assert.equal(h.pr, null);
  const ci = h.runs.find(r => r.id === 44714991399);
  assert.deepEqual(ci.failed.map(f => [f.attempt, f.job, f.steps.join(';'), f.tests.join(';'), f.hidden]), [
    [1, 'App tests', 'Run App tests', 'issue507FolderPathsComplete(legacyScanner:)', true],
    [1, 'Walking skeleton', 'Require the ledger check, package tests and App tests', '', true],
  ]);
  assert.deepEqual(h.runs.find(r => r.id === 44714991429).failed, []);
});

test('a failed final attempt is listed but not hidden; a missing log says unavailable', async () => {
  const R = 'repos/anzchy/mado';
  const get = fixtureGetter({ responses: {
    [`${R}/actions/runs?head_sha=abc&per_page=100&page=1`]: { total_count: 1, workflow_runs: [{ id: 7, name: 'CI', head_sha: 'abc', run_attempt: 1, status: 'completed', conclusion: 'failure' }] },
    [`${R}/actions/runs/7/attempts/1/jobs?per_page=100&page=1`]: { total_count: 2, jobs: [
      { id: 70, name: 'App tests', run_attempt: 1, conclusion: 'failure', steps: [{ name: 'Run App tests', conclusion: 'failure' }] },
      { id: 71, name: 'Design check', run_attempt: 1, conclusion: 'timed_out', steps: [] },
    ] },
    [`${R}/actions/jobs/70/logs`]: '✘ Test x() failed after 1.0 seconds with 1 issue.\n',
  } });
  const h = await collectHistory({ get, repo: 'anzchy/mado', sha: 'abc' });
  assert.deepEqual(h.runs[0].failed.map(f => [f.job, f.hidden, f.log, f.tests.join(';')]), [
    ['App tests', false, 'ok', 'x()'],
    ['Design check', false, 'unavailable', ''],
  ]);
});

test('jobs pages are followed until total_count; a cancelled run with a failed attempt counts as hidden', async () => {
  const R = 'repos/anzchy/mado';
  const job = (id, conclusion) => ({ id, name: `job ${id}`, run_attempt: 1, conclusion, steps: [] });
  const page1 = Array.from({ length: 100 }, (_, i) => job(i + 1, 'success'));
  const get = fixtureGetter({ responses: {
    [`${R}/actions/runs?head_sha=s&per_page=100&page=1`]: { total_count: 1, workflow_runs: [{ id: 9, name: 'CI', head_sha: 's', run_attempt: 1, conclusion: 'cancelled' }] },
    [`${R}/actions/runs/9/attempts/1/jobs?per_page=100&page=1`]: { total_count: 101, jobs: page1 },
    [`${R}/actions/runs/9/attempts/1/jobs?per_page=100&page=2`]: { total_count: 101, jobs: [job(101, 'failure')] },
    [`${R}/actions/jobs/101/logs`]: 'not ok 1 - late\n',
  } });
  const h = await collectHistory({ get, repo: 'anzchy/mado', sha: 's' });
  assert.deepEqual(h.runs[0].failed.map(f => [f.job, f.tests[0], f.hidden]), [['job 101', 'late', true]]);
});

test('a run or jobs request that fails is an error, not an empty history', async () => {
  await assert.rejects(collectHistory({ get: fixtureGetter({ responses: {} }), repo: 'anzchy/mado', sha: 'zzz' }), /no response|404/);
});

test('ticket rule: a PR body line naming the test with #n, or a list entry by name or pattern', () => {
  const h = { runs: [{ id: 1, name: 'CI', failed: [
    { attempt: 1, job: 'A', steps: [], tests: ['alpha()', 'beta', 'gamma(arg:)', 'delta', 'epsilon'], hidden: true, log: 'ok' },
    { attempt: 1, job: 'Walking skeleton', steps: ['Require'], tests: [], hidden: true, log: 'ok' },
  ] }] };
  const body = 'Flaky: `alpha` again, tracked in #600.\nbeta failed once\nSee #759 for the list.\n';
  const lists = [
    { name: 'gamma', issue: 425, source: 'scripts/ci/known-flaky.mjs' },
    { pattern: '^del.a$', issue: 759, source: '.agents/skills/mado-verify/known-flakes.json' },
  ];
  const c = classify(h, { body, lists });
  assert.deepEqual(c.ticketed.map(t => [t.test, t.issue, t.source]), [
    ['alpha()', 600, 'PR body'],
    ['gamma(arg:)', 425, 'scripts/ci/known-flaky.mjs'],
    ['delta', 759, '.agents/skills/mado-verify/known-flakes.json'],
  ]);
  // beta's line has no #n, and #759 on another line does not cover it; epsilon is named nowhere.
  assert.deepEqual(c.needsTicket.map(t => t.test), ['beta', 'epsilon']);
  assert.deepEqual(c.noTestNames.map(t => t.job), ['Walking skeleton']);
});

test('ticket rule: a name inside a longer word does not count', () => {
  const h = { runs: [{ id: 1, name: 'CI', failed: [{ attempt: 1, job: 'A', steps: [], tests: ['load'], hidden: true, log: 'ok' }] }] };
  assert.deepEqual(classify(h, { body: 'unloaded twice #12\n', lists: [] }).needsTicket.map(t => t.test), ['load']);
  assert.deepEqual(classify(h, { body: 'load (#12)\n', lists: [] }).ticketed.map(t => t.issue), [12]);
});

test('ticket lists are read from the three repo files', async () => {
  const root = emptyLists();
  writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), JSON.stringify([{ name: 'q1', pattern: '^q1$', issue: 1 }]));
  writeFileSync(join(root, '.agents/skills/mado-verify/known-flakes.json'), JSON.stringify({ flakes: [{ name: 'k1', pattern: '^k1$', issue: 2 }] }));
  writeFileSync(join(root, 'scripts/ci/known-flaky.mjs'), "export const knownFlaky = [{ name: 'f1', signature: /x/, issue: 3 }];\n");
  const lists = await loadTicketLists(root);
  assert.deepEqual(lists.map(l => [l.name, l.issue, l.source]), [
    ['q1', 1, 'scripts/tdd/app-quarantine.json'],
    ['k1', 2, '.agents/skills/mado-verify/known-flakes.json'],
    ['f1', 3, 'scripts/ci/known-flaky.mjs'],
  ]);
});

test('the repo lists load (known-flaky.mjs names carry their issue)', async () => {
  const lists = await loadTicketLists(process.cwd());
  assert.ok(lists.some(l => l.source === 'scripts/ci/known-flaky.mjs' && l.name === 't229Fix2RecoveryFollowsRootMovedWhileReadable' && l.issue === 379));
});

test('render: a summary table and one line per outcome', async () => {
  const h = await collectHistory({ get: fixtureGetter(pr799), repo: 'anzchy/mado', pr: 799 });
  const text = render(h, classify(h, { body: h.pr.body, lists: [] }));
  assert.match(text, /^attempt-history: PR #799 head baf1eae5 /m);
  assert.match(text, /^\| run \| workflow \| attempt \| job \| failed step \| failing tests \| hidden \|$/m);
  assert.match(text, /^\| 44756846987 \| CI \| 1\/2 \| Package tests \(non-UI\) \| Watchdog script tests \| ownership integration hosted step preserves crash runner outcome and report \| yes \|$/m);
  assert.match(text, /^needs-ticket: AC-4 INT and TERM keep shared lock through group kill grace \(run 44756846149 attempt 1, job Agent tooling\)$/m);
  assert.match(text, /^no-test-names: run 44756846987 attempt 1, job Walking skeleton, step Require the ledger check, package tests and App tests$/m);
  assert.match(text, /^summary: 3 failed job attempts in 2 runs, 3 hidden by a later attempt or a green\/cancelled run; 2 failing tests, 2 without a ticket$/m);
});

test('CLI on the PR #799 recording: advisory by default, --require-tickets exits 1', () => {
  const root = emptyLists();
  const fixture = join(root, 'pr799.json');
  writeFileSync(fixture, JSON.stringify(pr799));
  const base = ['--pr', '799', '--fixture', fixture, '--lists-root', root];
  const advisory = run(base);
  assert.equal(advisory.status, 0, advisory.stderr);
  assert.match(advisory.stdout, /^needs-ticket: ownership integration hosted step/m);
  assert.match(advisory.stdout, /^advisory: 2 failing tests without a ticket; pass --require-tickets to fail on them$/m);
  const strict = run([...base, '--require-tickets']);
  assert.equal(strict.status, 1);
  assert.match(strict.stdout, /^needs-ticket: /m);
});

test('CLI: --body-file names both tests with a ticket, so --require-tickets passes', () => {
  const root = emptyLists();
  const fixture = join(root, 'pr799.json');
  writeFileSync(fixture, JSON.stringify(pr799));
  const body = join(root, 'body.md');
  writeFileSync(body, '- `ownership integration hosted step preserves crash runner outcome and report` flaked, #788\n- AC-4 INT and TERM keep shared lock through group kill grace: #788\n');
  const r = run(['--pr', '799', '--fixture', fixture, '--lists-root', root, '--body-file', body, '--require-tickets']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.doesNotMatch(r.stdout, /needs-ticket/);
  assert.match(r.stdout, /^ticketed: AC-4 INT and TERM keep shared lock through group kill grace -> #788 \(PR body\)$/m);
});

test('CLI: usage errors and fetch errors exit 2', () => {
  assert.equal(run([]).status, 2);
  assert.equal(run(['--pr', '1', '--sha', 'abc']).status, 2);
  assert.equal(run(['--pr', 'x']).status, 2);
  const root = emptyLists();
  const fixture = join(root, 'empty.json');
  writeFileSync(fixture, '{"responses":{}}');
  const r = run(['--sha', 'abc', '--fixture', fixture, '--lists-root', root]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /attempt-history: /);
});

test('CLI --record writes a fixture that replays to the same output', () => {
  const root = emptyLists();
  const src = join(root, 'src.json');
  writeFileSync(src, JSON.stringify(sha796));
  const out = join(root, 'rec.json');
  const args = ['--sha', '39eda32e23a862b98dadd919dce716dbebd277b6', '--lists-root', root];
  const first = run([...args, '--fixture', src, '--record', out]);
  assert.equal(first.status, 0, first.stderr);
  const replay = run([...args, '--fixture', out]);
  assert.equal(replay.status, 0, replay.stderr);
  assert.equal(replay.stdout, first.stdout);
  assert.match(replay.stdout, /needs-ticket: issue507FolderPathsComplete\(legacyScanner:\)/);
});
