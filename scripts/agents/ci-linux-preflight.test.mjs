import test, { describe } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync, readdirSync, readlinkSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { checkGates } from './ui-parity-pr-body-lint.mjs';
import { parseWorkflow, workflowAt } from '../../.agents/skills/ci-linux-preflight/scripts/workflow.mjs';
import { checkSummary } from '../../.agents/skills/ci-linux-preflight/scripts/summary.mjs';

const root = resolve(import.meta.dirname, '../..');
const tool = join(root, '.agents/skills/ci-linux-preflight/scripts/preflight.mjs');
const realGit = spawnSync('/usr/bin/which', ['git'], { encoding: 'utf8' }).stdout.trim();
const realPython = spawnSync('/usr/bin/which', ['python3'], { encoding: 'utf8' }).stdout.trim();
const exec = (cmd, args, options = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...options });
const run = (args, options = {}) => exec(process.execPath, [tool, ...args], options);
const runAsync = (args, options = {}) => new Promise(resolve => {
  const child = spawn(process.execPath, [tool, ...args], options);
  let stdout = ''; let stderr = '';
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  child.on('close', status => resolve({ status, stdout, stderr }));
});
const footer = (tests, pass, fail = 0, skipped = 0, todo = 0, cancelled = 0) =>
  [`# tests ${tests}`, `# pass ${pass}`, `# fail ${fail}`, `# cancelled ${cancelled}`, `# skipped ${skipped}`, `# todo ${todo}`];
const tapStep = lines => `printf '%s\\n' ${lines.map(line => `'${line}'`).join(' ')} && : 'node --test'`;
const tap = `test "$CI" = true && test "$GITHUB_ACTIONS" = true && test "$LANG" = C.UTF-8 && test "$PATH" = /opt/node/bin:/usr/local/bin:/usr/bin:/bin && test -z "\${FAKE_SECRET:-}" && ${tapStep(footer(1, 1))}`;

