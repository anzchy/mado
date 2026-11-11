import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { UNIT_LIMITS } from './unit-lane.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const launcher = path.join(root, 'scripts/tdd/unit-lane.mjs');
const lock = path.join(root, 'scripts/heavy-lock.sh');
const short = { timeoutSeconds: 0.5, captureSeconds: 0.2, graceSeconds: 0.1 };
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-bound-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
  fs.mkdirSync(path.join(dir, 'scripts/tdd'), { recursive: true });
  fs.copyFileSync(path.join(root, 'scripts/tdd/unit-locked.mjs'), path.join(dir, 'scripts/tdd/unit-locked.mjs'));
  fs.mkdirSync(path.join(dir, 'scripts/ci'), { recursive: true });
  fs.copyFileSync(path.join(root, 'scripts/ci/test-watchdog.mjs'), path.join(dir, 'scripts/ci/test-watchdog.mjs'));
  fs.writeFileSync(path.join(bin, 'swift'), `#!${process.execPath}
const fs=require('node:fs'), cp=require('node:child_process');
fs.appendFileSync(process.env.ATTEMPTS,JSON.stringify(process.argv.slice(2))+'\\n');
if(process.env.PICSEE_HEAVY_LOCK_HELD!=='1')process.exit(23);
fs.writeFileSync(process.env.STARTED,String(Date.now()));
if(process.env.ORDER)fs.appendFileSync(process.env.ORDER,'swift\\n');
if(process.env.MODE==='hang'){
 fs.writeFileSync(process.env.LEADER,String(process.pid));
 cp.spawn(process.execPath,['-e',"require('fs').writeFileSync(process.env.HELPER,String(process.pid));process.on('SIGTERM',()=>{});setTimeout(()=>process.exit(0),5000);setInterval(()=>{},100);"],{detached:true,stdio:'inherit'});
 setTimeout(()=>process.exit(0),5000);setInterval(()=>{},100);
}else{
 console.log(process.env.MARKER||'normal-output'); console.error('normal-stderr');
 console.log('✔ Test run with 7 tests in 1 suite passed after 0.001 seconds.');
 process.exit(Number(process.env.STATUS||0));
}
`, { mode: 0o755 });
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, PICSEE_HEAVY_LOCK: path.join(dir, 'heavy.lock'),
    PICSEE_MDPRO_LOCK: path.join(dir, 'shared.lock'), PICSEE_HEAVY_LOCK_HELD: '', MDPRO_HEAVY_LOCK_HELD: '',
    ATTEMPTS: path.join(dir, 'attempts'), STARTED: path.join(dir, 'started'), LEADER: path.join(dir, 'leader'), HELPER: path.join(dir, 'helper') };
  return { dir, env };
}
function run(f, extra = {}) {
  const { stderrFile, ...overrides } = extra;
  const options = { cwd: f.dir, ...short, timeoutSeconds: f.env.MODE === 'hang' ? 2 : 30, verifyCoverage: false, ...overrides };
  const fd = stderrFile ? fs.openSync(stderrFile, 'w') : undefined;
  let result;
  try {
    result = spawnSync(process.execPath, ['--input-type=module', '-e',
      `import {runUnit} from ${JSON.stringify(launcher)};process.exitCode=runUnit(${JSON.stringify(options)});`],
    { env: f.env, encoding: 'utf8', timeout: 90_000, stdio: stderrFile ? ['ignore', 'pipe', fd] : undefined });
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  if (stderrFile) result.stderr = fs.readFileSync(stderrFile, 'utf8');
  return result;
}
function captures(f) { return fs.readdirSync(path.join(f.dir, '.build/unit-watchdog')).map(name => path.join(f.dir, '.build/unit-watchdog', name)); }

test('full unit success and ordinary failure preserve output, status and single execution', t => {
  for (const status of [0, 1]) {
    const f = fixture(t); f.env.STATUS = String(status);
    const r = run(f);
    assert.equal(r.status, status, r.stderr);
    assert.match(r.stdout, /normal-output/); assert.match(r.stderr, /normal-stderr/);
    assert.deepEqual(fs.readFileSync(f.env.ATTEMPTS, 'utf8').trim().split('\n').map(JSON.parse),
      [['test', '--package-path', 'Packages/MadoKit', '--enable-code-coverage']]);
    assert.match(fs.readFileSync(path.join(captures(f)[0], 'test.log'), 'utf8'), /7 tests/);
  }
});

test('fresh profile cleanup, the unchanged Swift command and strict evaluation share one lock admission', t => {
  const f = fixture(t);
  f.env.ORDER = path.join(f.dir, 'order');
  for (const [name, marker] of [['package-coverage-clear.mjs', 'clear'], ['package-coverage-local.mjs', 'evaluate']]) {
    fs.writeFileSync(path.join(f.dir, 'scripts/ci', name),
      `import fs from 'node:fs';if(process.env.PICSEE_HEAVY_LOCK_HELD!=='1')process.exit(23);fs.appendFileSync(process.env.ORDER,${JSON.stringify(marker + '\n')});`);
  }
  const r = run(f, { verifyCoverage: true });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(fs.readFileSync(f.env.ORDER, 'utf8').trim().split('\n'), ['clear', 'swift', 'evaluate']);
  assert.deepEqual(fs.readFileSync(f.env.ATTEMPTS, 'utf8').trim().split('\n').map(JSON.parse),
    [['test', '--package-path', 'Packages/MadoKit', '--enable-code-coverage']]);
});

test('coverage rejection has a distinct status after the Swift tests pass', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.dir, 'scripts/ci/package-coverage-clear.mjs'), '');
  fs.writeFileSync(path.join(f.dir, 'scripts/ci/package-coverage-local.mjs'),
    "console.log('Coverage gate: FAIL (invalid evidence)'); process.exitCode = 1;\n");
  const r = run(f, { verifyCoverage: true });
  assert.equal(r.status, 65, r.stderr + r.stdout);
  assert.match(r.stdout, /Test run with 7 tests/);
  assert.match(r.stdout, /Coverage gate: FAIL/);
  assert.match(r.stderr, /coverage verification failed after Swift tests passed/i);
});

