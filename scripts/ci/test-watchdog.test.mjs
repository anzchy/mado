import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { budgetMs, captureDiagnostics, exitStatus, parseArgs, processTree, sampleTargets, TIMEOUT_STATUS, watch }
  from './test-watchdog.mjs';

const script = fileURLToPath(new URL('./test-watchdog.mjs', import.meta.url));
const tempDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-'));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
// The real-hang tests need `ps` and `sample` (macOS, outside a sandbox that blocks process listing). Spindump is off in
// every test: on a CI runner with passwordless sudo it would otherwise run for real.
const realHang = process.platform !== 'darwin' ? 'needs macOS sample'
  : spawnSync('ps', ['-A', '-o', 'pid=']).status !== 0 ? 'ps is not permitted here' : false;
const watchdog = (args, command) => spawnSync('node', [script, '--no-spindump', ...args, '--', ...command],
  { encoding: 'utf8' });

test('parseArgs takes options before -- and the command after it', () => {
  const options = parseArgs(['--out', 'o', '--timeout-seconds', '5', '--no-spindump', '--match', 'x',
    '--capture-seconds', '40', '--snapshot-seconds', '2', '--', 'swift', 'test', '--', 'y'], {});
  assert.deepEqual(options.command, ['swift', 'test', '--', 'y']);
  assert.equal(options.out, 'o');
  assert.equal(options.timeoutSeconds, 5);
  assert.equal(options.match, 'x');
  assert.equal(options.spindump, false);
  assert.equal(options.captureSeconds, 40);
  assert.equal(options.snapshotSeconds, 2);
  const defaults = parseArgs(['--out', 'o', '--timeout-seconds', '5', '--', 'true'], {});
  assert.deepEqual([defaults.sampleSeconds, defaults.captureSeconds, defaults.graceSeconds, defaults.snapshotSeconds,
    defaults.spindump], [10, 90, 15, 30, true]);
  assert.equal(parseArgs(['--out', 'o', '--timeout-seconds', '5', '--', 'true'],
    { PICSEE_WATCHDOG_NO_SPINDUMP: '1' }).spindump, false);
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

const PS = [
  '  1     0 /sbin/launchd',
  ' 10     1 swift test --package-path Packages/PicseeKit',
  ' 11    10 /usr/bin/swift-build --build-tests',
  ' 12    10 /Applications/Xcode.app/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path PicseeKitPackageTests.xctest',
  ' 13    12 /bin/sh -c child',
  ' 14    10 /usr/bin/xctest PicseeKitPackageTests.xctest',
  ' 20     1 unrelated PicseeKitPackageTests',
  ' 30     1 swiftpm-testing-helper orphan',
].join('\n');

test('processTree walks descendants only, and sampleTargets prefers the test runner', () => {
  const tree = processTree(PS, 10);
  assert.deepEqual(tree.map(p => p.pid), [10, 11, 12, 14, 13]);
  assert.deepEqual(sampleTargets(tree, 'swiftpm-testing|PackageTests').map(p => p.pid), [12, 14]);
  assert.deepEqual(sampleTargets(tree, 'no-such-runner').map(p => p.pid), [10, 11, 12, 14, 13]);
  assert.deepEqual(processTree(PS, 99).map(p => p.pid), [99], 'an exited root is still listed once');
});

test('exitStatus passes the command status through and maps every signal to 128+n', () => {
  assert.equal(exitStatus({ timedOut: false, code: 0 }), 0);
  assert.equal(exitStatus({ timedOut: false, code: 1 }), 1);
  assert.equal(exitStatus({ timedOut: false, code: 70 }), 70);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGKILL' }), 137);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGTERM' }), 143);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGQUIT' }), 131);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGABRT' }), 134);
  assert.equal(exitStatus({ timedOut: false, code: null, signal: 'SIGSEGV' }), 128 + os.constants.signals.SIGSEGV);
  assert.equal(exitStatus({ timedOut: true, code: null, signal: 'SIGTERM' }), TIMEOUT_STATUS);
});