function fixture(first = `python3 -m unittest sample_test.py && ${tapStep(footer(1, 1))}`, second = tap, failingPython = false) {
  const base = mkdtempSync(join(tmpdir(), 'ci-preflight-'));
  const repo = join(base, 'repo');
  const hostHome = join(base, 'host');
  const bin = join(base, 'bin');
  mkdirSync(join(repo, '.github/workflows'), { recursive: true });
  mkdirSync(join(repo, '.agents/skills/ci-linux-preflight'), { recursive: true });
  mkdirSync(hostHome);
  mkdirSync(bin);
  cpSync(join(root, '.agents/skills/ci-linux-preflight/scripts'), join(repo, '.agents/skills/ci-linux-preflight/scripts'), { recursive: true });
  // The integration fixture controls the preflight result; env-check itself is tested below.
  writeFileSync(join(repo, '.agents/skills/ci-linux-preflight/scripts/env-check.sh'),
    '#!/bin/bash\nif [ "${FAKE_ENV_CHECK_FAIL:-}" = 1 ]; then echo "fixture environment mismatch" >&2; exit 1; fi\nexit 0\n');
  const workflow = `jobs:\n  agent-tests:\n    name: Agent tooling\n    steps:\n      - name: Checkout PR head\n        uses: actions/checkout@abc\n        with:\n          ref: \${{ github.event.pull_request.head.sha }}\n      - name: Set up Node\n        uses: actions/setup-node@abc\n        with:\n          node-version: 22\n      - name: Install portable device test tools\n        run: |\n          sudo apt-get update\n      - name: Python tests\n        working-directory: pr-head\n        run: ${first}\n      - name: Node totals\n        working-directory: pr-head\n        run: ${second}\n`;
  writeFileSync(join(repo, '.github/workflows/pr-body.yml'), workflow
    .replace('      - name: Set up Node', '          path: pr-head\n          fetch-depth: 0\n      - name: Set up Node')
    .replace('sudo apt-get update', 'sudo apt-get update\n          sudo apt-get install --no-install-recommends -y python3 git zsh'));
  writeFileSync(join(repo, 'sample_test.py'), `import unittest\nclass Sample(unittest.TestCase):\n def test_case(self):\n  ${failingPython ? "self.fail('broken')" : 'self.assertTrue(True)'}\n`);
  for (const [name, body] of Object.entries({
    node: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo v22.23.5; else exec "${process.execPath}" "$@"; fi\n`,
    git: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo "git version \${FAKE_GIT_VERSION:-2.56.1}"; exit; fi\nif [ "$FAKE_REMOTE_WRONG_HEAD" = 1 ]; then case "$*" in *'rev-parse HEAD'*) printf '%040d\\n' 0; exit;; esac; fi\nexec "$REAL_GIT" "$@"\n`,
    python3: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'Python 3.11.0'; else exec "$REAL_PYTHON" "$@"; fi\n`,
    zsh: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'zsh 5.8'; else exec /bin/zsh "$@"; fi\n`,
    ps: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'ps from procps-ng 3.3.17'; else exec /bin/ps "$@"; fi\n`,
    sudo: `#!/bin/sh\nexit 1\n`,
    flock: `#!/bin/sh\nif [ "${'$'}FAKE_BUSY" = 1 ]; then exit 1; fi\nexit 0\n`,
    timeout: `#!/usr/bin/env node\nconst {spawnSync}=require('node:child_process');const a=process.argv.slice(2);a.shift();const seconds=Number(a.shift());const cmd=a.shift();const r=spawnSync(cmd,a,{stdio:'inherit',timeout:seconds*1000});process.exit(r.error?.code==='ETIMEDOUT'?124:r.status??75);\n`,
    rsync: `#!/bin/sh\nif [ "$FAKE_RSYNC_FAIL" = 1 ]; then echo 'transfer failed' >&2; exit 1; fi\ncp "$3" "\${4#*:}"\n`,
    ssh: `#!/bin/bash\nset -o pipefail\nprintf '%s\\n' "$*" >> "$FAKE_CALLS"\ntmp=$(mktemp)\ncat > "$tmp"\ncat "$tmp" >> "$FAKE_INPUTS"\nif [ "$FAKE_SSH_FAIL" = 1 ]; then echo unreachable >&2; exit 1; fi\nif [ "$FAKE_NO_BIN_ZSH" = 1 ]; then sed 's#/bin/zsh#/missing-zsh#g' "$tmp" > "$tmp.nozsh"; mv "$tmp.nozsh" "$tmp"; fi\nfor item in "$@"; do last=$item; done\nsed "s#export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin#export PATH=$FAKE_BIN:/usr/local/bin:/usr/bin:/bin#g" "$tmp" | HOME="$FAKE_HOST_HOME" PATH="$FAKE_BIN:$PATH" /bin/bash -c "$last"\nstatus=$?\nrm -f "$tmp"\nexit $status\n`,
  })) writeFileSync(join(bin, name), body, { mode: 0o755 });
  for (const args of [['init', '-q'], ['config', 'user.name', 'Fixture'], ['config', 'user.email', 'fixture@example.test'], ['add', '.github/workflows/pr-body.yml', '.agents/skills/ci-linux-preflight/scripts', 'sample_test.py'], ['commit', '-qm', 'fixture']]) {
    const result = exec(realGit, args, { cwd: repo });
    assert.equal(result.status, 0, result.stderr);
  }
  const sha = exec(realGit, ['rev-parse', 'HEAD'], { cwd: repo }).stdout.trim();
  const calls = join(base, 'calls.jsonl');
  const inputs = join(base, 'inputs.txt');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, HOME: base, REAL_NODE: process.execPath, REAL_GIT: realGit, REAL_PYTHON: realPython, FAKE_HOST_HOME: hostHome, FAKE_BIN: bin, FAKE_CALLS: calls, FAKE_INPUTS: inputs, MADO_LINUX_HOST: '' };
  return { base, repo, hostHome, bin, calls, inputs, sha, env };
}
function summaryPath(result) { return result.stdout.match(/^Summary: (.+)$/m)?.[1]; }
function runFixture(f, args = [], env = {}) { return run(['run', f.sha, '--repo', f.repo, ...args], { env: { ...f.env, ...env } }); }
function runFixtureAsync(f, args = [], env = {}) { return runAsync(['run', f.sha, '--repo', f.repo, ...args], { env: { ...f.env, ...env } }); }

