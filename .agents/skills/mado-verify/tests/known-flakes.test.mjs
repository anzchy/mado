import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Owner 2026-11-14: verification gaps — known flaky tooling tests get one recorded procedure and one list.
const root = fileURLToPath(new URL('../../../../', import.meta.url));
const skillDir = path.join(root, '.agents/skills/mado-verify');
const listFile = path.join(skillDir, 'known-flakes.json');
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

import { knownFlakeProblems } from '../scripts/known-flakes.mjs';

// #759: every entry carries issue, owner and expires (the app-quarantine.json shape); an invalid or expired entry fails
// this test, so it fails the node lane. Nothing retries a failure because of the list, and evidence.mjs never reads it.
const today = '2026-11-20';
const valid = () => ({
  file: 'scripts/tdd/unit-lane.test.mjs',
  name: 'i632M1 fallback validates a known orphan when the full interrupt process query fails',
  pattern: '^i632M1 fallback validates a known orphan when the full interrupt process query fails$',
  why: 'process-query timing on a loaded machine (fixture entry)',
  issue: 759, owner: 'delegator', expires: '2026-12-01',
});
const problems = (entry, day = today) => knownFlakeProblems({ $comment: 'x', flakes: [entry] }, { root, today: day });

test('the real known-flake list passes the entry check today (the lane check)', () => {
  const list = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  assert.ok(Array.isArray(list.flakes));
  assert.deepEqual(knownFlakeProblems(list, { root, today: new Date().toISOString().slice(0, 10) }), []);
});

test('a valid entry naming an existing test with its exact pattern passes', () => {
  assert.deepEqual(problems(valid()), []);
});

test('an entry without issue, owner or expires is rejected', () => {
  for (const field of ['issue', 'owner', 'expires']) {
    const entry = valid(); delete entry[field];
    assert.match(problems(entry).join('\n'), new RegExp(field), `missing ${field}`);
  }
  assert.match(problems({ ...valid(), issue: 0 }).join('\n'), /issue/);
  assert.match(problems({ ...valid(), issue: '759' }).join('\n'), /issue/);
  assert.match(problems({ ...valid(), owner: '  ' }).join('\n'), /owner/);
  assert.match(problems({ ...valid(), extra: 1 }).join('\n'), /extra/);
});

test('an expired entry is rejected; it is still valid on its expiry day', () => {
  assert.deepEqual(problems({ ...valid(), expires: '2026-11-20' }), []);
  assert.match(problems({ ...valid(), expires: '2026-11-19' }).join('\n'), /expired 2026-11-19/);
});

test('expires must be a real ISO date at most 30 days out', () => {
  assert.deepEqual(problems({ ...valid(), expires: '2026-12-20' }), []);
  assert.match(problems({ ...valid(), expires: '2026-12-21' }).join('\n'), /30 days/);
  assert.match(problems({ ...valid(), expires: '2026-02-30' }).join('\n'), /expires/);
  assert.match(problems({ ...valid(), expires: '2026-12-1' }).join('\n'), /expires/);
});

test('an entry must name a test in its file and rerun it with the exact anchored pattern', () => {
  assert.match(problems({ ...valid(), pattern: 'i632M1' }).join('\n'), /pattern/);
  assert.match(problems({ ...valid(), name: 'no such test name' , pattern: '^no such test name$' }).join('\n'), /not found/);
  assert.match(problems({ ...valid(), file: 'scripts/tdd/missing.test.mjs' }).join('\n'), /not found/);
  assert.match(problems({ ...valid(), why: 'short' }).join('\n'), /why/);
  const twice = knownFlakeProblems({ $comment: 'x', flakes: [valid(), valid()] }, { root, today });
  assert.match(twice.join('\n'), /duplicate/);
});

test('the list comment points App quarantine at scripts/tdd/app-quarantine.json', () => {
  const list = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  assert.match(list.$comment, /scripts\/tdd\/app-quarantine\.json/);
  assert.doesNotMatch(list.$comment, /known-flaky\.mjs/);
  assert.match(list.$comment, /issue/);
  assert.match(list.$comment, /expires/);
});

test('SKILL.md step 1 points to the list and the exact two-rerun procedure, with no gate retry', () => {
  const skill = fs.readFileSync(path.join(skillDir, 'SKILL.md'), 'utf8');
  const step1 = skill.slice(skill.indexOf('## 1. Gate ladder'), skill.indexOf('## 2.'));
  assert.match(step1, /known-flakes\.json/);
  assert.match(step1, /node --test --test-name-pattern=/);
  assert.match(step1, /exactly one known-flaky test/i);
  assert.match(step1, /twice/);
  const owner = fs.readFileSync(path.join(root, '.agents/skills/mado-delegator/scripts/owner-gates.sh'), 'utf8');
  assert.doesNotMatch(owner, /known-flakes|retry/i);
  assert.match(fs.readFileSync(path.join(root, 'docs/agents/ci-flake-repro.md'), 'utf8'), /known-flakes\.json/);
});

