import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const note = '\n注：Picsee 是 Mado 的旧名（#547、ADR-0017）。\n';
const temp = () => mkdtempSync(join(tmpdir(), 'mado-docs-fix-'));
function put(dir, path, content) { mkdirSync(dirname(join(dir, path)), { recursive: true }); writeFileSync(join(dir, path), content); }
function git(dir, ...args) { return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
function commit(dir) { git(dir, 'add', '--all'); git(dir, '-c', 'user.name=Docs fixture', '-c', 'user.email=docs@example.invalid', 'commit', '-qm', 'fixture'); return git(dir, 'rev-parse', 'HEAD'); }
function node(dir, path, ...args) { return spawnSync(process.execPath, [path, ...args], { cwd: dir, encoding: 'utf8' }); }

test('lasting scan permits new historical records and sanctioned acceptance in a depth-one tree but rejects stale current commands', () => {
  const dir = temp(); git(dir, 'init', '-q');
  const path = 'scripts/name-checks/living-docs.test.mjs';
  put(dir, path, readFileSync(join(root, path), 'utf8'));
  put(dir, 'AGENTS.md', 'Packages/MadoKit -scheme Mado\n');
  put(dir, 'docs/adr/0018-next.md', '# New decision\nPicsee was the former name.\n');
  put(dir, 'docs/validation/P4.md', '# New validation\n');
  put(dir, 'docs/feature-ledger.md', '| OPEN-01 | feature | Partial | unit | P1 | — | A later owner-approved acceptance condition |\n');
  commit(dir);
  put(dir, 'docs/validation/P4.md', '# New validation\nA later measured run.\n'); commit(dir);
  const clone = join(temp(), 'clone');
  execFileSync('git', ['clone', '-q', '--depth', '1', 'file://' + dir, clone], { stdio: 'pipe' });
  assert.equal(git(clone, 'rev-parse', '--is-shallow-repository'), 'true');
  const pass = node(clone, join(clone, path));
  assert.equal(pass.status, 0, 'lasting scan must not require historical baseline objects or freeze future records');
  put(clone, 'AGENTS.md', '~/.picsee/ Packages/PicseeKit\n');
  const fail = node(clone, join(clone, path));
  assert.notEqual(fail.status, 0, 'stale current package must still fail');
  assert.match(fail.stdout + fail.stderr, /Packages\/PicseeKit/);
});

test('replay preserves the bundle namespace and release input while renaming surrounding app prose', () => {
  const dir = temp(); git(dir, 'init', '-q');
  const script = 'scripts/name-checks/rename-living-docs.mjs';
  put(dir, script, readFileSync(join(root, script), 'utf8'));
  const prompt = 'design/prototypes/example/_ds/example/_ds_prompt.md';
  put(dir, prompt, '# Picsee design\nUse window.PicseeUiSystem_bb8eab\n');
  const release = 'docs/release/notes-template.md', original = 'Picsee {{VERSION}}\nPicsee-{{VERSION}}.dmg\n';
  put(dir, release, original); commit(dir);
  const first = node(dir, join(dir, script)); assert.equal(first.status, 0, first.stderr);
  assert.equal(readFileSync(join(dir, prompt), 'utf8'), '# Mado design\nUse window.PicseeUiSystem_bb8eab\n');
  assert.equal(readFileSync(join(dir, release), 'utf8'), original);
  const second = node(dir, join(dir, script)); assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, /0 tracked text files rewritten/);
});

