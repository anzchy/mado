import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// #901: evidence.mjs record writes the worktree path; check refuses a record checked in a pane home or copied
// from another worktree. Tasks dispatched before #901 finish where they are with --legacy-worktree (a warning).
const evidence = fileURLToPath(new URL('../scripts/evidence.mjs', import.meta.url));
const names = ['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'apptests', 'node', 'ledger', 'design'];
const run = (cmd, args, cwd) => spawnSync(cmd, args, { cwd, encoding: 'utf8' });
const git = (cwd, ...args) => { const r = run('git', args, cwd); assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mado-i901-ev-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'main-checkout');
  fs.mkdirSync(home);
  git(home, 'init', '-q', '-b', 'main');
  git(home, 'config', 'user.email', 'fixture@example.invalid');
  git(home, 'config', 'user.name', 'Fixture');
  fs.writeFileSync(path.join(home, '.gitignore'), '.build/\n');
  fs.writeFileSync(path.join(home, 'sample.test.swift'), 'func testOne() { #expect(true) }\n');
  git(home, 'add', '.gitignore', 'sample.test.swift');
  git(home, 'commit', '-qm', 'base');
  git(home, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  // A worktree with one test-only commit on top of origin/main, as an implementer leaves it.
  const worktree = name => {
    const dir = path.join(root, name);
    git(home, 'worktree', 'add', '-q', '-b', `task/${name}`, dir, 'origin/main');
    fs.writeFileSync(path.join(dir, 'sample.test.swift'), 'func testTwo() { #expect(true) }\n');
    git(dir, 'commit', '-qam', 'change');
    return dir;
  };
  const record = dir => {
    const head = git(dir, 'rev-parse', 'HEAD');
    const source = path.join(root, `${path.basename(dir)}-input.json`);
    fs.writeFileSync(source, JSON.stringify({ issue: 648, task: 'i648', branch: 'test', head, integrity: 'none', byType: [], notVerified: ['none'],
      commentUrl: 'https://github.com/anzchy/mado/issues/648#issuecomment-9', gates: names.map(name => ({ name, command: name, exitCode: 0 })) }));
    const r = run('node', [evidence, 'record', source], dir);
    assert.equal(r.status, 0, r.stderr);
    return { head, file: path.join(dir, '.build/mado-verify', `${head}.json`) };
  };
  const check = (dir, head, ...extra) => run('node', [evidence, 'check', '--head', head, '--issue', '648', '--worktree', dir, ...extra], root);
  return { root, worktree, record, check };
}

test('#901 record writes the worktree path; check passes in a task worktree', t => {
  const f = fixture(t);
  const wt = f.worktree('648-demo');
  const { head, file } = f.record(wt);
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).worktree, wt);
  const ok = f.check(wt, head);
  assert.equal(ok.status, 0, ok.stderr);
  assert.doesNotMatch(ok.stdout, /WARNING worktree/);
});

test('#901 check refuses a record in a pane home; --legacy-worktree turns it into a warning', t => {
  const f = fixture(t);
  const pane = f.worktree('gpt-imple-1');
  const { head } = f.record(pane);
  const refused = f.check(pane, head);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /pane home/);
  assert.match(refused.stderr, /--legacy-worktree/);
  const legacy = f.check(pane, head, '--legacy-worktree');
  assert.equal(legacy.status, 0, legacy.stderr);
  assert.match(legacy.stdout, /WARNING worktree .*pane home.*dispatched before #901/);
});

test('#901 check refuses a worktree holding a dispatch marker (a pane home under any name)', t => {
  const f = fixture(t);
  const wt = f.worktree('648-demo');
  const { head } = f.record(wt);
  fs.writeFileSync(path.join(wt, '.build/mado-verify/target-worktree'), '{}\n');
  const refused = f.check(wt, head);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /dispatch marker/);
});

test('#901 check refuses a record written in another worktree', t => {
  const f = fixture(t);
  const a = f.worktree('648-demo');
  const { head, file } = f.record(a);
  const b = path.join(f.root, '648-copy');
  git(a, 'worktree', 'add', '-q', '--detach', b, head);
  fs.mkdirSync(path.join(b, '.build/mado-verify'), { recursive: true });
  fs.copyFileSync(file, path.join(b, '.build/mado-verify', `${head}.json`));
  const refused = f.check(b, head);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /record was written in .*648-demo, not in .*648-copy/);
});

test('#901 a record without a worktree path (written before #901) passes with a warning', t => {
  const f = fixture(t);
  const wt = f.worktree('648-demo');
  const { head, file } = f.record(wt);
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  delete record.worktree;
  fs.writeFileSync(file, JSON.stringify(record));
  const ok = f.check(wt, head);
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /WARNING worktree: the record has no worktree path/);
});