// #892 (owner 2026-11-25): the one bounded exception to "no flake exception". A node lane that failed outside the diff and
// passed its single serial rerun is accepted only through a reviewed disposition: advisory, never silently green.
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import { gateVerdict, MANDATORY_GATES } from '../scripts/gate-policy.mjs';

const day = '2026-11-25';
const failing = [{ file: 'scripts/tdd/b.test.mjs', name: 'b first exec, slow' }];
const flakyNode = (change = g => g) => change({
  name: 'node', command: 'owner-gates.sh (node lane)', exitCode: 1, keyLine: 'node=1',
  attempts: [{ exitCode: 1, log: 'i9-node.log', tests: structuredClone(failing) },
    { exitCode: 0, log: 'i9-node-rerun.log', files: ['scripts/tdd/b.test.mjs'] }],
  disposition: { kind: 'flaky', tests: structuredClone(failing), issue: 891, owner: 'delegator', reviewedBy: 'mado-delegator',
    expires: '2026-12-01', failedAttempt: 'i9-node.log' },
});
const ladder = node => MANDATORY_GATES.map(name => name === 'node' ? node : { name, command: name, exitCode: 0 });
const verdict = (node, today = day) => gateVerdict(ladder(node), { today });

test('892 WI-3 a reviewed flake disposition satisfies the node gate; an unexplained non-zero node lane does not', () => {
  assert.deepEqual(verdict(flakyNode()), { complete: true, problems: [] });
  assert.match(verdict({ name: 'node', command: 'node', exitCode: 1 }).problems.join('\n'), /failed node: 1/);
  assert.match(verdict(flakyNode(g => { delete g.disposition; return g; })).problems.join('\n'), /failed node: 1/);
});

test('892 WI-3 the disposition needs an expiry within 30 days', () => {
  for (const [expires, ok] of [['2026-11-25', true], ['2026-12-25', true], ['2026-12-26', false], ['2026-11-24', false],
    ['2026-02-30', false], ['2026-12-1', false], [undefined, false]]) {
    const v = verdict(flakyNode(g => { if (expires === undefined) delete g.disposition.expires; else g.disposition.expires = expires; return g; }));
    assert.equal(v.complete, ok, `${expires}: ${v.problems}`);
    if (!ok) assert.match(v.problems.join('\n'), /expires/, `${expires}`);
  }
});

test('892 WI-3 the disposition names an issue, an owner, a reviewer and the retained failed attempt', () => {
  for (const [label, change] of [
    ['issue 0', g => { g.disposition.issue = 0; }], ['issue -1', g => { g.disposition.issue = -1; }], ['issue text', g => { g.disposition.issue = '#123'; }],
    ['no issue', g => { delete g.disposition.issue; }], ['blank owner', g => { g.disposition.owner = ' '; }], ['no owner', g => { delete g.disposition.owner; }],
    ['no reviewer', g => { delete g.disposition.reviewedBy; }], ['blank reviewer', g => { g.disposition.reviewedBy = ''; }],
    ['other failed attempt', g => { g.disposition.failedAttempt = 'i9-node-rerun.log'; }], ['kind', g => { g.disposition.kind = 'quarantine'; }]]) {
    const v = verdict(flakyNode(g => { change(g); return g; }));
    assert.equal(v.complete, false, label);
  }
});

test('892 WI-3 exactly two attempts: the failed first equals the gate exit, the single rerun passed the same files', () => {
  for (const [label, change] of [
    ['one attempt', g => { g.attempts.pop(); }], ['three attempts', g => { g.attempts.push({ exitCode: 0, log: 'x', files: ['scripts/tdd/b.test.mjs'] }); }],
    ['rerun failed', g => { g.attempts[1].exitCode = 1; }], ['first passed', g => { g.attempts[0].exitCode = 0; }],
    ['first differs from gate', g => { g.attempts[0].exitCode = 2; }], ['rerun other files', g => { g.attempts[1].files = ['scripts/tdd/c.test.mjs']; }],
    ['rerun extra files', g => { g.attempts[1].files.push('scripts/tdd/c.test.mjs'); }], ['no failing tests', g => { g.attempts[0].tests = []; }],
    ['no attempts', g => { delete g.attempts; }]]) {
    assert.equal(verdict(flakyNode(g => { change(g); return g; })).complete, false, label);
  }
});