/** A fake process runner on a fake clock: `ps` lists PS, each sample or spindump takes `cost` seconds. */
function fakeRun({ cost, sudo = true, psFails = false }) {
  const clock = { now: 0 }, calls = [];
  const run = (cmd, args, options = {}) => {
    calls.push({ cmd, args, timeout: options.timeout, at: clock.now });
    if (cmd === 'ps') {
      if (psFails) return { status: 1, stdout: '', stderr: 'ps: operation not permitted' };
      if (args[0] === '-A') return { status: 0, stdout: PS, stderr: '' };
      const pid = Number(args.at(-1));
      return { status: 0, stdout: `${pid} 1 0.0 1000 00:10 S ${processTree(PS, pid)[0].command}\n`, stderr: '' };
    }
    if (cmd === 'sudo' && args[1] === 'true') return { status: sudo ? 0 : 1, stdout: '', stderr: '' };
    clock.now += Math.min(cost * 1000, options.timeout);
    fs.writeFileSync(args.at(-1), `report ${cmd} ${args.join(' ')}\n`);
    return { status: 0, stdout: '', stderr: '' };
  };
  return { run, calls, now: () => clock.now };
}

test('the capture phase samples in order within its budget and logs what it skipped', () => {
  const out = tempDir(), lines = [];
  // Two matching processes (12, 14). A 10 s sample costs 12 s, the budget is 30 s: both samples fit (24 s), the
  // spindumps do not (6 s left < 11 s needed).
  const fake = fakeRun({ cost: 12 });
  const result = captureDiagnostics({ root: 10, out, sampleSeconds: 10, captureSeconds: 30,
    match: 'swiftpm-testing|PackageTests', log: line => lines.push(line), run: fake.run, now: fake.now });
  const captures = fake.calls.filter(c => c.cmd === 'sample' || c.args[1] === 'spindump');
  assert.deepEqual(captures.map(c => `${c.cmd} ${c.args[0]}`), ['sample 12', 'sample 14']);
  assert.deepEqual(result.skipped, ['spindump 12', 'spindump 14']);
  assert.match(lines.join('\n'), /capture budget of 30 s spent; skipped spindump 12, spindump 14/);
  assert.doesNotMatch(lines.join('\n'), /spindump of/, 'a skipped capture is not announced as started');
  for (const c of captures) assert.ok(c.timeout <= 30_000 - c.at, `timeout ${c.timeout} at ${c.at}`);
  assert.ok(fake.now() <= 30_000, `capture took ${fake.now()} ms`);
  assert.deepEqual(result.written.map(f => path.basename(f)), ['ps.txt', 'sample-12.txt', 'sample-14.txt']);

  // A call that would run past the budget is cut off at what is left, and later captures are skipped.
  const slow = fakeRun({ cost: 100 });
  const cut = captureDiagnostics({ root: 10, out: tempDir(), sampleSeconds: 10, captureSeconds: 25,
    match: 'swiftpm-testing|PackageTests', log: () => {}, run: slow.run, now: slow.now });
  assert.equal(slow.calls.find(c => c.cmd === 'sample').timeout, 25_000);
  assert.deepEqual(cut.skipped, ['sample 14', 'spindump 12', 'spindump 14']);
  assert.ok(slow.now() <= 25_000, `capture took ${slow.now()} ms`);

  // With room for everything, the samples are followed by spindumps of the same processes, each bounded.
  const fast = fakeRun({ cost: 1 });
  const full = captureDiagnostics({ root: 10, out: tempDir(), sampleSeconds: 10, captureSeconds: 90,
    match: 'swiftpm-testing|PackageTests', log: () => {}, run: fast.run, now: fast.now });
  assert.deepEqual(full.skipped, []);
  assert.deepEqual(full.written.map(f => path.basename(f)),
    ['ps.txt', 'sample-12.txt', 'sample-14.txt', 'spindump-12.txt', 'spindump-14.txt']);
  for (const c of fast.calls.filter(c => c.cmd === 'sample' || c.args[1] === 'spindump')) assert.equal(c.timeout, 30_000);

  // Disabled spindump never asks sudo.
  const off = fakeRun({ cost: 1 });
  captureDiagnostics({ root: 10, out: tempDir(), sampleSeconds: 10, captureSeconds: 90, spindump: false, match: 'x',
    log: () => {}, run: off.run, now: off.now });
  assert.equal(off.calls.some(c => c.cmd === 'sudo'), false);
});

