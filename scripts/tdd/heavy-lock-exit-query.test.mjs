// #705 T5: after the job's leader exits, one failed process query must not
// end the run as "unknown cleanup". The supervisor retries it (at most 4
// queries, 0.2 s apart, within 5 s of the first failure) while it keeps
// handling cancellation, registration and the execution deadline. It releases
// only after a successful snapshot shows no owned member; survivors go to the
// existing drain; an exhausted budget is still unknown cleanup (70, shared lock
// kept). PICSEE_HEAVY_FAULT_EXIT_QUERY_PLAN=<file> scripts the post-exit
// queries with real substitute processes and logs each consumed token.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixtureEnv } from './fixture-env.mjs';
import { guardianEnvironments } from './guardian-env-probe.mjs';

const here = p => fileURLToPath(new URL(p, import.meta.url));
const supervisor = here('./heavy-lock.py');
const lock = here('../heavy-lock.sh');
const probe = here('./guardian-env-probe.mjs');
const scratch = mkdtempSync(path.join(tmpdir(), 'i705-exit-query-'));
test.after(() => rmSync(scratch, { recursive: true, force: true }));

// ---- QueryRetry, driven with a fake clock --------------------------------
const prelude = `
import importlib.util, json, random, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('hl', sys.argv[1])
hl = importlib.util.module_from_spec(spec); spec.loader.exec_module(hl)
class Clock:
    t = 100.0
    def __call__(self): return self.t
clock = Clock()
def fresh(): return hl.QueryRetry(clock=clock)
def step(dt): clock.t = round(clock.t + dt, 6)
out = []
`;
function python(body) {
  const r = spawnSync('python3', ['-c', prelude + body + '\nprint(json.dumps(out))', supervisor], { encoding: 'utf8', timeout: 20000 });
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}

test('QueryRetry: one failure, then an empty snapshot succeeds after the interval', () => {
  assert.deepEqual(python(`
r = fresh()
out.append(r.next_action()); out.append(r.observe(None))
step(0.1); out.append(r.next_action())
step(0.1); out.append(r.next_action()); out.append(r.observe([]))
out.append(r.next_action())
`), ['query', 'wait', 'wait', 'query', 'ok', 'query']);
});

test('QueryRetry: three failures, then a snapshot with survivors is a success', () => {
  assert.deepEqual(python(`
r = fresh()
for _ in range(3):
    out.append(r.next_action()); out.append(r.observe(None)); step(0.2)
out.append(r.next_action()); out.append(r.observe([(4242, 4242)]))
out.append(r.next_action())
`), ['query', 'wait', 'query', 'wait', 'query', 'wait', 'query', 'ok', 'query']);
});

test('QueryRetry: the fourth failure exhausts it until a snapshot succeeds', () => {
  assert.deepEqual(python(`
r = fresh()
for _ in range(4):
    out.append(r.next_action()); out.append(r.observe(None)); step(0.2)
out.append(r.next_action()); out.append(r.observe(None))
step(10); out.append(r.next_action())
out.append(r.observe([])); out.append(r.next_action())
`), ['query', 'wait', 'query', 'wait', 'query', 'wait', 'query', 'exhausted', 'exhausted', 'exhausted', 'exhausted', 'ok', 'query']);
});

test('QueryRetry: 5 s after the first failure it is exhausted with fewer than four queries', () => {
  assert.deepEqual(python(`
r = fresh()
out.append(r.observe(None)); step(2.5)
out.append(r.next_action()); out.append(r.observe(None)); step(2.4)
out.append(r.next_action()); step(0.1)
out.append(r.next_action())
r = fresh()
out.append(r.observe(None)); step(3.0); out.append(r.observe(None)); step(2.2)
out.append(r.observe(None))
`), ['wait', 'query', 'wait', 'query', 'exhausted', 'wait', 'wait', 'exhausted']);
});

test('QueryRetry law over seeded drivers: at most four spaced queries per failure streak, within 5 s', () => {
  assert.deepEqual(python(`
for seed in (1, 7, 705, 2026):
    rnd = random.Random(seed)
    for run in range(250):
        clock.t = 100.0; r = fresh(); streak = []
        for i in range(60):
            step(rnd.choice([0, 0.05, 0.1, 0.19, 0.2, 0.3, 0.5, 1.0, 1.2, 2.0]))
            # elapsed times compared at 1 us, as a float clock needs (0.6 - 0.4 < 0.2 in floats)
            expired = bool(streak) and (len(streak) >= 4 or round(clock.t - streak[0], 6) >= 5.0)
            expected = 'exhausted' if expired else ('query' if not streak or round(clock.t - streak[-1], 6) >= 0.2 else 'wait')
            action = r.next_action()
            if action != expected: out.append([seed, run, i, 'action', action, expected]); break
            if action == 'exhausted': break
            if action == 'wait': continue
            rows = rnd.choice([None, None, None, [], [(7, 7)]])
            if rows is None:
                streak.append(clock.t)
                want = 'exhausted' if len(streak) >= 4 or round(clock.t - streak[0], 6) >= 5.0 else 'wait'
            else:
                streak = []; want = 'ok'
            got = r.observe(rows)
            if got != want or len(streak) > 4: out.append([seed, run, i, 'observe', got, want]); break
            if got == 'exhausted': break
`), []);
});