test('892 WI-3 the disposition covers exactly the failing tests, in both directions', () => {
  const two = g => { const extra = { file: 'scripts/agents/a.test.mjs', name: 'a' }; g.attempts[0].tests.push(extra);
    g.attempts[1].files = ['scripts/agents/a.test.mjs', 'scripts/tdd/b.test.mjs']; g.disposition.tests.push({ ...extra }); return g; };
  assert.equal(verdict(flakyNode(two)).complete, true);
  assert.equal(verdict(flakyNode(g => { two(g); g.disposition.tests.pop(); return g; })).complete, false, 'one failing test not disposed');
  assert.equal(verdict(flakyNode(g => { g.disposition.tests.push({ file: 'scripts/tdd/b.test.mjs', name: 'other' }); return g; })).complete, false, 'extra test');
  assert.equal(verdict(flakyNode(g => { g.disposition.tests[0].name = 'b first exec'; return g; })).complete, false, 'inexact name');
});

test('892 WI-3 only the node gate carries a disposition, and only when it failed', () => {
  const passing = flakyNode(g => { g.exitCode = 0; return g; });
  assert.equal(gateVerdict(ladder(passing), { today: day }).complete, false, 'disposition on a passing node gate');
  const swift = { ...flakyNode(), name: 'swift' };
  const gates = ladder({ name: 'node', command: 'node', exitCode: 0 }).map(g => g.name === 'swift' ? swift : g);
  assert.match(gateVerdict(gates, { today: day }).problems.join('\n'), /swift/);
});

