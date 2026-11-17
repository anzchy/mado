import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isPrMerge, run } from './sync-main-after-merge.mjs';

const script = fileURLToPath(new URL('./sync-main-after-merge.mjs', import.meta.url));
const bash = (command, extra = {}) => ({ hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command }, cwd: '/tmp', ...extra });
const MERGE = 'gh pr merge 739 --repo anzchy/mado --rebase';

test('isPrMerge matches a real gh pr merge and nothing that only mentions it', () => {
  for (const c of [
    MERGE,
    'gh pr merge 1',
    'cd ~/work/app && gh pr merge 736 --repo anzchy/mado --rebase 2>&1 | tail -1',
    'GH_TOKEN=x gh pr merge 5 --rebase',
    'for n in 736 737; do gh pr merge $n --repo anzchy/mado --rebase; done',
    "bash -c 'gh pr merge 9 --rebase'",
  ]) assert.equal(isPrMerge(c), true, c);
  for (const c of [
    'gh pr view 739',
    'gh pr checks 739 --repo anzchy/mado',
    'gh pr merge --help',
    'gh pr merge -h',
    'echo gh pr merge 5',
    'git log --grep "gh pr merge"',
    'gh issue list',
    '',
  ]) assert.equal(isPrMerge(c), false, c);
});

// ---- unit tests with a scripted git -------------------------------------------------
function fakeGit(script) {
  const calls = [];
  const git = (args, cwd) => {
    calls.push({ args, cwd });
    const key = args.join(' ');
    for (const [prefix, result] of Object.entries(script)) {
      if (key.startsWith(prefix)) return { status: 0, stdout: '', stderr: '', ...result };
    }
    return { status: 0, stdout: '', stderr: '' };
  };
  return { git, calls };
}
const MAIN = '/repo/main-checkout';
const happy = {
  'worktree list --porcelain': { stdout: `worktree ${MAIN}\nHEAD abc\nbranch refs/heads/main\n\nworktree /repo/wt/other\nHEAD def\nbranch refs/heads/feat\n` },
  'symbolic-ref': { stdout: 'main\n' },
  'rev-parse main': { stdout: 'a'.repeat(40) + '\n' },
  'rev-parse origin/main': { stdout: 'a'.repeat(40) + '\n' },
  'log -1': { stdout: 'a1b2c3d4 test(tooling): something\n' },
};
const decision = (r) => r?.decision;
const context = (r) => r?.hookSpecificOutput?.additionalContext ?? '';

test('ignores other tools, other commands, and sessions that are not the main checkout', () => {
  const { git, calls } = fakeGit(happy);
  assert.equal(run({ tool_name: 'Write', tool_input: {} }, { env: { CLAUDE_PROJECT_DIR: MAIN }, git }), null);
  assert.equal(run(bash('gh pr view 1'), { env: { CLAUDE_PROJECT_DIR: MAIN }, git }), null);
  assert.equal(run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: '/repo/wt/other' }, git }), null);
  assert.ok(!calls.some((c) => c.args[0] === 'fetch' || c.args[0] === 'merge'), JSON.stringify(calls));
});

test('success: fetch, fast-forward only, verify, report the commit', () => {
  const { git, calls } = fakeGit(happy);
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git });
  assert.equal(decision(out), undefined);
  assert.match(context(out), /local main is now a1b2c3d/);
  assert.match(context(out), /origin\/main/);
  const verbs = calls.map((c) => c.args[0]);
  assert.ok(verbs.indexOf('fetch') < verbs.indexOf('merge'), verbs.join(','));
  const merge = calls.find((c) => c.args[0] === 'merge');
  assert.deepEqual(merge.args, ['merge', '--ff-only', 'origin/main']);
  assert.equal(merge.cwd, MAIN);
});

test('never discards or rewrites anything', () => {
  const { git, calls } = fakeGit(happy);
  run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git });
  for (const { args } of calls) {
    assert.ok(!['stash', 'reset', 'checkout', 'restore', 'clean', 'rebase', 'switch', 'push'].includes(args[0]), args.join(' '));
    assert.ok(!args.some((a) => /^--(force|hard)/.test(a)), args.join(' '));
  }
});

test('a main checkout on another branch is reported and left alone', () => {
  const { git, calls } = fakeGit({ ...happy, 'symbolic-ref': { stdout: 'feat/x\n' } });
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git });
  assert.equal(decision(out), 'block');
  assert.match(out.reason, /feat\/x/);
  assert.ok(!calls.some((c) => c.args[0] === 'merge'));
});

test('a failed fetch blocks with the reason and tries no merge', () => {
  const { git, calls } = fakeGit({ ...happy, fetch: { status: 128, stderr: 'fatal: unable to access github.com: SSL_ERROR_SYSCALL' } });
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git });
  assert.equal(decision(out), 'block');
  assert.match(out.reason, /fetch/i);
  assert.match(out.reason, /SSL_ERROR_SYSCALL/);
  assert.match(out.reason, /do not continue/i);
  assert.ok(!calls.some((c) => c.args[0] === 'merge'));
});