test('hung detached helper exits 124, keeps diagnostics and releases the lock', async t => {
  const f = fixture(t); f.env.MODE = 'hang';
  const started = Date.now(), r = run(f);
  assert.equal(r.status, 124, r.stderr);
  assert.ok(Date.now() - started < 15_000, 'bounded test run and cleanup');
  assert.match(r.stderr, /deadline passed/); assert.match(r.stderr, /exit 124 \(timed out\)/);
  const dir = captures(f)[0];
  assert.match(fs.readFileSync(path.join(dir, 'stacks/ps.txt'), 'utf8'), /PID PPID %CPU/);
  const pids = [f.env.LEADER, f.env.HELPER].map(file => Number(fs.readFileSync(file, 'utf8')));
  for (let i = 0; i < 30 && pids.some(alive); i++) await delay(50);
  assert.deepEqual(pids.map(alive), [false, false], 'leader and independent helper are dead');
  assert.equal(fs.readFileSync(f.env.ATTEMPTS, 'utf8').trim().split('\n').length, 1);
  const follower = spawnSync(lock, [process.execPath, '-e', "console.log('admitted')"], { env: f.env, encoding: 'utf8', timeout: 3000 });
  assert.equal(follower.status, 0, follower.stderr); assert.match(follower.stdout, /admitted/);
});