test('repro rejects unsafe commands before SSH and captures each commit outcome', async () => {
  const f = fixture();
  writeFileSync(join(f.repo, 'check.mjs'), "console.log('not ok 1 - deliberate failure'); process.exit(1)\n");
  exec(realGit, ['add', 'check.mjs'], { cwd: f.repo });
  exec(realGit, ['commit', '-qm', 'failing check'], { cwd: f.repo });
  const bad = exec(realGit, ['rev-parse', 'HEAD'], { cwd: f.repo }).stdout.trim();
  writeFileSync(join(f.repo, 'check.mjs'), 'process.exit(0)\n');
  exec(realGit, ['commit', '-qam', 'fixed check'], { cwd: f.repo });
  const good = exec(realGit, ['rev-parse', 'HEAD'], { cwd: f.repo }).stdout.trim();
  for (const cmd of ['curl example.com', 'node check.mjs; id', 'node --test ../check.mjs', 'node --test missing.mjs', 'node -e process.exit(0)']) {
    const rejected = run(['repro', bad, '--cmd', cmd, '--repo', f.repo], { env: f.env });
    assert.equal(rejected.status, 2, `${cmd}: ${rejected.stderr}`);
  }
  const matched = await runAsync(['repro', bad, good, '--cmd', 'node check.mjs', '--expect', 'fail,pass', '--repo', f.repo], { env: f.env });
  assert.equal(matched.status, 0, matched.stderr + matched.stdout);
  const path = summaryPath(matched);
  const body = readFileSync(path, 'utf8');
  assert.match(body, new RegExp(`result:${bad}:exit=1`));
  assert.match(body, new RegExp(`result:${good}:exit=0`));
  assert.match(body, new RegExp(`result:${bad}:failed=not ok 1 - deliberate failure`));
  assert.match(body, /outcome=MATCH/);
  assert.equal(run(['summary-check', path, '--expect-head', bad, '--repo', f.repo]).status, 0);
  writeFileSync(join(f.base, 'bad-summary'), body.replace('DONE\n', ''));
  assert.equal(run(['summary-check', join(f.base, 'bad-summary'), '--expect-head', bad, '--repo', f.repo]).status, 75);
  writeFileSync(join(f.base, 'bad-summary'), body.replace(`result:${bad}:exit=1`, `result:${bad}:exit=0`));
  assert.equal(run(['summary-check', join(f.base, 'bad-summary'), '--expect-head', bad, '--repo', f.repo]).status, 75);
  const mismatch = await runAsync(['repro', bad, good, '--cmd', 'node check.mjs', '--expect', 'pass,fail', '--repo', f.repo], { env: f.env });
  assert.equal(mismatch.status, 1, mismatch.stderr + mismatch.stdout);
  assert.match(readFileSync(summaryPath(mismatch), 'utf8'), /outcome=MISMATCH/);
  assert.deepEqual(readdirSync(join(f.hostHome, 'ci')).filter(name => name.startsWith('run.')), []);
});

test('repro busy lock and unreachable host are NOT VERIFIED', async () => {
  const f = fixture();
  const args = ['repro', f.sha, '--cmd', 'python3 -m unittest sample_test.py', '--repo', f.repo];
  for (const env of [{ FAKE_BUSY: '1' }, { FAKE_SSH_FAIL: '1' }]) {
    const result = await runAsync(args, { env: { ...f.env, ...env } });
    assert.equal(result.status, 75, result.stderr + result.stdout);
    assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=NOT VERIFIED/);
  }
});

