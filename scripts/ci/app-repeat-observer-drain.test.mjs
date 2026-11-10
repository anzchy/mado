import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { startGroupObservation } from './app-repeat-observer.mjs';
import { runProcessGroup } from './app-repeat-process.mjs';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function neverClosingProbe() {
  const child = new EventEmitter();
  const signals = [];
  child.pid = 123456789; child.exitCode = null; child.signalCode = null;
  child.stdout = new PassThrough();
  child.kill = signal => { signals.push(signal); return true; };
  child.unref = () => {};
  return { child, signals };
}

test('unreaped probe has a bounded terminal drain and cannot emit after stop', async t => {
  const { child, signals } = neverClosingProbe(), rows = [];
  const monitor = startGroupObservation({ group: 42, write: row => rows.push(row), intervalMs: 10,
    spawnProbe: () => child, probeKillGraceMs: 20, probeDrainMs: 30 });
  t.after(async () => { child.emit('close', null); await monitor.stop(); });
  await pause(25);
  const result = await Promise.race([monitor.stop(), pause(200).then(() => null)]);
  assert.ok(result, 'stop must resolve even if ChildProcess close never arrives');
  assert.equal(result.drained, false);
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL']);
  assert.equal(rows.at(-1).event, 'stopped');
  assert.equal(rows.at(-1).status, 'ps-undrained');
  assert.equal(rows.at(-1).reaped, false);
  const terminal = JSON.stringify(rows);
  child.stdout.emit('data', Buffer.from('101 42 S 0:00.02 /usr/bin/xctest\n'));
  child.emit('close', 0);
  await pause(60);
  assert.equal(JSON.stringify(rows), terminal, 'late data/close cannot reopen a sealed observer');
  assert.deepEqual(await monitor.stop(), result);
});

for (const status of [0, 23]) test(`unreaped observer poisons group drain while preserving command status ${status}`, async t => {
  const dir = mkdtempSync(path.join(tmpdir(), 'i600-observer-drain-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const logPath = path.join(dir, 'iter.log');
  const { child } = neverClosingProbe();
  t.after(() => child.emit('close', null));
  const done = runProcessGroup({ command: process.execPath, args: ['-e', `setTimeout(()=>process.exit(${status}),80)`],
    env: { ...process.env, APP_REPEAT_OBSERVE: '1' }, logPath, deadline: Date.now() + 1500,
    observation: { spawnProbe: () => child, probeKillGraceMs: 20, probeDrainMs: 30 } });
  const result = await Promise.race([done, pause(600).then(() => null)]);
  assert.ok(result, 'observer drain must not outlive the cleared iteration deadline');
  assert.equal(result.status, status, 'retain actual command result separately');
  assert.equal(result.drained, false, 'existing repeat guard must refuse a clean next iteration');
  assert.equal(result.observerUndrained, true);
  const log = readFileSync(logPath, 'utf8');
  assert.match(log, /ps-undrained/);
  child.emit('close', 0);
  await pause(50);
  assert.equal(readFileSync(logPath, 'utf8'), log);
});