// evidence.mjs check on a real git repository: the record's base..head diff decides in-diff and the node scope skip.
const evidence = path.join(skillDir, 'scripts/evidence.mjs');
const git = (dir, ...args) => { const r = spawnSync('git', args, { cwd: dir, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
function repo(t, changed) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-verify-892-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  git(dir, 'init', '-q'); git(dir, 'config', 'user.email', 'fixture@example.invalid'); git(dir, 'config', 'user.name', 'Fixture');
  fs.writeFileSync(path.join(dir, 'README'), 'base\n'); git(dir, 'add', 'README'); git(dir, 'commit', '-qm', 'base');
  const base = git(dir, 'rev-parse', 'HEAD');
  git(dir, 'update-ref', 'refs/remotes/origin/main', base);
  for (const file of changed) { fs.mkdirSync(path.dirname(path.join(dir, file)), { recursive: true }); fs.writeFileSync(path.join(dir, file), 'x\n'); git(dir, 'add', file); }
  git(dir, 'commit', '-qm', 'change', '--allow-empty');
  return { dir, base, head: git(dir, 'rev-parse', 'HEAD') };
}
const utcToday = () => new Date().toISOString().slice(0, 10);
const inDays = n => new Date(Date.parse(`${utcToday()}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
function check(r, node, base = r.base) {
  const record = { head: r.head, base, issue: 892, commentUrl: 'https://github.com/anzchy/mado/issues/892#issuecomment-1', gates: ladder(node) };
  fs.mkdirSync(path.join(r.dir, '.build/mado-verify'), { recursive: true });
  fs.writeFileSync(path.join(r.dir, '.build/mado-verify', `${r.head}.json`), JSON.stringify(record));
  return spawnSync(process.execPath, [evidence, 'check', '--head', r.head, '--issue', '892', '--worktree', r.dir], { encoding: 'utf8' });
}
const liveFlaky = () => flakyNode(g => { g.disposition.expires = inDays(7); return g; });

test('892 WI-3 check accepts a reviewed disposition outside the diff and warns that it is a flake, not a pass', t => {
  const r = repo(t, ['App/MadoApp.swift', 'scripts/agents/tool.mjs']);
  const ok = check(r, liveFlaky());
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /^OK head=/m);
  assert.match(ok.stdout, /^WARNING node FLAKY: b first exec, slow \(scripts\/tdd\/b\.test\.mjs\) failed attempt 1 \(i9-node\.log\), passed its one serial rerun; disposition issue #891 owner delegator reviewed by mado-delegator expires \d{4}-\d{2}-\d{2}$/m);
  const red = check(r, { name: 'node', command: 'node', exitCode: 1 });
  assert.equal(red.status, 1);
  assert.match(red.stderr, /failed node: 1/);
});

test('892 WI-3 check rejects a disposition for a test the diff touches, its file or its directory', t => {
  for (const changed of [['scripts/tdd/b.test.mjs'], ['scripts/tdd/heavy-lock.py']]) {
    const r = repo(t, changed);
    const res = check(r, liveFlaky());
    assert.equal(res.status, 1, `${changed}: ${res.stdout}`);
    assert.match(res.stderr, /disposition .*in the diff/, `${changed}`);
  }
});

test('892 WI-1 check accepts a node scope skip only when the diff selects no node lane', t => {
  const skip = { name: 'node', command: 'owner-gates.sh (OWNER_GATES_ROLE=implementer)', exitCode: 0,
    scopeSkip: 'implementer run; diff touches no scripts/, .agents/, .github/ or .claude/ path' };
  const product = repo(t, ['App/MadoApp.swift', 'Packages/MadoKit/Sources/MadoCore/A.swift']);
  const ok = check(product, skip);
  assert.equal(ok.status, 0, ok.stderr);
  for (const changed of [['App/MadoApp.swift', 'scripts/ci/x.mjs'], ['.github/workflows/ci.yml'], ['.claude/agents/a.md'], ['.agents/skills/x/SKILL.md'], []]) {
    const r = repo(t, changed);
    const res = check(r, skip);
    assert.equal(res.status, 1, `${changed}: ${res.stdout}`);
    assert.match(res.stderr, /node scope skip/, `${changed}`);
  }
  const unlistable = check(product, skip, 'f'.repeat(40));
  assert.equal(unlistable.status, 1);
  assert.match(unlistable.stderr, /node scope skip/);
});

test('892 WI-3 the rendered comment and the record show both attempts and the disposition', t => {
  const r = repo(t, ['App/MadoApp.swift']);
  const input = path.join(r.dir, '.build/input.json');
  fs.mkdirSync(path.dirname(input), { recursive: true });
  const data = { issue: 892, task: 'i892', branch: 'b', head: r.head, gates: ladder(liveFlaky()), integrity: 'none', byType: [], notVerified: ['none'],
    commentUrl: 'https://github.com/anzchy/mado/issues/892#issuecomment-2' };
  fs.writeFileSync(input, JSON.stringify(data));
  const rendered = spawnSync(process.execPath, [evidence, 'render', input], { cwd: r.dir, encoding: 'utf8' });
  assert.equal(rendered.status, 0, rendered.stderr);
  assert.match(rendered.stdout, /exit 1 \(attempt 1, i9-node\.log: b first exec, slow\); rerun of scripts\/tdd\/b\.test\.mjs exit 0 \(i9-node-rerun\.log\); FLAKY, reviewed disposition: issue #891, owner delegator, reviewed by mado-delegator, expires \d{4}-\d{2}-\d{2}; not a pass/);
  const recorded = spawnSync(process.execPath, [evidence, 'record', input], { cwd: r.dir, encoding: 'utf8' });
  assert.equal(recorded.status, 0, recorded.stderr);
  const record = JSON.parse(fs.readFileSync(path.join(r.dir, '.build/mado-verify', `${r.head}.json`), 'utf8'));
  assert.equal(record.lanes.node.status, 'flaky-disposition');
  assert.deepEqual(record.gates.find(g => g.name === 'node').attempts.map(a => a.exitCode), [1, 0]);
  assert.equal(record.complete, true);
});

// #892 review round: the fields that decide in-diff must be repo-relative, the reviewer is not the flake's owner, and an
// unreadable date fails closed.
test('892 review a disposition test file must be a normalized repository-relative path', () => {
  for (const file of ['/abs/scripts/tdd/b.test.mjs', './scripts/tdd/b.test.mjs', '../scripts/tdd/b.test.mjs', 'scripts//tdd/b.test.mjs', 'scripts/tdd/../tdd/b.test.mjs']) {
    const v = verdict(flakyNode(g => { for (const t of [...g.attempts[0].tests, ...g.disposition.tests]) t.file = file; g.attempts[1].files = [file]; return g; }));
    assert.equal(v.complete, false, file);
    assert.match(v.problems.join('\n'), /repository-relative/, file);
  }
});

test('892 review the reviewer differs from the owner, and an invalid today fails closed', () => {
  assert.match(verdict(flakyNode(g => { g.disposition.reviewedBy = g.disposition.owner; return g; })).problems.join('\n'), /reviewedBy/);
  for (const today of ['not-a-day', '2026-02-30', undefined]) {
    const v = gateVerdict(ladder(flakyNode()), { today });
    if (today === undefined) continue; // the default is the real UTC date
    assert.equal(v.complete, false, String(today));
    assert.match(v.problems.join('\n'), /today/, String(today));
  }
});
