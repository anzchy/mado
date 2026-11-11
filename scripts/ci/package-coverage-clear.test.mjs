import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

test('clears only Package coverage profiles after cache restore and is idempotent', t => {
  const root = mkdtempSync(join(tmpdir(), 'coverage-clear-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const codecov = join(root, 'Packages/MadoKit/.build/arm64-apple-macosx/debug/codecov');
  mkdirSync(codecov, { recursive: true });
  for (const name of ['default.profdata', 'Swift Testing.profraw', 'MadoKit.json']) writeFileSync(join(codecov, name), name);
  writeFileSync(join(root, 'Packages/MadoKit/.build/arm64-apple-macosx/debug/cache.bin'), 'cache');
  const cli = fileURLToPath(new URL('./package-coverage-clear.mjs', import.meta.url));
  for (let i = 0; i < 2; i++) {
    const run = spawnSync(process.execPath, [cli, '--root', root], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(existsSync(join(codecov, 'default.profdata')), false);
    assert.equal(existsSync(join(codecov, 'Swift Testing.profraw')), false);
    assert.equal(existsSync(join(codecov, 'MadoKit.json')), true);
    assert.equal(existsSync(join(root, 'Packages/MadoKit/.build/arm64-apple-macosx/debug/cache.bin')), true);
  }
});
