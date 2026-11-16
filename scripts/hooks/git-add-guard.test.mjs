import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { decide } from './git-add-guard.mjs';

const script = fileURLToPath(new URL('./git-add-guard.mjs', import.meta.url));
const bash = (command) => ({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd: '/tmp' });

test('denies whole-tree staging', () => {
  for (const c of [
    'git add -A',
    'git add --all',
    'git add .',
    'git add ./',
    'git add :/',
    'git add -Av',
    'git -C /tmp/wt add -A',
    'git -c core.commentChar=";" add --all docs',
    'git status && git add . && git commit -m x',
    "sh -c 'git add -A'",
  ]) {
    const r = decide(bash(c));
    assert.equal(r?.hookSpecificOutput?.permissionDecision, 'deny', c);
    assert.match(r.hookSpecificOutput.permissionDecisionReason, /Stage each path by name/);
  }
});

test('allows named paths and unrelated commands', () => {
  for (const c of [
    'git add AGENTS.md docs/agents/test-lanes.md',
    'git add -- docs/feature-ledger.md docs/feature-ledger.html',
    'git add -p AGENTS.md',
    'git add -u',
    'git commit -m "never git add -A"',
    'echo git add -A',
    'grep -n "git add ." AGENTS.md',
    'git log --all',
  ]) assert.equal(decide(bash(c)), null, c);
});

test('end to end', () => {
  const r = spawnSync(process.execPath, [script], { input: JSON.stringify(bash('git add -A')), encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.permissionDecision, 'deny');
  const ok = spawnSync(process.execPath, [script], { input: JSON.stringify(bash('git add AGENTS.md')), encoding: 'utf8' });
  assert.equal(ok.stdout, '');
});
