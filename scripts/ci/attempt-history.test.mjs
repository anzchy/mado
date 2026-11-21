// #788 item 4: failed job attempts hidden by reruns, listed per PR or head SHA, and the failing tests without a ticket.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
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

// opus L2: remove every temporary root when the file finishes.
const made = [];
process.on('exit', () => { for (const dir of made) rmSync(dir, { recursive: true, force: true }); });
// An empty ticket-list root, so the repo's own lists never decide a test's outcome by accident.
function emptyLists() {
  const root = mkdtempSync(join(tmpdir(), 'attempt-history-'));
  made.push(root);
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

// ---- i788d-fix1 ----
// gpt F1 (High): in --require-tickets mode every ticket source must exist and load; a missing or broken one refuses.
const TICKETED_BODY = '- `ownership integration hosted step preserves crash runner outcome and report` flaked, #788\n- AC-4 INT and TERM keep shared lock through group kill grace: #788\n';
function ticketedRun(mutate, extra = []) {
  const root = emptyLists();
  mutate(root);
  const fixture = join(root, 'pr799.json');
  writeFileSync(fixture, JSON.stringify(pr799));
  const body = join(root, 'body.md');
  writeFileSync(body, TICKETED_BODY);
  return run(['--pr', '799', '--fixture', fixture, '--lists-root', root, '--body-file', body, ...extra]);
}

for (const rel of ['scripts/tdd/app-quarantine.json', '.agents/skills/mado-verify/known-flakes.json', 'scripts/ci/known-flaky.mjs']) {
  test(`--require-tickets refuses when ${rel} is missing, even with every test ticketed in the body`, () => {
    const r = ticketedRun(root => rmSync(join(root, rel)), ['--require-tickets']);
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.match(r.stderr, new RegExp(`^attempt-history: refused: ticket source ${rel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} `, 'm'));
  });
}

test('--require-tickets refuses a ticket source that does not load (bad JSON, wrong shape, throwing module)', () => {
  const cases = [
    root => writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), '{not json'),
    root => writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), '{"id":"x"}'),
    root => writeFileSync(join(root, '.agents/skills/mado-verify/known-flakes.json'), '[]'),
    root => writeFileSync(join(root, 'scripts/ci/known-flaky.mjs'), "throw new Error('boom');\n"),
    root => writeFileSync(join(root, 'scripts/ci/known-flaky.mjs'), 'export const other = 1;\n'),
  ];
  for (const mutate of cases) {
    const r = ticketedRun(mutate, ['--require-tickets']);
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.match(r.stderr, /^attempt-history: refused: ticket source /m);
  }
});

test('--require-tickets refuses a --lists-root that is not a repo checkout', () => {
  const root = emptyLists();
  const fixture = join(root, 'pr799.json');
  writeFileSync(fixture, JSON.stringify(pr799));
  const body = join(root, 'body.md');
  writeFileSync(body, TICKETED_BODY);
  const r = run(['--pr', '799', '--fixture', fixture, '--lists-root', join(root, 'nowhere'), '--body-file', body, '--require-tickets']);
  assert.equal(r.status, 2, r.stdout + r.stderr);
  assert.match(r.stderr, /^attempt-history: refused: ticket source scripts\/tdd\/app-quarantine\.json /m);
});

test('advisory mode names a missing ticket source and still exits 0', () => {
  const r = ticketedRun(root => rmSync(join(root, 'scripts/ci/known-flaky.mjs')));
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^ticket-source-missing: scripts\/ci\/known-flaky\.mjs /m);
});

