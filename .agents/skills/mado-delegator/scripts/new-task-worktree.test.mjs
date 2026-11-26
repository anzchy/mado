import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// #901: new-task-worktree.sh <issue> <slug> [<base>] creates the task worktree and branch, installs the Codex role
// overlay on request, writes the dispatch marker through mark-target.mjs and prints the dispatch lines.
const helper = fileURLToPath(new URL('./new-task-worktree.sh', import.meta.url));
const run = (cmd, args, cwd) => spawnSync(cmd, args, { cwd, encoding: 'utf8', timeout: 20000 });
const git = (cwd, ...args) => { const r = run('git', args, cwd); assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mado-i901-nt-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'gpt-imple-9');
  fs.mkdirSync(path.join(home, '.codex/rules'), { recursive: true });
  git(home, 'init', '-q', '-b', 'main');
  git(home, 'config', 'user.email', 'fixture@example.invalid');
  git(home, 'config', 'user.name', 'Fixture');
  fs.writeFileSync(path.join(home, '.gitignore'), '.build/\n.codex/rules/picsee-role.rules\n');
  fs.writeFileSync(path.join(home, '.codex/rules/picsee.rules'), '# common rules\n');
  fs.writeFileSync(path.join(home, 'tracked.txt'), 'base\n');
  git(home, 'add', '.gitignore', '.codex/rules/picsee.rules', 'tracked.txt');
  git(home, 'commit', '-qm', 'base');
  git(home, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  const handoff = path.join(root, 'handoff.md');
  const helperRun = (...args) => run('bash', [helper, ...args, '--pane-home', home, '--task', 'i651', '--handoff', handoff, '--root', root], root);
  const marker = () => JSON.parse(fs.readFileSync(path.join(home, '.build/mado-verify/target-worktree'), 'utf8'));
  const hasMarker = () => fs.existsSync(path.join(home, '.build/mado-verify/target-worktree'));
  return { root, home, handoff, helperRun, marker, hasMarker };
}

test('#901 the helper creates the worktree and branch from origin/main, writes the marker and prints the dispatch lines', t => {
  const f = fixture(t);
  const r = f.helperRun('651', 'demo', '--pane', 'w1:p9');
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const wt = path.join(f.root, '651-demo');
  assert.equal(git(wt, 'rev-parse', '--show-toplevel'), wt);
  assert.equal(git(wt, 'symbolic-ref', '--short', 'HEAD'), 'task/651-demo');
  assert.equal(git(wt, 'rev-parse', 'HEAD'), git(f.home, 'rev-parse', 'origin/main'));
  assert.deepEqual(f.marker(), { worktree: wt, branch: 'task/651-demo', issue: 651, task: 'i651', handoff: f.handoff });
  assert.match(r.stdout, new RegExp(`^worktree: ${wt}$`, 'm'));
  assert.match(r.stdout, /^branch: task\/651-demo$/m);
  assert.match(r.stdout, /^marker: .*gpt-imple-9\/\.build\/mado-verify\/target-worktree$/m);
  // Claude dispatch: /clear in the pane, then a prompt that names the task worktree.
  assert.match(r.stdout, /herdr pane send-text w1:p9 '\/clear'/);
  assert.match(r.stdout, new RegExp(`Worktree: ${wt}`));
  assert.equal(fs.existsSync(path.join(wt, '.codex/rules/picsee-role.rules')), false);
});

