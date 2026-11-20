import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { basesAreValid } from '../scripts/reuse-policy.mjs';

const skill = fileURLToPath(new URL('../', import.meta.url));
const script = path.join(skill, 'scripts/reuse-check.mjs');
const evidence = path.join(skill, 'scripts/evidence.mjs');
const policy = path.join(skill, 'scripts/gate-policy.mjs');
const verifierScripts = fileURLToPath(new URL('../../mado-delegator/scripts/', import.meta.url));
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
function fixture(t, mainPath = 'docs/note.md', options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-reuse-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  git(dir, 'init', '-q', '-b', 'main');
  git(dir, 'config', 'user.email', 'fixture@example.invalid');
  git(dir, 'config', 'user.name', 'Fixture');
  for (const name of ['gate-policy.mjs', 'evidence.mjs', 'reuse-policy.mjs', 'reuse-check.mjs', 'reuse-allowlist.json'])
    write(dir, `.agents/skills/mado-verify/scripts/${name}`, fs.readFileSync(path.join(skill, 'scripts', name)));
  for (const name of ['rebase-verify.sh', 'rebase-verify-tree.py', 'scan-conflict-markers.py'])
    write(dir, `.agents/skills/mado-delegator/scripts/${name}`, fs.readFileSync(path.join(verifierScripts, name)));
  write(dir, 'App/Feature.swift', 'base\n');
  if (options.baseExtra) write(dir, options.baseExtra, 'base extra\n');
  git(dir, 'add', '.'); git(dir, 'commit', '-qm', 'base');
  const oldBase = git(dir, 'rev-parse', 'HEAD');
  git(dir, 'update-ref', 'refs/remotes/origin/main', oldBase);
  git(dir, 'switch', '-qc', 'topic');
  write(dir, 'feature.txt', 'topic\n');
  if (options.branchAllowlist) {
    const file = '.agents/skills/mado-verify/scripts/reuse-allowlist.json';
    const list = JSON.parse(fs.readFileSync(path.join(dir, file)));
    list.prefixes.push(options.branchAllowlist);
    write(dir, file, JSON.stringify(list));
  }
  git(dir, 'add', 'feature.txt', '.agents/skills/mado-verify/scripts/reuse-allowlist.json');
  git(dir, 'commit', '-qm', 'topic');
  const oldHead = git(dir, 'rev-parse', 'HEAD');
  const input = path.join(dir, 'input.json');
  write(dir, 'input.json', JSON.stringify({ issue: 772, task: 'fixture', branch: 'topic', head: oldHead,
    gates: gateNames.map(name => ({ name, command: name, exitCode: 0,
      ...(options.oldScopeSkip?.includes(name) ? { scopeSkip: 'not run' } : {}),
      ...(options.oldKeyLine && (name === 'swift' || name === 'lcov') ? { keyLine: `old ${name} measured` } : {}) })),
    integrity: 'none', byType: [], notVerified: [],
    commentUrl: 'https://github.com/anzchy/mado/issues/772#issuecomment-1' }));
  const recorded = run(dir, 'node', [path.join(dir, '.agents/skills/mado-verify/scripts/evidence.mjs'), 'record', input]);
  assert.equal(recorded.status, 0, recorded.stderr);
  git(dir, 'switch', '-q', 'main');
  if (options.mainSymlink) {
    const target = path.join(dir, mainPath);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.symlinkSync('../App/Feature.swift', target);
    git(dir, 'add', mainPath);
  } else if (options.mainRename) {
    git(dir, 'mv', options.mainRename, mainPath);
  } else {
    write(dir, mainPath, 'main advance\n');
    if (mainPath === '.agents/skills/mado-verify/scripts/gate-policy.mjs')
      write(dir, mainPath, `${fs.readFileSync(policy, 'utf8')}\n// main advance\n`);
    if (mainPath === '.agents/skills/mado-verify/scripts/reuse-allowlist.json') {
      const list = JSON.parse(fs.readFileSync(path.join(skill, 'scripts/reuse-allowlist.json')));
      list.exact.push('newly-allowed.txt');
      write(dir, mainPath, JSON.stringify(list));
    }
    git(dir, 'add', mainPath);
  }
  git(dir, 'commit', '-qm', 'main advance');
  const newBase = git(dir, 'rev-parse', 'HEAD');
  git(dir, 'update-ref', 'refs/remotes/origin/main', newBase);
  git(dir, 'switch', '-q', 'topic'); git(dir, 'rebase', 'main');
  const newHead = git(dir, 'rev-parse', 'HEAD');
  return { dir, oldBase, newBase, oldHead, newHead, args: [oldBase, newBase, oldHead, newHead],
    script: path.join(dir, '.agents/skills/mado-verify/scripts/reuse-check.mjs'),
    evidence: path.join(dir, '.agents/skills/mado-verify/scripts/evidence.mjs') };
}
function verdict(f) { return run(f.dir, 'node', [f.script, ...f.args]); }

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
test('base ancestry requires the actual old and new main merge bases', t => {
  const f = fixture(t);
  assert.equal(basesAreValid(f.dir, f.oldBase, f.newBase, f.oldHead, f.newHead), true);
  assert.equal(basesAreValid(f.dir, f.newBase, f.newBase, f.oldHead, f.newHead), false);
  assert.equal(basesAreValid(f.dir, f.oldBase, f.oldHead, f.oldHead, f.newHead), false);
});
test('wrong old base and missing historical fingerprint refuse reuse', t => {
  const f = fixture(t);
  assert.match(run(f.dir, 'node', [f.script, f.newBase, f.newBase, f.oldHead, f.newHead]).stdout, /^RERUN/);
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
test('branch-edited allow-list cannot authorize an App change on main', t => {
  const f = fixture(t, 'App/Other.swift', { branchAllowlist: 'App/' });
  assert.match(verdict(f).stdout, /^RERUN/);
});
test('old scope-skipped Swift or lcov cannot be reused', t => {
  for (const name of ['swift', 'lcov']) {
    const f = fixture(t, 'docs/note.md', { oldScopeSkip: [name] });
    assert.match(verdict(f).stdout, /^RERUN/, name);
  }
});
test('allowed-path symlink and rename into App refuse reuse', t => {
  const symlink = fixture(t, 'docs/link.md', { mainSymlink: true });
  assert.match(verdict(symlink).stdout, /^RERUN/);
  const rename = fixture(t, 'App/moved.swift', { baseExtra: 'docs/move.md', mainRename: 'docs/move.md' });
  assert.match(verdict(rename).stdout, /^RERUN/);
});
test('case variation and main-side allow-list edit refuse reuse', t => {
  assert.match(verdict(fixture(t, 'Docs/note.md')).stdout, /^RERUN/);
  assert.match(verdict(fixture(t, '.agents/skills/mado-verify/scripts/reuse-allowlist.json')).stdout, /^RERUN/);
});
test('allowed tooling path retained as tested input refuses reuse', t => {
  const f = fixture(t, '.agents/skills/mado-delegator/scripts/merge-gate.sh');
  assert.match(verdict(f).stdout, /^RERUN tested input tree changed/);
});
test('chained old record and old NOT VERIFIED lane refuse reuse', t => {
  const chain = fixture(t);
  const chainFile = path.join(chain.dir, '.build/mado-verify', `${chain.oldHead}.json`);
  const chainRecord = JSON.parse(fs.readFileSync(chainFile));
  chainRecord.link = { oldHead: chain.oldBase };
  fs.writeFileSync(chainFile, JSON.stringify(chainRecord));
  assert.match(verdict(chain).stdout, /^RERUN old record\/base invalid/);
  const unverified = fixture(t);
  const unverifiedFile = path.join(unverified.dir, '.build/mado-verify', `${unverified.oldHead}.json`);
  const record = JSON.parse(fs.readFileSync(unverifiedFile));
  record.gates.find(g => g.name === 'swift').notVerified = 'no result';
  record.lanes.swift.status = 'not-verified';
  fs.writeFileSync(unverifiedFile, JSON.stringify(record));
  assert.match(verdict(unverified).stdout, /^RERUN swift: old lane was not an executed pass/);
});
test('linked record accepts byte-for-byte copied old Swift/lcov results', t => {
  const f = fixture(t, 'docs/note.md', { oldKeyLine: true });
  const old = JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify', `${f.oldHead}.json`)));
  const input = linkedInput(f);
  for (const name of ['swift', 'lcov']) {
    const index = input.gates.findIndex(g => g.name === name);
    input.gates[index] = { ...old.gates.find(g => g.name === name), reusedFrom: f.oldHead };
  }
  assert.equal(recordLinked(f, input).status, 0);
  assert.equal(run(f.dir, 'node', [f.evidence, 'check', '--head', f.newHead, '--issue', '772']).status, 0);
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
  return run(f.dir, 'node', [f.evidence, 'record', file]);
}
test('linked record verifies and renders reused lanes as reused', t => {
  const f = fixture(t);
  const input = linkedInput(f);
  const source = path.join(f.dir, 'linked-input.json');
  fs.writeFileSync(source, JSON.stringify(input));
  const rendered = run(f.dir, 'node', [f.evidence, 'render', source]);
  assert.equal(rendered.status, 0, rendered.stderr);
  assert.match(rendered.stdout, new RegExp(`reused from ${f.oldHead}`));
  assert.doesNotMatch(rendered.stdout, /`swift`.*executed/);
  assert.equal(recordLinked(f).status, 0);
  const checked = run(f.dir, 'node', [f.evidence, 'check', '--head', f.newHead, '--issue', '772']);
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
    assert.notEqual(run(f.dir, 'node', [f.evidence, 'check', '--head', f.newHead, '--issue', '772']).status, 0);
  }
});
test('linked lanes reject invented reused key lines and skipped new-head gates', t => {
  const f = fixture(t, 'docs/note.md', { oldKeyLine: true });
  const invented = linkedInput(f);
  invented.gates.find(g => g.name === 'swift').keyLine = 'invented result';
  assert.notEqual(recordLinked(f, invented).status, 0);
  for (const name of ['ledger', 'design', 'diffcheck']) {
    const skipped = linkedInput(f);
    skipped.gates.find(g => g.name === name).scopeSkip = 'not run';
    assert.notEqual(recordLinked(f, skipped).status, 0, name);
  }
});
