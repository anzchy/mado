// #705: fixture PID files must be published atomically and read only when they
// hold a complete positive integer; cleanup must never signal 0 or an invalid
// PID (process.kill(0, …) targets the test runner's own process group).
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { publishedPID, publishedPIDList, publishedPIDLines, publishSource, publishListSource, safeKill, pidAlive } from './fixture-pid.mjs';

const MAX = 2147483647;
function scratch(t) { const dir = mkdtempSync(path.join(tmpdir(), 'i705-pid-')); t.after(() => rmSync(dir, { recursive: true, force: true })); return dir; }
function withContent(dir, content) { const file = path.join(dir, `f${Math.random().toString(36).slice(2)}`); if (content !== null) writeFileSync(file, content); return file; }
const canonical = text => { const s = text.trim(); return /^[1-9][0-9]*$/.test(s) && Number(s) <= MAX ? Number(s) : null; };
function mulberry32(seed) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}

test('publishedPID accepts only a complete positive integer', t => {
  const dir = scratch(t);
  for (const [content, expected] of [[null, null], ['', null], ['\n', null], ['   ', null], ['12a', null], ['0', null], ['00', null],
    ['012', null], ['-5', null], ['+5', null], ['1.5', null], ['1e3', null], ['0x10', null], ['12 34', null], ['garbage', null],
    ['2147483648', null], ['99999999999999999999', null], ['12345\n', 12345], ['12345', 12345], [' 7 \n', 7], ['2147483647', MAX]])
    assert.equal(publishedPID(withContent(dir, content)), expected, JSON.stringify(content));
  assert.equal(publishedPID(dir), null, 'a directory is not a PID file');
});

test('publishedPID law: canonical round-trip, everything else null', t => {
  const dir = scratch(t), alphabet = '0123456789 -+.\nax';
  for (const seed of [1, 7, 705]) {
    const random = mulberry32(seed);
    for (let i = 0; i < 300; i++) {
      const n = 1 + Math.floor(random() * (MAX - 1));
      assert.equal(publishedPID(withContent(dir, String(n))), n, `seed ${seed}/${i}: String(${n})`);
      let text = ''; for (let k = Math.floor(random() * 8); k > 0; k--) text += alphabet[Math.floor(random() * alphabet.length)];
      assert.equal(publishedPID(withContent(dir, text)), canonical(text), `seed ${seed}/${i}: ${JSON.stringify(text)}`);
    }
  }
});

test('publishedPIDList returns the list only when the whole JSON manifest is valid', t => {
  const dir = scratch(t);
  for (const [content, expected] of [[null, null], ['', null], ['[', null], ['[123,', null], ['[123,45', null], ['[0]', null], ['[-1]', null],
    ['[1,"2"]', null], ['[1.5]', null], ['{}', null], ['12', null], ['[2147483648]', null], ['[]', []], ['[123,456]', [123, 456]]])
    assert.deepEqual(publishedPIDList(withContent(dir, content)), expected, JSON.stringify(content));
});

test('publishedPIDLines reads complete lines only and rejects an invalid entry', t => {
  const dir = scratch(t);
  for (const [content, expected] of [[null, null], ['', []], ['12\n34\n', [12, 34]], ['12\n3', [12]], ['3', []], ['12\n0\n', null],
    ['x\n', null], ['12\n\n', null], ['-4\n', null], ['12\n1.5\n', null]])
    assert.deepEqual(publishedPIDLines(withContent(dir, content)), expected, JSON.stringify(content));
});

test('safeKill and pidAlive never reach process.kill with 0 or an invalid PID', () => {
  const calls = [], original = process.kill;
  process.kill = (...args) => { calls.push(args); return true; };
  try {
    for (const pid of [0, -0, -5, NaN, Infinity, '12', 1.5, null, undefined, MAX + 1]) {
      assert.equal(safeKill(pid, 'SIGKILL'), false, `safeKill(${String(pid)})`);
      assert.equal(safeKill(pid, 'SIGKILL', { group: true }), false, `safeKill group (${String(pid)})`);
      assert.equal(pidAlive(pid), false, `pidAlive(${String(pid)})`);
    }
    assert.deepEqual(calls, []);
    assert.equal(safeKill(12345, 'SIGTERM', { group: true }), true);
    assert.equal(safeKill(12345, 'SIGTERM'), true);
    assert.deepEqual(calls, [[-12345, 'SIGTERM'], [12345, 'SIGTERM']]);
  } finally { process.kill = original; }
});

test('safeKill signals a real process group and reports ESRCH afterwards', async () => {
  const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'], { detached: true, stdio: 'ignore' });
  const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve(signal)));
  try {
    assert.equal(pidAlive(child.pid), true);
    assert.equal(safeKill(child.pid, 'SIGKILL', { group: true }), true);
    assert.equal(await exited, 'SIGKILL');
    assert.equal(safeKill(child.pid, 'SIGKILL', { group: true }), false);
    assert.equal(safeKill(child.pid, 'SIGKILL'), false);
    assert.equal(pidAlive(child.pid), false);
  } finally { try { process.kill(child.pid, 'SIGKILL'); } catch {} }
});

// A reader polling while a writer republishes must never see a partial value.
const written = v => Number.isInteger(v) && v >= 100000 && v < 104001;
for (const [label, source, read, valid] of [
  ['PID file', file => publishSource(file, 'v'), publishedPID, written],
  ['JSON manifest', file => publishListSource(file, '[v,v+1]'), publishedPIDList, l => Array.isArray(l) && l.length === 2 && l.every(written) && l[1] === l[0] + 1],
]) test(`atomic publication: a concurrent reader never sees a partial ${label}`, { timeout: 60000 }, async t => {
  const dir = scratch(t), file = path.join(dir, 'pid'), done = path.join(dir, 'done');
  const writer = spawn(process.execPath, ['-e', `for(let v=100000;v<104000;v++){${source(file)}}require('node:fs').writeFileSync(${JSON.stringify(done)},'1');`], { stdio: 'ignore' });
  const closed = new Promise(resolve => writer.once('close', resolve));
  let reads = 0, partial = 0;
  const deadline = Date.now() + 45000;
  while (!existsSync(done) && Date.now() < deadline) {
    if (!existsSync(file)) { await new Promise(setImmediate); continue; }
    reads++;
    let value; try { value = read(file); } catch { value = null; }
    if (!valid(value)) partial++;
    if (reads % 200 === 0) await new Promise(setImmediate);
  }
  assert.equal(await closed, 0);
  assert.ok(reads > 100, `reader overlapped the writer (${reads} reads)`);
  assert.equal(partial, 0, `${partial} of ${reads} reads saw a partial ${label}`);
  assert.ok(valid(read(file)), 'final value is the last one written');
});

// The app-lane fixtures read PIDs only through these helpers.
test('app-lane fixtures read and signal PIDs only through fixture-pid', () => {
  const source = readFileSync(fileURLToPath(new URL('./app-lane.test.mjs', import.meta.url)), 'utf8');
  const offenders = source.split('\n').map((line, i) => [line, i + 1])
    .filter(([line]) => /Number\(readFileSync|\.map\(Number\)|JSON\.parse\(readFileSync\(marker|try\s*\{\s*process\.kill\(/.test(line))
    .map(([, n]) => n);
  assert.deepEqual(offenders, []);
});
