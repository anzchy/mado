import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('./local-pr-lint.mjs', import.meta.url));
const realValidator = readFileSync(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url), 'utf8');
const lanes = ['package-tests', 'package-coverage', 'app-tests', 'unsigned-build', 'node-tooling', 'ledger', 'diff-check', 'design-check', 'audit', 'device-smoke'];
const gates = sha => '## Gates\n\n| Lane | Status | SHA | Source |\n| --- | --- | --- | --- |\n' +
  lanes.map(lane => `| ${lane} | PASS | ${sha} | local evidence |`).join('\n');

function fixture(t, validator = 'export function checkGates() {}\nconsole.log("BASE validator");\n') {
  const root = mkdtempSync(join(tmpdir(), 'picsee-local-lint-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, 'repo'), extract = join(root, 'extract');
  mkdirSync(repo); mkdirSync(extract);
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-q', '-b', 'topic');
  git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Test');
  git('config', 'core.hooksPath', '/dev/null');
  const write = (path, content) => {
    mkdirSync(join(repo, path, '..'), { recursive: true }); writeFileSync(join(repo, path), content);
  };
  write('scripts/agents/ui-parity-pr-body-lint.mjs', validator);
  write('scripts/agents/helper.mjs', 'export const result = 1;\n');
  git('add', '.'); git('commit', '-qm', 'base');
  const base = git('rev-parse', 'HEAD');
  git('update-ref', 'refs/remotes/origin/main', base);
  write('scripts/tool.mjs', '// topic\n'); git('add', '.'); git('commit', '-qm', 'topic');
  const head = git('rev-parse', 'HEAD');
  const body = join(root, 'body.md'); writeFileSync(body, gates(head));
  const run = (...args) => spawnSync(process.execPath, [cli, '--body-file', body, ...args],
    { cwd: repo, env: { ...process.env, TMPDIR: extract }, encoding: 'utf8', timeout: 15000 });
  return { repo, git, write, base, head, body, run, extract };
}

function status(result, expected, pattern) {
  assert.equal(result.status, expected, result.stdout + result.stderr);
  if (pattern) assert.match(result.stdout + result.stderr, pattern);
}

test('explicit expectation refuses stale HEAD, accepts exact current commit, and cleans extraction', t => {
  const f = fixture(t);
  status(f.run('--expect', f.base), 2, /HEAD.*(expect|push)|expect.*HEAD/i);
  status(f.run('--expect', f.head), 0, /BASE validator/);
  assert.deepEqual(readdirSync(f.extract), []);
});

test('upstream fallback resolves the local tracking tip and refuses missing or stale tracking refs', t => {
  const f = fixture(t);
  status(f.run(), 2, /upstream|--expect/i);
  f.git('config', 'remote.origin.url', '.');
  f.git('config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*');
  f.git('config', 'branch.topic.remote', 'origin'); f.git('config', 'branch.topic.merge', 'refs/heads/topic');
  f.git('update-ref', 'refs/remotes/origin/topic', f.base);
  status(f.run(), 2, /HEAD.*(expect|push)|expect.*HEAD/i);
  f.git('update-ref', 'refs/remotes/origin/topic', f.head);
  status(f.run(), 0, /BASE validator/);
});

test('base validator and relative imports win over modified HEAD copies, for rejection and success', t => {
  const f = fixture(t, 'import { result } from "./helper.mjs";\nexport function checkGates() {}\nconsole.log("TRUSTED result=" + result);\nprocess.exitCode = result;\n');
  f.write('scripts/agents/ui-parity-pr-body-lint.mjs', 'console.log("UNTRUSTED");\n');
  f.write('scripts/agents/helper.mjs', 'export const result = 0;\n');
  f.git('add', '.'); f.git('commit', '-qm', 'weaken validator');
  const head = f.git('rev-parse', 'HEAD');
  const reject = f.run('--expect', head);
  status(reject, 1, /TRUSTED result=1/);
  assert.doesNotMatch(reject.stdout, /UNTRUSTED/);
  assert.deepEqual(readdirSync(f.extract), []);
  // A different explicitly selected trusted base has a passing helper.
  f.write('scripts/agents/ui-parity-pr-body-lint.mjs', 'import { result } from "./helper.mjs";\nexport function checkGates() {}\nconsole.log("OTHER BASE result=" + result);\nprocess.exitCode = result;\n');
  f.git('add', '.'); f.git('commit', '-qm', 'other base');
  const other = f.git('rev-parse', 'HEAD');
  f.git('branch', 'other-base', other);
  f.write('scripts/agents/helper.mjs', 'export const result = 1;\n');
  f.git('add', '.'); f.git('commit', '-qm', 'HEAD helper rejects');
  status(f.run('--base', 'other-base', '--expect', f.git('rev-parse', 'HEAD')), 0, /OTHER BASE result=0/);
  assert.deepEqual(readdirSync(f.extract), []);
});

test('real trusted validator checks stale gate evidence against worktree HEAD, then accepts corrected evidence', t => {
  const f = fixture(t, realValidator);
  writeFileSync(f.body, gates(f.base));
  status(f.run('--expect', f.head), 1, /stale head/);
  writeFileSync(f.body, gates(f.head));
  status(f.run('--expect', f.head), 0, /PR body: PASS/);
});

test('invalid invocation, unknown refs, missing body and pre-Gates base fail clearly', t => {
  const f = fixture(t, 'console.log("obsolete validator");\n');
  for (const args of [['--expect'], ['--expect', 'bogus'], ['--base', 'bogus', '--expect', f.head], ['--bad'], ['--base', '--expect', f.head]]) {
    status(f.run(...args), 2);
  }
  status(f.run('--expect', f.head), 2, /trusted.*checkGates/i);
  const noBody = spawnSync(process.execPath, [cli, '--expect', f.head], { cwd: f.repo, encoding: 'utf8' });
  status(noBody, 2, /usage|body-file/i);
  rmSync(f.body);
  status(f.run('--expect', f.head), 2, /body|ENOENT/i);
  assert.deepEqual(readdirSync(f.extract), []);
});
