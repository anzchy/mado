import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const hook = join(root, 'scripts/git-hooks/pre-push');
const lanes = ['package-tests', 'package-coverage', 'app-tests', 'unsigned-build', 'node-tooling', 'ledger', 'diff-check', 'design-check', 'audit', 'device-smoke'];
const gates = sha => '## Gates\n\n| Lane | Status | SHA | Source |\n| --- | --- | --- | --- |\n' +
  lanes.map(lane => `| ${lane} | PASS | ${sha} | local evidence |`).join('\n');

function fixture(t) {
  const repo = mkdtempSync(join(tmpdir(), 'picsee-pre-push-test-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const write = (file, content) => { mkdirSync(join(repo, file, '..'), { recursive: true }); writeFileSync(join(repo, file), content); };
  const paths = execFileSync('git', ['ls-files', '-z', 'App', 'Packages/PicseeKit/Sources'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
  for (const path of [...paths, 'docs/feature-ledger.md', 'docs/feature-ledger.html', 'scripts/ledger/build.mjs',
    'scripts/design/shortcut-model.mjs', 'design/prototypes/picsee-browser/states/shortcuts.html',
    'scripts/git-hooks/pre-push', 'scripts/agents/local-pr-lint.mjs', 'scripts/agents/ui-parity-pr-body-lint.mjs']) {
    mkdirSync(join(repo, path, '..'), { recursive: true }); copyFileSync(join(root, path), join(repo, path));
  }
  git('init', '-q', '-b', 'topic'); git('config', 'core.hooksPath', '/dev/null');
  git('config', 'user.name', 'Test'); git('config', 'user.email', 'test@example.invalid');
  git('add', '.'); git('commit', '-qm', 'base');
  const base = git('rev-parse', 'HEAD'); git('update-ref', 'refs/remotes/origin/main', base);
  write('scripts/tool.mjs', '// topic change\n'); git('add', '.'); git('commit', '-qm', 'topic');
  const head = git('rev-parse', 'HEAD');
  const body = join(repo, 'body.md'); writeFileSync(body, gates(head));
  const sentinels = join(repo, 'sentinels'); mkdirSync(sentinels);
  for (const name of ['swift', 'xcodebuild', 'xcodegen', 'npm', 'npx', 'chromium', 'playwright']) {
    writeFileSync(join(sentinels, name), '#!/bin/sh\necho "FORBIDDEN heavy command" >&2\nexit 98\n', { mode: 0o755 });
  }
  const input = oid => `refs/heads/topic ${oid} refs/heads/topic ${base}\n`;
  const run = ({ suppliedBody = false, oid = head, stdin = input(oid) } = {}) => spawnSync('sh', [hook, 'origin', 'unused'], {
    cwd: repo, input: stdin, encoding: 'utf8', timeout: 15000,
    env: { ...process.env, PATH: sentinels + ':' + process.env.PATH, PICSEE_PR_BODY: suppliedBody ? body : '' },
  });
  return { repo, git, write, base, head, body, run };
}
function status(result, expected, pattern) {
  assert.equal(result.status, expected, result.stdout + result.stderr);
  if (pattern) assert.match(result.stdout + result.stderr, pattern);
  assert.doesNotMatch(result.stdout + result.stderr, /FORBIDDEN heavy command/);
}

test('broken real ledger HTML blocks; regenerated HTML passes the hook without a PR body', t => {
  const f = fixture(t);
  f.write('docs/feature-ledger.html', '<p>broken</p>');
  f.git('add', '.'); f.git('commit', '-qm', 'commit drift');
  const broken = f.run({ oid: f.git('rev-parse', 'HEAD') });
  assert.notEqual(broken.status, 0, broken.stdout + broken.stderr);
  assert.match(broken.stdout + broken.stderr, /ledger|stale|out.of.date/i);
  execFileSync(process.execPath, ['scripts/ledger/build.mjs'], { cwd: f.repo });
  f.git('add', '.'); f.git('commit', '-qm', 'commit correction');
  status(f.run({ oid: f.git('rev-parse', 'HEAD') }), 0, /shortcut-model PASS/);
});

test('shortcut table drift blocks via the real standalone browser-free checker', t => {
  const f = fixture(t);
  const file = 'design/prototypes/picsee-browser/states/shortcuts.html';
  const original = readFileSync(join(f.repo, file), 'utf8');
  f.write(file, original.replace('data-shortcut="menu:Quit Picsee"', 'data-shortcut="menu:Unknown command"'));
  f.git('add', '.'); f.git('commit', '-qm', 'commit drift');
  const broken = f.run({ oid: f.git('rev-parse', 'HEAD') });
  assert.notEqual(broken.status, 0, broken.stdout + broken.stderr);
  assert.match(broken.stdout + broken.stderr, /shortcut-model FAIL/);
  f.write(file, original);
  f.git('add', '.'); f.git('commit', '-qm', 'commit correction');
  status(f.run({ oid: f.git('rev-parse', 'HEAD') }), 0, /shortcut-model PASS/);
});

test('stale PR body blocks and corrected body passes against Git pre-push local OID', t => {
  const f = fixture(t);
  writeFileSync(f.body, gates(f.base));
  status(f.run({ suppliedBody: true }), 1, /stale head/);
  writeFileSync(f.body, gates(f.head));
  status(f.run({ suppliedBody: true }), 0, /PR body: PASS/);
  status(f.run({ suppliedBody: true, oid: f.base }), 2, /HEAD.*(expect|push)|expect.*HEAD/i);
});

test('empty input cannot certify a supplied body; deletions skip lint and absent body needs no upstream', t => {
  const f = fixture(t);
  status(f.run({ suppliedBody: true, stdin: '' }), 2, /push|input|commit/i);
  writeFileSync(f.body, 'not a valid PR body');
  status(f.run({ suppliedBody: true, oid: '0'.repeat(40) }), 0);
  status(f.run(), 0, /shortcut-model PASS/);
});


test('disk regeneration cannot conceal committed stale ledger HTML', t => {
  const f = fixture(t);
  f.write('docs/feature-ledger.html', '<p>stale committed HTML</p>');
  f.git('add', 'docs/feature-ledger.html'); f.git('commit', '-qm', 'stale ledger');
  const stale = f.git('rev-parse', 'HEAD');
  execFileSync(process.execPath, ['scripts/ledger/build.mjs'], { cwd: f.repo });
  const corrected = readFileSync(join(f.repo, 'docs/feature-ledger.html'), 'utf8');
  const result = f.run({ oid: stale });
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout + result.stderr, /ledger.*stale/i);
  assert.equal(readFileSync(join(f.repo, 'docs/feature-ledger.html'), 'utf8'), corrected);
  // Valid older OID remains valid despite a stale HEAD and dirty checkout.
  status(f.run({ oid: f.head }), 0, /shortcut-model PASS/);
  f.git('add', 'docs/feature-ledger.html'); f.git('commit', '-qm', 'correct ledger');
  // Valid HEAD must not conceal a stale older OID.
  const nonHead = f.run({ oid: stale });
  assert.notEqual(nonHead.status, 0, nonHead.stdout + nonHead.stderr);
  assert.match(nonHead.stdout + nonHead.stderr, /ledger.*stale/i);
});

test('shortcut check uses pushed OID despite HEAD and checkout drift', t => {
  const f = fixture(t);
  const file = 'design/prototypes/picsee-browser/states/shortcuts.html';
  const original = readFileSync(join(f.repo, file), 'utf8');
  f.write(file, original.replace('data-shortcut="menu:Quit Picsee"', 'data-shortcut="menu:Unknown command"'));
  f.git('add', file); f.git('commit', '-qm', 'stale shortcuts');
  const stale = f.git('rev-parse', 'HEAD');
  status(f.run({ oid: f.head }), 0, /shortcut-model PASS/);
  f.write(file, original);
  const dirty = f.run({ oid: stale });
  assert.notEqual(dirty.status, 0, dirty.stdout + dirty.stderr);
  assert.match(dirty.stdout + dirty.stderr, /shortcut-model FAIL/);
  f.git('add', file); f.git('commit', '-qm', 'correct shortcuts');
  const nonHead = f.run({ oid: stale });
  assert.notEqual(nonHead.status, 0, nonHead.stdout + nonHead.stderr);
  assert.match(nonHead.stdout + nonHead.stderr, /shortcut-model FAIL/);
});

test('all non-deletion refs are checked and deletion-only or empty input is a no-op', t => {
  const f = fixture(t);
  f.write('docs/feature-ledger.html', 'stale');
  f.git('add', 'docs/feature-ledger.html'); f.git('commit', '-qm', 'stale ledger');
  const stale = f.git('rev-parse', 'HEAD');
  execFileSync(process.execPath, ['scripts/ledger/build.mjs'], { cwd: f.repo });
  const result = f.run({ stdin: `refs/heads/valid ${f.head} refs/heads/valid ${f.base}\nrefs/heads/stale ${stale} refs/heads/stale ${f.base}\n` });
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout + result.stderr, /ledger.*stale/i);
  // Neither a deletion nor empty input has content to check, even with dirty disk.
  f.write('docs/feature-ledger.html', 'still stale on disk');
  status(f.run({ oid: '0'.repeat(40) }), 0);
  status(f.run({ stdin: '' }), 0);
});


test('installed hook and runner survive topic replacement and still reject stale evidence', t => {
  const f = fixture(t);
  const install = spawnSync('sh', [hook, '--install', 'origin/main'], { cwd: f.repo, encoding: 'utf8' });
  status(install, 0);
  const installed = f.git('config', '--get', 'core.hooksPath');
  assert.ok(existsSync(join(installed, 'pre-push')), 'installer must create a runnable hook snapshot');
  assert.ok(installed.startsWith('/'), installed);
  assert.ok(!installed.startsWith(f.repo + '/scripts/'), installed);
  f.write('scripts/git-hooks/pre-push', '#!/bin/sh\nexit 0\n');
  f.write('scripts/agents/local-pr-lint.mjs', 'process.exit(0);\n');
  f.write('scripts/agents/ui-parity-pr-body-lint.mjs', 'process.exit(0);\n');
  f.git('add', 'scripts'); f.git('commit', '-qm', 'weaken topic gates');
  const head = f.git('rev-parse', 'HEAD');
  writeFileSync(f.body, gates(f.base));
  const run = () => {
    const refs = join(f.repo, 'push-input');
    writeFileSync(refs, `refs/heads/topic ${f.git('rev-parse', 'HEAD')} refs/heads/topic ${f.base}\n`);
    return spawnSync('git', ['hook', 'run', '--to-stdin=' + refs, 'pre-push', '--', 'origin', 'unused'], {
      cwd: f.repo, encoding: 'utf8', env: { ...process.env, PICSEE_PR_BODY: f.body }, timeout: 15000,
    });
  };
  status(run(), 1, /stale head/);
  writeFileSync(f.body, gates(head));
  status(run(), 0, /PR body: PASS/);
  f.git('rm', 'scripts/git-hooks/pre-push'); f.git('commit', '-qm', 'delete topic hook');
  writeFileSync(f.body, gates(f.base));
  status(run(), 1, /stale head/);
  f.write('docs/feature-ledger.html', 'stale');
  f.write('scripts/ledger/build.mjs', 'process.exit(0);\n');
  f.git('add', 'docs/feature-ledger.html', 'scripts/ledger/build.mjs'); f.git('commit', '-qm', 'weaken ledger');
  const result = spawnSync(join(installed, 'pre-push'), ['origin', 'unused'], {
    cwd: f.repo, input: `refs/heads/topic ${f.git('rev-parse', 'HEAD')} refs/heads/topic ${f.base}\n`,
    encoding: 'utf8', env: { ...process.env, PICSEE_PR_BODY: '' }, timeout: 15000,
  });
  status(result, 0, /ledger.*checker changed.*CI decides/i);
});


test('installation refuses missing runner without changing prior hooksPath', t => {
  const f = fixture(t);
  f.git('rm', 'scripts/agents/local-pr-lint.mjs'); f.git('commit', '-qm', 'incomplete base');
  const before = f.git('config', '--get', 'core.hooksPath');
  const result = spawnSync('sh', [hook, '--install', 'HEAD'], { cwd: f.repo, encoding: 'utf8' });
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.equal(f.git('config', '--get', 'core.hooksPath'), before);
  const missing = spawnSync('sh', [hook, '--install', 'missing-base'], { cwd: f.repo, encoding: 'utf8' });
  assert.notEqual(missing.status, 0);
  assert.equal(f.git('config', '--get', 'core.hooksPath'), before);
});

function documentedBootstrap() {
  const readme = readFileSync(join(root, 'scripts/codex-rules/README.md'), 'utf8');
  const snippet = readme.match(/Opt in to the light pre-push checks[\s\S]*?```sh\n([\s\S]*?)\n```/)?.[1];
  assert.ok(snippet, 'missing documented hook bootstrap');
  return snippet;
}
function bootstrap(f) {
  return spawnSync('sh', ['-c', documentedBootstrap()], { cwd: f.repo, encoding: 'utf8', timeout: 15000,
    env: { ...process.env, PICSEE_PR_BODY: '' } });
}
function baseAtHead(f) {
  f.git('add', 'scripts'); f.git('commit', '-qm', 'test installation base');
  f.git('update-ref', 'refs/remotes/origin/main', f.git('rev-parse', 'HEAD'));
}
test('documented bootstrap rejects a pre-install base loudly and preserves hooksPath', t => {
  const f = fixture(t);
  const old = execFileSync('git', ['show', 'e000f1dc:scripts/git-hooks/pre-push'], { cwd: root, encoding: 'utf8' });
  f.write('scripts/git-hooks/pre-push', old);
  baseAtHead(f);
  const result = bootstrap(f);
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stderr, /base.*(install|support)|install.*base/i);
  assert.equal(f.git('config', '--get', 'core.hooksPath'), '/dev/null');
  const direct = spawnSync('sh', [hook, '--install', 'origin/main'], { cwd: f.repo, encoding: 'utf8' });
  assert.notEqual(direct.status, 0, direct.stdout + direct.stderr);
  assert.match(direct.stderr, /base.*installer/i);
  assert.equal(f.git('config', '--get', 'core.hooksPath'), '/dev/null');
});
test('documented bootstrap installs an absolute runnable hook from a capable base', t => {
  const f = fixture(t);
  status(bootstrap(f), 0, /installed base/);
  const installed = f.git('config', '--get', 'core.hooksPath');
  assert.ok(installed.startsWith('/'));
  assert.ok(existsSync(join(installed, 'pre-push')));
});
for (const mode of ['show-failure', 'installer-failure', 'false-success', 'relative-path']) {
  test(`documented bootstrap propagates ${mode}`, t => {
    const f = fixture(t);
    if (mode === 'relative-path') f.git('config', 'core.hooksPath', 'scripts/git-hooks');
    if (mode === 'show-failure') f.git('update-ref', '-d', 'refs/remotes/origin/main');
    else {
      f.write('scripts/git-hooks/pre-push', `#!/bin/sh\nif [ "$1" = --install-capability ]; then echo picsee-pre-push-installer-v1; exit 0; fi\n${mode === 'installer-failure' ? 'exit 23' : 'exit 0'}\n`);
      baseAtHead(f);
    }
    const result = bootstrap(f);
    assert.notEqual(result.status, 0, result.stdout + result.stderr);
    if (mode === 'installer-failure') assert.equal(result.status, 23);
    assert.equal(f.git('config', '--get', 'core.hooksPath'), mode === 'relative-path' ? 'scripts/git-hooks' : '/dev/null');
  });
}

test('reinstall removes archive and prunes aged snapshots while retaining current and previous hooks', t => {
  const f = fixture(t);
  const install = () => {
    status(spawnSync('sh', [hook, '--install', 'origin/main'], { cwd: f.repo, encoding: 'utf8' }), 0);
    return f.git('config', '--get', 'core.hooksPath');
  };
  const first = install();
  const snapshot = join(first, '../../..');
  assert.equal(existsSync(join(snapshot, 'input.tar')), false);
  const old = new Date(Date.now() - 10 * 86400000);
  utimesSync(snapshot, old, old);
  const second = install();
  assert.ok(existsSync(first), 'retain previously configured hook for concurrent pushes');
  assert.ok(existsSync(second));
  const third = install();
  assert.equal(existsSync(first), false, 'prune aged, no longer selected snapshot');
  assert.ok(existsSync(second), 'retain previous snapshot');
  assert.ok(existsSync(third), 'retain installed snapshot');
});

for (const checker of ['ledger', 'shortcut']) {
  test(`changed ${checker} checker defers only its own check to CI without executing topic code`, t => {
    const f = fixture(t);
    status(spawnSync('sh', [hook, '--install', 'origin/main'], { cwd: f.repo, encoding: 'utf8' }), 0);
    const installed = f.git('config', '--get', 'core.hooksPath');
    const path = checker === 'ledger' ? 'scripts/ledger/build.mjs' : 'scripts/design/shortcut-model.mjs';
    const original = readFileSync(join(f.repo, path), 'utf8');
    if (checker === 'ledger') {
      f.write(path, original.replace('<!doctype html>', '<!-- topic renderer -->\n<!doctype html>'));
      execFileSync(process.execPath, [path], { cwd: f.repo });
      execFileSync(process.execPath, [path, '--check'], { cwd: f.repo });
    } else {
      f.write('App/NewKeys.swift', 'func keyDown(event: Event) { if event.keyCode == 99 {} }\n');
      f.write(path, original.replace('export const KEY_SITES = {',
        "export const KEY_SITES = { 'App/NewKeys.swift': { 99: { excluded: 'fixture control activation' } },"));
      execFileSync(process.execPath, [path], { cwd: f.repo });
    }
    f.git('add', 'scripts', 'App', 'docs/feature-ledger.html'); f.git('commit', '-qm', 'teach checker');
    const run = (suppliedBody = false) => spawnSync(join(installed, 'pre-push'), ['origin', 'unused'], { cwd: f.repo,
      input: `refs/heads/topic ${f.git('rev-parse', 'HEAD')} refs/heads/topic ${f.base}\n`, encoding: 'utf8', timeout: 15000,
      env: { ...process.env, PICSEE_PR_BODY: suppliedBody ? f.body : '' } });
    const deferred = run();
    status(deferred, 0, new RegExp(`${checker}.*checker changed.*CI decides`, 'i'));
    assert.match(deferred.stdout, /CI decides.*local check deferred.*PR body must carry Checker-Change: acknowledgement for independent review/);
    assert.doesNotMatch(deferred.stdout + deferred.stderr, /TOPIC CHECKER MUST NOT EXECUTE/);
    f.write(path, 'throw Error("TOPIC CHECKER MUST NOT EXECUTE");\n');
    f.git('add', path); f.git('commit', '-qm', 'sentinel topic checker');
    const sentinel = run();
    status(sentinel, 0, /checker changed.*CI decides/i);
    assert.match(sentinel.stdout, /PR body must carry Checker-Change: acknowledgement for independent review/);
    assert.doesNotMatch(sentinel.stdout + sentinel.stderr, /TOPIC CHECKER MUST NOT EXECUTE/);
    writeFileSync(f.body, gates(f.base));
    status(run(true), 1, checker === 'shortcut' ? /UI files changed; PR body needs/ : /stale head/);
    // The unchanged checker still rejects drift, even when the other is deferred.
    if (checker === 'ledger') {
      const page = 'design/prototypes/picsee-browser/states/shortcuts.html';
      f.write(page, readFileSync(join(f.repo, page), 'utf8').replace('menu:Quit Picsee', 'menu:Unknown command'));
    } else f.write('docs/feature-ledger.html', 'stale');
    f.git('add', 'docs', 'design'); f.git('commit', '-qm', 'other checker drift');
    const failed = run();
    assert.notEqual(failed.status, 0, failed.stdout + failed.stderr);
    assert.match(failed.stdout + failed.stderr, checker === 'ledger' ? /shortcut-model FAIL/ : /ledger.*stale/);
  });
}
