// Structural checks on .github/workflows/ci.yml that keep the required checks and the main-branch guarantees intact.
import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
  APP_JOB: 'success', UNSIGNED_BUILD: 'success', APP_TEST_STEP: 'success', APP_RETRIED: 'false', EVENT_NAME: 'push' };
const runVerdict = (t, env, { trustedScript = false } = {}) => {
  const directory = mkdtempSync(join(tmpdir(), 'mado-walking-skeleton-'));
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
  const pass = runVerdict(t, allSucceeded, { trustedScript: true });
  assert.equal(pass.status, 0, pass.stdout + pass.stderr);
  assert.match(pass.stdout, /walking-skeleton: PASS/);
  for (const key of ['APP_JOB', 'APP_TEST_STEP', 'UNSIGNED_BUILD']) {
    for (const value of ['failure', 'cancelled', 'skipped', '']) {
      const fail = runVerdict(t, { ...allSucceeded, [key]: value }, { trustedScript: true });
      assert.equal(fail.status, 1, `${key}=${value}`);
    }
  }
  const diagnostic = runVerdict(t, { ...allSucceeded, EVENT_NAME: 'workflow_dispatch', APP_TESTS: 'false', APP_TEST_STEP: 'skipped' }, { trustedScript: true });
  assert.equal(diagnostic.status, 0, diagnostic.stdout + diagnostic.stderr);
  assert.match(diagnostic.stdout, /tests not run/);
  assert.match(diagnostic.stdout, /formal App evidence: false/);
  const docs = runVerdict(t, { CHANGES: 'success', NATIVE: 'false', LEDGER: 'success', PACKAGE: 'skipped',
    MACUI: 'skipped', APP_JOB: 'skipped', UNSIGNED_BUILD: '', APP_TEST_STEP: '' }, { trustedScript: true });
  assert.equal(docs.status, 0, docs.stdout + docs.stderr);
});