test('a blocked fast-forward (local changes) is reported, not worked around', () => {
  const { git, calls } = fakeGit({ ...happy, merge: { status: 1, stderr: 'error: Your local changes to the following files would be overwritten by merge:\n\tAGENTS.md' } });
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git });
  assert.equal(decision(out), 'block');
  assert.match(out.reason, /AGENTS\.md/);
  assert.match(out.reason, /do not continue/i);
  assert.ok(!calls.some((c) => ['stash', 'reset', 'checkout'].includes(c.args[0])));
});

test('local main that still differs from origin/main after the merge blocks', () => {
  const { git } = fakeGit({ ...happy, 'rev-parse main': { stdout: 'b'.repeat(40) + '\n' } });
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git });
  assert.equal(decision(out), 'block');
  assert.match(out.reason, /differs|not equal|behind/i);
});

test('an unreadable worktree list does nothing', () => {
  const { git } = fakeGit({ ...happy, 'worktree list --porcelain': { status: 128, stderr: 'fatal: not a git repository' } });
  assert.equal(run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: MAIN }, git }), null);
});

// ---- integration with real temporary repositories -----------------------------------
function sh(cwd, ...args) {
  return execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...args],
    { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'sync-main-hook-')));
  t.after(() => rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
  const origin = join(root, 'origin.git');
  const main = join(root, 'main');
  const other = join(root, 'other');
  const wt = join(root, 'wt');
  sh(root, 'init', '-q', '--bare', '-b', 'main', origin);
  sh(root, 'clone', '-q', origin, main);
  writeFileSync(join(main, 'a.txt'), 'one\n');
  writeFileSync(join(main, 'AGENTS.md'), 'agents\n');
  sh(main, 'add', 'a.txt', 'AGENTS.md');
  sh(main, 'commit', '-q', '-m', 'first');
  sh(main, 'push', '-q', 'origin', 'main');
  sh(main, 'worktree', 'add', '-q', '-b', 'feat/x', wt);
  sh(root, 'clone', '-q', origin, other);
  const land = (file, text, message) => { // another clone lands a merge on origin
    writeFileSync(join(other, file), text);
    sh(other, 'add', file);
    sh(other, 'commit', '-q', '-m', message);
    sh(other, 'push', '-q', 'origin', 'main');
    return sh(other, 'rev-parse', 'HEAD');
  };
  return { root, origin, main, wt, land };
}

test('integration: the main checkout fast-forwards to the merged commit', (t) => {
  const f = fixture(t);
  const merged = f.land('b.txt', 'two\n', 'docs: landed by a PR merge');
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: f.main } });
  assert.equal(decision(out), undefined, JSON.stringify(out));
  assert.equal(sh(f.main, 'rev-parse', 'HEAD'), merged);
  assert.match(context(out), new RegExp(merged.slice(0, 7)));
  assert.match(context(out), /landed by a PR merge/);
});

test('integration: a session in an implementer worktree does nothing', (t) => {
  const f = fixture(t);
  const before = sh(f.main, 'rev-parse', 'HEAD');
  f.land('b.txt', 'two\n', 'landed');
  assert.equal(run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: f.wt } }), null);
  assert.equal(sh(f.main, 'rev-parse', 'HEAD'), before);
});

test('integration: a local edit that blocks the fast-forward is kept and reported', (t) => {
  const f = fixture(t);
  f.land('AGENTS.md', 'agents, changed upstream\n', 'docs: upstream edit');
  writeFileSync(join(f.main, 'AGENTS.md'), 'agents, my local edit\n');
  const before = sh(f.main, 'rev-parse', 'HEAD');
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: f.main } });
  assert.equal(decision(out), 'block', JSON.stringify(out));
  assert.match(out.reason, /AGENTS\.md/);
  assert.equal(readFileSync(join(f.main, 'AGENTS.md'), 'utf8'), 'agents, my local edit\n');
  assert.equal(sh(f.main, 'rev-parse', 'HEAD'), before);
  assert.equal(sh(f.main, 'stash', 'list'), '');
});

test('integration: an unreachable remote blocks and moves nothing', (t) => {
  const f = fixture(t);
  const before = sh(f.main, 'rev-parse', 'HEAD');
  sh(f.main, 'remote', 'set-url', 'origin', join(f.root, 'does-not-exist.git'));
  const out = run(bash(MERGE), { env: { CLAUDE_PROJECT_DIR: f.main } });
  assert.equal(decision(out), 'block');
  assert.match(out.reason, /fetch/i);
  assert.equal(sh(f.main, 'rev-parse', 'HEAD'), before);
});

test('the script reads the hook input from stdin and prints JSON', (t) => {
  const f = fixture(t);
  const merged = f.land('b.txt', 'two\n', 'landed via cli');
  const res = spawnSync('node', [script], { input: JSON.stringify(bash(MERGE)), encoding: 'utf8',
    env: { ...process.env, CLAUDE_PROJECT_DIR: f.main } });
  assert.equal(res.status, 0, res.stderr);
  const out = JSON.parse(res.stdout);
  assert.equal(out.hookSpecificOutput.hookEventName, 'PostToolUse');
  assert.match(out.hookSpecificOutput.additionalContext, new RegExp(merged.slice(0, 7)));
  const quiet = spawnSync('node', [script], { input: JSON.stringify(bash('gh pr view 1')), encoding: 'utf8',
    env: { ...process.env, CLAUDE_PROJECT_DIR: f.main } });
  assert.equal(quiet.status, 0);
  assert.equal(quiet.stdout, '');
});