describe('ci-linux-preflight', { concurrency: true }, () => {
test('real Agent tooling workflow has two runnable steps and rejects unsupported YAML', () => {
  const head = exec(realGit, ['rev-parse', 'HEAD'], { cwd: root }).stdout.trim();
  const real = workflowAt(root, head);
  assert.equal(real.steps.length, 5);
  assert.equal(real.steps.filter(step => step.kind === 'run').length, 2);
  assert.equal(real.steps.find(step => step.name === 'Install portable device test tools').kind, 'provision');
  for (const fragment of ['env:', 'shell: bash', 'run: >', 'if: true', 'continue-on-error: true', 'timeout-minutes: 1']) {
    const source = `jobs:\n  agent-tests:\n    steps:\n      - name: Test\n        working-directory: pr-head\n        ${fragment}\n        run: echo ok\n`;
    assert.throws(() => parseWorkflow(source), /unsupported|folded|duplicate/i, fragment);
  }
  assert.throws(() => parseWorkflow(`jobs:\n  agent-tests:\n    steps:\n      - name: Test\n        working-directory: pr-head\n        run: echo \${{ secrets.X }}\n`), /expression/);
});

test('fake SSH executes remote script, copies bundle, records isolated step summary and cleans run dir', async () => {
  const f = fixture();
  const result = await runFixtureAsync(f, [], { FAKE_SECRET: 'must-not-reach-step' });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const body = readFileSync(summaryPath(result), 'utf8');
  assert.match(body, new RegExp(`head=${f.sha}`));
  assert.match(body, /steps_total=5\nsteps_run=2\noutcome=PASS/);
  assert.match(body, /step:Install portable device test tools=provision-checked/);
  assert.match(body, /step:Node totals:tests=1/);
  assert.match(body, /step:Python tests:python_tests=1/);
  assert.match(body, /step:Node totals:peak_rss_kb=(?:unknown|\d+)/);
  assert.match(body, /node=v22\.23\.5/);
  assert.match(body, /git=git version 2\.56\.1/);
  assert.match(body, /procps=ps from procps-ng 3\.3\.17/);
  const missingTap = body.replace('step:Node totals:tests=1', 'step:Node totals:tests=0').replace('step:Node totals:pass=1', 'step:Node totals:pass=0');
  assert.throws(() => checkSummary(missingTap, f.sha, workflowAt(f.repo, f.sha)), /missing Node TAP totals/);
  assert.match(result.stdout, /Linux-Preflight \(supplementary; GitHub required checks remain binding\):/);
  const summary = summaryPath(result);
  assert.equal(readlinkSync(join(resolve(summary, '..'), 'latest')), summary.split('/').at(-1));
  assert.equal(statSync(summary.replace('-summary.txt', '-raw.log')).mode & 0o777, 0o600);
  const calls = readFileSync(f.calls, 'utf8').trim().split('\n');
  assert.ok(calls.every(call => call.includes('mado-ci-linux')));
  assert.ok(calls.every(call => ['-a', '-x', 'BatchMode=yes', 'ConnectTimeout=10', 'ServerAliveInterval=15', 'ServerAliveCountMax=4'].every(option => call.includes(option))));
  assert.ok(calls.every(call => !call.includes('StrictHostKeyChecking=no')));
  assert.doesNotMatch(readFileSync(f.inputs, 'utf8'), /sudo apt-get/);
  assert.deepEqual(readdirSync(join(f.hostHome, 'ci')).filter(name => name.startsWith('run.')), []);
  const workflowFile = join(f.repo, '.github/workflows/pr-body.yml');
  writeFileSync(workflowFile, readFileSync(workflowFile, 'utf8').replace(`run: ${tap}`, 'run: exit 7'));
  assert.notEqual(parseWorkflow(readFileSync(workflowFile, 'utf8')).workflowSha256, workflowAt(f.repo, f.sha).workflowSha256);
  assert.equal(runFixture(f).status, 2, 'tracked dirt must be refused before transfer');
  exec(realGit, ['add', '.github/workflows/pr-body.yml'], { cwd: f.repo });
  exec(realGit, ['commit', '-qm', 'edit command'], { cwd: f.repo });
  const editedHead = exec(realGit, ['rev-parse', 'HEAD'], { cwd: f.repo }).stdout.trim();
  const editedHash = workflowAt(f.repo, editedHead).workflowSha256;
  const edited = await runAsync(['remote', f.repo, editedHead, 'agent-tests', editedHash, '60', '120'], { env: f.env });
  assert.equal(edited.status, 1, edited.stderr + edited.stdout);
  assert.match(edited.stdout, /step:Node totals:exit=7/);
  assert.match(edited.stdout, /outcome=FAIL/);
  assert.match(checkSummary(edited.stdout, editedHead, workflowAt(f.repo, editedHead)), /agent-tooling FAIL Node totals/);
});

test('observed Node footer preserves skipped count and the exact PR total', async () => {
  const first = `python3 -m unittest sample_test.py && ${tapStep(footer(17, 17))}`;
  const f = fixture(first, tapStep(footer(897, 871, 0, 26)));
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const body = readFileSync(summaryPath(result), 'utf8');
  for (const [key, value] of Object.entries({ tests: 897, pass: 871, fail: 0, skip: 26, todo: 0, cancelled: 0 })) {
    assert.match(body, new RegExp(`step:Node totals:${key}=${value}\\n`));
  }
  assert.match(result.stdout, /agent-tooling PASS 888\/914 \(26 skip\)/);
  const compensated = body.replace('step:Python tests:pass=17', 'step:Python tests:pass=16')
    .replace('step:Node totals:pass=871', 'step:Node totals:pass=872');
  assert.throws(() => checkSummary(compensated, f.sha, workflowAt(f.repo, f.sha)), /TAP totals mismatch/);
  for (const key of ['skip', 'todo', 'cancelled']) {
    const missingField = body.replace(new RegExp(`^step:Node totals:${key}=.*\\n`, 'm'), '');
    assert.throws(() => checkSummary(missingField, f.sha, workflowAt(f.repo, f.sha)), new RegExp(`missing step:Node totals:${key}`));
  }
});

test('missing or truncated Node footer is NOT VERIFIED', async () => {
  const complete = footer(1, 1);
  for (const missing of complete) {
    const f = fixture(undefined, tapStep(complete.filter(line => line !== missing)));
    const result = await runFixtureAsync(f);
    assert.equal(result.status, 75, `${missing}\n${result.stderr}${result.stdout}`);
    assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=NOT VERIFIED\nreason=/);
  }
  const f = fixture(undefined, tapStep(complete.slice(0, 3)));
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 75, result.stderr + result.stdout);
});

