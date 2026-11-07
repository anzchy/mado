// Structural checks on .github/workflows/ci.yml that keep the required checks and the main-branch guarantees intact.
import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const BASELINE_BUILD = "xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci";
const HASHING_SETTING = "'OTHER_SWIFT_FLAGS=$(inherited) -enable-incremental-file-hashing'";
const jobBlock = id => {
  const match = workflow.match(new RegExp(`^  ${id}:\\n([\\s\\S]*?)(?=^  [a-z][a-z0-9-]*:\\n|(?![\\s\\S]))`, 'm'));
  assert.ok(match, `job ${id} exists`);
  return match[1];
};

test('main pushes and dispatches never share a concurrency group; pull requests cancel older runs', () => {
  assert.match(workflow, /^  group: \$\{\{ github\.workflow \}\}-\$\{\{ github\.event_name == 'pull_request' && github\.ref \|\| github\.run_id \}\}$/m);
  assert.match(workflow, /^  cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}$/m);
});

test('App tests has a static readable job name even when the job is skipped', () => {
  const name = jobBlock('app-tests').match(/^    name: (.+)$/m)?.[1];
  assert.doesNotMatch(name ?? '', /\$\{\{|\}\}/, 'skipped jobs must not expose an unevaluated expression');
  assert.equal(name, 'App tests');
});

for (const name of ['Build App tests', 'Run App tests']) {
  test(`App-test step ${name} retains the dispatch input condition`, () => {
    const step = jobBlock('app-tests').split(/^      - name: /m)
      .find(block => block.startsWith(`${name}\n`));
    assert.ok(step, `${name} step exists`);
    assert.match(step, /^        if: github\.event_name != 'workflow_dispatch' \|\| inputs\.app_tests$/m,
      `${name} must respect dispatch app_tests=false`);
  });
}

test('required checks retain their public names', () => {
  assert.match(jobBlock('walking-skeleton'), /^    name: Walking skeleton$/m);
  const prBody = readFileSync(new URL('../../.github/workflows/pr-body.yml', import.meta.url), 'utf8');
  for (const name of ['Agent tooling', 'PR body Gates']) {
    assert.ok(prBody.split('\n').includes(`    name: ${name}`), name);
  }
});

test('the App tests job keeps the exact unsigned build as its own step, and Walking skeleton reads that step', () => {
  assert.doesNotMatch(workflow, /^  unsigned-build:$/m, 'no separate unsigned-build job');
  const app = jobBlock('app-tests');
  const steps = app.split(/^      - name: /m);
  const build = steps.find(step => step.startsWith('Build unsigned app\n'));
  assert.ok(build, 'Build unsigned app step exists');
  assert.match(build, /^        id: unsigned-build$/m);
  // The baseline command (`xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  // -derivedDataPath .build/dd-ci`) plus exactly one argument, the hashing flag (#479 acceptance criteria).
  const run = build.match(/^        run: \|\n((?:          .*\n)+)/m)?.[1].trimEnd().split('\n');
  assert.deepEqual(run, [
    `          ${BASELINE_BUILD} ${HASHING_SETTING}`,
    '          node scripts/name-checks/built-product.mjs .build/dd-ci/Build/Products/Debug/Mado.app --entitlements App/Resources/Mado.entitlements',
  ]);
  assert.doesNotMatch(build, /^        if:/m, 'the unsigned build runs on every event');
  assert.match(app, /^      unsigned_build: \$\{\{ steps\.unsigned-build\.outcome \}\}$/m);
  assert.ok(app.indexOf('Build unsigned app\n') < app.indexOf('Build App tests\n'), 'build runs before build-for-testing');
  const skeleton = jobBlock('walking-skeleton');
  assert.match(skeleton, /^    if: always\(\)$/m);
  for (const need of ['ledger-check', 'package-tests', 'package-macui-tests', 'app-tests']) {
    assert.match(skeleton, new RegExp(`^    needs: \\[.*\\b${need}\\b.*\\]$`, 'm'), need);
  }
  assert.match(skeleton, /^          UNSIGNED_BUILD: \$\{\{ needs\.app-tests\.outputs\.unsigned_build \}\}$/m);
});

// The verdict step's shell script, as GitHub runs it.
const verdictScript = () => {
  const skeleton = jobBlock('walking-skeleton');
  const match = skeleton.match(/^        run: \|\n((?:^          .*\n|^\n)+)/m);
  assert.ok(match, 'the verdict step has a run block');
  return match[1].replace(/^ {10}/gm, '');
};
const allSucceeded = { CHANGES: 'success', NATIVE: 'true', LEDGER: 'success', PACKAGE: 'success', MACUI: 'success',
  APP_JOB: 'success', UNSIGNED_BUILD: 'success' };