test('queue delay does not consume the post-admission execution deadline', async t => {
  const f = fixture(t), ready = path.join(f.dir, 'ready'), released = path.join(f.dir, 'released');
  const stderrFile = path.join(f.dir, 'queued-stderr'), proofFile = path.join(f.dir, 'queue-proof.json');
  const queueBudgetSeconds = 30, queueHoldSeconds = 32;
  const holder = spawn('python3', ['-c', `
import fcntl,json,os,sys,time
lock_path,ready_path,released_path,stderr_path,proof_path,started_path=sys.argv[1:7]
budget,hold=float(sys.argv[7]),float(sys.argv[8])
with open(lock_path,'w') as owner:
 fcntl.flock(owner,fcntl.LOCK_EX)
 open(ready_path,'w').close()
 marker='[heavy-lock] waiting for '+lock_path
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  try:
   with open(stderr_path) as log: waiting=marker in log.read()
  except FileNotFoundError: waiting=False
  if waiting:
   assert not os.path.exists(started_path),'Swift started while the holder still owns the lock'
   queued_wall_ms=time.time()*1000
   queued_ns=time.monotonic_ns()
   time.sleep(hold)
   assert not os.path.exists(started_path),'Swift started before lock release'
   released_ns=time.monotonic_ns()
   with open(proof_path,'w') as proof:
    json.dump({'queuedMonotonicNs':str(queued_ns),'releasedMonotonicNs':str(released_ns),
      'queuedWallMs':queued_wall_ms,'executionBudgetSeconds':budget,'holdSeconds':hold,
      'waitingMarker':marker,'startedBeforeRelease':False},proof)
   with open(released_path,'w') as release: release.write(str(time.time()*1000))
   break
  time.sleep(.02)
 else: raise RuntimeError('actual heavy-lock waiting marker was not observed within twenty seconds')
`, f.env.PICSEE_HEAVY_LOCK, ready, released, stderrFile, proofFile, f.env.STARTED,
  String(queueBudgetSeconds), String(queueHoldSeconds)]);
  let holderOutput = '';
  holder.stderr.on('data', chunk => { holderOutput += chunk; });
  const ended = new Promise(resolve => holder.on('close', resolve));
  t.after(() => { if (holder.exitCode === null) holder.kill('SIGKILL'); });
  try {
    for (let i = 0; i < 2000 && !fs.existsSync(ready); i++) await delay(10);
    assert.ok(fs.existsSync(ready));
    const start = Date.now(), r = run(f, { stderrFile, timeoutSeconds: queueBudgetSeconds });
    assert.equal(await ended, 0, holderOutput);
    assert.equal(r.status, 0, r.stderr);
    assert.ok(Date.now() - start > short.timeoutSeconds * 1000);
    assert.ok(Date.now() - start > 2000, 'queue exceeds the actual two-second fixture run budget');
    assert.ok(fs.existsSync(f.env.STARTED), 'Swift ran after lock admission');
    assert.ok(Number(fs.readFileSync(f.env.STARTED, 'utf8')) >= Number(fs.readFileSync(released, 'utf8')));
    const proof = JSON.parse(fs.readFileSync(proofFile, 'utf8'));
    assert.equal(proof.executionBudgetSeconds, queueBudgetSeconds);
    assert.equal(proof.holdSeconds, queueHoldSeconds);
    assert.equal(proof.startedBeforeRelease, false);
    assert.equal(proof.waitingMarker, `[heavy-lock] waiting for ${f.env.PICSEE_HEAVY_LOCK}`);
    assert.ok(BigInt(proof.releasedMonotonicNs) - BigInt(proof.queuedMonotonicNs) > BigInt(queueBudgetSeconds) * 1_000_000_000n,
      'observed lock blocking exceeds the actual thirty-second execution budget');
    assert.match(r.stderr, /deadline in 30 s/);
  } finally {
    if (holder.exitCode === null) holder.kill('SIGKILL');
    await ended;
  }
});

test('consecutive invocations keep distinct logs and earlier diagnostic evidence', t => {
  const f = fixture(t); f.env.MARKER = 'first-run';
  assert.equal(run(f).status, 0);
  assert.ok(fs.existsSync(path.join(f.dir, '.build/unit-watchdog')), 'persistent captures created');
  const first = captures(f)[0], before = fs.readFileSync(path.join(first, 'test.log'));
  fs.mkdirSync(path.join(first, 'stacks')); fs.writeFileSync(path.join(first, 'stacks/marker'), 'retained');
  f.env.MARKER = 'second-run'; assert.equal(run(f).status, 0);
  const dirs = captures(f); assert.equal(dirs.length, 2);
  assert.ok(dirs.every(dir => path.basename(dir).startsWith('run-')));
  const second = dirs.find(dir => dir !== first); assert.ok(second);
  assert.deepEqual(fs.readFileSync(path.join(first, 'test.log')), before);
  assert.equal(fs.readFileSync(path.join(first, 'stacks/marker'), 'utf8'), 'retained');
  assert.match(fs.readFileSync(path.join(second, 'test.log'), 'utf8'), /second-run/);
});

