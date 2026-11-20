import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const skill = fileURLToPath(new URL('../', import.meta.url));
const script = path.join(skill, 'scripts/reuse-check.mjs');
const evidence = path.join(skill, 'scripts/evidence.mjs');
const policy = path.join(skill, 'scripts/gate-policy.mjs');
const gateNames = ['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'apptests', 'node', 'ledger', 'design'];
const run = (cwd, command, args) => spawnSync(command, args, { cwd, encoding: 'utf8' });
function git(cwd, ...args) {
  const r = run(cwd, 'git', args);
  assert.equal(r.status, 0, `${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}
function write(cwd, name, value) {
  const file = path.join(cwd, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, value);
}
function fixture(t, mainPath = 'docs/note.md') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-reuse-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  git(dir, 'init', '-q', '-b', 'main');
  git(dir, 'config', 'user.email', 'fixture@example.invalid');
  git(dir, 'config', 'user.name', 'Fixture');
  write(dir, '.agents/skills/mado-verify/scripts/gate-policy.mjs', fs.readFileSync(policy));
  write(dir, 'App/Feature.swift', 'base\n');
  git(dir, 'add', '.'); git(dir, 'commit', '-qm', 'base');
  const oldBase = git(dir, 'rev-parse', 'HEAD');
  git(dir, 'update-ref', 'refs/remotes/origin/main', oldBase);
  git(dir, 'switch', '-qc', 'topic');
  write(dir, 'feature.txt', 'topic\n');
  git(dir, 'add', 'feature.txt'); git(dir, 'commit', '-qm', 'topic');
  const oldHead = git(dir, 'rev-parse', 'HEAD');
  const input = path.join(dir, 'input.json');
  write(dir, 'input.json', JSON.stringify({ issue: 772, task: 'fixture', branch: 'topic', head: oldHead,
    gates: gateNames.map(name => ({ name, command: name, exitCode: 0 })), integrity: 'none', byType: [], notVerified: [],
    commentUrl: 'https://github.com/anzchy/mado/issues/772#issuecomment-1' }));
  const recorded = run(dir, 'node', [evidence, 'record', input]);
  assert.equal(recorded.status, 0, recorded.stderr);
  git(dir, 'switch', '-q', 'main');
  write(dir, mainPath, 'main advance\n');
  git(dir, 'add', mainPath); git(dir, 'commit', '-qm', 'main advance');
  const newBase = git(dir, 'rev-parse', 'HEAD');
  git(dir, 'update-ref', 'refs/remotes/origin/main', newBase);
  git(dir, 'switch', '-q', 'topic'); git(dir, 'rebase', 'main');
  const newHead = git(dir, 'rev-parse', 'HEAD');
  return { dir, oldBase, newBase, oldHead, newHead, args: [oldBase, newBase, oldHead, newHead] };
}
function verdict(f) { return run(f.dir, 'node', [script, ...f.args]); }

test('docs-only main movement reuses after CODE same', t => {
  const f = fixture(t);
  const r = verdict(f);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^REUSE\b/);
});
test('explicitly allowed tooling main movement reuses', t => {
  const f = fixture(t, '.agents/skills/mado-verify/SKILL.md');
  assert.match(verdict(f).stdout, /^REUSE\b/);
});
for (const changed of ['App/Other.swift', 'Packages/MadoKit/Sources/Other.swift', 'Package.resolved', 'project.yml',
  'App/Mado.entitlements', 'App/Info.plist', '.github/workflows/check.yml', 'scripts/unknown.mjs',
  'scripts/tdd/unit-lane.mjs']) {
  test(`main movement touching ${changed} refuses reuse`, t => {
    const f = fixture(t, changed);
    const r = verdict(f);
    assert.match(r.stdout, new RegExp(`^RERUN .*${changed.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`), r.stdout + r.stderr);
  });
}
test('CODE different refuses reuse', t => {
  const f = fixture(t);
  write(f.dir, 'feature.txt', 'different topic\n');
  git(f.dir, 'add', 'feature.txt'); git(f.dir, 'commit', '--amend', '-qm', 'topic');
  f.args[3] = git(f.dir, 'rev-parse', 'HEAD');
  assert.match(verdict(f).stdout, /^RERUN .*CODE/);
});
test('wrong old base and missing historical fingerprint refuse reuse', t => {
  const f = fixture(t);
  assert.match(run(f.dir, 'node', [script, f.newBase, f.newBase, f.oldHead, f.newHead]).stdout, /^RERUN/);
  const file = path.join(f.dir, '.build/mado-verify', `${f.oldHead}.json`);
  const old = JSON.parse(fs.readFileSync(file));
  delete old.fingerprints;
  fs.writeFileSync(file, JSON.stringify(old));
  assert.match(verdict(f).stdout, /^RERUN .*fingerprint/i);
});
test('changed toolchain fingerprint refuses reuse', t => {
  const f = fixture(t);
  const file = path.join(f.dir, '.build/mado-verify', `${f.oldHead}.json`);
  const old = JSON.parse(fs.readFileSync(file));
  old.fingerprints.toolchain.swift = 'different Swift version';
  fs.writeFileSync(file, JSON.stringify(old));
  assert.match(verdict(f).stdout, /^RERUN historical fingerprint changed/);
});
test('gate policy changed on main refuses reuse', t => {
  const f = fixture(t, '.agents/skills/mado-verify/scripts/gate-policy.mjs');
  assert.match(verdict(f).stdout, /^RERUN \.agents\/skills\/mado-verify\/scripts\/gate-policy\.mjs/);
});

function linkedInput(f) {
  return { issue: 772, task: 'linked', branch: 'topic', head: f.newHead, base: f.newBase,
    link: { oldBase: f.oldBase, newBase: f.newBase, oldHead: f.oldHead, newHead: f.newHead },
    gates: gateNames.map(name => ({ name, command: name, exitCode: 0,
      ...(name === 'swift' || name === 'lcov' ? { reusedFrom: f.oldHead } : {}) })),
    integrity: 'none', byType: [], notVerified: [],
    commentUrl: 'https://github.com/anzchy/mado/issues/772#issuecomment-2' };
}
function recordLinked(f, input = linkedInput(f)) {
  const file = path.join(f.dir, 'linked-input.json');
  fs.writeFileSync(file, JSON.stringify(input));
  return run(f.dir, 'node', [evidence, 'record', file]);
}
test('linked record verifies and renders reused lanes as reused', t => {
  const f = fixture(t);
  const input = linkedInput(f);
  const source = path.join(f.dir, 'linked-input.json');
  fs.writeFileSync(source, JSON.stringify(input));
  const rendered = run(f.dir, 'node', [evidence, 'render', source]);
  assert.equal(rendered.status, 0, rendered.stderr);
  assert.match(rendered.stdout, new RegExp(`reused from ${f.oldHead}`));
  assert.doesNotMatch(rendered.stdout, /`swift`.*executed/);
  assert.equal(recordLinked(f).status, 0);
  const checked = run(f.dir, 'node', [evidence, 'check', '--head', f.newHead, '--issue', '772']);
  assert.equal(checked.status, 0, checked.stderr);
  const record = JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify', `${f.newHead}.json`)));
  assert.equal(record.link.oldBase, f.oldBase);
  assert.equal(record.link.newBase, f.newBase);
  assert.equal(record.lanes.swift.status, 'reused');
  assert.equal(record.lanes.ledger.status, 'executed');
});
test('forged link, wrong base, changed allow-list version and missing executed gate refuse', t => {
  const f = fixture(t);
  const wrong = linkedInput(f);
  wrong.link.oldBase = f.newBase;
  assert.notEqual(recordLinked(f, wrong).status, 0);
  assert.equal(recordLinked(f).status, 0);
  const file = path.join(f.dir, '.build/mado-verify', `${f.newHead}.json`);
  const original = JSON.parse(fs.readFileSync(file));
  for (const forged of [
    { ...original, link: { ...original.link, oldHead: f.newHead } },
    { ...original, link: { ...original.link, oldBase: f.newBase } },
    { ...original, link: undefined },
    { ...original, fingerprints: { ...original.fingerprints, allowlistVersion: 'forged' } },
    { ...original, lanes: { ...original.lanes, ledger: { status: 'reused', from: f.oldHead } } }
  ]) {
    fs.writeFileSync(file, JSON.stringify(forged));
    assert.notEqual(run(f.dir, 'node', [evidence, 'check', '--head', f.newHead, '--issue', '772']).status, 0);
  }
});
