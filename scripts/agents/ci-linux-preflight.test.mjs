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
const exec = (cmd, args, options = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...options });
const run = (args, options = {}) => exec(process.execPath, [tool, ...args], options);
const runAsync = (args, options = {}) => new Promise(resolve => {
  const child = spawn(process.execPath, [tool, ...args], options);
  let stdout = ''; let stderr = '';
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  child.on('close', status => resolve({ status, stdout, stderr }));
});
const tap = `test "$CI" = true && test "$GITHUB_ACTIONS" = true && test "$LANG" = C.UTF-8 && test "$PATH" = /opt/node/bin:/usr/local/bin:/usr/bin:/bin && test -z "\${FAKE_SECRET:-}" && printf '# tests 1\\n# pass 1\\n# fail 0\\n# skip 0\\n' && : 'node --test'`;

function fixture(first = 'python3 -m unittest sample_test.py', second = tap, failingPython = false) {
  const base = mkdtempSync(join(tmpdir(), 'ci-preflight-'));
  const repo = join(base, 'repo');
  const hostHome = join(base, 'host');
  const bin = join(base, 'bin');
  mkdirSync(join(repo, '.github/workflows'), { recursive: true });
  mkdirSync(join(repo, '.agents/skills/ci-linux-preflight'), { recursive: true });
  mkdirSync(hostHome);
  mkdirSync(bin);
  cpSync(join(root, '.agents/skills/ci-linux-preflight/scripts'), join(repo, '.agents/skills/ci-linux-preflight/scripts'), { recursive: true });
  const workflow = `jobs:\n  agent-tests:\n    name: Agent tooling\n    steps:\n      - name: Checkout PR head\n        uses: actions/checkout@abc\n        with:\n          ref: \${{ github.event.pull_request.head.sha }}\n      - name: Set up Node\n        uses: actions/setup-node@abc\n        with:\n          node-version: 22\n      - name: Install portable device test tools\n        run: |\n          sudo apt-get update\n      - name: Python tests\n        working-directory: pr-head\n        run: ${first}\n      - name: Node totals\n        working-directory: pr-head\n        run: ${second}\n`;
  writeFileSync(join(repo, '.github/workflows/pr-body.yml'), workflow
    .replace('      - name: Set up Node', '          path: pr-head\n          fetch-depth: 0\n      - name: Set up Node')
    .replace('sudo apt-get update', 'sudo apt-get update\n          sudo apt-get install --no-install-recommends -y python3 git zsh'));
  writeFileSync(join(repo, 'sample_test.py'), `import unittest\nclass Sample(unittest.TestCase):\n def test_case(self):\n  ${failingPython ? "self.fail('broken')" : 'self.assertTrue(True)'}\n`);
  for (const [name, body] of Object.entries({
    node: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo v22.23.5; else exec "$REAL_NODE" "$@"; fi\n`,
    git: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo "git version \${FAKE_GIT_VERSION:-2.56.1}"; exit; fi\nif [ "$FAKE_REMOTE_WRONG_HEAD" = 1 ]; then case "$*" in *'rev-parse HEAD'*) printf '%040d\\n' 0; exit;; esac; fi\nexec "$REAL_GIT" "$@"\n`,
    zsh: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'zsh 5.8'; else exec /bin/zsh "$@"; fi\n`,
    ps: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'ps from procps-ng 3.3.17'; else exec /bin/ps "$@"; fi\n`,
    flock: `#!/bin/sh\nif [ "${'$'}FAKE_BUSY" = 1 ]; then exit 1; fi\nexit 0\n`,
    timeout: `#!/usr/bin/env node\nconst {spawnSync}=require('node:child_process');const a=process.argv.slice(2);a.shift();const seconds=Number(a.shift());const cmd=a.shift();const r=spawnSync(cmd,a,{stdio:'inherit',timeout:seconds*1000});process.exit(r.error?.code==='ETIMEDOUT'?124:r.status??75);\n`,
    rsync: `#!/bin/sh\nif [ "$FAKE_RSYNC_FAIL" = 1 ]; then echo 'transfer failed' >&2; exit 1; fi\ncp "$3" "\${4#*:}"\n`,
    ssh: `#!/bin/bash\nset -o pipefail\nprintf '%s\\n' "$*" >> "$FAKE_CALLS"\ntmp=$(mktemp)\ncat > "$tmp"\ncat "$tmp" >> "$FAKE_INPUTS"\nif [ "$FAKE_SSH_FAIL" = 1 ]; then echo unreachable >&2; exit 1; fi\nfor item in "$@"; do last=$item; done\nsed "s#export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin#export PATH=$FAKE_BIN:/usr/local/bin:/usr/bin:/bin#g" "$tmp" | HOME="$FAKE_HOST_HOME" PATH="$FAKE_BIN:$PATH" /bin/bash -c "$last"\nstatus=$?\nrm -f "$tmp"\nexit $status\n`,
  })) writeFileSync(join(bin, name), body, { mode: 0o755 });
  for (const args of [['init', '-q'], ['config', 'user.name', 'Fixture'], ['config', 'user.email', 'fixture@example.test'], ['add', '.github/workflows/pr-body.yml', '.agents/skills/ci-linux-preflight/scripts', 'sample_test.py'], ['commit', '-qm', 'fixture']]) {
    const result = exec(realGit, args, { cwd: repo });
    assert.equal(result.status, 0, result.stderr);
  }
  const sha = exec(realGit, ['rev-parse', 'HEAD'], { cwd: repo }).stdout.trim();
  const calls = join(base, 'calls.jsonl');
  const inputs = join(base, 'inputs.txt');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, HOME: base, REAL_NODE: process.execPath, REAL_GIT: realGit, FAKE_HOST_HOME: hostHome, FAKE_BIN: bin, FAKE_CALLS: calls, FAKE_INPUTS: inputs, PICSEE_LINUX_HOST: 'picsee-ci-linux' };
  return { base, repo, hostHome, bin, calls, inputs, sha, env };
}
function summaryPath(result) { return result.stdout.match(/^Summary: (.+)$/m)?.[1]; }
function runFixture(f, args = [], env = {}) { return run(['run', f.sha, '--repo', f.repo, ...args], { env: { ...f.env, ...env } }); }
function runFixtureAsync(f, args = [], env = {}) { return runAsync(['run', f.sha, '--repo', f.repo, ...args], { env: { ...f.env, ...env } }); }

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
  const edited = await runAsync(['remote', f.repo, editedHead, 'agent-tests', editedHash, '3', '5'], { env: f.env });
  assert.equal(edited.status, 1, edited.stderr + edited.stdout);
  assert.match(edited.stdout, /step:Node totals:exit=7/);
});

test('Python failure before Node yields FAIL, step name, and remote cleanup', async () => {
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
  const result = await runAsync(['remote', f.repo, f.sha, 'agent-tests', hash, '1', '3', '--time-bin', '/nonexistent-gnu-time'], { env: f.env });
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
  const mismatch = exec('/bin/zsh', [join(root, '.agents/skills/ci-linux-preflight/scripts/env-check.sh')], { env: { ...f.env, FAKE_GIT_VERSION: '2.34.1' } });
  assert.notEqual(mismatch.status, 0);
  assert.match(mismatch.stdout, /git.*2\.34\.1.*FAIL/);
  writeFileSync(join(f.bin, 'sudo'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const privileged = exec('/bin/zsh', [join(root, '.agents/skills/ci-linux-preflight/scripts/env-check.sh')], { env: f.env });
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
