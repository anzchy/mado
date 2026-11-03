import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
    'scripts/agents/local-pr-lint.mjs', 'scripts/agents/ui-parity-pr-body-lint.mjs']) {
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
