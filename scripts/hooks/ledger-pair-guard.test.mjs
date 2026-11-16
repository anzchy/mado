import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { decide } from './ledger-pair-guard.mjs';

const script = fileURLToPath(new URL('./ledger-pair-guard.mjs', import.meta.url));
const bash = (command, cwd = '/repo') => ({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd });

function fakeDeps({ staged = [], unstaged = [], ok = true }) {
  const calls = [];
  return {
    calls,
    git(dir, args) {
      if (args[0] === 'rev-parse') return `${dir}\n`;
      if (args.includes('--cached')) return staged.join('\n');
      return unstaged.join('\n');
    },
    check(root) {
      calls.push(root);
      return { ok, output: ok ? '' : 'feature-ledger.html is stale' };
    },
  };
}
const decision = (r) => r?.hookSpecificOutput?.permissionDecision ?? null;

test('ledger staged and html check passes: allow', () => {
  const deps = fakeDeps({ staged: ['docs/feature-ledger.md', 'docs/feature-ledger.html'] });
  assert.equal(decide(bash('git commit -m "docs(ledger): x"'), deps), null);
  assert.deepEqual(deps.calls, ['/repo']);
});

test('ledger staged and html check fails: deny', () => {
  const deps = fakeDeps({ staged: ['docs/feature-ledger.md', 'docs/feature-ledger.html'], ok: false });
  const r = decide(bash('git commit -m x'), deps);
  assert.equal(decision(r), 'deny');
  assert.match(r.hookSpecificOutput.permissionDecisionReason, /ledger:html-check/);
});

test('ledger staged, regenerated html left unstaged: deny without running the check', () => {
  const deps = fakeDeps({ staged: ['docs/feature-ledger.md'], unstaged: ['docs/feature-ledger.html'] });
  assert.equal(decision(decide(bash('git commit -m x'), deps)), 'deny');
  assert.deepEqual(deps.calls, []);
});

test('ledger not in the commit: no check', () => {
  const deps = fakeDeps({ staged: ['AGENTS.md'], unstaged: ['docs/feature-ledger.md'], ok: false });
  assert.equal(decide(bash('git commit -m x'), deps), null);
  assert.deepEqual(deps.calls, []);
});

test('commit -a and same-command git add count as staged', () => {
  const a = fakeDeps({ unstaged: ['docs/feature-ledger.md', 'docs/feature-ledger.html'], ok: false });
  assert.equal(decision(decide(bash('git commit -am x'), a)), 'deny');
  const b = fakeDeps({ ok: false });
  assert.equal(decision(decide(bash('git add docs/feature-ledger.md docs/feature-ledger.html && git commit -m x'), b)), 'deny');
  const c = fakeDeps({ ok: true });
  assert.equal(decide(bash('git add docs/feature-ledger.md docs/feature-ledger.html && git commit -m x'), c), null);
});

test('git -C points the check at that repository', () => {
  const deps = fakeDeps({ staged: ['docs/feature-ledger.md'] });
  decide(bash('git -C /other/wt commit -m x'), deps);
  assert.deepEqual(deps.calls, ['/other/wt']);
});

test('non-commit commands are ignored', () => {
  const deps = fakeDeps({ staged: ['docs/feature-ledger.md'], ok: false });
  assert.equal(decide(bash('git status'), deps), null);
  assert.equal(decide(bash('echo git commit'), deps), null);
});

test('end to end against a real repository and npm script', () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'ledger-hook-')));
  try {
    const git = (...args) => execFileSync('git', ['-C', dir, ...args], { stdio: 'ignore' });
    git('init', '-q');
    mkdirSync(join(dir, 'docs'));
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ scripts: { 'ledger:html-check': "node -e \"process.exit(require('fs').existsSync('ok')?0:1)\"" } }));
    writeFileSync(join(dir, 'docs/feature-ledger.md'), 'a\n');
    writeFileSync(join(dir, 'docs/feature-ledger.html'), 'a\n');
    git('add', 'docs/feature-ledger.md', 'docs/feature-ledger.html');
    const run = () => spawnSync(process.execPath, [script], { input: JSON.stringify(bash('git commit -m x', dir)), encoding: 'utf8' });
    const bad = run();
    assert.equal(bad.status, 0);
    assert.equal(JSON.parse(bad.stdout).hookSpecificOutput.permissionDecision, 'deny');
    writeFileSync(join(dir, 'ok'), '');
    const good = run();
    assert.equal(good.status, 0);
    assert.equal(good.stdout, '');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