test('a failed ps is reported, written to ps.txt, and leaves only the leader group to signal', () => {
  const out = tempDir(), lines = [];
  const fake = fakeRun({ cost: 1, psFails: true });
  const result = captureDiagnostics({ root: 10, known: [{ pid: 12, command: 'swiftpm-testing-helper' }], out,
    sampleSeconds: 1, captureSeconds: 30, spindump: false, match: 'swiftpm-testing', log: line => lines.push(line),
    run: fake.run, now: fake.now });
  assert.deepEqual(result.tree, [{ pid: 10, command: '' }], 'unverifiable snapshot pids are not signalled');
  assert.match(lines.join('\n'), /ps failed \(status 1\): ps: operation not permitted; only the command's process group/);
  assert.match(fs.readFileSync(path.join(out, 'stacks', 'ps.txt'), 'utf8'), /^# ps failed .*operation not permitted/m);
});

test('a snapshot process is kept only while ps lists it with the same command', () => {
  const fake = fakeRun({ cost: 1 });
  const result = captureDiagnostics({ root: 99, out: tempDir(), sampleSeconds: 1, captureSeconds: 30, spindump: false,
    known: [{ pid: 30, command: 'swiftpm-testing-helper orphan' }, { pid: 20, command: 'some earlier helper' },
      { pid: 77, command: 'gone' }], match: 'swiftpm-testing', log: () => {}, run: fake.run, now: fake.now });
  assert.deepEqual(result.tree.map(p => p.pid), [99, 30]);
});

test('watch falls back to the process group when ps fails, and still stops the command', async () => {
  const out = tempDir(), lines = [];
  const fake = fakeRun({ cost: 0, psFails: true });
  const sampled = [];
  const run = (cmd, args, options) => { if (cmd === 'sample') sampled.push(Number(args[0])); return fake.run(cmd, args, options); };
  const started = Date.now();
  const status = await watch(parseArgs(['--out', out, '--timeout-seconds', '1', '--sample-seconds', '1',
    '--grace-seconds', '1', '--no-spindump', '--', 'sh', '-c', "trap '' TERM; sleep 60"], {}),
    { log: line => lines.push(line), run });
  assert.equal(status, TIMEOUT_STATUS);
  assert.ok(Date.now() - started < 20_000);
  assert.match(lines.join('\n'), /ps failed/);
  assert.match(lines.join('\n'), /sending KILL/);
  assert.equal(sampled.length, 1, 'the leader alone is sampled');
  assert.equal(alive(-sampled[0]), false, 'the leader group is gone');
});

test('a finished command keeps its status and output, with no stacks', () => {
  const out = tempDir();
  const run = watchdog(['--out', out, '--timeout-seconds', '30'], ['sh', '-c', 'echo hello; echo oops >&2; exit 3']);
  assert.equal(run.status, 3);
  assert.match(run.stdout, /hello/);
  assert.match(fs.readFileSync(path.join(out, 'test.log'), 'utf8'), /hello[\s\S]*oops|oops[\s\S]*hello/);
  assert.equal(fs.existsSync(path.join(out, 'stacks')), false);
});

test('a command killed by a signal other than TERM or KILL exits 128+n', () => {
  const run = watchdog(['--out', tempDir(), '--timeout-seconds', '30'], ['sh', '-c', 'kill -QUIT $$']);
  assert.equal(run.status, 128 + os.constants.signals.SIGQUIT, run.stderr);
});

test('a finished command\'s leftover group members are killed', () => {
  const run = watchdog(['--out', tempDir(), '--timeout-seconds', '30'],
    ['sh', '-c', 'sleep 60 >/dev/null 2>&1 & echo $!']);
  assert.equal(run.status, 0, run.stderr);
  const leftover = Number(run.stdout.trim());
  assert.ok(leftover > 0, run.stdout);
  assert.match(run.stderr, /killing what is left of its process group/);
  assert.equal(alive(leftover), false);
});

test('a missing command fails with 127', () => {
  const run = watchdog(['--out', tempDir(), '--timeout-seconds', '5'], ['no-such-command-391']);
  assert.equal(run.status, 127);
  assert.match(run.stderr, /cannot start/);
});

test('a hung command is sampled, recorded and killed with 124', { skip: realHang }, () => {
  const out = tempDir();
  const started = Date.now();
  // The child ignores TERM, so only the KILL after the grace period ends it.
  const run = watchdog(['--out', out, '--timeout-seconds', '1', '--sample-seconds', '1', '--grace-seconds', '1',
    '--match', 'sleep'], ['sh', '-c', "trap '' TERM; echo $$; sleep 60 & wait; sleep 60"]);
  assert.equal(run.status, TIMEOUT_STATUS, run.stderr);
  assert.ok(Date.now() - started < 30_000, 'killed well before the child would finish');
  assert.match(run.stderr, /deadline passed/);
  assert.match(run.stderr, /spindump disabled/);
  assert.match(run.stderr, /sending TERM/);
  assert.match(run.stderr, /sending KILL/);
  const stacks = fs.readdirSync(path.join(out, 'stacks'));
  const ps = fs.readFileSync(path.join(out, 'stacks', 'ps.txt'), 'utf8');
  assert.match(ps, /%CPU RSS/);
  assert.match(ps, /sleep 60/);
  const samples = stacks.filter(name => name.startsWith('sample-'));
  assert.ok(samples.length >= 1, `samples: ${stacks}`);
  assert.match(fs.readFileSync(path.join(out, 'stacks', samples[0]), 'utf8'), /Call graph|Analysis of sampling/);
  assert.equal(alive(-Number(run.stdout.trim())), false, 'no process of the group survives');
});

test('a hung helper in its own process group is killed when the leader exits on TERM', { skip: realHang }, () => {
  const out = tempDir();
  // Like swift test: the leader dies on TERM, its helper runs in a group of its own and ignores TERM.
  const helper = "perl -e 'setpgrp(0, 0); $SIG{TERM} = q(IGNORE); $| = 1; print qq($$\\n); sleep 60; # helper-391'";
  const started = Date.now();
  const run = watchdog(['--out', out, '--timeout-seconds', '1', '--sample-seconds', '1', '--grace-seconds', '1',
    '--match', 'helper-391'], ['sh', '-c', `${helper} & wait`]);
  assert.equal(run.status, TIMEOUT_STATUS, run.stderr);
  // The helper holds the output pipe open, so a watchdog that misses it waits the helper's full 60 s.
  assert.ok(Date.now() - started < 30_000, `took ${Date.now() - started} ms`);
  assert.match(run.stderr, /sending KILL/);
  assert.doesNotMatch(run.stderr, /still alive/);
  assert.ok(fs.readdirSync(path.join(out, 'stacks')).some(name => name.startsWith('sample-')));
  assert.equal(alive(Number(run.stdout.trim())), false, 'the helper does not survive the watchdog');
});

test('a helper orphaned by a leader that exited normally is found by the snapshots and killed', { skip: realHang }, () => {
  const out = tempDir();
  // The leader exits 0 after 2 s; its helper, in a group of its own and reparented to launchd, keeps the pipe open.
  const helper = "perl -e 'setpgrp(0, 0); $SIG{TERM} = q(IGNORE); $| = 1; print qq($$\\n); sleep 60; # orphan-391'";
  const started = Date.now();
  const run = watchdog(['--out', out, '--timeout-seconds', '5', '--sample-seconds', '1', '--grace-seconds', '1',
    '--snapshot-seconds', '0.5', '--match', 'orphan-391'], ['sh', '-c', `${helper} & sleep 2; exit 0`]);
  assert.equal(run.status, TIMEOUT_STATUS, run.stderr);
  assert.ok(Date.now() - started < 30_000, `took ${Date.now() - started} ms`);
  const pid = Number(run.stdout.trim());
  assert.ok(fs.readdirSync(path.join(out, 'stacks')).includes(`sample-${pid}.txt`), run.stderr);
  assert.match(fs.readFileSync(path.join(out, 'stacks', 'ps.txt'), 'utf8'), /orphan-391/);
  assert.equal(alive(pid), false, 'the orphaned helper does not survive the watchdog');
});
