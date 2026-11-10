import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
let directory, executable;
before(() => {
  directory = mkdtempSync(path.join(tmpdir(), 'i600-signal-contract-'));
  executable = path.join(directory, 'signal-contract');
  const compiled = spawnSync(path.join(root, 'scripts/heavy-lock.sh'), ['xcrun', 'clang', '-std=c11', '-O0',
    '-fno-omit-frame-pointer', path.join(root, 'AppTests/Issue600MainThreadCapture.c'),
    path.join(root, 'scripts/ci/fixtures/issue600-signal.c'), '-o', executable], { encoding: 'utf8', timeout: 1900000 });
  assert.equal(compiled.status, 0, `native fixture must compile: ${compiled.error?.message ?? compiled.stderr}`);
});
after(() => { if (directory) rmSync(directory, { recursive: true, force: true }); });
function run(mode) {
  const result = spawnSync(executable, [mode], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.signal, null, `fixture must survive ${mode}: ${result.stderr}`);
  assert.equal(result.status, 0, `fixture must finish ${mode}: ${result.stderr}`);
  return JSON.parse(result.stdout);
}

test('pending own SIGUSR2 is drained before default disposition restoration and next session is fresh', () => {
  const result = run('pending');
  assert.equal(result.owner, true);
  assert.equal(result.pendingBefore, 1);
  assert.equal(result.drained, 1);
  assert.equal(result.pendingAfter, 0);
  assert.equal(result.maskPreserved, true);
  assert.equal(result.defaultRestored, true);
  assert.equal(result.nextDistinct, true);
  assert.equal(result.nextCaptured, true);
  assert.equal(result.nextFresh, true);
});
test('foreign SIGUSR2 disposition is refused and remains functional', () => {
  const result = run('foreign');
  assert.equal(result.owner, false);
  assert.equal(result.status, 2);
  assert.equal(result.preserved, true);
  assert.equal(result.foreignCount, 1);
});
test('busy nonowner cannot restore the active owner handler', () => {
  const result = run('busy');
  assert.equal(result.owner, true);
  assert.equal(result.otherOwner, false);
  assert.equal(result.otherStatus, 1);
  assert.equal(result.nonownerPreserved, true);
  assert.equal(result.restored, true);
});