test('guardian fixes the production deadline and preserves coverage policy', () => {
  const config = JSON.parse(fs.readFileSync(path.join(root, '.claude/tdd-guardian/config.json'), 'utf8'));
  const unit = config.lanes.find(l => l.name === 'unit');
  assert.equal(unit.command, 'node scripts/tdd/unit-lane.mjs');
  assert.equal(unit.timeoutMs, 9000000);
  assert.deepEqual(UNIT_LIMITS, { timeoutSeconds: 600, captureSeconds: 90, graceSeconds: 15, lockWaitSeconds: 7200 });
  assert.equal(unit.coverageReportCommand, 'node scripts/ci/package-coverage-local.mjs --reuse');
  assert.equal(unit.coverageSummaryPath, 'coverage/package-eligible.lcov');
  assert.deepEqual(config.coverageThresholds, { lines: 100, functions: 100, branches: 0, statements: 100 });
  const lane = config.lanes.find(l => l.name === 'unit-watchdog-node');
  assert.deepEqual(lane.gateOn, ['manual']); assert.equal(lane.coverage, 'none');
  const r = spawnSync(process.execPath, [launcher, '--timeout-seconds', '0.01'], { encoding: 'utf8' });
  assert.equal(r.status, 64); assert.match(r.stderr, /usage/);
});

// M1 uses independent, long-lived external workloads. Its timing inputs do not
// depend on the legacy startup/hang fixture budgets above.
const m1Watchdog = path.join(root, 'scripts/ci/test-watchdog.mjs');
const m1SafetyMs = 45_000;
const m1SignalBoundMs = 8_000;

async function m1Until(predicate, message, timeoutMs = 20_000) {
  const until = Date.now() + timeoutMs;
  while (!predicate() && Date.now() < until) await delay(20);
  assert.ok(predicate(), message);
}

function m1Fixture(mode = 'ordinary') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-interrupt-'));
  const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
  const files = Object.fromEntries(['owned', 'leaderReady', 'helperReady', 'diagnostic', 'entered', 'snapshots', 'leave', 'admission']
    .map(name => [name, path.join(dir, name)]));
  const writeExe = (name, source) => fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n${source}`, { mode: 0o755 });
  writeExe('i632-M1-owned-swift', `
const fs=require('node:fs'),cp=require('node:child_process');
for(const sig of ['SIGINT','SIGTERM','SIGHUP'])process.on(sig,()=>{});
const helper=cp.spawn(process.execPath,['-e',
 "const fs=require('node:fs');for(const sig of ['SIGINT','SIGTERM','SIGHUP'])process.on(sig,()=>{});fs.writeFileSync(process.env.M1_HELPER_READY,'ready');setTimeout(()=>process.exit(0),${m1SafetyMs});setInterval(()=>{},100);/* i632-M1-owned-helper */"],{detached:true,stdio:'inherit'});
fs.writeFileSync(process.env.M1_OWNED,JSON.stringify({leader:process.pid,helper:helper.pid,watchdog:process.ppid}));
fs.writeFileSync(process.env.M1_LEADER_READY,'ready');
console.log('i632-M1 owned workload ready');
setTimeout(()=>process.exit(0),${m1SafetyMs});
setInterval(()=>{if(fs.existsSync(process.env.M1_LEAVE))process.exit(0);},20);
`);
  const block = `
for(const sig of ['SIGINT','SIGTERM','SIGHUP'])process.on(sig,()=>{});
fs.writeFileSync(process.env.M1_DIAGNOSTIC,String(process.pid));
fs.writeFileSync(process.env.M1_ENTERED,'entered');
setTimeout(()=>process.exit(0),${m1SafetyMs});setInterval(()=>{},100);
`;
  writeExe('sample', `const fs=require('node:fs');${block}`);
  writeExe('ps', `
