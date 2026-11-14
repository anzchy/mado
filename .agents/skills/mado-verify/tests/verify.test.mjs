import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const skill = fileURLToPath(new URL('../', import.meta.url));
const script = name => path.join(skill, 'scripts', name);
const mandatoryNames = ['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'node', 'ledger', 'design'];
const gates = (overrides = {}) => mandatoryNames.map(name => ({ name, command: name, exitCode: overrides[name] ?? 0 }));
function run(cmd, args, cwd, input) {
  return spawnSync(cmd, args, { cwd, encoding: 'utf8', input });
}
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-verify-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const args of [['init', '-q'], ['config', 'user.email', 'fixture@example.invalid'], ['config', 'user.name', 'Fixture']]) assert.equal(run('git', args, dir).status, 0);
  fs.writeFileSync(path.join(dir, 'sample.test.swift'), 'func testOne() { #expect(true) }\n');
  run('git', ['add', 'sample.test.swift'], dir); run('git', ['commit', '-qm', 'base'], dir);
  const base = run('git', ['rev-parse', 'HEAD'], dir).stdout.trim();
  run('git', ['update-ref', 'refs/remotes/origin/main', base], dir);
  marker(dir, dir, run('git', ['symbolic-ref', '-q', '--short', 'HEAD'], dir).stdout.trim(), 648, 'i648');
  return { dir, base, head: () => run('git', ['rev-parse', 'HEAD'], dir).stdout.trim(), commit: () => { run('git', ['add', 'sample.test.swift'], dir); run('git', ['commit', '-qm', 'change'], dir); } };
}
function marker(home, worktree, branch, issue = 651, task = 'i651-20261111-a', handoff = path.join(home, 'handoff.md')) {
  const file = path.join(home, '.build/mado-verify/target-worktree');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ worktree, branch, issue, task, handoff }) + '\n');
  const head = run('git', ['rev-parse', 'HEAD'], worktree);
  if (head.status === 0) fs.writeFileSync(handoff, `Worktree: ${worktree}\nBranch: ${branch}\nHEAD: ${head.stdout.trim()}\n`);
  return file;
}

test('integrity scan reports assertion removal, skips, retry, timeout, exit and counts', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testOne() { #expect(true == true); XCTSkip(); .disabled; retry; timeout: 120; exit(0) }\nfunc testTwo() {}\n');
  f.commit();
  const r = run('node', [script('test-integrity.mjs'), '--base', f.base], f.dir);
  assert.equal(r.status, 0, r.stderr);
  const report = JSON.parse(r.stdout);
  for (const type of ['assertion-removed', 'skip', 'retry', 'timeout', 'exit-zero']) assert.ok(report.hits.some(x => x.type === type), type);
  assert.equal(report.testCounts.before, 1); assert.equal(report.testCounts.after, 2);
  assert.ok(report.receipts.some(x => x.status === 'MISSING-RED'));
});

test('integrity scan ignores a non-test script whose name contains test', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.dir, 'test-integrity.mjs'), 'const retry = 1;\n');
  run('git', ['add', 'test-integrity.mjs'], f.dir); run('git', ['commit', '-qm', 'script'], f.dir);
  const r = run('node', [script('test-integrity.mjs'), '--base', f.base], f.dir);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).hits.length, 0);
});