test('a tested run without a literal node command still requires a complete TAP footer', async () => {
  const second = `printf '%s\\n' '# tests 1' '# pass 1' && : 'alternate runner'`;
  const f = fixture(undefined, second);
  const hash = workflowAt(f.repo, f.sha).workflowSha256;
  const result = await runAsync(['remote', f.repo, f.sha, 'agent-tests', hash, '60', '120'], { env: f.env });
  assert.equal(result.status, 75, result.stderr + result.stdout);
  assert.match(result.stdout, /outcome=NOT VERIFIED\nreason=/);
});

test('zero Node tests are NOT VERIFIED, cancelled tests fail, and todo appears only when positive', async () => {
  const zero = await runFixtureAsync(fixture(undefined, tapStep(footer(0, 0))));
  assert.equal(zero.status, 75, zero.stderr + zero.stdout);
  assert.match(readFileSync(summaryPath(zero), 'utf8'), /outcome=NOT VERIFIED/);
  const cancelled = await runFixtureAsync(fixture(undefined, tapStep(footer(2, 1, 0, 0, 0, 1))));
  assert.equal(cancelled.status, 1, cancelled.stderr + cancelled.stdout);
  assert.match(readFileSync(summaryPath(cancelled), 'utf8'), /step:Node totals:cancelled=1/);
  assert.match(cancelled.stdout, /agent-tooling FAIL/);
  const todo = await runFixtureAsync(fixture(undefined, tapStep(footer(3, 2, 0, 0, 1))));
  assert.equal(todo.status, 0, todo.stderr + todo.stdout);
  assert.match(readFileSync(summaryPath(todo), 'utf8'), /step:Node totals:todo=1/);
  assert.match(todo.stdout, /agent-tooling PASS 3\/4 \(0 skip, 1 todo\)/);
});

test('Python failure before Node yields FAIL, retains the failed name, and cleans the remote directory', async () => {
  const f = fixture(undefined, undefined, true);
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 1, result.stderr + result.stdout);
  const body = readFileSync(summaryPath(result), 'utf8');
  assert.match(body, /outcome=FAIL/);
  assert.match(body, /step:Python tests:exit=1/);
  assert.match(body, /step:Node totals=not-run/);
  assert.match(body, /failed:test_case/);
  assert.match(result.stdout, /agent-tooling FAIL Python tests/);
  assert.deepEqual(readdirSync(join(f.hostHome, 'ci')).filter(name => name.startsWith('run.')), []);
});

