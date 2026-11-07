import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { verdict } from './walking-skeleton.mjs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const job = id => workflow.match(new RegExp(`^  ${id}:\\n([\\s\\S]*?)(?=^  [a-z][a-z0-9-]*:|$$(?![\\s\\S]))`, 'm'))?.[1] ?? '';
const success = { CHANGES: 'success', NATIVE: 'true', LEDGER: 'success', PACKAGE: 'success', MACUI: 'success',
  APP_JOB: 'success', UNSIGNED_BUILD: 'success' };

test('Node name suites and code scan run in the existing required Ubuntu ledger job', () => {
  const ledger = job('ledger-check');
  assert.match(ledger, /runs-on: ubuntu-latest/);
  assert.match(ledger, /run: node --test scripts\/name-checks\/\*\.test\.mjs scripts\/ci\/name-checks-ci\.test\.mjs/);
  assert.match(ledger, /run: node scripts\/name-checks\/code-name\.mjs/);
  assert.equal(verdict({ ...success, LEDGER: 'failure' }).ok, false);
  assert.equal(verdict({ ...success, APP_JOB: 'failure' }).ok, true);
});

test('executing the real unsigned-build shell block gates on build AND product checker outcomes', () => {
  const app = job('app-tests');
  const step = app.split(/^      - name: /m).find(block => block.startsWith('Build unsigned app\n'));
  const body = step?.match(/^        run: \|\n((?:          .*\n)+)/m)?.[1];
  assert.ok(body, 'build and checker share the required unsigned-build outcome');
  const script = body.replace(/^ {10}/gm, '');
  assert.ok(script.indexOf('xcodebuild build') < script.indexOf('node scripts/name-checks/built-product.mjs'));
  const bin = mkdtempSync(join(tmpdir(), 'identity-ci-'));
  // Only external executable outcomes are controlled. The real product CLI is covered separately on fixtures and a fresh app.
  writeFileSync(join(bin, 'xcodebuild'), '#!/bin/sh\nexit "$BUILD_STATUS"\n', { mode: 0o755 });
  writeFileSync(join(bin, 'node'), '#!/bin/sh\nexit "$NAME_STATUS"\n', { mode: 0o755 });
  for (const [build, checker, ok] of [[0, 0, true], [1, 0, false], [0, 1, false], [1, 1, false]]) {
    const run = spawnSync('/bin/bash', ['-e', '-c', script], { encoding: 'utf8',
      env: { PATH: bin, BUILD_STATUS: String(build), NAME_STATUS: String(checker) } });
    assert.equal(run.status === 0, ok, `build=${build} checker=${checker}: ${run.stderr}`);
    assert.equal(verdict({ ...success, UNSIGNED_BUILD: run.status === 0 ? 'success' : 'failure' }).ok, ok);
  }
});