// ---- real supervisor runs ---------------------------------------------------
function environment(extra = {}) {
  const home = mkdtempSync(path.join(scratch, 'run-'));
  return fixtureEnv({ HOME: home, PICSEE_HEAVY_LOCK: path.join(home, 'heavy.lock'), PICSEE_MDPRO_LOCK: path.join(home, 'mdpro.lock'),
    PICSEE_HEAVY_LOCK_WAIT_SECS: '15', ...extra });
}
function withPlan(env, tokens) {
  const file = path.join(env.HOME, 'query-plan');
  writeFileSync(file, tokens.join(','));
  env.PICSEE_HEAVY_FAULT_EXIT_QUERY_PLAN = file;
  return () => existsSync(`${file}.log`) ? readFileSync(`${file}.log`, 'utf8').trim().split('\n').filter(Boolean)
    .map(line => { const [token, at] = line.split(' '); return { token, at: Number(at) }; }) : [];
}
function start(args, env) {
  const child = spawn(lock, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  const lines = [];
  const record = chunk => { output += chunk; for (const line of String(chunk).split('\n')) if (line) lines.push({ line, at: Date.now() }); };
  child.stdout.on('data', record); child.stderr.on('data', record);
  const done = new Promise((resolve, reject) => { child.on('error', reject); child.on('close', (code, signal) => resolve({ code, signal, output, at: Date.now() })); });
  return { child, done, output: () => output, lines };
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(check, ms, message) {
  const until = Date.now() + ms;
  while (!check() && Date.now() < until) await pause(10);
  assert.ok(check(), message);
}
// A job that records its exit on the shared monotonic clock, in ms since the epoch, and exits.
const exitJob = file => ['python3', '-c', 'import sys,time; open(sys.argv[1],"w").write(f"{time.monotonic()} {time.time()*1000}")', file];
const readExit = file => { const [mono, wall] = readFileSync(file, 'utf8').split(' ').map(Number); return { mono, wall }; };

test('exitQueryOneFailureThenEmptyReleases', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, ['error', 'real']);
  const r = await start(['true'], env).done;
  assert.equal(r.code, 0, r.output);
  assert.doesNotMatch(r.output, /unknown cleanup/);
  assert.deepEqual(log().map(t => t.token), ['error', 'real']);
  assert.ok(log()[1].at - log()[0].at >= 0.15, 'the retry waits its interval');
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), false, 'shared lock released');
});

test('exitQueryTimeoutMalformedOrRepeatedErrorThenEmptyReleases', { timeout: 25000 }, async () => {
  for (const tokens of [['timeout', 'real'], ['malformed', 'real'], ['error', 'error', 'error', 'real']]) {
    const env = environment(), log = withPlan(env, tokens);
    const r = await start(['true'], env).done;
    assert.equal(r.code, 0, `${tokens}: ${r.output}`);
    assert.deepEqual(log().map(t => t.token), tokens);
    assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), false, `${tokens}: shared lock released`);
  }
});

test('exitQueryPermanentFailureIsUnknownAfterFourSpacedAttempts', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, Array(10).fill('error'));
  const r = await start(['true'], env).done;
  assert.equal(r.code, 70, r.output);
  assert.match(r.output, /unknown cleanup: process query failed/);
  const tokens = log();
  assert.deepEqual(tokens.map(t => t.token), ['error', 'error', 'error', 'error']);
  for (let i = 1; i < tokens.length; i++) assert.ok(tokens[i].at - tokens[i - 1].at >= 0.15, `attempt ${i + 1} waited its interval`);
  assert.ok(tokens.at(-1).at - tokens[0].at < 5, 'within the 5 s budget');
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), true, 'unknown cleanup keeps the shared lock');
});

test('exitQueryPermanentTimeoutIsBounded', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, Array(10).fill('timeout')), marker = path.join(env.HOME, 'exit');
  const r = await start(exitJob(marker), env).done;
  assert.equal(r.code, 70, r.output);
  assert.match(r.output, /unknown cleanup: process query failed/);
  const tokens = log();
  assert.ok(tokens.length >= 1 && tokens.length <= 4, JSON.stringify(tokens));
  assert.ok(tokens.every(t => t.token === 'timeout'));
  assert.ok(r.at - readExit(marker).wall < 8000, `bounded after the leader exit (${r.at - readExit(marker).wall} ms)`);
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), true);
});