test('#901 --codex installs the implementor role overlay and prints the start-fresh-codex task-worktree line', t => {
  const f = fixture(t);
  const r = f.helperRun('651', 'demo', '--codex', '--pane', 'w1:p2', '--brief', '/tmp/brief.md');
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const wt = path.join(f.root, '651-demo');
  assert.match(fs.readFileSync(path.join(wt, '.codex/rules/picsee-role.rules'), 'utf8'), /^# Local picsee role: implementor$/m);
  assert.match(r.stdout, new RegExp(`start-fresh-codex\\.sh w1:p2 gpt-imple-9 --cwd ${f.home} --task-worktree ${wt} --prompt 'New task: .*Worktree: ${wt}.*/tmp/brief\\.md`));
});

test('#901 the helper takes an explicit base and branch name', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.home, 'tracked.txt'), 'next\n');
  git(f.home, 'commit', '-qam', 'next');
  const r = f.helperRun('652', 'base-demo', 'main', '--branch', 'tooling/652-base-demo');
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const wt = path.join(f.root, '652-base-demo');
  assert.equal(git(wt, 'symbolic-ref', '--short', 'HEAD'), 'tooling/652-base-demo');
  assert.equal(git(wt, 'rev-parse', 'HEAD'), git(f.home, 'rev-parse', 'main'));
});

test('#901 the helper refuses an existing path and leaves the marker alone', t => {
  const f = fixture(t);
  fs.mkdirSync(path.join(f.root, '651-demo'));
  const r = f.helperRun('651', 'demo');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /already exists/);
  assert.equal(f.hasMarker(), false);
});

test('#901 the helper refuses a dirty base: a base branch with uncommitted tracked changes in its worktree', t => {
  const f = fixture(t);
  const other = path.join(f.root, '650-feature');
  git(f.home, 'worktree', 'add', '-q', '-b', 'feature', other, 'origin/main');
  fs.writeFileSync(path.join(other, 'tracked.txt'), 'uncommitted\n');
  const r = f.helperRun('651', 'demo', 'feature');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /base feature has uncommitted changes in .*650-feature/);
  assert.equal(fs.existsSync(path.join(f.root, '651-demo')), false);
});

test('#901 the helper refuses a pane home as the target, bad names, an unknown base and an existing branch', t => {
  const f = fixture(t);
  // The computed path is the pane home itself.
  const pane = run('bash', [helper, '651', 'demo', '--pane-home', path.join(f.root, '651-demo'), '--task', 'i651', '--handoff', f.handoff, '--root', f.root], f.root);
  assert.notEqual(pane.status, 0);
  assert.match(pane.stderr, /pane home/);
  for (const [issue, slug, pattern] of [['x', 'demo', /issue/], ['651', 'Bad/Slug', /slug/]]) {
    const r = f.helperRun(issue, slug);
    assert.notEqual(r.status, 0, `${issue} ${slug}`);
    assert.match(r.stderr, pattern, `${issue} ${slug}`);
  }
  const base = f.helperRun('651', 'demo', 'no-such-ref');
  assert.notEqual(base.status, 0);
  assert.match(base.stderr, /base no-such-ref is not a commit/);
  git(f.home, 'branch', 'task/651-demo', 'origin/main');
  const exists = f.helperRun('651', 'demo');
  assert.notEqual(exists.status, 0);
  assert.match(exists.stderr, /branch task\/651-demo already exists.*--existing-branch/);
  assert.equal(fs.existsSync(path.join(f.root, '651-demo')), false);
  assert.equal(f.hasMarker(), false);
});

test('#901 --existing-branch moves a fix round of an older task into its own worktree', t => {
  const f = fixture(t);
  git(f.home, 'branch', 'task/651-demo', 'origin/main');
  const r = f.helperRun('651', 'demo', '--existing-branch');
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.equal(git(path.join(f.root, '651-demo'), 'symbolic-ref', '--short', 'HEAD'), 'task/651-demo');
  assert.equal(f.marker().branch, 'task/651-demo');
});

// Runs one printed command line in `cwd` with bash; fake commands write their argv NUL-separated to `out`.
function fakeCommand(file, out) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `#!/bin/bash\nprintf '%s\\0' "$@" >> ${JSON.stringify(out)}\nprintf '\\n' >> ${JSON.stringify(out)}\n`, { mode: 0o755 });
}
const calls = out => fs.readFileSync(out, 'utf8').split('\n').filter(Boolean).map(line => line.split('\0').slice(0, -1));