test('a base without the script falls back to requiring every job and the build step to succeed, with no skip', t => {
  const pass = runVerdict(t, allSucceeded);
  assert.equal(pass.status, 0, pass.stdout + pass.stderr);
  assert.match(pass.stdout, /walking-skeleton: PASS \(strict fallback/);
  for (const key of ['CHANGES', 'LEDGER', 'PACKAGE', 'MACUI', 'APP_JOB', 'UNSIGNED_BUILD', 'APP_TEST_STEP']) {
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

test('the ledger and release checks run on macOS', () => {
  const ledger = jobBlock('ledger-check');
  assert.match(ledger, /^    runs-on: macos-26$/m);
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
  const swift = [...workflow.matchAll(/^ {10}swift test --package-path Packages\/MadoKit .*$/gm)].map(match => match[0]);
  assert.equal(swift.length, 2);
  for (const line of swift) assert.match(line, / -Xswiftc -enable-incremental-file-hashing$/);
  const xcode = [...workflow.matchAll(/(?:run: |^ {10})xcodebuild .*$/gm)].map(match => 'run: ' + match[0].trim().replace(/^run: /, ''));
  assert.deepEqual(xcode, [
    `run: ${BASELINE_BUILD} ${HASHING_SETTING}`,
    `run: ${BASELINE_BUILD.replace('xcodebuild build ', 'xcodebuild build-for-testing ')} ${HASHING_SETTING}`,
  ]);
});

test('the classification ledger and verdict jobs read the repo only and keep no token in their checkouts', () => {
  for (const id of ['changes', 'ledger-check', 'walking-skeleton']) {
    const job = jobBlock(id);
    assert.match(job, new RegExp(`^    runs-on: ${id === 'ledger-check' ? 'macos-26' : 'ubuntu-latest'}$`, 'm'), id);
    assert.match(job, /^    permissions:\n      contents: read\n/m, id);
    assert.doesNotMatch(job, /^      [a-z-]+: write$/m, id);
    const checkouts = job.split(/^      - name: /m).filter(step => step.includes('uses: actions/checkout@'));
    assert.ok(checkouts.length > 0, id);
    for (const step of checkouts) assert.match(step, /^          persist-credentials: false$/m, id);
  }
});

// #606: execute the actual routing shell with harmless node stand-ins.
test('dispatch repeat routing leaves push, PR, default dispatch and build-only behavior intact', t => {
  const app = jobBlock('app-tests');
  assert.match(workflow, /app_filter:\n(?:.*\n)*?        type: string\n/);
  assert.match(workflow, /app_repeat:\n(?:.*\n)*?        type: number\n        default: 1/);
  assert.match(app, /timeout-minutes: \$\{\{ github.event_name == 'workflow_dispatch' && inputs.app_repeat > 1 && 120 \|\| 45 \}\}/);
  const step = app.split(/^      - name: /m).find(s => s.startsWith('Run App tests\n'));
  assert.match(step, /REPEAT_ENABLED: \$\{\{ github.event_name == 'workflow_dispatch' && inputs.app_repeat > 1 \}\}/);
  assert.match(step, /APP_FILTER: \$\{\{ inputs.app_filter \}\}/);
  assert.match(step, /APP_REPEAT: \$\{\{ inputs.app_repeat \}\}/);
  const script = step.match(/^        run: \|\n((?:          .*\n)+)/m)?.[1].replace(/^ {10}/gm, '');
  assert.ok(script);
  const directory = mkdtempSync(join(tmpdir(), 'app-repeat-route-'));
  t.after(() => rmSync(directory, {recursive:true,force:true}));
  for (const [event, repeat, expected] of [['push',3,'scripts/tdd/app-lane.mjs'],['pull_request',3,'scripts/tdd/app-lane.mjs'],
    ['workflow_dispatch',1,'scripts/tdd/app-lane.mjs'],['workflow_dispatch',3,'scripts/ci/app-repeat.mjs']]) {
    const run = spawnSync('bash', ['-e', '-c', `node() { echo "$@"; };\n${script}`], {
      cwd: directory, env: {...process.env, REPEAT_ENABLED: String(event === 'workflow_dispatch' && repeat > 1), APP_JOB_STARTED_MS:'0'}, encoding:'utf8'});
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout.trim(), expected);
  }
  const upload = app.split(/^      - name: /m).find(s => s.startsWith('Upload App repeat logs\n'));
  assert.match(upload, /if: always\(\) && github.event_name == 'workflow_dispatch' && inputs.app_tests && inputs.app_repeat > 1/);
  assert.match(upload, /name: app-repeat\n/);
  assert.match(upload, /path: .build\/app-repeat/);
  const originalUpload = app.split(/^      - name: /m).find(s => s.startsWith('Upload first App attempt\n'));
  assert.match(originalUpload, /^        if: always\(\)$/m);
  assert.match(originalUpload, /name: app-lane-attempt1\n/);
});

test('dispatch validates all repeat inputs before building, and repeat upload is nonfatal', () => {
  const app = jobBlock('app-tests');
  const validate = app.split(/^      - name: /m).find(s => s.startsWith('Validate App repeat input\n'));
  assert.ok(validate);
  assert.match(validate, /^        if: github.event_name == 'workflow_dispatch'$/m);
  assert.match(validate, /APP_REPEAT: \$\{\{ inputs.app_repeat \}\}/);
  assert.match(validate, /run: node scripts\/ci\/app-repeat.mjs --validate/);
  assert.ok(app.indexOf('Validate App repeat input') < app.indexOf('Build unsigned app'));
  const upload = app.split(/^      - name: /m).find(s => s.startsWith('Upload App repeat logs\n'));
  assert.match(upload, /^        continue-on-error: true$/m);
});


const appStep = name => {
  const step = jobBlock('app-tests').split(/^      - name: /m).find(s => s.startsWith(`${name}\n`));
  assert.ok(step, `${name} step exists`);
  return step;
};
const shellBlock = step => {
  const script = step.match(/^        run: \|\n((?:          .*\n)+)/m)?.[1].replace(/^ {10}/gm, '');
  assert.ok(script, 'step has a shell run block');
  return script;
};

test('App evidence step outputs reach Walking skeleton and report runs on every outcome', () => {
  const app = jobBlock('app-tests');
  assert.match(appStep('Run App tests'), /^        id: app-run$/m);
  assert.match(app, /app_test_step: \$\{\{ steps\.app-run\.outcome \}\}/);
  assert.match(app, /app_retried: \$\{\{ steps\.app-report\.outputs\.retried \}\}/);
  const report = appStep('Report App test evidence');
  assert.match(report, /^        if: always\(\)$/m);
  assert.match(report, /^        id: app-report$/m);
  assert.match(report, /APP_TEST_STEP: \$\{\{ steps\.app-run\.outcome \}\}/);
  assert.match(report, /EVENT_NAME: \$\{\{ github\.event_name \}\}/);
  assert.match(report, /APP_TESTS: \$\{\{ inputs\.app_tests \}\}/);
  for (const [field, expression] of [
    ['APP_TEST_STEP', 'needs.app-tests.outputs.app_test_step'],
    ['APP_RETRIED', 'needs.app-tests.outputs.app_retried'],
    ['EVENT_NAME', 'github.event_name'], ['APP_TESTS', 'inputs.app_tests'],
  ]) assert.ok(jobBlock('walking-skeleton').includes(field + ': $' + '{{ ' + expression + ' }}'), field);
  const upload = appStep('Upload first App attempt');
  assert.match(upload, /^        if: always\(\)$/m);
  assert.match(upload, /^        continue-on-error: true$/m);
});

test('actual App run and report shells preserve exit status, logs, quarantine and retry evidence', t => {
  const runScript = shellBlock(appStep('Run App tests'));
  const reportScript = shellBlock(appStep('Report App test evidence'));
  const directory = mkdtempSync(join(tmpdir(), 'app-evidence-shell-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const quarantine = 'app-lane quarantine skip=MadoAppTests.fixture() issue=#597\napp-lane quarantine owner=fixture expires=2026-11-22 id=MadoAppTests.fixture()\n';
  const retry = 'app-lane: known flaky fixture (#425); retrying once\n';
  for (const [status, retried] of [[0, false], [0, true], [1, false], [70, false], [1, true]]) {
    const output = quarantine + (retried ? retry : '') + 'Tests run: 1, Failures: ' + (status ? '1' : '0') + ', Errors: 0, Skipped: 0\n';
    const env = { PATH: process.env.PATH, REPEAT_ENABLED: 'false', APP_JOB_STARTED_MS: '0',
      FIXTURE_OUTPUT: output, FIXTURE_STATUS: String(status),
      GITHUB_OUTPUT: join(directory, 'outputs'), GITHUB_STEP_SUMMARY: join(directory, 'summary'),
      EVENT_NAME: 'push', APP_TESTS: '', APP_TEST_STEP: status ? 'failure' : 'success' };
    writeFileSync(env.GITHUB_OUTPUT, ''); writeFileSync(env.GITHUB_STEP_SUMMARY, '');
    // A real Node process stands in for the native runner; all shell/filesystem transport is real.
    const standIn = `node() { command node -e 'process.stdout.write(process.env.FIXTURE_OUTPUT); process.exit(Number(process.env.FIXTURE_STATUS))'; };\n`;
    const run = spawnSync('bash', ['-e', '-c', standIn + runScript], { cwd: directory, env, encoding: 'utf8' });
    assert.equal(run.status, status, run.stdout + run.stderr);
    assert.equal(run.stdout, output);
    assert.equal(readFileSync(join(directory, '.build/app-tests.log'), 'utf8'), output);
    const report = spawnSync('bash', ['-e', '-c', reportScript], { cwd: directory, env, encoding: 'utf8' });
    assert.equal(report.status, 0, report.stdout + report.stderr);
    assert.match(readFileSync(env.GITHUB_OUTPUT, 'utf8'), new RegExp(`^retried=${retried}$`, 'm'));
    const summary = readFileSync(env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.match(summary, status ? /App tests: failed/ : retried ? /passed after the one automatic retry/ : /passed directly/);
    assert.match(summary, new RegExp(`formal App evidence: ${!status}`));
    assert.ok(summary.includes(quarantine.trim()), 'quarantine reports are retained');
    if (retried) assert.ok(summary.includes(retry.trim()), 'retry hit is retained even on failure');
  }
});

test('App report marks build-only dispatch and absent or cancelled test steps as no formal evidence', t => {
  const script = shellBlock(appStep('Report App test evidence'));
  const directory = mkdtempSync(join(tmpdir(), 'app-evidence-skipped-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  for (const step of ['skipped', 'cancelled', '', 'failure']) {
    const env = { PATH: process.env.PATH, EVENT_NAME: 'workflow_dispatch', APP_TESTS: 'false', APP_TEST_STEP: step,
      GITHUB_OUTPUT: join(directory, 'outputs'), GITHUB_STEP_SUMMARY: join(directory, 'summary') };
    writeFileSync(env.GITHUB_OUTPUT, ''); writeFileSync(env.GITHUB_STEP_SUMMARY, '');
    const report = spawnSync('bash', ['-e', '-c', script], { cwd: directory, env, encoding: 'utf8' });
    assert.equal(report.status, 0, report.stderr);
    const summary = readFileSync(env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.match(summary, /formal App evidence: false/);
    assert.doesNotMatch(summary, /passed directly|passed after/);
    if (step === 'skipped') assert.match(summary, /tests not run/);
  }
});
