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
function role(dir, name = 'implementor') {
  const rules = path.join(dir, '.codex/rules'); fs.mkdirSync(rules, { recursive: true });
  fs.writeFileSync(path.join(rules, 'picsee-role.rules'), `# Local picsee role: ${name}\n`);
}
function hook(f, input = {}, extra = []) {
  return run('node', [script('stop-hook.mjs'), ...extra], f.dir, JSON.stringify({ hook_event_name: 'Stop', cwd: f.dir, ...input }));
}
function marker(home, worktree, branch, issue = 651, task = 'i651-20261111-a') {
  const file = path.join(home, '.build/mado-verify/target-worktree');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ worktree, branch, issue, task }) + '\n');
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

test('Stop hook allows unchanged and non-repo; blocks stale, missing, dirty; allows fresh', t => {
  const f = fixture(t);
  role(f.dir);
  const runHook = () => hook(f);
  assert.equal(runHook().status, 0);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  assert.match(runHook().stdout, /"decision":"block"/);
  const old = path.join(f.dir, '.build/mado-verify'); fs.mkdirSync(old, { recursive: true });
  fs.writeFileSync(path.join(old, `${f.base}.json`), JSON.stringify({ head: f.base, issue: 648, commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-1', gates: [] }));
  assert.match(runHook().stdout, /"decision":"block"/);
  fs.writeFileSync(path.join(old, `${f.head()}.json`), JSON.stringify({ head: f.head(), issue: 648, commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-2', gates: gates() }));
  assert.equal(runHook().status, 0); assert.equal(runHook().stdout, '');
  fs.appendFileSync(path.join(f.dir, 'sample.test.swift'), '// dirty\n');
  assert.match(runHook().stdout, /"decision":"block"/);
  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-nonrepo-')); t.after(() => fs.rmSync(other, { recursive: true, force: true }));
  assert.equal(run('node', [script('stop-hook.mjs')], other, '{}').status, 0);
});

test('failed or incomplete gate record remains evidence but cannot complete handoff', t => {
  const f = fixture(t); role(f.dir);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  const source = path.join(f.dir, 'input.json');
  const data = { issue: 648, task: 'i648', branch: 'test', head: f.head(), commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-3', gates: gates({ swift: 1 }), integrity: 'none', byType: [], notVerified: ['swift failed'] };
  for (const list of [data.gates, gates().slice(1)]) {
    data.gates = list; fs.writeFileSync(source, JSON.stringify(data));
    assert.equal(run('node', [script('evidence.mjs'), 'record', source], f.dir).status, 0);
    assert.match(hook(f).stdout, /"decision":"block"/);
  }
  data.gates = gates(); fs.writeFileSync(source, JSON.stringify(data));
  assert.equal(run('node', [script('evidence.mjs'), 'record', source], f.dir).status, 0);
  assert.equal(hook(f).stdout, '');
});

test('Stop allows continuation, BLOCKED handoff, question, auditor, absent overlay and absent main', t => {
  const f = fixture(t); role(f.dir);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  assert.match(hook(f).stdout, /"decision":"block"/);
  assert.equal(hook(f, { stop_hook_active: true }).stdout, '');
  assert.equal(hook(f, { last_assistant_message: 'BLOCKED: need an owner decision.' }).stdout, '');
  assert.equal(hook(f, { last_assistant_message: 'Should I continue?' }).stdout, '');
  role(f.dir, 'auditor'); assert.equal(hook(f).stdout, '');
  fs.unlinkSync(path.join(f.dir, '.codex/rules/picsee-role.rules')); assert.equal(hook(f).stdout, '');
  role(f.dir); run('git', ['update-ref', '-d', 'refs/remotes/origin/main'], f.dir); assert.equal(hook(f).stdout, '');
});

test('detached clean feature checkout allows read-only Stop; Claude agent flag scopes by agent', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  assert.equal(run('git', ['checkout', '--detach', '-q', 'HEAD'], f.dir).status, 0);
  role(f.dir);
  fs.unlinkSync(path.join(f.dir, '.build/mado-verify/target-worktree'));
  assert.equal(hook(f).stdout, '');
  assert.match(hook(f, {}, ['--role-source', 'claude-agent']).stdout, /"decision":"block"/);
});

test('Claude implementer agent frontmatter registers Stop before skill invocation', () => {
  const root = fileURLToPath(new URL('../../../../', import.meta.url));
  for (const name of ['opus-implementor', 'codex-implementor']) {
    const content = fs.readFileSync(path.join(root, '.claude/agents', `${name}.md`), 'utf8');
    assert.match(content.split('---')[1], /hooks:\s*\n\s*Stop:/);
    assert.match(content, /--role-source claude-agent/);
  }
});

test('Stop accepts only a top-level first-line BLOCKED and a final top-level question', t => {
  const f = fixture(t); role(f.dir);
  fs.writeFileSync(path.join(f.dir, 'sample.test.swift'), 'func testTwo() {}\n'); f.commit();
  for (const message of [
    'DONE\n> BLOCKED',
    'DONE\n```text\nBLOCKED\n```',
    'DONE\n```text\nCan I stop?\n```',
    'DONE\n> Can I stop?',
  ]) assert.match(hook(f, { last_assistant_message: message }).stdout, /"decision":"block"/, message);
  assert.equal(hook(f, { last_assistant_message: '\nBLOCKED: scope needs an amendment' }).stdout, '');
  assert.equal(hook(f, { last_assistant_message: 'BLOCKED\nDetails follow.' }).stdout, '');
  assert.equal(hook(f, { last_assistant_message: 'DONE\nCan I continue？' }).stdout, '');
});

test('pane-home marker checks briefed worktree and its own complete record', t => {
  const f = fixture(t), target = `${f.dir}-target`;
  t.after(() => fs.rmSync(target, { recursive: true, force: true }));
  assert.equal(run('git', ['worktree', 'add', '-q', '-b', 'feature', target], f.dir).status, 0);
  role(f.dir);
  fs.writeFileSync(path.join(target, 'sample.test.swift'), 'func changed() {}\n');
  run('git', ['add', 'sample.test.swift'], target); run('git', ['commit', '-qm', 'feature'], target);
  marker(f.dir, target, 'feature', 648, 'i648');
  assert.match(hook(f).stdout, /"decision":"block"/);
  const targetHead = run('git', ['rev-parse', 'HEAD'], target).stdout.trim();
  const record = path.join(target, '.build/mado-verify', `${targetHead}.json`);
  fs.mkdirSync(path.dirname(record), { recursive: true });
  fs.writeFileSync(record, JSON.stringify({ head: targetHead, issue: 648, commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-123', gates: gates() }));
  assert.equal(hook(f).stdout, '');
  fs.unlinkSync(record); fs.unlinkSync(path.join(f.dir, '.codex/rules/picsee-role.rules')); role(target);
  assert.match(hook(f).stdout, /"decision":"block"/, 'target overlay alone selects implementor role');
});

test('invalid target marker blocks implementor but allows auditor; absent marker keeps cwd behavior', t => {
  const f = fixture(t); role(f.dir);
  const markerFile = path.join(f.dir, '.build/mado-verify/target-worktree');
  marker(f.dir, '/tmp/no-such-mado-worktree', 'feature');
  assert.match(hook(f).stdout, /target worktree/i);
  role(f.dir, 'auditor'); assert.equal(hook(f).stdout, '');
  fs.unlinkSync(markerFile); role(f.dir); assert.match(hook(f).stdout, /target worktree/i);
  fs.writeFileSync(markerFile, `${f.dir}\n`);
  assert.match(hook(f).stdout, /Legacy one-line markers are invalid/);
});

test('dispatch marker rejects sibling, pane-home self-reference, stale branch and issue, and missing marker', t => {
  const f = fixture(t), target = `${f.dir}-target`, sibling = `${f.dir}-sibling`;
  for (const dir of [target, sibling]) t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  assert.equal(run('git', ['worktree', 'add', '-q', '-b', 'feature', target], f.dir).status, 0);
  assert.equal(run('git', ['worktree', 'add', '-q', '-b', 'sibling', sibling], f.dir).status, 0);
  role(f.dir);
  const file = marker(f.dir, target, 'feature');
  assert.match(hook(f, { last_assistant_message: `Worktree: ${sibling}` }).stdout, /"decision":"block"/);
  marker(f.dir, f.dir, 'feature');
  assert.match(hook(f).stdout, /"decision":"block"/);
  marker(f.dir, target, 'sibling');
  assert.match(hook(f).stdout, /"decision":"block"/);
  marker(f.dir, target, 'feature', 650);
  const head = run('git', ['rev-parse', 'HEAD'], target).stdout.trim();
  const record = path.join(target, '.build/mado-verify', `${head}.json`);
  fs.mkdirSync(path.dirname(record), { recursive: true });
  fs.writeFileSync(record, JSON.stringify({ head, issue: 651, commentUrl: 'https://github.com/anzchy/mado/issues/651#issuecomment-123', gates: gates() }));
  assert.match(hook(f).stdout, /"decision":"block"/);
  fs.unlinkSync(file);
  assert.match(hook(f).stdout, /"decision":"block"/);
  role(f.dir, 'auditor'); assert.equal(hook(f).stdout, '');
});

test('matching target and fresh complete record allows handoff; mismatched named HEAD blocks', t => {
  const f = fixture(t), target = `${f.dir}-target`;
  t.after(() => fs.rmSync(target, { recursive: true, force: true }));
  assert.equal(run('git', ['worktree', 'add', '-q', '-b', 'feature', target], f.dir).status, 0);
  role(f.dir); marker(f.dir, target, 'feature');
  const head = run('git', ['rev-parse', 'HEAD'], target).stdout.trim();
  const record = path.join(target, '.build/mado-verify', `${head}.json`);
  fs.mkdirSync(path.dirname(record), { recursive: true });
  fs.writeFileSync(record, JSON.stringify({ head, issue: 651, commentUrl: 'https://github.com/anzchy/mado/issues/651#issuecomment-123', gates: gates() }));
  assert.equal(hook(f, { last_assistant_message: `Worktree: ${target}\nBranch: feature\nHEAD: ${head}` }).stdout, '');
  assert.match(hook(f, { last_assistant_message: `Worktree: ${target}\nBranch: feature\nHEAD: ${f.base.replace(/^./, '0')}` }).stdout, /"decision":"block"/);
});

test('mark-target writes complete dispatch identity', t => {
  const f = fixture(t), target = `${f.dir}-target`;
  t.after(() => fs.rmSync(target, { recursive: true, force: true }));
  assert.equal(run('git', ['worktree', 'add', '-q', '-b', 'feature', target], f.dir).status, 0);
  const r = run('node', [script('mark-target.mjs'), f.dir, target, '651', 'i651-20261111-a'], f.dir);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify/target-worktree'))), { worktree: fs.realpathSync(target), branch: 'feature', issue: 651, task: 'i651-20261111-a' });
});