test('#901 fix1 (gpt F2) printed dispatch lines are shell-quoted: paths with spaces and a brief with a quote', t => {
  const f = fixture(t);
  const roots = path.join(f.root, 'task roots');
  fs.mkdirSync(roots);
  const home = path.join(f.root, 'pane homes', 'gpt-imple-8');
  git(f.home, 'worktree', 'add', '-q', '--detach', home, 'origin/main');
  const brief = path.join(f.root, "it's brief.md");
  const helperArgs = ['--pane-home', home, '--task', 'i651', '--handoff', f.handoff, '--root', roots, '--pane', 'w1:p2', '--brief', brief];
  const codex = run('bash', [helper, '651', 'demo', '--codex', ...helperArgs], f.root);
  assert.equal(codex.status, 0, codex.stderr + codex.stdout);
  const wt = path.join(roots, '651-demo');
  const line = codex.stdout.match(/^dispatch \(Codex\): (.*)$/m)?.[1];
  assert.ok(line, codex.stdout);
  const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-i901-q-'));
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));
  const out = path.join(sandbox, 'argv');
  fakeCommand(path.join(sandbox, '.agents/skills/mado-delegator/scripts/start-fresh-codex.sh'), out);
  const exec = run('bash', ['-c', line], sandbox);
  assert.equal(exec.status, 0, exec.stderr);
  const [argv] = calls(out);
  assert.deepEqual(argv.slice(0, 6), ['w1:p2', 'gpt-imple-8', '--cwd', home, '--task-worktree', wt]);
  assert.equal(argv[6], '--prompt');
  assert.match(argv[7], new RegExp(`Worktree: ${wt.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} `));
  assert.ok(argv[7].includes(brief), argv[7]);
  assert.equal(argv.length, 8);

  // The Claude line: the commands after "then" run as printed with a fake herdr.
  fs.writeFileSync(out, '');
  const claude = run('bash', [helper, '652', 'demo', ...helperArgs], f.root);
  assert.equal(claude.status, 0, claude.stderr + claude.stdout);
  const send = claude.stdout.match(/^dispatch \(Claude\): .*?; then (.*)$/m)?.[1];
  assert.ok(send, claude.stdout);
  fakeCommand(path.join(sandbox, 'bin/herdr'), out);
  const sent = spawnSync('bash', ['-c', send], { cwd: sandbox, encoding: 'utf8', env: { ...process.env, PATH: `${sandbox}/bin:${process.env.PATH}` } });
  assert.equal(sent.status, 0, sent.stderr);
  const [text, keys] = calls(out);
  assert.deepEqual(text.slice(0, 3), ['pane', 'send-text', 'w1:p2']);
  assert.equal(text.length, 4);
  assert.ok(text[3].includes(`Worktree: ${path.join(roots, '652-demo')} `) && text[3].includes(brief), text[3]);
  assert.deepEqual(keys, ['pane', 'send-keys', 'w1:p2', 'Enter']);
});

test('#901 fix1 (gpt M1) an explicit HEAD base is checked for uncommitted tracked changes too', t => {
  for (const base of ['HEAD', '@']) {
    const f = fixture(t);
    fs.writeFileSync(path.join(f.home, 'tracked.txt'), 'uncommitted\n');
    const r = f.helperRun('651', 'demo', base);
    assert.notEqual(r.status, 0, base);
    assert.match(r.stderr, new RegExp(`base ${base} has uncommitted changes in .*gpt-imple-9`), base);
    assert.equal(fs.existsSync(path.join(f.root, '651-demo')), false, base);
    assert.equal(f.hasMarker(), false, base);
    // A clean HEAD is a valid base.
    fs.writeFileSync(path.join(f.home, 'tracked.txt'), 'base\n');
    const ok = f.helperRun('651', 'demo', base);
    assert.equal(ok.status, 0, ok.stderr);
  }
});