const fs=require('node:fs'),cp=require('node:child_process'),args=process.argv.slice(2);
if(args.includes('-A')){
 const attempts=process.env.M1_SNAPSHOTS+'.attempts';
 const attempt=Number(fs.existsSync(attempts)?fs.readFileSync(attempts,'utf8'):0)+1;
 fs.writeFileSync(attempts,String(attempt));
 if(process.env.M1_MODE==='snapshot'&&attempt===1){${block}}
 else {
  const r=cp.spawnSync('/bin/ps',args,{encoding:'utf8',maxBuffer:64*1024*1024});
  process.stdout.write(r.stdout||'',error=>{
   if(error||r.error||r.status!==0)return;
   const count=Number(fs.existsSync(process.env.M1_SNAPSHOTS)?fs.readFileSync(process.env.M1_SNAPSHOTS,'utf8'):0)+1;
   const proof={status:r.status,error:null,stdout:r.stdout,bytes:Buffer.byteLength(r.stdout),finalRecord:r.stdout.trimEnd().split('\\n').at(-1)};
   const proofFile=process.env.M1_SNAPSHOTS+'.proof-'+count;
   fs.writeFileSync(proofFile+'.tmp',JSON.stringify(proof));fs.renameSync(proofFile+'.tmp',proofFile);
   fs.writeFileSync(process.env.M1_SNAPSHOTS+'.tmp',String(count));fs.renameSync(process.env.M1_SNAPSHOTS+'.tmp',process.env.M1_SNAPSHOTS);
  });
  process.stderr.write(r.stderr||'');process.exitCode=r.status??1;
 }
}else{const r=cp.spawnSync('/bin/ps',args,{encoding:'utf8',maxBuffer:64*1024*1024});process.stdout.write(r.stdout||'');process.stderr.write(r.stderr||'');process.exitCode=r.status??1;}
`);
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, M1_MODE: mode,
    PICSEE_HEAVY_LOCK: path.join(dir, 'heavy.lock'), PICSEE_MDPRO_LOCK: path.join(dir, 'shared.lock'),
    PICSEE_HEAVY_LOCK_HELD: '', MDPRO_HEAVY_LOCK_HELD: '', PICSEE_HEAVY_LOCK_WAIT_SECS: '7200',
    M1_OWNED: files.owned, M1_LEADER_READY: files.leaderReady, M1_HELPER_READY: files.helperReady,
    M1_DIAGNOSTIC: files.diagnostic, M1_ENTERED: files.entered, M1_SNAPSHOTS: files.snapshots, M1_LEAVE: files.leave,
    PICSEE_WATCHDOG_NO_SPINDUMP: '1' };
  return { dir, bin, files, env, jobs: [] };
}

function m1Launch(f, executable, args) {
  const child = spawn(executable, args, { cwd: f.dir, env: f.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const job = { child, output: '' };
  for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { job.output += chunk; });
  job.exited = new Promise(resolve => {
    child.once('error', error => resolve({ code: 127, error }));
    child.once('exit', (code, signal) => resolve({ code, signal }));
  });
  job.closed = new Promise(resolve => child.once('close', resolve));
  f.jobs.push(job);
  return job;
}

function m1Status(result) { return result.code ?? (128 + os.constants.signals[result.signal]); }
function m1Owned(f) { return JSON.parse(fs.readFileSync(f.files.owned, 'utf8')); }
function m1Pids(f) {
  const owned = fs.existsSync(f.files.owned) ? m1Owned(f) : {};
  const result = [owned.leader, owned.helper, owned.watchdog];
  if (fs.existsSync(f.files.diagnostic)) result.push(Number(fs.readFileSync(f.files.diagnostic, 'utf8')));
  return result.filter(pid => Number.isSafeInteger(pid) && pid > 0);
}
function m1Kill(pid) {
  try { process.kill(-pid, 'SIGKILL'); } catch { /* already gone or not a group leader */ }
  try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ }
}
async function m1Finally(f) {
  // This runs after admission-time evidence and assertions, even on the expected
  // RED, before the test process can release its outer machine-wide lock.
  for (const pid of m1Pids(f)) m1Kill(pid);
  for (const job of f.jobs) m1Kill(job.child.pid);
  await Promise.all(f.jobs.map(job => job.closed));
  for (let n = 0; n < 100 && m1Pids(f).some(alive); n++) await delay(20);
  const survivors = m1Pids(f).filter(alive);
  fs.rmSync(f.dir, { recursive: true, force: true });
  assert.deepEqual(survivors, [], 'finally reaps every owned fake worker, including on RED');
}

function m1WatchArgs(f, mode = 'ordinary') {
  return [m1Watchdog, '--out', path.join(f.dir, 'capture'), '--timeout-seconds', mode === 'capture' ? '5' : '35',
    '--capture-seconds', '90', '--grace-seconds', '15', '--sample-seconds', '1',
    '--snapshot-seconds', mode === 'snapshot' || mode === 'orphan' ? '1' : '30',
    '--no-spindump', '--match', 'i632-M1-owned', '--', path.join(f.bin, 'i632-M1-owned-swift')];
}

async function m1Ready(f) {
  await m1Until(() => fs.existsSync(f.files.leaderReady) && fs.existsSync(f.files.helperReady), 'both owned workers become ready');
}

async function m1VerifiedSnapshot(f) {
  let proof, helperRow;
  await m1Until(() => {
    if (!fs.existsSync(f.files.snapshots)) return false;
    const completed = Number(fs.readFileSync(f.files.snapshots, 'utf8'));
    if (completed < 2) return false;
    // A newer successful snapshot means the watchdog finished consuming this
    // earlier one. The proof is published atomically after stdout has flushed.
    const file = `${f.files.snapshots}.proof-${completed - 1}`;
    if (!fs.existsSync(file)) return false;
    proof = JSON.parse(fs.readFileSync(file, 'utf8'));
    const helper = m1Owned(f).helper;
    helperRow = proof.stdout.split('\n').find(line => new RegExp(`^\\s*${helper}\\s+\\d+\\s+`).test(line));
    return Boolean(helperRow?.includes('i632-M1-owned-helper'));
  }, 'an earlier completed snapshot contains the actual detached helper and its command');
  assert.equal(proof.status, 0);
  assert.equal(proof.error, null);
  assert.equal(Buffer.byteLength(proof.stdout), proof.bytes, 'snapshot proof retains every captured byte');
  assert.ok(proof.stdout.endsWith('\n'), 'snapshot retains the final complete process record');
  assert.equal(proof.stdout.trimEnd().split('\n').at(-1), proof.finalRecord);
  assert.match(proof.finalRecord, /^\s*\d+\s+\d+\s+\S/);
  assert.ok(helperRow.trimEnd().endsWith('/* i632-M1-owned-helper */'), 'the helper command tail is present, not truncated');
  console.log('i632M1 complete snapshot proof', JSON.stringify({ bytes: proof.bytes,
    finalRecord: proof.finalRecord, helperPID: m1Owned(f).helper, helperCommand: helperRow }));
}

async function m1Follower(f) {
  const owned = m1Owned(f);
  const pids = [owned.leader, owned.helper];
  if (fs.existsSync(f.files.diagnostic)) pids.push(Number(fs.readFileSync(f.files.diagnostic, 'utf8')));
  const source = `const fs=require('node:fs');const pids=${JSON.stringify(pids)};fs.writeFileSync(${JSON.stringify(f.files.admission)},JSON.stringify({at:Date.now(),alive:pids.map(pid=>{try{process.kill(pid,0);return true;}catch{return false;}})}));`;
  const follower = m1Launch(f, lock, [process.execPath, '-e', source]);
  await m1Until(() => /\[heavy-lock\] waiting for/.test(follower.output), 'follower queues behind the interrupted workload');
  return follower;
}

async function m1Admission(f, follower, signalledAt) {
  await m1Until(() => fs.existsSync(f.files.admission), 'follower is admitted after interruption', 15_000);
  const admission = JSON.parse(fs.readFileSync(f.files.admission, 'utf8'));
  assert.deepEqual(admission.alive, admission.alive.map(() => false), 'owned workers are already dead when follower is admitted');
  assert.ok(admission.at - signalledAt < m1SignalBoundMs, 'signal-to-follower admission stays strictly below eight seconds');
  assert.equal(m1Status(await follower.exited), 0, follower.output);
}

test('i632M1 heavy-lock TERM kills owned work before follower admission', async () => {
  const f = m1Fixture();
  try {
    const leader = m1Launch(f, lock, [process.execPath, ...m1WatchArgs(f)]);
    await m1Ready(f);
    const follower = await m1Follower(f), signalledAt = Date.now();
    leader.child.kill('SIGTERM');
    await m1Admission(f, follower, signalledAt);
    assert.equal(m1Status(await leader.exited), 143, leader.output);
  } finally { await m1Finally(f); }
});

test('i632M1 direct INT TERM HUP and repeated signals preserve first status and unrelated sentinel', async () => {
  for (const [signal, expected, repeat] of [['SIGINT', 130, false], ['SIGTERM', 143, false], ['SIGHUP', 129, false], ['SIGINT', 130, true]]) {
    const f = m1Fixture();
    try {
      const sentinel = m1Launch(f, process.execPath, ['-e', `setTimeout(()=>process.exit(0),${m1SafetyMs});setInterval(()=>{},100);/* unrelated sentinel */`]);
      const leader = m1Launch(f, lock, [process.execPath, ...m1WatchArgs(f)]);
      await m1Ready(f);
      const follower = await m1Follower(f), signalledAt = Date.now(), pid = m1Owned(f).watchdog;
      process.kill(pid, signal);
      if (repeat) { await delay(100); try { process.kill(pid, 'SIGTERM'); } catch { /* original RED watchdog already exited */ } }
      await m1Admission(f, follower, signalledAt);
      assert.equal(m1Status(await leader.exited), expected, leader.output);
      assert.equal(alive(sentinel.child.pid), true, 'unrelated process survives owned-tree cleanup');
    } finally { await m1Finally(f); }
  }
});

test('i632M1 interruption stays responsive during blocked capture and snapshot subprocesses', async () => {
  for (const mode of ['capture', 'snapshot']) {
    const f = m1Fixture(mode);
    try {
      const leader = m1Launch(f, lock, [process.execPath, ...m1WatchArgs(f, mode)]);
      await m1Ready(f);
      await m1Until(() => fs.existsSync(f.files.entered), `real external ${mode} tool blocks`);
      const follower = await m1Follower(f), signalledAt = Date.now();
      leader.child.kill('SIGTERM');
      await m1Admission(f, follower, signalledAt);
      assert.equal(m1Status(await leader.exited), 143, leader.output);
      assert.match(leader.output, new RegExp(`watchdog: exit ${mode === 'capture' ? 124 : 143}(?:\\s|$)`),
        'watchdog keeps committed timeout status independently of the interrupted heavy-lock parent');
      assert.ok(fs.existsSync(path.join(f.dir, 'capture/test.log')), 'partial command evidence is retained');
    } finally { await m1Finally(f); }
  }
});

test('i632M1 a committed deadline keeps 124 when interrupted during capture', async () => {
  const f = m1Fixture('capture');
  try {
    // Direct watchdog exit (not inherited pipe close) gives an assertion RED
    // promptly even when the old synchronous diagnostic child survives it.
    const job = m1Launch(f, process.execPath, m1WatchArgs(f, 'capture'));
    await m1Ready(f);
    await m1Until(() => fs.existsSync(f.files.entered), 'deadline has entered actual blocked diagnostics');
    const signalledAt = Date.now();
    job.child.kill('SIGTERM');
    const result = await job.exited;
    assert.equal(m1Status(result), 124, job.output);
    assert.ok(Date.now() - signalledAt < m1SignalBoundMs, 'committed-timeout interrupt cleanup stays below eight seconds');
    const pids = m1Pids(f).filter(pid => pid !== job.child.pid);
    assert.deepEqual(pids.map(alive), pids.map(() => false), 'timeout and interrupt finish all owned work before watchdog exit');
  } finally { await m1Finally(f); }
});

test('i632M1 interrupt cleans a verified detached helper after its leader exits', async () => {
  const f = m1Fixture('orphan');
  try {
    const leader = m1Launch(f, lock, [process.execPath, ...m1WatchArgs(f, 'orphan')]);
    await m1Ready(f);
    await m1Until(() => fs.existsSync(f.files.snapshots) && Number(fs.readFileSync(f.files.snapshots, 'utf8')) >= 2,
      'a completed earlier real snapshot established helper ownership');
    await m1VerifiedSnapshot(f);
    fs.writeFileSync(f.files.leave, 'leave');
    await m1Until(() => !alive(m1Owned(f).leader), 'workload leader exits before interruption');
    assert.equal(alive(m1Owned(f).helper), true, 'detached helper remains live before interruption');
    const follower = await m1Follower(f), signalledAt = Date.now();
    process.kill(m1Owned(f).watchdog, 'SIGTERM');
    await m1Admission(f, follower, signalledAt);
    assert.equal(m1Status(await leader.exited), 143, leader.output);
  } finally { await m1Finally(f); }
});

test('i632M1 fallback validates a known orphan when the full interrupt process query fails', async () => {
  const f = m1Fixture('orphan');
  try {
    const failedQuery = path.join(f.dir, 'failed-full-query');
    f.env.M1_FAILED_QUERY = failedQuery;
    const processAdapter = path.join(f.bin, 'interrupt-process-adapter');
    // Only the interrupt collector's external /bin/ps invocation is redirected.
    // Real snapshots still establish ownership; per-PID queries use real ps.
    fs.writeFileSync(processAdapter, '#!/bin/sh\nif [ "$1" = "-A" ]; then\n  printf "failed\\n" > "$M1_FAILED_QUERY"\n  echo "full process query unavailable" >&2\n  exit 1\nfi\nexec /bin/ps "$@"\n', { mode: 0o755 });
    const watched = path.join(f.dir, 'actual-watch-with-process-adapter.mjs');
    fs.writeFileSync(watched, `
