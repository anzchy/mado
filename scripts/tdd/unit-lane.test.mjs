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
const short = { timeoutSeconds: 0.5, captureSeconds: 0.2, graceSeconds: 0.1, sampleSeconds: 0.1, snapshotSeconds: 0.05 };
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-bound-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'swift'), `#!${process.execPath}
const fs=require('node:fs'), cp=require('node:child_process');
fs.appendFileSync(process.env.ATTEMPTS,JSON.stringify(process.argv.slice(2))+'\\n');
if(process.env.PICSEE_HEAVY_LOCK_HELD!=='1')process.exit(23);
fs.writeFileSync(process.env.STARTED,String(Date.now()));
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
  const options = { cwd: f.dir, ...short, timeoutSeconds: 2, ...extra };
  return spawnSync(process.execPath, ['--input-type=module', '-e',
    `import {runUnit} from ${JSON.stringify(launcher)};process.exitCode=runUnit(${JSON.stringify(options)});`],
  { env: f.env, encoding: 'utf8', timeout: 20_000 });
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
  const holder = spawn('python3', ['-c', 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(3.2); open(sys.argv[3],"w").write(str(time.time()*1000)); f.close()', f.env.PICSEE_HEAVY_LOCK, ready, released]);
  const ended = new Promise(resolve => holder.on('close', resolve));
  t.after(() => { if (holder.exitCode === null) holder.kill('SIGKILL'); });
  for (let i = 0; i < 100 && !fs.existsSync(ready); i++) await delay(10);
  assert.ok(fs.existsSync(ready));
  const start = Date.now(), r = run(f);
  await ended;
  assert.equal(r.status, 0, r.stderr);
  assert.ok(Date.now() - start > short.timeoutSeconds * 1000);
  assert.ok(Date.now() - start > 2000, 'queue exceeds the actual two-second fixture run budget');
  assert.ok(fs.existsSync(f.env.STARTED), 'Swift ran after lock admission');
  assert.ok(Number(fs.readFileSync(f.env.STARTED, 'utf8')) >= Number(fs.readFileSync(released, 'utf8')));
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
  assert.equal(unit.coverageReportCommand, 'sh scripts/tdd/swift-lcov.sh');
  assert.equal(unit.coverageSummaryPath, 'coverage/lcov.info');
  assert.deepEqual(config.coverageThresholds, { lines: 100, functions: 100, branches: 0, statements: 100 });
  const lane = config.lanes.find(l => l.name === 'unit-watchdog-node');
  assert.deepEqual(lane.gateOn, ['manual']); assert.equal(lane.coverage, 'none');
  const r = spawnSync(process.execPath, [launcher, '--timeout-seconds', '0.01'], { encoding: 'utf8' });
  assert.equal(r.status, 64); assert.match(r.stderr, /usage/);
});
