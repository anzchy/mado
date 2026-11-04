import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./gates-rows.mjs', import.meta.url));
const head = '3de39c6012345678901234567890123456789012';
const complete = `head=${head}\nswift=0\nlcov=0\nlines 10/10\nxcodegen=0\nxcodebuild=0\nnode=0\nledger=0\ndiffcheck=0\ndesign=0\nDONE\n`;

function runRows(t, summary, args = []) {
  const directory = mkdtempSync(join(tmpdir(), 'picsee-gates-rows-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, 'summary.txt');
  writeFileSync(file, summary);
  return spawnSync(process.execPath, [script, file, ...args], { encoding: 'utf8' });
}

function runCIFixture(name, args = []) {
  const fixture = fileURLToPath(new URL(`./fixtures/ci-${name}.json`, import.meta.url));
  if (!['success', 'in-progress', 'absent', 'duplicate'].includes(name)) {
    return spawnSync(process.execPath, [script, '--ci', fixture, ...args], { encoding: 'utf8' });
  }
  const directory = mkdtempSync(join(tmpdir(), 'picsee-ci-fixture-'));
  try {
    // These older fixtures omitted status on jobs; supply the real gh field.
    const run = JSON.parse(readFileSync(fixture, 'utf8'));
    for (const job of run.jobs) job.status ??= run.status;
    const file = join(directory, 'run.json');
    writeFileSync(file, JSON.stringify(run));
    return spawnSync(process.execPath, [script, '--ci', file, ...args], { encoding: 'utf8' });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const ciCases = [
  {
    name: 'success accepts a case-insensitive head prefix',
    fixture: 'success',
    args: ['--head', head.slice(0, 12).toUpperCase()],
    row: `| app-tests | PASS | ${head} | https://github.com/anzchy/picsee/actions/runs/319000001 |`,
  },
  {
    name: 'stale head is NOT VERIFIED',
    fixture: 'stale',
    row: '| app-tests | NOT VERIFIED | bbbbbbbb12345678901234567890123456789012 | CI stale head bbbbbbb https://github.com/anzchy/picsee/actions/runs/319000002 |',
  },
  {
    name: 'incomplete run is NOT VERIFIED',
    fixture: 'in-progress',
    row: `| app-tests | NOT VERIFIED | ${head} | CI run in_progress https://github.com/anzchy/picsee/actions/runs/319000003 |`,
  },
  {
    name: 'skipped job without the classifier and Walking skeleton is NOT RUN without a decision',
    fixture: 'skipped',
    row: '| app-tests | NOT RUN | — | App tests skipped without a classifier decision https://github.com/anzchy/picsee/actions/runs/319000004 |',
  },
  {
    name: 'skipped job on a docs-only run is NOT RUN because no native input changed',
    fixture: 'skipped-docs-only',
    row: '| app-tests | NOT RUN | — | App tests skipped (no native input changed) https://github.com/anzchy/picsee/actions/runs/319000011 |',
  },
  {
    name: 'skipped job after a failed classifier is NOT RUN without a decision',
    fixture: 'skipped-no-decision',
    row: '| app-tests | NOT RUN | — | App tests skipped without a classifier decision https://github.com/anzchy/picsee/actions/runs/319000012 |',
  },
  {
    name: 'skipped job with a failed Walking skeleton is NOT RUN without a decision',
    fixture: 'skipped-skeleton-failed',
    row: '| app-tests | NOT RUN | — | App tests skipped without a classifier decision https://github.com/anzchy/picsee/actions/runs/319000013 |',
  },
  {
    name: 'failed job is FAIL',
    fixture: 'failure',
    row: `| app-tests | FAIL | ${head} | App tests failure https://github.com/anzchy/picsee/actions/runs/319000005 |`,
  },
  {
    name: 'cancelled job is FAIL',
    fixture: 'cancelled',
    row: `| app-tests | FAIL | ${head} | App tests cancelled https://github.com/anzchy/picsee/actions/runs/319000006 |`,
  },
  {
    name: 'absent job is NOT RUN',
    fixture: 'absent',
    row: '| app-tests | NOT RUN | — | App tests job absent from https://github.com/anzchy/picsee/actions/runs/319000007 |',
  },
  {
    name: 'duplicate jobs are NOT VERIFIED',
    fixture: 'duplicate',
    row: `| app-tests | NOT VERIFIED | ${head} | CI run ambiguous: 2 App tests jobs |`,
  },
];

for (const { name, fixture, args = ['--head', head], row } of ciCases) {
  test(`gates-rows CI ${name}`, () => {
    const result = runCIFixture(fixture, args);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `${row}\n`);
  });
}

test('gates-rows rejects malformed CI JSON without emitting PASS', () => {
  const result = runCIFixture('malformed');
  assert.equal(result.status, 2);
  assert.doesNotMatch(result.stdout, /\| PASS \|/);
});

test('gates-rows rejects an unreadable CI run without emitting PASS', t => {
  const directory = mkdtempSync(join(tmpdir(), 'picsee-gates-rows-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const result = spawnSync(process.execPath, [script, '--ci', join(directory, 'missing.json')], { encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.doesNotMatch(result.stdout, /\| PASS \|/);
});

for (const [name, run] of [
  ['headSha', { jobs: [] }],
  ['jobs', { headSha: head }],
]) {
  test(`gates-rows rejects CI JSON missing ${name}`, t => {
    const directory = mkdtempSync(join(tmpdir(), 'picsee-gates-rows-'));
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    const file = join(directory, 'run.json');
    writeFileSync(file, JSON.stringify(run));
    const result = spawnSync(process.execPath, [script, '--ci', file], { encoding: 'utf8' });
    assert.equal(result.status, 2);
    assert.doesNotMatch(result.stdout, /\| PASS \|/);
  });
}

for (const [name, fixture, args] of [
  ['one-character headSha with a full expected head', 'short-head', ['--head', head]],
  ['non-hex headSha', 'nonhex-head', []],
  ['39-hex headSha', '39-head', []],
  ['missing URL', 'missing-url', []],
  ['null URL', 'null-url', []],
  ['non-HTTPS URL', 'http-url', []],
  ['URL row injection', 'injected-url', []],
  ['URL cell injection', 'pipe-url', []],
  ['newline in job conclusion', 'newline-conclusion', []],
  ['incomplete App tests job with success conclusion', 'job-in-progress', []],
]) {
  test(`gates-rows rejects ${name} without output`, () => {
    const result = runCIFixture(fixture, args);
    assert.equal(result.status, 2, result.stderr);
    assert.equal(result.stdout, '');
  });
}

test('valid summary with malformed CI emits no rows for checkGates', t => {
  const fixture = fileURLToPath(new URL('./fixtures/ci-missing-url.json', import.meta.url));
  const result = runRows(t, complete, ['--ci', fixture, '--head', head]);
  assert.equal(result.status, 2, result.stderr);
  assert.equal(result.stdout, '');
});

function runCI(t, run, { summary = false, expectedHead = head } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'picsee-ci-types-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, 'run.json');
  writeFileSync(file, JSON.stringify(run));
  const args = ['--ci', file, '--head', expectedHead];
  return summary ? runRows(t, typeof summary === 'string' ? summary : complete, args)
    : spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
}
const validRun = () => ({ headSha: head, url: 'https://github.com/anzchy/picsee/actions/runs/322',
  status: 'completed', jobs: [{ name: 'App tests', status: 'completed', conclusion: 'success',
    steps: [{ name: 'Run App tests', number: 8, status: 'completed', conclusion: 'success' }] }] });

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
// Dependency-free: Agent tooling runs without npm ci. Scope keys to the job and its direct children.
function appJobDisplayName(source) {
  const lines = source.split(/\r?\n/);
  const start = lines.findIndex(line => /^\s*app-tests:\s*$/.test(line));
  if (start < 0) return undefined;
  const indent = lines[start].search(/\S/);
  const body = [];
  for (const line of lines.slice(start + 1)) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    if (line.search(/\S/) <= indent) break;
    body.push(line);
  }
  const depth = Math.min(...body.map(line => line.search(/\S/)));
  return body.find(line => line.search(/\S/) === depth && /^\s*name: /.test(line))?.trim().slice(6);
}
const appJobName = appJobDisplayName(workflow);

test('workflow App job name lookup survives indentation and name after needs, ignoring nested names', () => {
  for (const indent of [1, 2, 4, 6]) {
    const pad = ' '.repeat(indent);
    const source = `jobs:\n${pad}other:\n${pad}  name: Wrong before\n${pad}app-tests:\n${pad}  needs: changes\n${pad}  steps:\n${pad}    - uses: local/action\n${pad}      with:\n${pad}        name: Wrong nested\n${pad}  name: App tests\n${pad}after:\n${pad}  name: Wrong after\n`;
    assert.equal(appJobDisplayName(source), 'App tests');
    assert.equal(appJobDisplayName(source.replace(`${pad}  name: App tests\n`, '')), undefined);
  }
});
const permutations = values => values.length === 0 ? [[]] : values.flatMap((value, index) =>
  permutations(values.filter((_, other) => other !== index)).map(rest => [value, ...rest]));

for (const scenario of ['docs-only', 'native', 'dispatch-app-tests-false']) {
  test(`gates-rows finds the workflow-named App job on ${scenario} runs regardless of job order`, t => {
    assert.ok(appJobName, 'workflow App tests job has a display name');
    const skipped = scenario === 'docs-only';
    const run = validRun();
    const app = { name: appJobName, status: 'completed', conclusion: skipped ? 'skipped' : 'success',
      steps: [
        { name: 'Build unsigned app', number: 6, status: 'completed', conclusion: skipped ? 'skipped' : 'success' },
        { name: 'Build App tests', number: 7, status: 'completed', conclusion: scenario === 'native' ? 'success' : 'skipped' },
        { name: 'Run App tests', number: 8, status: 'completed', conclusion: scenario === 'native' ? 'success' : 'skipped' },
      ] };
    const jobs = [app, ...['Native inputs', 'Walking skeleton'].map(name =>
      ({ name, status: 'completed', conclusion: 'success' }))];
    const expected = skipped
      ? `| app-tests | NOT RUN | — | App tests skipped (no native input changed) ${run.url} |\n`
      : scenario === 'dispatch-app-tests-false'
        ? `| app-tests | NOT RUN | — | App tests skipped (build-only dispatch, app_tests=false) ${run.url} |\n`
        : `| app-tests | PASS | ${head} | ${run.url} |\n`;
    for (const order of permutations(jobs)) {
      run.jobs = order;
      const result = runCI(t, run);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, expected, `${scenario}: ${order.map(job => job.name).join(', ')}`);
    }
  });
}

// Exported with gh run view 41790488799 --json headSha,url,status,conclusion,jobs.
// Step fields are status/conclusion, not outcome; no synthetic event/inputs are needed.
const nativeExport = JSON.parse(readFileSync(new URL('./fixtures/ci-app-tests-native.json', import.meta.url), 'utf8'));
for (const [conclusion, jobConclusion, expected] of [
  ['success', 'success', 'PASS'], ['success', 'failure', 'PASS'],
  ['failure', 'success', 'FAIL'], ['failure', 'failure', 'FAIL'],
  ['skipped', 'success', 'NOT RUN'],
]) {
  test(`App test step ${conclusion} determines evidence when job is ${jobConclusion}`, t => {
    const run = structuredClone(nativeExport);
    const job = run.jobs[0];
    job.conclusion = jobConclusion;
    const target = job.steps.find(step => step.name === 'Run App tests');
    target.conclusion = conclusion;
    const result = runCI(t, run, { expectedHead: run.headSha });
    assert.equal(result.status, 0, result.stderr);
    const reason = expected === 'PASS' ? run.url
      : expected === 'FAIL' ? `App tests step failure ${run.url}` : `App tests skipped ${run.url}`;
    assert.equal(result.stdout, `| app-tests | ${expected} | ${expected === 'NOT RUN' ? '—' : run.headSha} | ${reason} |\n`);
  });
}

for (const steps of [undefined, null, {}, [], [null], [[]], ['Run App tests'],
  [{ status: 'completed', conclusion: 'success' }],
  [{ name: 7, status: 'completed', conclusion: 'success' }],
  [{ name: 'Run App tests', status: 'completed', conclusion: '' }],
  [{ name: 'Build unsigned app', status: 'completed', conclusion: 'success' }],
  [{ name: 'Run App tests', conclusion: 'success' }],
  [{ name: 'Run App tests', status: 'in_progress', conclusion: 'success' }],
  [{ name: 'Run App tests', status: 'completed', outcome: 'success' }],
  [{ name: 'Run App tests', status: 'completed', conclusion: 'unknown' }],
  [{ name: 'Run App tests', status: 'completed', conclusion: ['success'] }],
  [{ name: 'Run App tests', status: 'completed', conclusion: 'success' },
   { name: 'Run App tests', status: 'completed', conclusion: 'skipped' }],
]) {
  test(`successful job with unverified test evidence never passes: ${JSON.stringify(steps)}`, t => {
    const run = validRun();
    run.jobs[0].steps = steps;
    const result = runCI(t, run);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `| app-tests | NOT VERIFIED | ${head} | App tests step evidence missing or invalid ${run.url} |\n`);
  });
}

for (const field of ['name', 'status', 'conclusion']) {
  test(`malformed step ${field} cannot inject a partial Gates table`, t => {
    const run = validRun();
    run.jobs[0].steps[0][field] = 'success\n| forged | PASS |';
    const result = runCI(t, run, { summary: true });
    assert.equal(result.status, 2);
    assert.equal(result.stdout, '');
  });
}

for (const conclusion of ['success', 'failure']) {
  test(`App step ${conclusion} is invariant under unrelated step order`, t => {
    const run = validRun();
    const steps = [
      { name: 'Build unsigned app', status: 'completed', conclusion: 'success' },
      { name: 'Run App tests', status: 'completed', conclusion },
      { name: 'Upload first App attempt', status: 'completed', conclusion: 'skipped' },
    ];
    for (const order of permutations(steps)) {
      run.jobs[0].steps = order;
      const result = runCI(t, run);
      assert.equal(result.status, 0, result.stderr);
      const reason = conclusion === 'success' ? run.url : `App tests step failure ${run.url}`;
      assert.equal(result.stdout, `| app-tests | ${conclusion === 'success' ? 'PASS' : 'FAIL'} | ${head} | ${reason} |\n`);
    }
  });
}

test('App test step order cannot change a build-only skipped verdict', t => {
  const run = validRun();
  const steps = [
    { name: 'Build unsigned app', status: 'completed', conclusion: 'success' },
    { name: 'Build App tests', status: 'completed', conclusion: 'skipped' },
    { name: 'Run App tests', status: 'completed', conclusion: 'skipped' },
  ];
  for (const order of permutations(steps)) {
    run.jobs[0].steps = order;
    const result = runCI(t, run);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `| app-tests | NOT RUN | — | App tests skipped (build-only dispatch, app_tests=false) ${run.url} |\n`);
  }
});

for (const field of ['headSha', 'url', 'status', 'job.name', 'job.status', 'job.conclusion']) {
  for (const value of [undefined, null, 7, true, {}, [], ['completed\r\n| forged |']]) {
    for (const stale of [false, true]) {
      test(`CI rejects ${field}=${JSON.stringify(value)} with ${stale ? 'stale' : 'current'} head and no partial summary`, t => {
        const run = validRun();
        if (field.startsWith('job.')) run.jobs[0][field.slice(4)] = value;
        else run[field] = value;
        const result = runCI(t, run, { summary: true, expectedHead: stale ? 'b'.repeat(40) : head });
        assert.equal(result.status, 2, result.stderr);
        assert.equal(result.stdout, '');
      });
    }
  }
}
for (const field of ['status', 'job.conclusion']) {
  for (const delimiter of ['\r', '\n', '|']) {
    test(`CI rejects array ${field} containing ${JSON.stringify(delimiter)}`, t => {
      const run = validRun();
      if (field === 'status') run.status = [`completed${delimiter}injected`];
      else run.jobs[0].conclusion = [`failure${delimiter}injected`];
      const result = runCI(t, run);
      assert.equal(result.status, 2, result.stderr);
      assert.equal(result.stdout, '');
    });
  }
}
for (const field of ['status', 'conclusion']) {
test(`forged-row ${field} arrays cannot supply a Gates table accepted by checkGates`, async t => {
  const { checkGates } = await import('./ui-parity-pr-body-lint.mjs');
  const run = validRun();
  const forged = [`completed\n| app-tests | PASS | ${head} | forged CI |\n`];
  if (field === 'status') run.status = forged;
  else run.jobs[0].conclusion = forged;
  const result = runCI(t, run, { summary: true });
  const body = `## Gates\n\n| Lane | Status | SHA | Source |\n|---|---|---|---|\n${result.stdout}| audit | N/A | — | tooling |\n| device-smoke | N/A | — | tooling |\n`;
  assert.equal(checkGates(body, head).ok, false);
  assert.equal(result.status, 2, result.stderr);
  assert.equal(result.stdout, '');
});
}
for (const job of [null, [], 'App tests', { name: 'Other job', status: [], conclusion: 'success' }]) {
  test(`CI validates every job before stale-head handling: ${JSON.stringify(job)}`, t => {
    const run = validRun();
    run.jobs.push(job);
    const result = runCI(t, run, { expectedHead: 'b'.repeat(40) });
    assert.equal(result.status, 2, result.stderr);
    assert.equal(result.stdout, '');
  });
}

test('gates-rows requires a summary or CI run', () => {
  for (const args of [[], ['--head', head]]) {
    const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /^usage:/);
  }
});

