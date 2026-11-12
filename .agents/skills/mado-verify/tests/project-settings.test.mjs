import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../../', import.meta.url));
const settingsFile = path.join(root, '.claude/settings.json');
const sourceScripts = path.join(root, '.agents/skills/mado-verify/scripts');
const gateNames = ['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'node', 'ledger', 'design'];

function run(command, args, cwd, input) {
  return spawnSync(command, args, { cwd, input, encoding: 'utf8' });
}

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-project-stop-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const scripts = path.join(dir, '.agents/skills/mado-verify/scripts');
  fs.mkdirSync(scripts, { recursive: true });
  for (const name of ['stop-hook.mjs', 'gate-policy.mjs']) fs.copyFileSync(path.join(sourceScripts, name), path.join(scripts, name));
  for (const args of [['init', '-q'], ['config', 'user.email', 'fixture@example.invalid'], ['config', 'user.name', 'Fixture']]) {
    assert.equal(run('git', args, dir).status, 0);
  }
  fs.writeFileSync(path.join(dir, 'sample.txt'), 'base\n');
  assert.equal(run('git', ['add', 'sample.txt'], dir).status, 0);
  assert.equal(run('git', ['commit', '-qm', 'base'], dir).status, 0);
  const base = run('git', ['rev-parse', 'HEAD'], dir).stdout.trim();
  assert.equal(run('git', ['update-ref', 'refs/remotes/origin/main', base], dir).status, 0);
  fs.writeFileSync(path.join(dir, 'sample.txt'), 'changed\n');
  assert.equal(run('git', ['add', 'sample.txt'], dir).status, 0);
  assert.equal(run('git', ['commit', '-qm', 'change'], dir).status, 0);
  const head = run('git', ['rev-parse', 'HEAD'], dir).stdout.trim();
  const branch = run('git', ['symbolic-ref', '-q', '--short', 'HEAD'], dir).stdout.trim();
  const handoff = path.join(dir, 'handoff.md');
  fs.writeFileSync(handoff, `Worktree: ${dir}\nBranch: ${branch}\nHEAD: ${head}\n`);
  const markerDir = path.join(dir, '.build/mado-verify');
  fs.mkdirSync(markerDir, { recursive: true });
  fs.writeFileSync(path.join(markerDir, 'target-worktree'), JSON.stringify({ worktree: dir, branch, issue: 659, task: 'i659', handoff }));
  return { dir, head, markerDir };
}

function commandFromSettings() {
  const settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
  assert.equal(settings.enabledPlugins['tdd-guardian@xiaolai'], true);
  const entries = settings.hooks.Stop;
  assert.equal(entries.length, 1);
  assert.equal(entries[0].hooks.length, 1);
  const hook = entries[0].hooks[0];
  assert.equal(hook.type, 'command');
  assert.equal(hook.timeout, 1);
  assert.equal(hook.command, 'node "$(git rev-parse --show-toplevel)/.agents/skills/mado-verify/scripts/stop-hook.mjs"');
  assert.doesNotMatch(hook.command, /--role-source/);
  return hook.command;
}

function stop(command, dir) {
  return run('sh', ['-c', command], dir, JSON.stringify({ hook_event_name: 'Stop', cwd: dir, last_assistant_message: 'Work complete.' }));
}

test('project Stop command is overlay-gated and accepts complete evidence', t => {
  const command = commandFromSettings();
  const f = fixture(t);
  const noOverlay = stop(command, f.dir);
  assert.equal(noOverlay.status, 0, noOverlay.stderr);
  assert.equal(noOverlay.stdout, '');
  assert.equal(noOverlay.stderr, '');

  const rules = path.join(f.dir, '.codex/rules');
  fs.mkdirSync(rules, { recursive: true });
  fs.writeFileSync(path.join(rules, 'picsee-role.rules'), '# Local picsee role: implementor\n');
  const missing = stop(command, f.dir);
  assert.equal(missing.status, 0, missing.stderr);
  assert.equal(JSON.parse(missing.stdout).decision, 'block');

  fs.writeFileSync(path.join(f.markerDir, `${f.head}.json`), JSON.stringify({
    head: f.head,
    issue: 659,
    commentUrl: 'https://github.com/anzchy/mado/issues/659#issuecomment-123',
    gates: gateNames.map(name => ({ name, command: name, exitCode: 0 })),
  }));
  const complete = stop(command, f.dir);
  assert.equal(complete.status, 0, complete.stderr);
  assert.equal(complete.stdout, '');
  assert.equal(complete.stderr, '');
});