// opus F1 (High): app-quarantine.json entries use the documented schema {id, issue, reason, owner, expires}
// (docs/agents/test-lanes.md; scripts/tdd/app-lane.mjs loadQuarantine). The entry below is the real one from 67d524656.
const REAL_QUARANTINE_ENTRY = {
  id: 'MadoAppTests.issue454ReadOwnerFailureRetryCancelAndCompletionUseActualFolder()',
  issue: 597,
  reason: 'Issue454ReadOwnerLifecycleTests.swift:118:9 sees window.isVisible true; 8 failing versus 5 passing main executions since 2026-11-05, with recovery on main run 42439831377 attempt 2 and PR reruns. Reproduce under the desktop lock before fixing.',
  owner: 'delegator',
  expires: '2026-11-22',
};

test('a quarantined App test (real id schema) is ticketed by its issue, matched on the id\'s last component', async () => {
  const root = emptyLists();
  writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), JSON.stringify([
    REAL_QUARANTINE_ENTRY,
    { id: 'MadoAppTests.Issue507Suite/issue507FolderPathsComplete(legacyScanner:)', issue: 600, reason: 'r', owner: 'o', expires: '2026-11-30' },
    { id: 'ViewerUITests/testZoomAnchors', issue: 601, reason: 'r', owner: 'o', expires: '2026-11-30' },
  ]));
  const lists = await loadTicketLists(root);
  const h = { runs: [{ id: 1, name: 'CI', failed: [{ attempt: 1, job: 'App tests', steps: [], hidden: true, log: 'ok', tests: [
    'issue454ReadOwnerFailureRetryCancelAndCompletionUseActualFolder()',
    'issue507FolderPathsComplete(legacyScanner:)',
    'ViewerUITests.testZoomAnchors',
    'issue454ReadOwnerFailureRetryCancelAndCompletionUseActualFolderTwo()',
  ] }] }] };
  const c = classify(h, { body: '', lists });
  assert.deepEqual(c.ticketed.map(t => [t.test, t.issue, t.source]), [
    ['issue454ReadOwnerFailureRetryCancelAndCompletionUseActualFolder()', 597, 'scripts/tdd/app-quarantine.json'],
    ['issue507FolderPathsComplete(legacyScanner:)', 600, 'scripts/tdd/app-quarantine.json'],
    ['ViewerUITests.testZoomAnchors', 601, 'scripts/tdd/app-quarantine.json'],
  ]);
  assert.deepEqual(c.needsTicket.map(t => t.test), ['issue454ReadOwnerFailureRetryCancelAndCompletionUseActualFolderTwo()']);
});

test('a list entry with arguments tickets only the same arguments (opus L2)', async () => {
  const root = emptyLists();
  writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), JSON.stringify([{ ...REAL_QUARANTINE_ENTRY, id: 'MadoAppTests.foo(a:)' }]));
  const lists = await loadTicketLists(root);
  const h = { runs: [{ id: 1, name: 'CI', failed: [{ attempt: 1, job: 'A', steps: [], hidden: true, log: 'ok', tests: ['foo(a:)', 'foo(b:)'] }] }] };
  const c = classify(h, { body: '', lists });
  assert.deepEqual(c.ticketed.map(t => t.test), ['foo(a:)']);
  assert.deepEqual(c.needsTicket.map(t => t.test), ['foo(b:)']);
});

test('every entry of the repo\'s own app-quarantine.json becomes a ticket entry with its issue', async () => {
  const repo = JSON.parse(readFileSync('scripts/tdd/app-quarantine.json', 'utf8'));
  const lists = (await loadTicketLists(process.cwd())).filter(l => l.source === 'scripts/tdd/app-quarantine.json');
  assert.deepEqual(lists.map(l => [l.id, l.issue]), repo.map(e => [e.id, e.issue]));
});