test('exitQueryTokensAreConsumedOnlyAfterTheLeaderExits', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, ['real', 'real', 'real']), marker = path.join(env.HOME, 'exit');
  const job = ['python3', '-c', 'import sys,time; time.sleep(1); open(sys.argv[1],"w").write(f"{time.monotonic()} {time.time()*1000}")', marker];
  const r = await start(job, env).done;
  assert.equal(r.code, 0, r.output);
  const tokens = log();
  assert.ok(tokens.length >= 1, 'the post-exit query used the plan');
  assert.ok(tokens.every(t => t.at >= readExit(marker).mono), JSON.stringify({ tokens, exit: readExit(marker) }));
});

// The guardian probe must see guardian environments on Linux too: procps has
// no -E, so the Linux path lists PIDs with "ps -eo pid=,args=" and reads
// /proc/<pid>/environ. A procps-style shim and a fake /proc root stand in here.
test('guardianProbeReadsEnvironmentsUnderProcpsSemantics', { timeout: 10000 }, () => {
  const root = mkdtempSync(path.join(scratch, 'procps-')), proc = path.join(root, 'proc'), shim = path.join(root, 'ps');
  writeFileSync(shim, `#!/bin/sh
if [ "$*" = "-eo pid=,args=" ]; then
  echo "    1 /sbin/init"
  echo " 4242 /usr/bin/python3 /w/scripts/tdd/heavy-lock.py --guardian 5 6"
  echo " 4343 /usr/bin/python3 /w/scripts/tdd/heavy-lock.py --guardian 7 8"
  echo " 4444 /usr/bin/python3 /w/scripts/tdd/heavy-lock.py --guardian 9 10"
  echo " 4545 node -e x heavy-lock.py --guardian"
  exit 0
fi
echo "error: unsupported SysV option" >&2
exit 1
`, { mode: 0o755 });
  const environ = (pid, vars) => { mkdirSync(path.join(proc, pid), { recursive: true }); writeFileSync(path.join(proc, pid, 'environ'), vars.map(v => `${v}\0`).join('')); };
  environ('4242', ['HOME=/h', 'PICSEE_HEAVY_GUARDIAN_OWNER=/h/heavy.lock.guardian-a.owner', 'PICSEE_HEAVY_FAULT_EXIT_QUERY_PLAN=/h/query-plan']);
  environ('4343', ['HOME=/other', 'PICSEE_HEAVY_GUARDIAN_OWNER=/other/heavy.lock.guardian-b.owner']);
  environ('4545', ['PICSEE_HEAVY_GUARDIAN_OWNER=/h/heavy.lock.guardian-c.owner']);
  // 4444 exited between the listing and the read: it has no environ file.
  const all = guardianEnvironments({ platform: 'linux', ps: shim, procRoot: proc });
  assert.deepEqual(all.map(g => g.pid), [4242, 4343]);
  const ours = guardianEnvironments({ platform: 'linux', ps: shim, procRoot: proc, owner: '/h/' });
  assert.deepEqual(ours.map(g => g.pid), [4242]);
  assert.match(ours[0].env, /PICSEE_HEAVY_FAULT_EXIT_QUERY_PLAN=\/h\/query-plan/);
  assert.deepEqual(guardianEnvironments({ platform: 'linux', ps: shim, procRoot: proc, owner: '/other/' }).map(g => g.env.includes('PICSEE_HEAVY_FAULT_EXIT_QUERY_PLAN=')), [false]);
});

test('exitQueryPlanIsNotInheritedByJobOrGuardian', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, ['real']);
  // The probe waits (at most 5 s) for this run's guardian, found by its owner file under this HOME.
  const r = await start([process.execPath, probe, `${env.HOME}/`], env).done;
  assert.equal(r.code, 0, r.output);
  const seen = JSON.parse(r.output.split('\n').find(line => line.startsWith('{')));
  assert.equal(seen.job, false, 'job env');
  assert.ok(seen.guardians >= 1, 'a guardian was inspected');
  assert.equal(seen.leak, false, 'guardian env');
  assert.ok(log().length >= 1, 'the supervisor itself still used the plan');
});

test('exitQueryExhaustedPlanFallsBackToRealQueries', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, ['error']);
  const r = await start(['true'], env).done;
  assert.equal(r.code, 0, r.output);
  assert.deepEqual(log().map(t => t.token), ['error']);
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), false);
});

