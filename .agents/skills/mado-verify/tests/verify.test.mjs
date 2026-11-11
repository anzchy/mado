import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const skill = fileURLToPath(new URL('../', import.meta.url));
const script = name => path.join(skill, 'scripts', name);
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
  return { dir, base, head: () => run('git', ['rev-parse', 'HEAD'], dir).stdout.trim(), commit: () => { run('git', ['add', 'sample.test.swift'], dir); run('git', ['commit', '-qm', 'change'], dir); } };
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

test('evidence renderer scans privacy and record writer requires a real comment URL', t => {
  const f = fixture(t);
  const data = { issue: 648, task: 'i648', branch: 'test', head: f.base, gates: [{ command: 'node --test', exitCode: 0, keyLine: '2 tests' }], integrity: 'none', byType: [{ behavior: 'tool', expected: 'pass', actual: 'pass', result: 'PASS' }], notVerified: ['none'] };
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

test('Stop hook allows unchanged and non-repo; blocks stale, missing, dirty; allows fresh', t => {
  const f = fixture(t);
  const hook = () => run('node', [script('stop-hook.mjs')], f.dir, JSON.stringify({ hook_event_name: 'Stop', cwd: f.dir }));
  assert.equal(hook().status, 0);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  assert.match(hook().stdout, /"decision":"block"/);
  const old = path.join(f.dir, '.build/mado-verify'); fs.mkdirSync(old, { recursive: true });
  fs.writeFileSync(path.join(old, `${f.base}.json`), JSON.stringify({ head: f.base, commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-1', gates: [] }));
  assert.match(hook().stdout, /"decision":"block"/);
  fs.writeFileSync(path.join(old, `${f.head()}.json`), JSON.stringify({ head: f.head(), commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-2', gates: [{exitCode:0}] }));
  assert.equal(hook().status, 0); assert.equal(hook().stdout, '');
  fs.appendFileSync(path.join(f.dir, 'sample.test.swift'), '// dirty\n');
  assert.match(hook().stdout, /"decision":"block"/);
  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-nonrepo-')); t.after(() => fs.rmSync(other, { recursive: true, force: true }));
  assert.equal(run('node', [script('stop-hook.mjs')], other, '{}').status, 0);
});
