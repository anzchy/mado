import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { startGroupObservation, parsePsTargets } from './app-repeat-observer.mjs';
import { runProcessGroup } from './app-repeat-process.mjs';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function directory(t) {
  const dir = mkdtempSync(path.join(tmpdir(), 'i600-observer-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function records(log) {
  return log.split('\n').filter(line => line.startsWith('[i600.supervisor] '))
    .map(line => JSON.parse(line.slice('[i600.supervisor] '.length)));
}
async function until(check, milliseconds = 5000) {
  const end = Date.now() + milliseconds;
  while (!check() && Date.now() < end) await pause(20);
  assert.ok(check(), 'fixture must reach its expected state');
}
const running = pid => {
  try { process.kill(pid, 0); return true; } catch { return false; }
};
const env = { ...process.env, APP_REPEAT_OBSERVE: '1' };

test('target parsing restricts the owned process group and does not reuse replaced PIDs', () => {
  const first = parsePsTargets('101 42 S 0:00.02 /usr/bin/xctest\n102 77 R 0:04.21 /usr/bin/xctest\n103 42 S 0:00.01 /usr/bin/node\n', 42);
  assert.deepEqual(first, { status: 'ok', targets: [{ pid: 101, state: 'S', cpuTime: '0:00.02' }] });
  assert.deepEqual(parsePsTargets('104 42 T 0:00.03 /usr/bin/xctest\n', 42), {
    status: 'ok', targets: [{ pid: 104, state: 'T', cpuTime: '0:00.03' }]
  });
  assert.deepEqual(parsePsTargets('102 77 R 0:04.21 /usr/bin/xctest\n', 42), { status: 'target-unavailable', targets: [] });
  assert.deepEqual(parsePsTargets('not a ps row', 42), { status: 'ps-malformed', targets: [] });
  assert.deepEqual(parsePsTargets('', 42), { status: 'ps-malformed', targets: [] });
});

test('real stopped target has flat cumulative CPU while supervisor heartbeats continue', async t => {
  const dir = directory(t), logPath = path.join(dir, 'iter-01.log'), pidFile = path.join(dir, 'pid');
  let pid;
  t.after(() => { if (pid && running(pid)) { process.kill(pid, 'SIGCONT'); process.kill(pid, 'SIGKILL'); } });
  const code = `require('node:fs').writeFileSync(process.argv[1],String(process.pid));setTimeout(()=>process.exit(0),2400)`;
  const done = runProcessGroup({ command: process.execPath, args: ['-e', code, pidFile], env, logPath,
    deadline: Date.now() + 6000, observation: { targetName: path.basename(process.execPath) } });
  await until(() => existsSync(pidFile));
  pid = Number(readFileSync(pidFile, 'utf8'));
  const stoppedAt = Date.now();
  process.kill(pid, 'SIGSTOP');
  await pause(950);
  const resumedAt = Date.now();
  process.kill(pid, 'SIGCONT');
  const result = await done;
  assert.equal(result.status, 0);
  assert.equal(result.drained, true);
  const rows = records(readFileSync(logPath, 'utf8'));
  const during = rows.filter(row => row.event === 'heartbeat' && row.wallUnixMs > stoppedAt + 100 && row.wallUnixMs < resumedAt);
  assert.ok(during.length >= 2, 'independent default 250ms cadence continues inside stop');
  for (const row of during) {
    assert.ok(Number.isFinite(row.monotonicMs) && Number.isFinite(row.gapMs));
    assert.ok(row.gapMs < 750, 'supervisor did not stop with target');
    assert.ok(Number.isFinite(row.sampleAgeMs));
  }
  const samples = rows.filter(row => row.event === 'ps.end' && row.wallUnixMs > stoppedAt + 100 && row.wallUnixMs < resumedAt);
  const targets = samples.flatMap(row => row.targets).filter(target => target.pid === pid && target.state.startsWith('T'));
  assert.ok(targets.length >= 2, 'ps observed the same owned stopped PID more than once');
  assert.equal(new Set(targets.map(target => target.cpuTime)).size, 1);
  assert.ok(rows.some(row => row.event === 'ps.end' && row.wallUnixMs > resumedAt && row.targets.some(target => target.pid === pid && !target.state.startsWith('T'))));
  const frozen = readFileSync(logPath, 'utf8');
  await pause(300);
  assert.equal(readFileSync(logPath, 'utf8'), frozen, 'completion stops all writes');
  assert.ok(!running(pid));
});

test('real absent and replaced targets exclude an unrelated matching process', async t => {
  const dir = directory(t), logPath = path.join(dir, 'iter-02.log'), ids = path.join(dir, 'pids');
  const unrelated = spawn('/usr/bin/tail', ['-f', '/dev/null'], { stdio: 'ignore' });
  t.after(() => unrelated.kill('SIGKILL'));
  const code = `const fs=require('node:fs'),{spawn}=require('node:child_process');function one(){const c=spawn('/usr/bin/tail',['-f','/dev/null'],{stdio:'ignore'});fs.appendFileSync(process.argv[1],c.pid+'\\n');setTimeout(()=>c.kill('SIGTERM'),600);return c;}setTimeout(()=>one().on('close',()=>setTimeout(()=>one().on('close',()=>setTimeout(()=>process.exit(0),300)),300)),350);`;
  const result = await runProcessGroup({ command: process.execPath, args: ['-e', code, ids], env, logPath,
    deadline: Date.now() + 6000, observation: { targetName: 'tail', intervalMs: 75 } });
  assert.equal(result.status, 0);
  const owned = readFileSync(ids, 'utf8').trim().split('\n').map(Number);
  assert.equal(owned.length, 2);
  const rows = records(readFileSync(logPath, 'utf8')).filter(row => row.event === 'ps.end');
  assert.ok(rows.some(row => row.status === 'target-unavailable'));
  for (const pid of owned) assert.ok(rows.some(row => row.targets.some(target => target.pid === pid)));
  assert.ok(!rows.some(row => row.targets.some(target => target.pid === unrelated.pid)));
  const firstB = rows.findIndex(row => row.targets.some(target => target.pid === owned[1]));
  assert.ok(firstB >= 0);
  assert.ok(rows.slice(firstB).every(row => row.targets.every(target => target.pid !== owned[0])));
  for (const pid of owned) assert.ok(!running(pid));
});

for (const kind of ['exit-error', 'malformed']) test(`ps ${kind} is explicit and never invents target state`, async t => {
  const rows = [];
  const probeArgs = ['-e', kind === 'exit-error' ? 'process.exit(7)' : 'console.log("not a ps row")'];
  const monitor = startGroupObservation({ group: process.pid, write: row => rows.push(row), intervalMs: 40,
    probeCommand: process.execPath, probeArgs, probeTimeoutMs: 400 });
  t.after(() => monitor.stop());
  await pause(180);
  await monitor.stop();
  const samples = rows.filter(row => row.event === 'ps.end');
  assert.ok(samples.length > 0);
  assert.ok(samples.every(row => row.status === (kind === 'exit-error' ? 'ps-error' : 'ps-malformed')));
  assert.ok(samples.every(row => row.targets.length === 0));
  assert.ok(rows.some(row => row.event === 'heartbeat' && Number.isFinite(row.wallUnixMs)));
});

test('slow and hung ps never block heartbeat and are reaped before stable repeated stop', async t => {
  const dir = directory(t), pidFile = path.join(dir, 'probe-pid'), rows = [];
  const code = `require('node:fs').writeFileSync(process.argv[1],String(process.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000)`;
  const monitor = startGroupObservation({ group: process.pid, write: row => rows.push(row), intervalMs: 40,
    probeCommand: process.execPath, probeArgs: ['-e', code, pidFile], probeTimeoutMs: 220 });
  t.after(() => monitor.stop());
  await until(() => existsSync(pidFile));
  const pid = Number(readFileSync(pidFile, 'utf8'));
  t.after(() => { if (running(pid)) process.kill(pid, 'SIGKILL'); });
  await pause(320);
  const began = rows.filter(row => row.event === 'ps.begin');
  const beats = rows.filter(row => row.event === 'heartbeat' && row.inFlight);
  assert.ok(beats.length >= 4, 'probe cannot block independent heartbeat');
  assert.ok(beats.at(-1).sampleAgeMs > beats[0].sampleAgeMs);
  assert.equal(began.length, 1, 'at most one probe in flight before termination');
  const start = Date.now();
  await monitor.stop();
  await monitor.stop();
  assert.ok(Date.now() - start < 1500);
  assert.ok(!running(pid), 'probe was actually reaped');
  assert.ok(rows.some(row => row.event === 'ps.end' && row.status === 'ps-timeout'));
  const count = rows.length;
  await pause(120);
  assert.equal(rows.length, count);
});

for (const status of [0, 23]) test(`hung probe preserves command exit ${status} and bounded cleanup`, async t => {
  const dir = directory(t), logPath = path.join(dir, 'iter.log'), pidFile = path.join(dir, 'probe-pid');
  const code = `require('node:fs').writeFileSync(process.argv[1],String(process.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000)`;
  const start = Date.now();
  const result = await runProcessGroup({ command: process.execPath,
    args: ['-e', `setTimeout(()=>process.exit(${status}),350)`], env, logPath, deadline: Date.now() + 4000,
    observation: { intervalMs: 40, probeCommand: process.execPath, probeArgs: ['-e', code, pidFile], probeTimeoutMs: 2000 } });
  assert.equal(result.status, status);
  assert.equal(result.drained, true);
  assert.ok(Date.now() - start < 2000);
  assert.ok(existsSync(pidFile));
  assert.ok(!running(Number(readFileSync(pidFile, 'utf8'))));
  const log = readFileSync(logPath, 'utf8');
  assert.ok(records(log).some(row => row.event === 'ps.end' && row.status === 'ps-cancelled'));
  await pause(100);
  assert.equal(readFileSync(logPath, 'utf8'), log);
});

test('workflow enables observation in existing iteration artifact and CLI preserves exit code', async t => {
  const source = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  assert.match(source, /export APP_REPEAT_OBSERVE=1\s+node scripts\/ci\/app-repeat\.mjs/);
  assert.match(source, /name: app-repeat\s+path: \.build\/app-repeat/);
  const dir = directory(t), logPath = path.join(dir, 'iter-01.log');
  const child = spawn(process.execPath, [new URL('./app-repeat-process.mjs', import.meta.url).pathname,
    String(Date.now() + 4000), logPath, process.execPath, '-e', 'setTimeout(()=>process.exit(19),500)'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '', error = '';
  child.stdout.on('data', chunk => output += chunk); child.stderr.on('data', chunk => error += chunk);
  const result = await new Promise(resolve => child.on('close', (code, signal) => resolve({ code, signal })));
  assert.equal(result.code, 0, error);
  assert.equal(result.signal, null);
  assert.equal(JSON.parse(output).status, 19);
  assert.ok(records(readFileSync(logPath, 'utf8')).some(row => row.event === 'heartbeat'));
});

test('delayed successful ps reports latency while heartbeat stays independent', async t => {
  const rows = [];
  const monitor = startGroupObservation({ group: 42, write: row => rows.push(row), intervalMs: 40,
    probeCommand: process.execPath, probeArgs: ['-e', 'setTimeout(()=>console.log("101 42 S 0:00.02 /usr/bin/xctest"),350)'], probeTimeoutMs: 1000 });
  t.after(() => monitor.stop());
  await pause(500);
  await monitor.stop();
  const completed = rows.find(row => row.event === 'ps.end' && row.status === 'ok');
  assert.ok(completed, 'held boundary probe eventually completed successfully');
  assert.ok(completed.durationMs >= 300);
  assert.deepEqual(completed.targets, [{ pid: 101, state: 'S', cpuTime: '0:00.02' }]);
  const during = rows.filter(row => row.event === 'heartbeat' && row.monotonicMs < completed.monotonicMs);
  assert.ok(during.length >= 5);
  let active = 0;
  for (const row of rows) {
    if (row.event === 'ps.begin') active++;
    if (row.event === 'ps.end') active--;
    assert.ok(active >= 0 && active <= 1, 'probe lifecycle never overlaps');
  }
  assert.equal(active, 0);
});

test('interruption with observation stops heartbeat and reaps the owned target', async t => {
  const dir = directory(t), logPath = path.join(dir, 'interrupt.log'), pidFile = path.join(dir, 'pid');
  const code = "require('node:fs').writeFileSync(process.argv[1],String(process.pid));setInterval(()=>{},1000)";
  const supervisor = spawn(process.execPath, [new URL('./app-repeat-process.mjs', import.meta.url).pathname,
    String(Date.now() + 5000), logPath, process.execPath, '-e', code, pidFile], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => supervisor.kill('SIGKILL'));
  let output = '';
  supervisor.stdout.on('data', chunk => output += chunk);
  const closed = new Promise(resolve => supervisor.on('close', (code, signal) => resolve({ code, signal })));
  await until(() => existsSync(pidFile));
  await pause(300);
  supervisor.kill('SIGTERM');
  const ended = await closed;
  assert.equal(ended.code, 0);
  assert.equal(ended.signal, null);
  assert.equal(JSON.parse(output).status, 70);
  assert.equal(JSON.parse(output).drained, true);
  assert.ok(!running(Number(readFileSync(pidFile, 'utf8'))));
  const log = readFileSync(logPath, 'utf8');
  const observed = records(log);
  assert.ok(observed.some(row => row.event === 'heartbeat'));
  assert.equal(observed.at(-1).event, 'stopped');
  await pause(150);
  assert.equal(readFileSync(logPath, 'utf8'), log);
});
