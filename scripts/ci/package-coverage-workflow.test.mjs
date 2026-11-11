import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const job = id => workflow.match(new RegExp(String.raw`^  ${id}:\n([\s\S]*?)(?=^  [a-z][a-z0-9-]*:\n|$(?![\s\S]))`, 'm'))?.[1] ?? '';
const step = (body, name) => body.split(/^      - name: /m).find(part => part.startsWith(`${name}\n`)) ?? '';
const script = body => body.match(/^        run: \|\n((?:^          .*\n|^\n)+)/m)?.[1]?.replace(/^ {10}/gm, '') ?? '';

test('both existing Package shards produce fresh instrumented evidence with their original test selection', () => {
  for (const [id, shard, log] of [['package-tests', 'non-ui', 'package-tests'], ['package-macui-tests', 'macui', 'package-macui-tests']]) {
    const body = job(id);
    assert.ok(body, id);
    assert.match(body, /--enable-code-coverage/);
    assert.match(body, /--timeout-seconds 1500/);
    assert.match(body, new RegExp(`--out ci-logs/${log}`));
    assert.match(body, /cache-key\.mjs spm-coverage/);
    const restore = body.indexOf('Restore SwiftPM build');
    const clear = body.indexOf('Clear stale coverage profile');
    const run = body.indexOf('Swift Testing (');
    const exportAt = body.indexOf('Export Package coverage');
    const upload = body.indexOf('Upload Package coverage');
    assert.ok(restore < clear && clear < run && run < exportAt && exportAt < upload, `${id} order`);
    assert.match(step(body, 'Clear stale coverage profile'), /node scripts\/ci\/package-coverage-clear\.mjs/);
    const exporter = step(body, 'Export Package coverage');
    assert.match(exporter, new RegExp(`--shard ${shard}`));
    assert.match(exporter, /--not-before/);
    assert.match(step(body, 'Upload Package coverage'), /if-no-files-found: error/);
    assert.match(step(body, 'Upload Package coverage'), /coverage\.lcov/);
    assert.match(step(body, 'Upload Package coverage'), /metadata\.json/);
  }
  assert.match(job('package-tests'), /--skip 'MadoMacUITests\\\.'/);
  assert.match(job('package-macui-tests'), /--no-parallel/);
  assert.match(job('package-macui-tests'), /--skip '\(MadoCoreTests\|MadoApplicationTests\|MadoInfrastructureTests\)\\\.'/);
});

test('Linux aggregation downloads both shards and reports their exact gate', () => {
  const body = job('package-coverage');
  assert.match(body, /runs-on: ubuntu-latest/);
  assert.match(body, /needs: \[changes, package-tests, package-macui-tests\]/);
  assert.match(body, /if: needs\.changes\.outputs\.native == 'true'/);
  assert.match(body, /actions\/download-artifact@/);
  assert.match(body, /name: package-coverage-non-ui/);
  assert.match(body, /name: package-coverage-macui/);
  assert.match(body, /node scripts\/ci\/package-coverage\.mjs/);
  assert.match(body, /Upload Package coverage report[\s\S]*if: always\(\)/);
  assert.match(body, /--formal/);
});

test('Walking skeleton has one disabled rollout switch and enforces coverage before an old trusted verdict when enabled', t => {
  const body = job('walking-skeleton');
  assert.match(body, /needs: \[changes, ledger-check, package-tests, package-macui-tests, package-coverage, app-tests\]/);
  assert.match(body, /^          COVERAGE: \$\{\{ needs\.package-coverage\.result \}\}$/m);
  assert.match(body, /^          COVERAGE_ENFORCE: 'false' # #631: switch to true only after ten accepted cold runs$/m);
  const verdict = script(step(body, 'Require the ledger check, package tests and App tests'));
  assert.match(verdict, /COVERAGE_ENFORCE/);
  const dir = mkdtempSync(join(tmpdir(), 'coverage-rollout-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'trusted/scripts/ci'), { recursive: true });
  copyFileSync(fileURLToPath(new URL('./fixtures/walking-skeleton-b213bb18.mjs', import.meta.url)), join(dir, 'trusted/scripts/ci/walking-skeleton.mjs'));
  const base = { PATH: process.env.PATH, CHANGES: 'success', NATIVE: 'true', LEDGER: 'success', PACKAGE: 'success', MACUI: 'success', APP_JOB: 'success', UNSIGNED_BUILD: 'success', APP_TEST_STEP: 'success', APP_RETRIED: 'false', APP_FORMAL: 'true', APP_DIAGNOSTIC: 'false', EVENT_NAME: 'pull_request' };
  const invoke = (coverage, enforce, native = 'true') => spawnSync('bash', ['-e', '-c', verdict], { cwd: dir, env: { ...base, NATIVE: native, COVERAGE: coverage, COVERAGE_ENFORCE: enforce }, encoding: 'utf8' });
  assert.equal(invoke('success', 'true').status, 0);
  for (const state of ['failure', 'cancelled', 'skipped', '']) {
    const blocked = invoke(state, 'true');
    assert.equal(blocked.status, 1, `${state}: ${blocked.stdout}${blocked.stderr}`);
    assert.match(blocked.stdout, /Package coverage minimum/);
    const pending = invoke(state, 'false');
    assert.equal(pending.status, 0, `${state}: ${pending.stdout}${pending.stderr}`);
    assert.match(pending.stdout, /Package coverage pending/);
  }
  const docs = invoke('skipped', 'true', 'false');
  assert.equal(docs.status, 1, 'native jobs in this fixture did not skip');
});

test('a predeclared cold dispatch can seed a same-branch coverage cache for one restored validation run', () => {
  assert.match(workflow, /^      coverage_cache_seed:\n/m);
  assert.match(workflow, /description: Seed the coverage build cache from one cold full-package dispatch/);
  const nonUI = job('package-tests');
  const save = step(nonUI, 'Save SwiftPM build');
  assert.match(save, /github\.event_name == 'workflow_dispatch' && inputs\.cold && inputs\.coverage_cache_seed && inputs\.swift_filter == ''/);
  assert.match(step(nonUI, 'Restore SwiftPM build'), /!inputs\.cold/);
  assert.match(step(job('package-macui-tests'), 'Restore SwiftPM build'), /!inputs\.cold/);
});

test('each shard records whether the restored validation actually hit a cache', () => {
  for (const id of ['package-tests', 'package-macui-tests']) {
    const body = job(id);
    assert.match(step(body, 'Restore SwiftPM build'), /id: spm-restore/);
    assert.match(step(body, 'Report SwiftPM cache restore'), /steps\.spm-restore\.outputs\.cache-hit/);
    assert.ok(body.indexOf('Restore SwiftPM build') < body.indexOf('Report SwiftPM cache restore'));
    assert.ok(body.indexOf('Report SwiftPM cache restore') < body.indexOf('Clear stale coverage profile'));
  }
});