test('summary and CI rows pass checkGates; stale CI carries NOT VERIFIED', async t => {
  const { checkGates } = await import('./ui-parity-pr-body-lint.mjs');
  const table = rows => `## Gates\n\n| Lane | Status | SHA | Source |\n|---|---|---|---|\n${rows}\n| audit | N/A | — | tooling-only test |\n| device-smoke | N/A | — | no user-visible change |\n`;
  const current = runCI(t, validRun(), { summary: true });
  assert.equal(current.status, 0, current.stderr);
  assert.equal(current.stdout.trim().split('\n').length, 8);
  assert.deepEqual(checkGates(table(current.stdout.trim()), head), { ok: true });

  const stale = runRows(t, complete, ['--ci', fileURLToPath(new URL('./fixtures/ci-stale.json', import.meta.url)), '--head', head]);
  assert.equal(stale.status, 0, stale.stderr);
  const staleBody = table(stale.stdout.trim());
  assert.match(staleBody, /\| app-tests \| NOT VERIFIED \|/);
  assert.deepEqual(checkGates(staleBody, head), { ok: true });
});

function assertAmbiguous(t, summary) {
  const result = runRows(t, summary, ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  const rows = result.stdout.trim().split('\n');
  assert.equal(rows.length, 7);
  for (const row of rows) assert.match(row, new RegExp(`\\| NOT VERIFIED \\| ${head} \\| owner-gates summary ambiguous \\|$`));
  assert.doesNotMatch(result.stdout, /\| PASS \|/);
}

for (const [design, status, lint] of [['0', 'PASS', { ok: true }], ['7', 'FAIL', { ok: false, reason: 'design-check is a FAIL row' }], [undefined, 'NOT VERIFIED', { ok: true }]]) {
  test(`design=${design ?? 'missing'} survives summary, Gates rows and PR lint`, async t => {
    const { checkGates } = await import('./ui-parity-pr-body-lint.mjs');
    const summary = complete.replace('design=0\n', design === undefined ? '' : `design=${design}\n`);
    const result = runCI(t, validRun(), { summary });
    assert.equal(result.status, 0, result.stderr);
    const source = design === undefined ? 'owner-gates summary missing design' : `owner-gates design=${design}`;
    assert.ok(result.stdout.trim().split('\n').includes(`| design-check | ${status} | ${head} | ${source} |`), result.stdout);
    const body = `## Gates\n\n| Lane | Status | SHA | Source |\n|---|---|---|---|\n${result.stdout}| audit | N/A | — | tooling-only test |\n| device-smoke | N/A | — | no user-visible change |\n`;
    assert.deepEqual(checkGates(body, head), lint);
  });
}

test('duplicate design evidence including whitespace is ambiguous', t => {
  assertAmbiguous(t, complete.replace('design=0\n', 'design=0\ndesign = 7\n'));
});

test('malformed design evidence makes every lane unverified', t => {
  const result = runRows(t, complete.replace('design=0', 'design=invalid'), ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  const rows = result.stdout.trim().split('\n');
  assert.equal(rows.length, 7);
  for (const row of rows) assert.match(row, new RegExp(`\\| NOT VERIFIED \\| ${head} \\| owner-gates summary malformed \\|$`));
});

test('gates-rows rejects duplicate lane keys as ambiguous', t => {
  assertAmbiguous(t, complete.replace('node=0\n', 'node=0\nnode=1\n'));
});

test('gates-rows normalises whitespace before detecting duplicate keys', t => {
  assertAmbiguous(t, complete.replace('node=0\n', 'node=0\nnode = 1\n'));
});

test('gates-rows rejects a malformed recognised lane value', t => {
  const result = runRows(t, complete.replace('node=0', 'node=abc'), ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  const rows = result.stdout.trim().split('\n');
  assert.equal(rows.length, 7);
  for (const row of rows) assert.match(row, new RegExp(`\\| NOT VERIFIED \\| ${head} \\| owner-gates summary malformed \\|$`));
  assert.doesNotMatch(result.stdout, /\| (?:PASS|FAIL) \|/);
});

test('gates-rows rejects two concatenated runs as ambiguous', t => {
  assertAmbiguous(t, complete + complete.replaceAll(head, 'b'.repeat(40)));
});

test('gates-rows rejects DONE followed by another record as ambiguous', t => {
  assertAmbiguous(t, complete + 'late=1\n');
});

test('gates-rows converts a complete owner-gates summary to seven PASS rows', t => {
  const result = runRows(t, complete, ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'), [
    `| package-tests | PASS | ${head} | owner-gates swift=0 |`,
    `| package-coverage | PASS | ${head} | owner-gates lcov=0 |`,
    `| unsigned-build | PASS | ${head} | owner-gates xcodebuild=0 |`,
    `| node-tooling | PASS | ${head} | owner-gates node=0 |`,
    `| ledger | PASS | ${head} | owner-gates ledger=0 |`,
    `| diff-check | PASS | ${head} | owner-gates diffcheck=0 |`,
    `| design-check | PASS | ${head} | owner-gates design=0 |`,
  ]);
});

test('gates-rows marks every row NOT VERIFIED without final DONE', t => {
  const result = runRows(t, complete.replace('DONE\n', ''), ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  const rows = result.stdout.trim().split('\n');
  assert.equal(rows.length, 7);
  for (const row of rows) assert.match(row, new RegExp(`\\| NOT VERIFIED \\| ${head} \\| owner-gates summary incomplete \\|$`));
  assert.doesNotMatch(result.stdout, /\| PASS \|/);
});

test('gates-rows marks every row NOT VERIFIED for a stale summary head', t => {
  const currentHead = 'b'.repeat(40);
  const result = runRows(t, complete, ['--head', currentHead]);
  assert.equal(result.status, 0, result.stderr);
  const rows = result.stdout.trim().split('\n');
  assert.equal(rows.length, 7);
  for (const row of rows) assert.match(row, new RegExp(`\\| NOT VERIFIED \\| ${head} \\| owner-gates stale head ${head.slice(0, 7)} \\|$`));
  assert.doesNotMatch(result.stdout, /\| PASS \|/);
});

test('gates-rows converts a non-zero lane exit to FAIL', t => {
  const result = runRows(t, complete.replace('xcodebuild=0', 'xcodebuild=1'), ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(`^\\| unsigned-build \\| FAIL \\| ${head} \\| owner-gates xcodebuild=1 \\|$`, 'm'));
  assert.equal(result.stdout.match(/\| PASS \|/g).length, 6);
});

test('gates-rows marks a missing key NOT RUN with a reason', t => {
  const result = runRows(t, complete.replace('node=0\n', ''), ['--head', head]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^\| node-tooling \| NOT RUN \| — \| owner-gates summary missing node \|\n/m);
  assert.equal(result.stdout.match(/\| PASS \|/g).length, 6);
});

test('gates-rows rejects a missing summary without emitting PASS', t => {
  const directory = mkdtempSync(join(tmpdir(), 'picsee-gates-rows-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const result = spawnSync(process.execPath, [script, join(directory, 'missing.txt'), '--head', head], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /\| PASS \|/);
});

test('CI design-check job uses pinned actions and runs the design gate', async () => {
  const { readFileSync } = await import('node:fs');
  const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = workflow.match(/^  design-check:\n([\s\S]*?)(?=^  [a-z][a-z-]*:\n|$(?![\s\S]))/m)?.[1];
  assert.ok(job, 'missing design-check job');
  assert.match(job, /name: Design check/);
  assert.match(job, /if: github\.event_name != 'workflow_dispatch'/);
  assert.match(job, /runs-on: ubuntu-latest/);
  assert.match(job, /timeout-minutes: 10/);
  assert.match(job, /actions\/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4\.4\.0/);
  assert.match(job, /actions\/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4\.4\.0/);
  assert.match(job, /run: npm ci --ignore-scripts/);
  assert.match(job, /run: npx playwright install --with-deps chromium/);
  assert.match(job, /run: npm run design:check/);
});

test('PR-body workflow isolates PR tests from the trusted body-gates runner', async () => {
  const { readFileSync } = await import('node:fs');
  const workflow = readFileSync(new URL('../../.github/workflows/pr-body.yml', import.meta.url), 'utf8');
  const ci = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  assert.match(workflow, /on:\n  pull_request:\n    types: \[opened, edited, synchronize, reopened\]/);
  assert.match(workflow, /permissions:\n  contents: read/);
  assert.match(workflow, /concurrency:\n  group: \$\{\{ github\.workflow \}\}-\$\{\{ github\.event\.pull_request\.number \}\}\n  cancel-in-progress: true/);
  assert.doesNotMatch(ci, /^  pr-body-lint:/m);
  assert.doesNotMatch(workflow, /^\s+needs:/m);
  const agentJob = workflow.match(/^  agent-tests:\n([\s\S]*?)(?=^  [a-z][a-z-]*:\n|$(?![\s\S]))/m)?.[1];
  const gatesJob = workflow.match(/^  pr-body-gates:\n([\s\S]*?)(?=^  [a-z][a-z-]*:\n|$(?![\s\S]))/m)?.[1];
  assert.ok(agentJob, 'missing agent-tests job');
  assert.ok(gatesJob, 'missing independent pr-body-gates job');
  assert.match(agentJob, /- name: Checkout PR head[\s\S]*?ref: \$\{\{ github\.event\.pull_request\.head\.sha \}\}[\s\S]*?path: pr-head/);
  assert.match(agentJob, /- name: Test agent tooling\n        working-directory: pr-head\n        run: node --test scripts\/agents\/\*\.test\.mjs/);
  assert.match(agentJob, /runs-on: ubuntu-latest/);
  assert.match(agentJob, /timeout-minutes: 5/);
  const command = agentJob.match(/run: (node --test .+)/)?.[1];
  assert.ok(command, 'missing tooling test command');
  for (const suite of ['agents', 'perf', 'ledger', 'tdd']) {
    assert.ok(command.split(/\s+/).includes(`scripts/${suite}/*.test.mjs`), `missing ${suite} suite`);
  }
  assert.match(gatesJob, /if: github\.event_name == 'pull_request'/);
  assert.match(gatesJob, /- name: Checkout trusted base[\s\S]*?ref: \$\{\{ github\.event\.pull_request\.base\.sha \}\}[\s\S]*?path: trusted/);
  assert.match(gatesJob, /- name: Checkout PR head[\s\S]*?ref: \$\{\{ github\.event\.pull_request\.head\.sha \}\}[\s\S]*?path: pr-head/);
  assert.match(gatesJob, /actions\/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4\.4\.0/);
  assert.doesNotMatch(gatesJob, /node --test/);
  for (const line of gatesJob.split('\n').filter(line => /\bnode\s+/.test(line))) {
    assert.match(line, /\bnode\s+(?:\.\.\/)?trusted\//, line);
  }
  assert.match(gatesJob, /- name: Check PR body gates\n        working-directory: pr-head/);
  assert.match(gatesJob, /PR_BODY: \$\{\{ github\.event\.pull_request\.body \}\}/);
  assert.match(gatesJob, /grep -q '\^export function checkGates' \.\.\/trusted\/scripts\/agents\/ui-parity-pr-body-lint\.mjs/);
  assert.match(gatesJob, /trusted PR-body lint lacks checkGates/);
  assert.match(gatesJob, /printf '%s' "\$PR_BODY" > "\$RUNNER_TEMP\/pr-body\.md"/);
  assert.match(gatesJob, /node \.\.\/trusted\/scripts\/agents\/ui-parity-pr-body-lint\.mjs --base origin\/main --body-file "\$RUNNER_TEMP\/pr-body\.md"/);
  const shell = [...gatesJob.matchAll(/run: \|\n((?:        .*\n?)+)/g)].map(match => match[1]).join('\n');
  assert.doesNotMatch(shell, /\$\{\{\s*github\.event\.pull_request\.body/);
  assert.doesNotMatch(gatesJob, /xcode/i);
});

test('pre-Gates baseline lint fails the trusted guard', async t => {
  const { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import('node:fs');
  const { execFileSync } = await import('node:child_process');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const workflow = readFileSync(new URL('../../.github/workflows/pr-body.yml', import.meta.url), 'utf8');
  const checkStep = workflow.match(/- name: Check PR body gates\n([\s\S]*)$/)?.[1];
  assert.ok(checkStep, 'missing Check PR body gates step');
  const indentedShell = checkStep.match(/run: \|\n((?:          .*\n?)+)/)?.[1];
  assert.ok(indentedShell, 'missing trusted lint shell');
  const shell = indentedShell.split('\n').filter(Boolean).map(line => line.slice(10)).join('\n');
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const baseline = execFileSync('git', ['show', '3de39c60:scripts/agents/ui-parity-pr-body-lint.mjs'], { cwd: root, encoding: 'utf8' });
  assert.doesNotMatch(baseline, /^export function checkGates/m);
  const directory = mkdtempSync(join(tmpdir(), 'picsee-trusted-lint-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  mkdirSync(join(directory, 'trusted/scripts/agents'), { recursive: true });
  mkdirSync(join(directory, 'pr-head'));
  writeFileSync(join(directory, 'trusted/scripts/agents/ui-parity-pr-body-lint.mjs'), baseline);
  const result = spawnSync('bash', ['-eu', '-c', shell], {
    cwd: join(directory, 'pr-head'),
    env: { ...process.env, PR_BODY: '## Summary\n', RUNNER_TEMP: directory },
    encoding: 'utf8',
  });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /trusted PR-body lint lacks checkGates/);
  assert.doesNotMatch(result.stdout, /UI-Parity PR body: PASS/);
});

test('GitHub Actions pins every remote uses line to a SHA with a version comment', async () => {
  const { readFileSync, readdirSync } = await import('node:fs');
  const directory = new URL('../../.github/workflows/', import.meta.url);
  for (const file of readdirSync(directory).filter(file => file.endsWith('.yml'))) {
    const lines = readFileSync(new URL(file, directory), 'utf8').split(/\r?\n/);
    for (const line of lines.filter(line => /^\s*uses:/.test(line))) {
      if (/^\s*uses: \.\//.test(line)) continue;
      assert.match(line, /^\s*uses: \S+@[0-9a-f]{40} # v\S+$/, `${file}: ${line.trim()}`);
    }
  }
});