test('CLI: the real quarantine entry tickets its failing test, so --require-tickets passes', () => {
  const root = emptyLists();
  writeFileSync(join(root, 'scripts/tdd/app-quarantine.json'), JSON.stringify([
    { ...REAL_QUARANTINE_ENTRY, id: 'MadoAppTests.issue507FolderPathsComplete(legacyScanner:)', issue: 600 },
  ]));
  const src = join(root, 'sha.json');
  writeFileSync(src, JSON.stringify(sha796));
  const r = run(['--sha', '39eda32e23a862b98dadd919dce716dbebd277b6', '--fixture', src, '--lists-root', root, '--require-tickets']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^ticketed: issue507FolderPathsComplete\(legacyScanner:\) -> #600 \(scripts\/tdd\/app-quarantine\.json\)$/m);
});

// opus M1: a failed job whose test names cannot be read (expired log, crash, timeout) is an unknown, not a pass.
function shaFixture(jobs, logs, runExtra = {}) {
  const R = 'repos/anzchy/mado';
  const sha = 'a'.repeat(40);
  const responses = {
    [`${R}/actions/runs?head_sha=${sha}&per_page=100&page=1`]: { total_count: 1, workflow_runs: [{ id: 5, name: 'CI', head_sha: sha, run_attempt: 2, conclusion: 'success', ...runExtra }] },
    [`${R}/actions/runs/5/attempts/1/jobs?per_page=100&page=1`]: { total_count: jobs.length, jobs },
    [`${R}/actions/runs/5/attempts/2/jobs?per_page=100&page=1`]: { total_count: 0, jobs: [] },
  };
  for (const [id, text] of Object.entries(logs)) responses[`${R}/actions/jobs/${id}/logs`] = text;
  return { sha, responses };
}
const job = (id, name, conclusion = 'failure', step = 'Run tests') => ({ id, name, run_attempt: 1, conclusion, steps: [{ name: step, conclusion }] });

test('--require-tickets counts unreadable failures: expired log, crash without test lines, timed-out job', () => {
  const fx = shaFixture(
    [job(1, 'App tests'), job(2, 'Package tests (non-UI)'), job(3, 'Design check', 'timed_out'), job(4, 'Walking skeleton', 'failure', 'Require the ledger check')],
    {
      2: "*** Terminating app due to uncaught exception 'NSInvalidArgumentException'\nerror: Exited with unexpected signal code 6\n",
      3: 'still running\n',
      4: 'formal App evidence: false\n##[error]Process completed with exit code 1.\n',
    });
  const root = emptyLists();
  const fixture = join(root, 'f.json');
  writeFileSync(fixture, JSON.stringify({ responses: fx.responses }));
  const args = ['--sha', fx.sha, '--fixture', fixture, '--lists-root', root];
  const advisory = run(args);
  assert.equal(advisory.status, 0, advisory.stderr);
  assert.match(advisory.stdout, /^needs-ticket-unknown: run 5 attempt 1, job App tests \(log unavailable\)$/m);
  assert.match(advisory.stdout, /^needs-ticket-unknown: run 5 attempt 1, job Package tests \(non-UI\) \(crash or signal without failing-test lines\)$/m);
  assert.match(advisory.stdout, /^needs-ticket-unknown: run 5 attempt 1, job Design check \(timed out\)$/m);
  assert.match(advisory.stdout, /^no-test-names: run 5 attempt 1, job Walking skeleton, step Require the ledger check$/m);
  assert.doesNotMatch(advisory.stdout, /needs-ticket-unknown: .*Walking skeleton/);
  const strict = run([...args, '--require-tickets']);
  assert.equal(strict.status, 1, strict.stdout + strict.stderr);
});

test('--require-tickets passes when the only no-name failures are aggregates', () => {
  const fx = shaFixture([job(4, 'Walking skeleton', 'failure', 'Require the ledger check')], { 4: '##[error]Process completed with exit code 1.\n' });
  const root = emptyLists();
  const fixture = join(root, 'f.json');
  writeFileSync(fixture, JSON.stringify({ responses: fx.responses }));
  const r = run(['--sha', fx.sha, '--fixture', fixture, '--lists-root', root, '--require-tickets']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

// opus M2 / gpt M1: a full SHA only; no runs is an error when opted in; PR mode keeps only the PR's own runs.
test('--sha must be a full 40-hex commit SHA', () => {
  const r = run(['--sha', 'baf1eae5']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--sha must be a full 40-character commit SHA/);
});

test('no workflow runs: advisory says so, --require-tickets refuses', () => {
  const sha = 'b'.repeat(40);
  const root = emptyLists();
  const fixture = join(root, 'f.json');
  writeFileSync(fixture, JSON.stringify({ responses: { [`repos/anzchy/mado/actions/runs?head_sha=${sha}&per_page=100&page=1`]: { total_count: 0, workflow_runs: [] } } }));
  const args = ['--sha', sha, '--fixture', fixture, '--lists-root', root];
  const advisory = run(args);
  assert.equal(advisory.status, 0, advisory.stderr);
  assert.match(advisory.stdout, /^no-runs: no workflow runs found/m);
  const strict = run([...args, '--require-tickets']);
  assert.equal(strict.status, 2);
  assert.match(strict.stderr, /^attempt-history: refused: no workflow runs found/m);
});

test('PR mode drops runs whose metadata shows another PR (fork head repo, created before the PR, other PR number)', async () => {
  const fx = structuredClone(pr799);
  const key = Object.keys(fx.responses).find(k => k.includes('/actions/runs?branch='));
  const base = fx.responses[key].workflow_runs[0];
  const other = (id, patch) => ({ ...base, id, run_attempt: 1, ...patch });
  fx.responses[key].workflow_runs.push(
    other(1, { head_repository: { full_name: 'someone/mado' } }),
    other(2, { created_at: '2026-01-01T00:00:00Z' }),
    other(3, { pull_requests: [{ number: 12 }] }),
    other(4, { head_repository: undefined, created_at: undefined, pull_requests: undefined }),
  );
  fx.responses[key].total_count += 4;
  fx.responses['repos/anzchy/mado/actions/runs/4/attempts/1/jobs?per_page=100&page=1'] = { total_count: 0, jobs: [] };
  const h = await collectHistory({ get: fixtureGetter(fx), repo: 'anzchy/mado', pr: 799 });
  assert.deepEqual(h.runs.map(r => r.id), [4, 44756846149, 44756846987]);
  assert.deepEqual(h.excluded.map(e => [e.id, e.reason]), [
    [1, 'head repository someone/mado, not anzchy/mado'],
    [2, 'created 2026-01-01T00:00:00Z, before PR #799 (2026-11-20T14:47:25Z)'],
    [3, 'belongs to PR #12'],
  ]);
  const text = render(h, classify(h, { body: '', lists: [] }));
  assert.match(text, /^excluded: run 1 \(head repository someone\/mado, not anzchy\/mado\)$/m);
});

test('pages are followed without total_count until a short page (opus L2)', async () => {
  const R = 'repos/anzchy/mado';
  const sha = 'c'.repeat(40);
  const mk = (id, c) => ({ id, name: `j${id}`, run_attempt: 1, conclusion: c, steps: [] });
  const get = fixtureGetter({ responses: {
    [`${R}/actions/runs?head_sha=${sha}&per_page=100&page=1`]: { workflow_runs: [{ id: 8, name: 'CI', head_sha: sha, run_attempt: 1, conclusion: 'failure' }] },
    [`${R}/actions/runs/8/attempts/1/jobs?per_page=100&page=1`]: { jobs: Array.from({ length: 100 }, (_, i) => mk(i + 1, 'success')) },
    [`${R}/actions/runs/8/attempts/1/jobs?per_page=100&page=2`]: { jobs: [mk(101, 'failure')] },
    [`${R}/actions/jobs/101/logs`]: 'not ok 1 - page two\n',
  } });
  const h = await collectHistory({ get, repo: 'anzchy/mado', sha });
  assert.deepEqual(h.runs[0].failed.map(f => f.tests[0]), ['page two']);
});