const runVerdict = (t, env, { trustedScript = false } = {}) => {
  const directory = mkdtempSync(join(tmpdir(), 'picsee-walking-skeleton-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  if (trustedScript) {
    mkdirSync(join(directory, 'trusted/scripts/ci'), { recursive: true });
    copyFileSync(fileURLToPath(new URL('./walking-skeleton.mjs', import.meta.url)),
      join(directory, 'trusted/scripts/ci/walking-skeleton.mjs'));
  }
  return spawnSync('bash', ['-e', '-c', verdictScript()],
    { cwd: directory, env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });
};

test('Walking skeleton runs the verdict from a checkout of the trusted base, never from the pull request head', () => {
  const skeleton = jobBlock('walking-skeleton');
  assert.match(skeleton, /ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.sha \}\}\n(?:          .*\n)*?          path: trusted\n/);
  const script = verdictScript();
  assert.match(script, /^if \[ -f trusted\/scripts\/ci\/walking-skeleton\.mjs \]; then\n  node trusted\/scripts\/ci\/walking-skeleton\.mjs\n/);
  assert.doesNotMatch(script, /(^|[^/])scripts\/ci\/walking-skeleton\.mjs/m, 'no path outside trusted/');
});

test('with the trusted script, the step follows its verdict', t => {
  const pass = runVerdict(t, { ...allSucceeded, APP_JOB: 'failure' }, { trustedScript: true });
  assert.equal(pass.status, 0, pass.stdout + pass.stderr);
  assert.match(pass.stdout, /walking-skeleton: PASS/);
  const fail = runVerdict(t, { ...allSucceeded, APP_JOB: 'cancelled' }, { trustedScript: true });
  assert.equal(fail.status, 1);
});