test('ordinary nonzero exits keep FAIL across missing, partial, and inconsistent TAP output', async () => {
  const cases = [
    [2, 'exit 2'],
    [42, 'exit 42'],
    [42, `printf '%s\\n' 'not ok 1 - marker_failure' '# tests 1' && exit 42`, 'marker_failure'],
    [42, `${tapStep(footer(2, 1))}; exit 42`],
    [42, `${tapStep(footer(1, 1))}; exit 42`],
    [75, 'exit 75'],
    [127, 'exit 127'],
  ];
  for (const [code, second, failedName] of cases) {
    const f = fixture(undefined, second);
    const hash = workflowAt(f.repo, f.sha).workflowSha256;
    const result = await runAsync(['remote', f.repo, f.sha, 'agent-tests', hash, '60', '120'], { env: f.env });
    assert.equal(result.status, 1, `${code}: ${result.stderr}${result.stdout}`);
    assert.match(result.stdout, /outcome=FAIL/);
    assert.match(result.stdout, new RegExp(`step:Node totals:exit=${code}\\n`));
    if (failedName) assert.match(result.stdout, new RegExp(`failed:${failedName}\\n`));
    assert.match(checkSummary(result.stdout, f.sha, workflowAt(f.repo, f.sha)), /agent-tooling FAIL Node totals/);
  }
});

test('successful step with a complete but inconsistent footer remains NOT VERIFIED', async () => {
  const f = fixture(undefined, tapStep(footer(2, 1)));
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 75, result.stderr + result.stdout);
  assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=NOT VERIFIED\nreason=TAP totals mismatch Node totals/);
});

test('remote checkout refuses a mismatched SHA before executing steps', () => {
  const f = fixture();
  const runDir = join(f.hostHome, 'ci', 'run.WRONG');
  mkdirSync(runDir, { recursive: true });
  const ref = `refs/preflight/${f.sha}`;
  exec(realGit, ['update-ref', ref, f.sha], { cwd: f.repo });
  exec(realGit, ['bundle', 'create', join(runDir, 'head.bundle'), ref], { cwd: f.repo });
  exec(realGit, ['update-ref', '-d', ref], { cwd: f.repo });
  const script = readFileSync(join(root, '.agents/skills/ci-linux-preflight/scripts/remote-run.sh'), 'utf8')
    .replace('export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin', `export PATH=${f.bin}:/usr/local/bin:/usr/bin:/bin`);
  const result = exec('/bin/bash', ['-s', '--', runDir, f.sha, 'agent-tests', workflowAt(f.repo, f.sha).workflowSha256, '2', '30'],
    { input: script, env: { ...f.env, HOME: f.hostHome, FAKE_REMOTE_WRONG_HEAD: '1' } });
  assert.equal(result.status, 75, result.stderr + result.stdout);
  assert.match(result.stderr, /checkout head mismatch/);
  assert.deepEqual(readdirSync(join(f.hostHome, 'ci')).filter(name => name.startsWith('run.')), []);
});

test('transfer failure and busy lock are NOT VERIFIED with exit 75 and immutable attempts', async () => {
  const f = fixture();
  const transfer = await runFixtureAsync(f, [], { FAKE_RSYNC_FAIL: '1' });
  assert.equal(transfer.status, 75);
  assert.match(readFileSync(summaryPath(transfer), 'utf8'), /outcome=NOT VERIFIED\nreason=bundle transfer:/);
  const busy = await runFixtureAsync(f, [], { FAKE_BUSY: '1' });
  assert.equal(busy.status, 75, busy.stderr);
  assert.match(readFileSync(summaryPath(busy), 'utf8'), /outcome=NOT VERIFIED\nreason=busy/);
  assert.notEqual(summaryPath(transfer), summaryPath(busy));
});

test('step timeout is TIMEOUT; summary checker refuses truncation, duplicate DONE, wrong head and missing totals', async () => {
  const f = fixture('sleep 1.2');
  const hash = workflowAt(f.repo, f.sha).workflowSha256;
  const result = await runAsync(['remote', f.repo, f.sha, 'agent-tests', hash, '1', '60', '--time-bin', '/nonexistent-gnu-time'], { env: f.env });
  assert.equal(result.status, 1, result.stderr + result.stdout);
  const body = result.stdout;
  assert.match(body, /outcome=TIMEOUT/);
  assert.match(body, /step:Python tests:exit=124/);
  assert.match(body, /step:Python tests:peak_rss_kb=unknown/);
  const path = join(f.base, 'summary.txt');
  writeFileSync(path, body);
  assert.equal(run(['summary-check', path, '--expect-head', f.sha, '--repo', f.repo]).status, 0);
  const workflow = workflowAt(f.repo, f.sha);
  const reordered = body.split('\n');
  const first = reordered.findIndex(line => line === 'step:Checkout PR head=bundle-checked');
  const second = reordered.findIndex(line => line === 'step:Set up Node=provision-checked');
  [reordered[first], reordered[second]] = [reordered[second], reordered[first]];
  for (const invalid of [body.replace(/DONE\n$/, ''), `${body}DONE\n`, body.replace(`head=${f.sha}`, `head=${'a'.repeat(40)}`), body.replace(/^step:Python tests:tests=.*\n/m, ''), body.replace('steps_total=5\n', 'steps_total=5\nsteps_total=5\n'), reordered.join('\n')]) assert.throws(() => checkSummary(invalid, f.sha, workflow));
});

