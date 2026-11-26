import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// #901: a Codex implementer pane stays in its pane home (the agent-list cwd); the task worktree is passed separately
// with --task-worktree and must be named in the prompt. An implementer dispatched with a pane-home --cwd and no task
// worktree is refused before the pane is touched (found 2026-11-25: "pane cwd … != expected").
const here = path.dirname(fileURLToPath(import.meta.url));
const freshDir = path.join(here, 'fixtures/fresh-codex');
const helper = path.join(here, 'start-fresh-codex.sh');

function scenario(t, { name = 'gpt-imple-9', cwd } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mado-i901-fc-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  // #891: link the checked-in fake (mode 100755); a fresh copy pays the macOS first-exec assessment.
  fs.symlinkSync(path.join(freshDir, 'fake-herdr.cjs'), path.join(bin, 'herdr'));
  // #901 fix1: the pane home is a git worktree, and task worktrees are worktrees of the same repository beside it.
  const paneHome = path.join(dir, name);
  fs.mkdirSync(paneHome);
  const git = (cwd, ...args) => assert.equal(spawnSync('git', args, { cwd }).status, 0, `git ${args.join(' ')}`);
  git(paneHome, 'init', '-q', '-b', 'main');
  git(paneHome, '-c', 'user.email=f@example.invalid', '-c', 'user.name=F', 'commit', '-q', '--allow-empty', '-m', 'base');
  const repo = (nameOf, at = dir) => {
    const wt = path.join(at, nameOf);
    fs.mkdirSync(path.dirname(wt), { recursive: true });
    git(paneHome, 'worktree', 'add', '-q', '--detach', wt);
    return wt;
  };
  const alien = nameOf => {
    const wt = path.join(dir, nameOf);
    fs.mkdirSync(wt);
    git(wt, 'init', '-q');
    return wt;
  };
  const stateFile = path.join(dir, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({ phase: 'old', name, status: 'idle', cwd: cwd?.(dir) ?? paneHome, reads: 0, prompts: 0, events: [] }));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MADO_FIXTURE_SCENARIO: JSON.stringify({ dialog: true }),
    MADO_FIXTURE_STATE: stateFile, MADO_FIXTURE_DIR: freshDir, MADO_FRESH_START_SECS: '0.8',
    MADO_FRESH_CONFIRM_SECS: '0.25', MADO_FRESH_POLL_SECS: '0.02' };
  const run = (...args) => spawnSync('/bin/bash', [helper, ...args], { env, encoding: 'utf8', timeout: 10000 });
  const state = () => JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  return { dir, paneHome, repo, alien, run, state, name };
}
const untouched = s => { assert.equal(s.state().prompts, 0); assert.ok(!s.state().events.includes('send-new'), 'pane was touched'); };

test('#901 --task-worktree starts the implementer in its pane home and prompts the task worktree', t => {
  const s = scenario(t);
  const wt = s.repo('651-demo');
  const r = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--task-worktree', wt, '--prompt', `New task: … Worktree: ${wt}. Read and follow the brief.`);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.equal(s.state().prompts, 1);
  assert.equal(s.state().status, 'working');
});

test('#901 an implementer with a pane-home --cwd and no --task-worktree is refused before the pane is touched', t => {
  const s = scenario(t);
  const r = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--prompt', 'New task: …');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /pane home .*--task-worktree/);
  assert.equal(r.stderr.trim().split('\n').length, 1);
  untouched(s);
});