function rangeFixture() {
  const dir = temp(); git(dir, 'init', '-q');
  const record = 'docs/adr/0017-decision.md', validation = 'docs/validation/P0.md';
  put(dir, record, '# Decision\nOriginal statement.\n'); put(dir, validation, '# Original validation\n');
  const rows = ['OPEN-03', 'CMD-05', 'WIN-02', 'EXT-03', 'OPEN-08', 'CMD-01', 'OPEN-01'];
  const ledger = '| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |\n|---|---|---|---|---|---|---|\n' + rows.map(id => `| ${id} | feature | Partial | unit | P1 | \`a|b\` | ${rows.slice(0,4).includes(id) ? 'picsee works' : 'unchanged'}。限制：picsee untested |`).join('\n') + '\n';
  put(dir, 'docs/feature-ledger.md', ledger);
  put(dir, 'docs/release/notes-template.md', 'Picsee {{VERSION}}\n');
  const base = commit(dir);
  put(dir, record, '# Decision\nOriginal statement.\n' + note); put(dir, validation, '# Original validation\n' + note);
  put(dir, 'docs/feature-ledger.md', ledger.replaceAll('picsee', 'Mado'));
  const head = commit(dir);
  return { dir, record, validation, base, head };
}
function check(f, ...args) {
  const script = join(root, 'scripts/name-checks/check-living-docs-range.mjs');
  assert.ok(existsSync(script), 'explicit one-shot range checker must exist');
  return node(f.dir, script, ...args);
}

test('one-shot check uses only explicit immutable trees and rejects unsupported transitions', () => {
  const f = rangeFixture();
  const run = head => check(f, '--base', f.base, '--head', head);
  const pass = run(f.head); assert.equal(pass.status, 0, pass.stderr); assert.match(pass.stdout, /2 records.*7 ledger rows/);
  // Later historical/acceptance evolution must not affect the selected PR range.
  put(f.dir, 'docs/adr/0018-new.md', '# Later ADR\n');
  put(f.dir, f.validation, 'Later sanctioned validation\n');
  put(f.dir, 'docs/feature-ledger.md', readFileSync(join(f.dir, 'docs/feature-ledger.md'), 'utf8').replace('unchanged', 'Later acceptance'));
  const later = commit(f.dir);
  assert.equal(run(f.head).status, 0, 'outside-range changes must not alter the original verdict');
  assert.notEqual(run(later).status, 0);
  // Build independent malformed heads directly from the valid selected tree.
  const goodLedger = git(f.dir, 'show', f.head + ':docs/feature-ledger.md') + '\n';
  const goodRecord = '# Decision\nOriginal statement.\n' + note;
  for (const [path, content, diagnostic] of [
    [f.record, goodRecord.replace('Original', 'Changed'), f.record],
    [f.record, goodRecord + note, f.record],
    [f.record, '# Decision\nOriginal statement.\n', f.record],
    ['docs/feature-ledger.md', goodLedger.replace('unchanged', 'weakened'), 'OPEN-08'],
    ['docs/feature-ledger.md', goodLedger.replace('Mado works', 'Mado sometimes works'), 'OPEN-03'],
    ['docs/feature-ledger.md', goodLedger.split('\n').filter(line => !line.startsWith('| OPEN-01 |')).join('\n'), 'ledger'],
  ]) {
    // create a commit with the valid head as parent, without moving or deleting files/branches
    const index = join(temp(), 'index');
    execFileSync('git', ['-C', f.dir, 'read-tree', f.head], { env: { ...process.env, GIT_INDEX_FILE: index } });
    const blob = execFileSync('git', ['-C', f.dir, 'hash-object', '-w', '--stdin'], { input: content, encoding: 'utf8' }).trim();
    execFileSync('git', ['-C', f.dir, 'update-index', '--cacheinfo', '100644', blob, path], { env: { ...process.env, GIT_INDEX_FILE: index } });
    const tree = execFileSync('git', ['-C', f.dir, 'write-tree'], { env: { ...process.env, GIT_INDEX_FILE: index }, encoding: 'utf8' }).trim();
    const bad = git(f.dir, '-c', 'user.name=Docs fixture', '-c', 'user.email=docs@example.invalid', 'commit-tree', tree, '-p', f.head, '-m', 'invalid fixture');
    const result = run(bad); assert.notEqual(result.status, 0, diagnostic); assert.ok((result.stdout + result.stderr).includes(diagnostic), diagnostic);
  }
});

test('one-shot check requires both revisions and fails visibly when the chosen object is absent', () => {
  const f = rangeFixture();
  for (const args of [[], ['--base', f.base], ['--head', f.head], ['--base'], ['--wat', 'x'], ['--base', f.base, '--head', 'missing-revision']]) {
    const result = check(f, ...args); assert.notEqual(result.status, 0); assert.match(result.stderr, /required|usage|argument|revision|commit/i);
  }
});