import { watch, parseArgs, defaultRun } from ${JSON.stringify(m1Watchdog)};
const options=parseArgs(process.argv.slice(2));
process.exitCode=await watch(options,{run:(command,args,opts)=>defaultRun(command==='/bin/ps'?${JSON.stringify(processAdapter)}:command,args,opts)});
`);
    const sentinel = m1Launch(f, process.execPath, ['-e', `setTimeout(()=>process.exit(0),${m1SafetyMs});setInterval(()=>{},100);/* unrelated fallback sentinel */`]);
    const leader = m1Launch(f, lock, [process.execPath, watched, ...m1WatchArgs(f, 'orphan').slice(1)]);
    await m1Ready(f);
    await m1Until(() => fs.existsSync(f.files.snapshots) && Number(fs.readFileSync(f.files.snapshots, 'utf8')) >= 2,
      'completed real snapshots establish detached-helper identity before query failure');
    await m1VerifiedSnapshot(f);
    fs.writeFileSync(f.files.leave, 'leave');
    await m1Until(() => !alive(m1Owned(f).leader), 'leader exits before the full ownership query fails');
    assert.equal(alive(m1Owned(f).helper), true, 'known orphan is live before external interruption');
    assert.equal(alive(sentinel.child.pid), true, 'unrelated sentinel is live before external interruption');
    const follower = await m1Follower(f), signalledAt = Date.now();
    leader.child.kill('SIGTERM');
    await m1Until(() => fs.existsSync(failedQuery), 'real external full ownership query fails with evidence');
    await m1Admission(f, follower, signalledAt);
    assert.equal(m1Status(await leader.exited), 143, leader.output);
    assert.match(leader.output, /watchdog: exit 143(?:\s|$)/);
    assert.equal(alive(sentinel.child.pid), true, 'fallback validation does not kill unrelated work');
  } finally { await m1Finally(f); }
});