test('#901 --task-worktree must be a separate <issue>-<slug> worktree root that the prompt names', t => {
  const s = scenario(t);
  const wt = s.repo('651-demo');
  fs.mkdirSync(path.join(wt, 'sub'));
  const other = s.repo('gpt-imple-2');
  const cases = [
    [s.paneHome, `Worktree: ${s.paneHome}`, /task worktree .*is the pane home|not a task worktree/],
    [other, `Worktree: ${other}`, /not a task worktree/],
    [path.join(wt, 'sub'), `Worktree: ${path.join(wt, 'sub')}`, /not a worktree root/],
    [path.join(s.dir, '651-missing'), 'Worktree: missing', /not a directory|does not exist/],
    [wt, 'New task: no path here', /prompt does not name the task worktree/],
  ];
  for (const [taskWorktree, prompt, pattern] of cases) {
    const r = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--task-worktree', taskWorktree, '--prompt', prompt);
    assert.notEqual(r.status, 0, taskWorktree);
    assert.match(r.stderr, pattern, taskWorktree);
  }
  untouched(s);
});

test('#901 the task worktree may be written with ~ in the prompt; prompt-and-confirm takes --task-worktree too', t => {
  const s = scenario(t);
  const wt = s.repo('651-demo');
  const r = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--task-worktree', wt, '--prompt', `Worktree: ${wt.replace(os.homedir(), '~')}`);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const p = scenario(t);
  const wt2 = p.repo('652-demo');
  const bad = p.run('prompt-and-confirm', 'w1:p5', p.name, '--cwd', p.paneHome, '--task-worktree', wt2, 'no path');
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /prompt does not name the task worktree/);
  untouched(p);
});

test('#901 a Codex implementer relaunched in its task worktree, and auditors in their own worktree, need no --task-worktree', t => {
  const s = scenario(t, { cwd: dir => path.join(dir, '651-demo') });
  const wt = s.repo('651-demo');
  const r = s.run('w1:p5', s.name, '--cwd', wt, '--prompt', `Worktree: ${wt}`);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const a = scenario(t, { name: 'gpt-auditor' });
  const audit = a.run('w1:p5', 'gpt-auditor', '--cwd', a.paneHome, '--prompt', 'Audit #901');
  assert.equal(audit.status, 0, audit.stderr + audit.stdout);
});

test('#901 fix1 (gpt M3, opus M3) the task worktree sits beside the pane home in the same repository', t => {
  const s = scenario(t);
  const elsewhere = s.repo('651-x', path.join(s.dir, 'tmp'));
  const outside = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--task-worktree', elsewhere, '--prompt', `Worktree: ${elsewhere}`);
  assert.notEqual(outside.status, 0);
  assert.match(outside.stderr, /not under the picsee-wt root .* of the pane home/);
  const other = s.alien('651-alien');
  const alien = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--task-worktree', other, '--prompt', `Worktree: ${other}`);
  assert.notEqual(alien.status, 0);
  assert.match(alien.stderr, /not a worktree of the pane home's repository/);
  untouched(s);
});

test('#901 fix1 (gpt M3, opus M3) the prompt names the task worktree as a whole path in live text', t => {
  const s = scenario(t);
  const wt = s.repo('651-demo');
  for (const prompt of [
    `<!-- Worktree: ${wt} --> Work in the pane home.`,
    `# Worktree: ${wt}\nWork in the pane home.`,
    `Worktree: ${wt}-old. Read the brief.`,
    `Worktree: ${wt}/sub. Read the brief.`,
    `Worktree: x${wt}. Read the brief.`,
  ]) {
    const r = s.run('w1:p5', s.name, '--cwd', s.paneHome, '--task-worktree', wt, '--prompt', prompt);
    assert.notEqual(r.status, 0, prompt);
    assert.match(r.stderr, /prompt does not name the task worktree/, prompt);
  }
  untouched(s);
  for (const prompt of [`Worktree: \`${wt}\` (branch task/651-demo).`, `New task (${wt}): read the brief`, `Refs #651. Worktree: ${wt}, then read`]) {
    const ok = scenario(t);
    const wt2 = ok.repo('651-demo');
    const r = ok.run('w1:p5', ok.name, '--cwd', ok.paneHome, '--task-worktree', wt2, '--prompt', prompt.replaceAll(wt, wt2));
    assert.equal(r.status, 0, prompt + r.stderr);
  }
});
