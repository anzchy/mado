import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { budgetMs, exitStatus, parseArgs, processTree, sampleTargets, TIMEOUT_STATUS } from './test-watchdog.mjs';

const script = fileURLToPath(new URL('./test-watchdog.mjs', import.meta.url));
const tempDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-'));

test('parseArgs takes options before -- and the command after it', () => {
  const options = parseArgs(['--out', 'o', '--timeout-seconds', '5', '--match', 'x', '--', 'swift', 'test', '--', 'y']);
  assert.deepEqual(options.command, ['swift', 'test', '--', 'y']);
  assert.equal(options.out, 'o');
  assert.equal(options.timeoutSeconds, 5);
  assert.equal(options.match, 'x');
  assert.equal(options.sampleSeconds, 10);
  assert.equal(options.graceSeconds, 15);
});

test('parseArgs rejects a missing command, output, budget or value', () => {
  assert.throws(() => parseArgs(['--out', 'o', '--timeout-seconds', '5']), /usage/);
  assert.throws(() => parseArgs(['--out', 'o', '--timeout-seconds', '5', '--']), /usage/);
  assert.throws(() => parseArgs(['--timeout-seconds', '5', '--', 'true']), /--out/);
  assert.throws(() => parseArgs(['--out', 'o', '--', 'true']), /--timeout-seconds or --deadline-epoch/);
  assert.throws(() => parseArgs(['--out', 'o', '--timeout-seconds', '0', '--', 'true']), /positive/);
  assert.throws(() => parseArgs(['--out', 'o', '--timeout-seconds', 'soon', '--', 'true']), /positive/);
  assert.throws(() => parseArgs(['--out', 'o', '--timeout-seconds', '--', 'true']), /positive|needs a value/);
  assert.throws(() => parseArgs(['--out', 'o', '--wait', '1', '--', 'true']), /unknown option/);
});

test('budgetMs takes the earlier of the timeout and the deadline, never below zero', () => {
  const now = 1_000_000_000;
  assert.equal(budgetMs({ timeoutSeconds: 60 }, now), 60_000);
  assert.equal(budgetMs({ deadlineEpoch: now / 1000 + 30 }, now), 30_000);
  assert.equal(budgetMs({ timeoutSeconds: 60, deadlineEpoch: now / 1000 + 30 }, now), 30_000);
  assert.equal(budgetMs({ timeoutSeconds: 10, deadlineEpoch: now / 1000 + 30 }, now), 10_000);
  assert.equal(budgetMs({ deadlineEpoch: now / 1000 - 5 }, now), 0);
});

test('processTree walks descendants only, and sampleTargets prefers the test runner', () => {
  const ps = [
    '  1     0 /sbin/launchd',
    ' 10     1 swift test --package-path Packages/PicseeKit',
    ' 11    10 /usr/bin/swift-build --build-tests',
    ' 12    10 /Applications/Xcode.app/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path PicseeKitPackageTests.xctest',
    ' 13    12 /bin/sh -c child',
    ' 20     1 unrelated PicseeKitPackageTests',
  ].join('\n');
  const tree = processTree(ps, 10);
  assert.deepEqual(tree.map(p => p.pid), [10, 11, 12, 13]);
  assert.deepEqual(sampleTargets(tree, 'swiftpm-testing|PackageTests').map(p => p.pid), [12]);
  assert.deepEqual(sampleTargets(tree, 'no-such-runner').map(p => p.pid), [10, 11, 12, 13]);
  assert.deepEqual(processTree(ps, 99).map(p => p.pid), [99], 'an exited root is still listed once');
});

test('exitStatus passes the command status through and marks a watchdog stop', () => {
  assert.equal(exitStatus({ timedOut: false, code: 0 }), 0);
  assert.equal(exitStatus({ timedOut: false, code: 1 }), 1);
  assert.equal(exitStatus({ timedOut: false, code: 70 }), 70);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGKILL' }), 137);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGTERM' }), 143);
  assert.equal(exitStatus({ timedOut: true, code: null, signal: 'SIGTERM' }), TIMEOUT_STATUS);
});

test('a finished command keeps its status and output, with no stacks', () => {
  const out = tempDir();
  const run = spawnSync('node', [script, '--out', out, '--timeout-seconds', '30', '--',
    'sh', '-c', 'echo hello; echo oops >&2; exit 3'], { encoding: 'utf8' });
  assert.equal(run.status, 3);
  assert.match(run.stdout, /hello/);
  assert.match(fs.readFileSync(path.join(out, 'test.log'), 'utf8'), /hello[\s\S]*oops|oops[\s\S]*hello/);
  assert.equal(fs.existsSync(path.join(out, 'stacks')), false);
});

test('a missing command fails with 127', () => {
  const run = spawnSync('node', [script, '--out', tempDir(), '--timeout-seconds', '5', '--', 'no-such-command-391'],
    { encoding: 'utf8' });
  assert.equal(run.status, 127);
  assert.match(run.stderr, /cannot start/);
});

test('a hung command is sampled, recorded and killed with 124', { skip: process.platform !== 'darwin' && 'needs macOS sample' }, () => {
  const out = tempDir();
  const started = Date.now();
  // The child ignores TERM, so only the KILL after the grace period ends it.
  const run = spawnSync('node', [script, '--out', out, '--timeout-seconds', '1', '--sample-seconds', '1',
    '--grace-seconds', '1', '--match', 'sleep', '--', 'sh', '-c', "trap '' TERM; sleep 60 & wait; sleep 60"],
    { encoding: 'utf8' });
  assert.equal(run.status, TIMEOUT_STATUS, run.stderr);
  assert.ok(Date.now() - started < 30_000, 'killed well before the child would finish');
  assert.match(run.stderr, /deadline passed/);
  assert.match(run.stderr, /sending TERM/);
  assert.match(run.stderr, /sending KILL/);
  const stacks = fs.readdirSync(path.join(out, 'stacks'));
  assert.ok(stacks.includes('ps.txt'));
  const ps = fs.readFileSync(path.join(out, 'stacks', 'ps.txt'), 'utf8');
  assert.match(ps, /%CPU RSS/);
  assert.match(ps, /sleep 60/);
  const samples = stacks.filter(name => name.startsWith('sample-'));
  assert.ok(samples.length >= 1, `samples: ${stacks}`);
  assert.match(fs.readFileSync(path.join(out, 'stacks', samples[0]), 'utf8'), /Call graph|Analysis of sampling/);
  assert.equal(spawnSync('pgrep', ['-f', "trap '' TERM; sleep 60"]).status, 1, 'no process of the group survives');
});
