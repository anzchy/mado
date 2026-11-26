import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// #901 (owner 2026-11-25): 「每个任务单独的worktree(对于implementor来说）」. mark-target.mjs is the dispatch-time control:
// it refuses a pane home, another task's worktree and a dirty tree, and lets a fix round reuse its own task worktree.
const markTarget = fileURLToPath(new URL('../scripts/mark-target.mjs', import.meta.url));
const run = (cmd, args, cwd) => spawnSync(cmd, args, { cwd, encoding: 'utf8' });
const git = (cwd, ...args) => { const r = run('git', args, cwd); assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mado-i901-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'opus-imple-9');
  fs.mkdirSync(home);
  git(home, 'init', '-q', '-b', 'main');
  git(home, 'config', 'user.email', 'fixture@example.invalid');
  git(home, 'config', 'user.name', 'Fixture');
  fs.writeFileSync(path.join(home, '.gitignore'), '.build/\n');
  fs.writeFileSync(path.join(home, 'tracked.txt'), 'base\n');
  git(home, 'add', '.gitignore', 'tracked.txt');
  git(home, 'commit', '-qm', 'base');
  const worktree = (name, ...args) => { const dir = path.join(root, name); git(home, 'worktree', 'add', '-q', ...args, dir); return dir; };
  const handoff = path.join(root, 'handoff.md');
  const mark = (target, issue, task, branch) => run('node', [markTarget, home, target, String(issue), task, handoff, ...(branch ? [branch] : [])], home);
  const marker = () => JSON.parse(fs.readFileSync(path.join(home, '.build/mado-verify/target-worktree'), 'utf8'));
  const hasMarker = () => fs.existsSync(path.join(home, '.build/mado-verify/target-worktree'));
  return { root, home, worktree, handoff, mark, marker, hasMarker };
}

test('#901 a clean new task worktree is accepted: marker in the pane home, task identity in the worktree', t => {
  const f = fixture(t);
  const wt = f.worktree('651-demo', '-b', 'task/651-demo');
  const r = f.mark(wt, 651, 'i651');
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(f.marker(), { worktree: wt, branch: 'task/651-demo', issue: 651, task: 'i651', handoff: f.handoff });
  const identityFile = path.join(wt, '.build/mado-verify/task-identity.json');
  assert.ok(fs.existsSync(identityFile), 'mark-target writes the task identity into the worktree');
  const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
  assert.equal(identity.issue, 651);
  assert.equal(identity.branch, 'task/651-demo');
  assert.equal(identity.task, 'i651');
});

test('#901 a pane-home worktree is refused: the pane home itself and any picsee-wt/<pane-name> worktree', t => {
  const f = fixture(t);
  const self = f.mark(f.home, 651, 'i651', 'main');
  assert.notEqual(self.status, 0);
  assert.match(self.stderr, /pane home/);
  assert.match(self.stderr, /new-task-worktree\.sh 651 <slug>/);
  for (const name of ['gpt-imple-1', 'opus-imple-2', 'gpt-auditor', 'kimi-researcher']) {
    const other = f.worktree(name, '-b', `pane/${name}`);
    const r = f.mark(other, 651, 'i651');
    assert.notEqual(r.status, 0, name);
    assert.match(r.stderr, /pane home/, name);
  }
  assert.equal(f.hasMarker(), false);
});

test('#901 a worktree named for another issue, or not named <issue>-<slug>, is refused', t => {
  const f = fixture(t);
  for (const name of ['652-other', 'scratch', '651']) {
    const wt = f.worktree(name, '-b', `task/${name}`);
    const r = f.mark(wt, 651, 'i651');
    assert.notEqual(r.status, 0, name);
    assert.match(r.stderr, /not a task worktree for #651/, name);
    assert.match(r.stderr, /picsee-wt\/651-<slug>/, name);
  }
  assert.equal(f.hasMarker(), false);
});

test('#901 a worktree holding a dispatch marker is a pane home whatever its name', t => {
  const f = fixture(t);
  const wt = f.worktree('651-demo', '-b', 'task/651-demo');
  fs.mkdirSync(path.join(wt, '.build/mado-verify'), { recursive: true });
  fs.writeFileSync(path.join(wt, '.build/mado-verify/target-worktree'), '{}\n');
  const r = f.mark(wt, 651, 'i651');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /dispatch marker/);
});

test('#901 a second task in the same worktree is refused', t => {
  const f = fixture(t);
  const wt = f.worktree('651-demo', '-b', 'task/651-demo');
  assert.equal(f.mark(wt, 651, 'i651').status, 0);
  // Another branch named for the same worktree: refused by the task identity.
  const second = f.mark(wt, 651, 'i651-b', 'task/651-other');
  assert.notEqual(second.status, 0);
  assert.match(second.stderr, /already holds task #651 \(branch task\/651-demo\)/);
  // The worktree switched to another branch: refused before the identity is consulted.
  git(wt, 'switch', '-q', '-c', 'task/651-switched');
  const switched = f.mark(wt, 651, 'i651-c', 'task/651-demo');
  assert.notEqual(switched.status, 0);
  assert.match(switched.stderr, /holds branch task\/651-switched, not the task branch task\/651-demo/);
  assert.equal(f.marker().task, 'i651');
});

test('#901 a fix round reuses its task worktree; untracked tool files are allowed, tracked changes are not', t => {
  const f = fixture(t);
  const wt = f.worktree('651-demo', '-b', 'task/651-demo');
  assert.equal(f.mark(wt, 651, 'i651').status, 0);
  fs.writeFileSync(path.join(wt, 'tracked.txt'), 'work\n');
  git(wt, 'commit', '-qam', 'work');
  fs.mkdirSync(path.join(wt, '.claude/tdd-guardian'), { recursive: true });
  fs.writeFileSync(path.join(wt, '.claude/tdd-guardian/plan.md'), 'plan\n');
  const fix = f.mark(wt, 651, 'i651-fix1');
  assert.equal(fix.status, 0, fix.stderr);
  assert.equal(f.marker().task, 'i651-fix1');
  fs.writeFileSync(path.join(wt, 'tracked.txt'), 'uncommitted\n');
  const dirty = f.mark(wt, 651, 'i651-fix2');
  assert.notEqual(dirty.status, 0);
  assert.match(dirty.stderr, /tracked changes/);
  assert.equal(f.marker().task, 'i651-fix1');
});

test('#901 a new task needs a fully clean tree: untracked or tracked leftovers are refused', t => {
  const f = fixture(t);
  const wt = f.worktree('651-demo', '-b', 'task/651-demo');
  fs.writeFileSync(path.join(wt, 'default.profraw'), 'stale\n');
  const untracked = f.mark(wt, 651, 'i651');
  assert.notEqual(untracked.status, 0);
  assert.match(untracked.stderr, /not clean/);
  fs.rmSync(path.join(wt, 'default.profraw'));
  fs.writeFileSync(path.join(wt, 'tracked.txt'), 'edit\n');
  const tracked = f.mark(wt, 651, 'i651');
  assert.notEqual(tracked.status, 0);
  assert.match(tracked.stderr, /not clean/);
  assert.equal(f.hasMarker(), false);
  assert.equal(fs.existsSync(path.join(wt, '.build/mado-verify/task-identity.json')), false);
});

test('#901 a detached task worktree is accepted with an explicit task branch (rebase in progress)', t => {
  const f = fixture(t);
  const wt = f.worktree('651-demo', '--detach');
  const r = f.mark(wt, 651, 'i651', 'task/651-demo');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.marker().branch, 'task/651-demo');
});