test('a base without the script falls back to requiring every job and the build step to succeed, with no skip', t => {
  const pass = runVerdict(t, allSucceeded);
  assert.equal(pass.status, 0, pass.stdout + pass.stderr);
  assert.match(pass.stdout, /walking-skeleton: PASS \(strict fallback/);
  for (const key of ['CHANGES', 'LEDGER', 'PACKAGE', 'MACUI', 'APP_JOB', 'UNSIGNED_BUILD']) {
    for (const value of ['failure', 'cancelled', 'skipped', '']) {
      const result = runVerdict(t, { ...allSucceeded, [key]: value });
      assert.equal(result.status, 1, `${key}=${value}`);
      assert.match(result.stdout, /walking-skeleton: FAIL \(strict fallback/, `${key}=${value}`);
    }
  }
  for (const native of ['false', '', 'TRUE']) {
    const result = runVerdict(t, { ...allSucceeded, NATIVE: native });
    assert.equal(result.status, 1, `NATIVE=${native}`);
  }
  const docsOnly = runVerdict(t, { CHANGES: 'success', NATIVE: 'false', LEDGER: 'success', PACKAGE: 'skipped',
    MACUI: 'skipped', APP_JOB: 'skipped', UNSIGNED_BUILD: '' });
  assert.equal(docsOnly.status, 1, 'the fallback never accepts a docs-only skip');
});

test('the ledger check runs on Ubuntu', () => {
  const ledger = jobBlock('ledger-check');
  assert.match(ledger, /^    runs-on: ubuntu-latest$/m);
  assert.match(ledger, /^        run: node scripts\/ledger\/build\.mjs --check$/m);
  assert.doesNotMatch(ledger, /^    if:/m);
});

test('native jobs run only on the classifier saying so; Walking skeleton always reports and reads the classifier', () => {
  const changes = jobBlock('changes');
  assert.match(changes, /^    runs-on: ubuntu-latest$/m);
  assert.doesNotMatch(changes, /^    if:/m, 'the classifier runs on every event');
  assert.match(changes, /^      native: \$\{\{ steps\.classify\.outputs\.native \}\}$/m);
  assert.match(changes, /ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.sha \}\}\n          path: trusted/);
  assert.match(changes, /^            node trusted\/scripts\/ci\/native-inputs\.mjs$/m);
  assert.match(changes, /^            echo 'native=true' >> "\$GITHUB_OUTPUT"$/m, 'a base without the classifier runs native jobs');
  assert.match(changes, /^      pull-requests: read$/m);
  for (const id of ['package-tests', 'package-macui-tests', 'app-tests']) {
    const job = jobBlock(id);
    assert.match(job, /^    needs: changes$/m, id);
    assert.match(job, /^    if: needs\.changes\.outputs\.native == 'true'$/m, id);
  }
  const skeleton = jobBlock('walking-skeleton');
  assert.match(skeleton, /^    needs: \[changes, /m);
  assert.match(skeleton, /^          CHANGES: \$\{\{ needs\.changes\.result \}\}$/m);
  assert.match(skeleton, /^          NATIVE: \$\{\{ needs\.changes\.outputs\.native \}\}$/m);
  assert.doesNotMatch(workflow, /paths-ignore:|^\s+paths:/m, 'no workflow-level path filters: required checks must report');
});

test('build caches: restored on pull requests and dispatches (unless cold), saved only by a passing main push', () => {
  const restores = [...workflow.matchAll(/^      - name: (Restore [^\n]+)\n([\s\S]*?)(?=^      - name: |^  [a-z]|(?![\s\S]))/gm)];
  const saves = [...workflow.matchAll(/^      - name: (Save [^\n]+)\n([\s\S]*?)(?=^      - name: |^  [a-z]|(?![\s\S]))/gm)];
  assert.deepEqual(restores.map(match => match[1]),
    ['Restore SwiftPM build', 'Restore SwiftPM build', 'Restore DerivedData', 'Restore Playwright browsers']);
  assert.deepEqual(saves.map(match => match[1]), ['Save SwiftPM build', 'Save DerivedData', 'Save Playwright browsers']);
  for (const [, name, body] of restores) {
    const condition = name === 'Restore Playwright browsers' ? "github.event_name != 'push'" : "github.event_name != 'push' && !inputs.cold";
    assert.ok(body.includes(`\n        if: ${condition}\n`) || body.startsWith(`        if: ${condition}\n`), name);
    assert.match(body, /uses: actions\/cache\/restore@[0-9a-f]{40} # v/);
    if (name === 'Restore Playwright browsers') {
      assert.match(body, /^          key: playwright-v1-\$\{\{ runner\.os \}\}-\$\{\{ runner\.arch \}\}-\$\{\{ steps\.playwright\.outputs\.version \}\}$/m);
      assert.doesNotMatch(body, /restore-keys:/, 'browsers restore only for the exact Playwright version');
      continue;
    }
    assert.match(body, /^          key: \$\{\{ steps\.(spm|dd)-key\.outputs\.key \}\}$/m);
    assert.match(body, /^          restore-keys: \$\{\{ steps\.(spm|dd)-key\.outputs\.prefix \}\}$/m);
  }
  for (const [, , body] of saves) {
    assert.match(body, /^        if: success\(\) && github\.event_name == 'push' && github\.ref == 'refs\/heads\/main'$/m);
    assert.match(body, /uses: actions\/cache\/save@[0-9a-f]{40} # v/);
  }
  assert.ok(jobBlock('package-tests').includes('Save SwiftPM build'), 'only the non-UI job saves the shared .build');
  assert.ok(!jobBlock('package-macui-tests').includes('Save SwiftPM build'));
  assert.equal([...workflow.matchAll(/run: node scripts\/ci\/cache-key\.mjs (spm|dd) "\$MANIFEST" "\$INPUTS"$/gm)].length, 3);
  assert.doesNotMatch(workflow, /actions\/cache@/, 'no combined restore-and-save cache action in ci.yml');
});

test('every cached build uses incremental file hashing, with identical flags in both package jobs', () => {
  const swift = [...workflow.matchAll(/^ {10}swift test --package-path Packages\/PicseeKit .*$/gm)].map(match => match[0]);
  assert.equal(swift.length, 2);
  for (const line of swift) assert.match(line, / -Xswiftc -enable-incremental-file-hashing$/);
  const xcode = [...workflow.matchAll(/(?:run: |^ {10})xcodebuild .*$/gm)].map(match => 'run: ' + match[0].trim().replace(/^run: /, ''));
  assert.deepEqual(xcode, [
    `run: ${BASELINE_BUILD} ${HASHING_SETTING}`,
    `run: ${BASELINE_BUILD.replace('xcodebuild build ', 'xcodebuild build-for-testing ')} ${HASHING_SETTING}`,
  ]);
});

test('the Ubuntu jobs added for the speed-up read the repo only and keep no token in their checkouts', () => {
  for (const id of ['changes', 'ledger-check', 'walking-skeleton']) {
    const job = jobBlock(id);
    assert.match(job, /^    permissions:\n      contents: read\n/m, id);
    assert.doesNotMatch(job, /^      [a-z-]+: write$/m, id);
    const checkouts = job.split(/^      - name: /m).filter(step => step.includes('uses: actions/checkout@'));
    assert.ok(checkouts.length > 0, id);
    for (const step of checkouts) assert.match(step, /^          persist-credentials: false$/m, id);
  }
});
