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
  APP_JOB: 'success', UNSIGNED_BUILD: 'success', APP_TEST_STEP: 'success', APP_RETRIED: 'false' };

test('Node name suites and code scan run in the existing required macOS ledger job', () => {
  const ledger = job('ledger-check');
  assert.match(ledger, /runs-on: macos-26/);
  assert.match(ledger, /run: node --test scripts\/name-checks\/\*\.test\.mjs scripts\/ci\/name-checks-ci\.test\.mjs/);
  assert.match(ledger, /run: node scripts\/name-checks\/code-name\.mjs/);
  assert.equal(verdict({ ...success, LEDGER: 'failure' }).ok, false);
  // #587 step 2 requires App assertion failures to fail the required check.
  assert.equal(verdict({ ...success, APP_JOB: 'failure' }).ok, false);
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


test('release regressions run unconditionally in the required ledger job with a shallow safe checkout', () => {
  const ledger = job('ledger-check');
  assert.doesNotMatch(ledger, /^    (?:if|continue-on-error):/m);
  assert.match(ledger, /^    permissions:\n      contents: read\n/m);
  const steps = ledger.split(/^      - name: /m);
  const checkout = steps.find(step => step.startsWith('Checkout\n'));
  assert.ok(checkout);
  assert.match(checkout, /^          fetch-depth: 1$/m);
  assert.match(checkout, /^          persist-credentials: false$/m);
  const release = steps.find(step => step.startsWith('Test release regressions\n'));
  assert.ok(release, 'the full release suite is required even for documentation-only changes');
  assert.match(release, /^        run: node --test scripts\/release\/\*\.test\.mjs$/m);
  assert.doesNotMatch(release, /^        (?:if|continue-on-error):/m);
  assert.doesNotMatch(release, /\|\||continue-on-error|set \+e|--test-name-pattern/);
  assert.match(ledger, /^        run: node scripts\/ledger\/build\.mjs --check$/m);
  const skeleton = job('walking-skeleton');
  assert.match(skeleton, /^    if: always\(\)$/m);
  assert.match(skeleton, /^    needs: \[.*\bledger-check\b.*\]$/m);
  assert.match(skeleton, /^          LEDGER: \$\{\{ needs\.ledger-check\.result \}\}$/m);
});

test('required ledger failures reject both native and documentation-only verdicts', () => {
  const docsOnly = { ...success, NATIVE: 'false', PACKAGE: 'skipped', MACUI: 'skipped', APP_JOB: 'skipped', UNSIGNED_BUILD: '', APP_TEST_STEP: '' };
  for (const baseline of [success, docsOnly]) {
    assert.equal(verdict(baseline).ok, true);
    for (const LEDGER of ['failure', 'cancelled', 'skipped']) {
      assert.equal(verdict({ ...baseline, LEDGER }).ok, false, `native=${baseline.NATIVE} ledger=${LEDGER}`);
    }
  }
});