// The leader leaves a worker that replaces itself by forking every 0.1 s for
// 1.5 s; the first post-exit query fails. A competitor must stay blocked until
// the last member is gone.
test('exitQueryFailureThenSurvivorDrainsReforkingWorkerBeforeRelease', { timeout: 25000 }, async () => {
  const env = environment(), log = withPlan(env, ['error', 'real']);
  const marker = path.join(env.HOME, 'exit'), ended = path.join(env.HOME, 'worker-ended'), admitted = path.join(env.HOME, 'admitted');
  const job = ['python3', '-c', `import os,sys,time
marker, ended = sys.argv[1], sys.argv[2]
if os.fork() == 0:
    for fd in (0, 1, 2): os.close(fd)
    began = time.time()
    while time.time() - began < 1.5:
        time.sleep(0.1)
        if os.fork() != 0: os._exit(0)
    open(ended, 'w').write(str(time.time() * 1000)); os._exit(0)
open(marker, 'w').write(f"{time.monotonic()} {time.time()*1000}")`, marker, ended];
  const run = start(job, env);
  await waitFor(() => existsSync(marker), 15000, 'leader exited');
  const competitor = start(['python3', '-c', 'import sys,time; open(sys.argv[1],"w").write(str(time.time()*1000))', admitted], env);
  const [r, c] = await Promise.all([run.done, competitor.done]);
  assert.equal(r.code, 0, r.output);
  assert.equal(c.code, 0, c.output);
  assert.deepEqual(log().slice(0, 2).map(t => t.token), ['error', 'real']);
  assert.ok(existsSync(ended), 'the worker chain finished by itself');
  assert.ok(Number(readFileSync(admitted, 'utf8')) >= Number(readFileSync(ended, 'utf8')),
    'the competitor was admitted only after the last worker ended');
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), false);
});

test('exitQueryRetryNeverResetsTheDrainDeadline', { timeout: 25000 }, async () => {
  const env = environment({ PICSEE_HEAVY_LOCK_DRAIN_SECS: '2', PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: '0.2' });
  const log = withPlan(env, Array(20).fill(['real', 'error']).flat()), marker = path.join(env.HOME, 'exit');
  const job = ['python3', '-c', `import os,subprocess,sys,time
subprocess.Popen(['/bin/sleep', '30'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
open(sys.argv[1], 'w').write(f"{time.monotonic()} {time.time()*1000}")`, marker];
  const run = start(job, env);
  const r = await run.done;
  const drained = run.lines.find(l => /drain timed out/.test(l.line));
  assert.ok(drained, r.output);
  assert.ok(drained.at - readExit(marker).wall <= 4000, `drain expired ${drained.at - readExit(marker).wall} ms after the leader exit`);
  assert.ok(log().some(t => t.token === 'error'), 'failed queries were interleaved with the drain');
  assert.doesNotMatch(r.output, /unknown cleanup/);
});

test('exitQueryRetryStillHandlesCancellation', { timeout: 25000 }, async () => {
  const env = environment({ PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: '0.2' });
  const log = withPlan(env, Array(10).fill('timeout')), marker = path.join(env.HOME, 'exit');
  const run = start(exitJob(marker), env);
  await waitFor(() => existsSync(marker), 15000, 'leader exited');
  await waitFor(() => log().length >= 1, 5000, 'the retry started');
  const signalled = Date.now();
  run.child.kill('SIGTERM');
  const r = await run.done;
  assert.equal(r.signal, 'SIGTERM', r.output);
  assert.ok(r.at - signalled < 2500, `cancellation handled during the retry (${r.at - signalled} ms)`);
  const consumed = log().length;
  await pause(1500);
  assert.equal(log().length, consumed, 'no query after the run ended');
  assert.ok(consumed < 4, 'cancellation preempted the retry');
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), false, 'complete stop releases the shared lock');
});

test('exitQueryRetryStillHandlesTheExecutionDeadline', { timeout: 25000 }, async () => {
  const env = environment({ PICSEE_HEAVY_LOCK_EXEC_SECS: '1.5', PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: '0.2' });
  const log = withPlan(env, Array(10).fill('timeout')), marker = path.join(env.HOME, 'exit');
  const job = ['python3', '-c', 'import sys,time; time.sleep(0.5); open(sys.argv[1],"w").write(f"{time.monotonic()} {time.time()*1000}")', marker];
  const run = start(job, env);
  const r = await run.done;
  assert.equal(r.code, 124, r.output);
  const timedOut = run.lines.find(l => /execution timeout/.test(l.line));
  assert.ok(timedOut, r.output);
  assert.ok(timedOut.at - readExit(marker).wall < 2500, `deadline handled during the retry (${timedOut.at - readExit(marker).wall} ms after exit)`);
  const consumed = log().length;
  assert.ok(consumed >= 1 && consumed < 4, JSON.stringify(log()));
  await pause(1500);
  assert.equal(log().length, consumed, 'no query after the run ended');
  assert.equal(existsSync(env.PICSEE_MDPRO_LOCK), false);
});