test('evidence renderer scans privacy and record writer requires a real comment URL', t => {
  const f = fixture(t);
  const data = { issue: 648, task: 'i648', branch: 'test', head: f.base, gates: gates(), integrity: 'none', byType: [{ behavior: 'tool', expected: 'pass', actual: 'pass', result: 'PASS' }], notVerified: ['none'] };
  const source = path.join(f.dir, 'input.json'); fs.writeFileSync(source, JSON.stringify(data));
  const rendered = run('node', [script('evidence.mjs'), 'render', source], f.dir);
  assert.equal(rendered.status, 0, rendered.stderr);
  assert.match(rendered.stdout, /<!-- mado-verify issue=648 task=i648 head=/);
  assert.match(rendered.stdout, /#### NOT VERIFIED/);
  data.integrity = '/Users/private-name'; fs.writeFileSync(source, JSON.stringify(data));
  assert.notEqual(run('node', [script('evidence.mjs'), 'render', source], f.dir).status, 0);
  data.integrity = 'none'; fs.writeFileSync(source, JSON.stringify(data));
  assert.notEqual(run('node', [script('evidence.mjs'), 'record', source], f.dir).status, 0);
  data.commentUrl = 'https://github.com/anzchy/mado/issues/648#issuecomment-123'; fs.writeFileSync(source, JSON.stringify(data));
  assert.equal(run('node', [script('evidence.mjs'), 'record', source], f.dir).status, 0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify', `${f.base}.json`))).head, f.base);
});

function check(f, head, extra = []) {
  return run('node', [script('evidence.mjs'), 'check', '--head', head, ...extra], f.dir);
}
function recordFor(f, data) {
  const source = path.join(f.dir, '.build/input.json');
  fs.mkdirSync(path.dirname(source), { recursive: true });
  fs.writeFileSync(source, JSON.stringify({ issue: 648, task: 'i648', branch: 'test', head: f.head(), integrity: 'none', byType: [], notVerified: ['none'], commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-9', gates: gates(), ...data }));
  const r = run('node', [script('evidence.mjs'), 'record', source], f.dir);
  assert.equal(r.status, 0, r.stderr);
}

test('manual check passes on a complete record for the head, also via --worktree and a SHA prefix', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  recordFor(f, {});
  const ok = check(f, f.head());
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, new RegExp(`^OK head=${f.head()} issue=648 comment=https://github\\.com/anzchy/mado/issues/648#issuecomment-9$`, 'm'));
  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-check-cwd-')); t.after(() => fs.rmSync(other, { recursive: true, force: true }));
  const remote = run('node', [script('evidence.mjs'), 'check', '--head', f.head().slice(0, 9), '--worktree', f.dir], other);
  assert.equal(remote.status, 0, remote.stderr);
});

test('manual check fails on a stale head: record for an older commit, or --head not the worktree HEAD', t => {
  const f = fixture(t);
  recordFor(f, {});
  const old = f.head();
  assert.equal(check(f, old).status, 0);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  const stale = check(f, old);
  assert.equal(stale.status, 1);
  assert.match(stale.stderr, /not the worktree HEAD/);
  const missing = check(f, f.head());
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /no mado-verify record/);
  const forged = path.join(f.dir, '.build/mado-verify', `${f.head()}.json`);
  fs.writeFileSync(forged, JSON.stringify({ ...JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify', `${old}.json`), 'utf8')), head: old }));
  assert.match(check(f, f.head()).stderr, /record head/);
});

test('manual check fails on a failed or missing gate', t => {
  const f = fixture(t);
  recordFor(f, { gates: gates({ swift: 1 }) });
  const failed = check(f, f.head());
  assert.equal(failed.status, 1);
  assert.match(failed.stderr, /failed swift: 1/);
  recordFor(f, { gates: gates().slice(1) });
  assert.match(check(f, f.head()).stderr, /missing diffcheck/);
});

test('manual check fails on a missing or foreign commentUrl', t => {
  const f = fixture(t);
  recordFor(f, {});
  const file = path.join(f.dir, '.build/mado-verify', `${f.head()}.json`);
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const commentUrl of [undefined, '', 'https://github.com/anzchy/mado/issues/649#issuecomment-9', 'https://example.com/x']) {
    fs.writeFileSync(file, JSON.stringify({ ...record, commentUrl }));
    const r = check(f, f.head());
    assert.equal(r.status, 1, String(commentUrl));
    assert.match(r.stderr, /commentUrl/);
  }
});

test('manual check fails on tracked changes and on bad usage', t => {
  const f = fixture(t);
  recordFor(f, {});
  fs.appendFileSync(path.join(f.dir, 'sample.test.swift'), '// dirty\n');
  assert.match(check(f, f.head()).stderr, /tracked changes/);
  assert.equal(run('node', [script('evidence.mjs'), 'check'], f.dir).status, 1);
  assert.equal(run('node', [script('evidence.mjs'), 'check', '--head', 'zzz'], f.dir).status, 1);
});

test('mark-target writes complete dispatch identity', t => {
  const f = fixture(t), target = `${f.dir}-target`;
  t.after(() => fs.rmSync(target, { recursive: true, force: true }));
  assert.equal(run('git', ['worktree', 'add', '-q', '-b', 'feature', target], f.dir).status, 0);
  const handoff = path.join(f.dir, 'round-handoff.md');
  const r = run('node', [script('mark-target.mjs'), f.dir, target, '651', 'i651-20261111-a', handoff], f.dir);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify/target-worktree'))), { worktree: fs.realpathSync(target), branch: 'feature', issue: 651, task: 'i651-20261111-a', handoff });
});