test('environment mismatch and unsupported workflow fail closed', async () => {
  const f = fixture();
  const mismatch = exec('/bin/bash', [join(root, '.agents/skills/ci-linux-preflight/scripts/env-check.sh')], { env: { ...f.env, FAKE_GIT_VERSION: '2.34.1' } });
  assert.notEqual(mismatch.status, 0);
  assert.match(mismatch.stdout, /git.*2\.34\.1.*FAIL/);
  writeFileSync(join(f.bin, 'sudo'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const privileged = exec('/bin/bash', [join(root, '.agents/skills/ci-linux-preflight/scripts/env-check.sh')], { env: f.env });
  assert.notEqual(privileged.status, 0);
  assert.match(privileged.stdout, /sudo passwordless FAIL/);
  const bad = fixture();
  const workflow = join(bad.repo, '.github/workflows/pr-body.yml');
  writeFileSync(workflow, readFileSync(workflow, 'utf8').replace('working-directory: pr-head', 'working-directory: pr-head\n        shell: bash'));
  exec(realGit, ['add', '.github/workflows/pr-body.yml'], { cwd: bad.repo });
  exec(realGit, ['commit', '-qm', 'unsupported'], { cwd: bad.repo });
  const head = exec(realGit, ['rev-parse', 'HEAD'], { cwd: bad.repo }).stdout.trim();
  assert.equal(run(['run', head, '--repo', bad.repo], { env: bad.env }).status, 2);
});

test('environment check runs with bash and reports the actual mismatch', async () => {
  const f = fixture();
  const check = join(root, '.agents/skills/ci-linux-preflight/scripts/env-check.sh');
  const syntax = exec('/bin/bash', ['-n', check]);
  assert.equal(syntax.status, 0, syntax.stderr);
  assert.doesNotMatch(readFileSync(join(root, '.agents/skills/ci-linux-preflight/scripts/remote-run.sh'), 'utf8'), /\/bin\/zsh/);
  const healthy = exec('/bin/bash', [check], { env: f.env });
  assert.equal(healthy.status, 0, healthy.stderr + healthy.stdout);
  const withoutBinZsh = await runFixtureAsync(f, [], { FAKE_NO_BIN_ZSH: '1' });
  assert.equal(withoutBinZsh.status, 0, withoutBinZsh.stderr + withoutBinZsh.stdout);
  const failed = await runFixtureAsync(f, [], { FAKE_ENV_CHECK_FAIL: '1' });
  assert.equal(failed.status, 75, failed.stderr + failed.stdout);
  assert.match(readFileSync(summaryPath(failed), 'utf8'), /outcome=NOT VERIFIED\nreason=environment mismatch\n/);
});

test('fake SSH outcome does not depend on passwordless sudo on the test host', async () => {
  const f = fixture();
  writeFileSync(join(f.bin, 'sudo'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=PASS/);
});

test('supplementary PR line does not change Gates lint', () => {
  const head = '3de39c6012345678901234567890123456789012';
  const source = readFileSync(join(root, '.agents/skills/pr/SKILL.md'), 'utf8');
  const gates = source.match(/## Gates\n([\s\S]*?)\nDevice-Smoke:/)?.[1];
  assert.ok(gates);
  const body = `## Gates\n${gates}`.replaceAll('<head-sha>', head)
    + `\nLinux-Preflight (supplementary; GitHub required checks remain binding): ${head.slice(0, 7)} agent-tooling PASS 1/1 (0 skip)\n`;
  assert.deepEqual(checkGates(body, head), { ok: true });
});
});
