#!/usr/bin/env node
/** Dispatch-only observer around xctest. Exit status and test output pass through unchanged. */
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const command = process.argv[2], args = process.argv.slice(3);
if (!command || !args.length) {
  process.stderr.write('app-stall-watchdog: expected native command and bundle\n');
  process.exit(64);
}
const directory = path.resolve(process.env.PICSEE_APP_WATCHDOG_DIR ?? '.build/app-watchdog');
mkdirSync(directory, { recursive: true });
const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
let current = null, lastStage = null, lastStageAt = 0, serial = 0, stopped = false;
const thresholds = [20, 60, 170];
const write = line => {
  process.stderr.write(`app-stall-watchdog: ${line}\n`);
};
const rows = () => {
  const ps = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,rss=,command='], { encoding: 'utf8', timeout: 2000 });
  if (ps.error || ps.status !== 0) return { error: ps.error?.message ?? `ps status ${ps.status}`, rows: [] };
  return { rows: ps.stdout.split('\n').flatMap(line => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(line);
    return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), rssKB: Number(match[3]), command: match[4] }] : [];
  }) };
};
const countLsof = pid => {
  const result = spawnSync('/usr/sbin/lsof', ['-p', String(pid)], { encoding: 'utf8', timeout: 3000, maxBuffer: 8 * 1024 * 1024 });
  return result.error ? { error: result.error.message } :
    { status: result.status, openFiles: result.stdout.trim() ? Math.max(0, result.stdout.trim().split('\n').length - 1) : 0 };
};
const sample = (pid, filename) => new Promise(resolve => {
  const probe = spawn('/usr/bin/sample', [String(pid), '5', '-file', filename], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '', settled = false;
  const timeout = setTimeout(() => { probe.kill('SIGKILL'); finish({ status: 'timeout', stderr }); }, 15000);
  const finish = result => {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    resolve(result);
  };
  probe.stderr.on('data', chunk => { stderr += chunk.toString(); });
  probe.on('error', error => finish({ status: 'error', error: error.message }));
  probe.on('close', (code, signal) => finish({ status: code, signal, stderr: stderr.slice(-2000) }));
});
const capture = async (threshold, observed) => {
  const prefix = path.join(directory, `${String(++serial).padStart(2, '0')}-${threshold}s`);
  const inspected = rows(), all = inspected.rows;
  const descendants = new Set([child.pid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of all) if (descendants.has(row.ppid) && !descendants.has(row.pid)) {
      descendants.add(row.pid); changed = true;
    }
  }
  const xctest = all.find(row => descendants.has(row.pid) && /(?:\/|\b)xctest(?:\s|$)/.test(row.command)) ??
    all.find(row => descendants.has(row.pid) && row.command.includes('MadoAppTests.xctest'));
  const hosted = all.filter(row => process.env.MADO_HOST_EXECUTABLE && row.command.includes(process.env.MADO_HOST_EXECUTABLE));
  const targets = [...new Map([xctest, ...hosted].filter(Boolean).map(row => [row.pid, row])).values()];
  const record = { thresholdSeconds: threshold, observedAt: new Date().toISOString(),
    elapsedMilliseconds: observed.elapsed, test: observed.test, lastStage: observed.stage,
    xcrunPID: child.pid, xctestPID: xctest?.pid ?? null, hostedAppPIDs: hosted.map(row => row.pid),
    processError: inspected.error ?? null, processes: targets.map(row => ({ ...row, lsof: countLsof(row.pid) })) };
  writeFileSync(`${prefix}.json`, JSON.stringify(record, null, 2) + '\n');
  write(`threshold=${threshold}s test=${JSON.stringify(observed.test)} stage=${JSON.stringify(observed.stage)} capture=${prefix}.json`);
  for (const target of targets) {
    const result = await sample(target.pid, `${prefix}-pid${target.pid}.sample.txt`);
    writeFileSync(`${prefix}-pid${target.pid}.sample-result.json`, JSON.stringify(result, null, 2) + '\n');
  }
};
const handleLine = line => {
  const started = /^◇ Test (?!case |run )(.+) started\.$/.exec(line) ??
    /^Test Case '-\[([^\]]+)\]' started\.$/.exec(line);
  if (started) {
    const matchesStage = (started[1].includes('issue140') || started[1].includes('TemporaryWatchdog'))
      ? lastStage?.startsWith('[i140]') : started[1].includes('sidebarWatch') && lastStage?.startsWith('[i676]');
    if (!matchesStage || Date.now() - lastStageAt > 2000) lastStage = null;
    current = { test: started[1], start: Date.now(), fired: new Set() };
  }
  if (/^\[(?:i676|i140)\]/.test(line)) { lastStage = line; lastStageAt = Date.now(); }
  const ended = /^[✔✘➜] Test (?!run with )(.+) (?:passed|failed|skipped)/.exec(line) ??
    /^Test Case '-\[([^\]]+)\]' (?:passed|failed|skipped)/.exec(line);
  if (ended && current?.test === ended[1]) { current = null; lastStage = null; }
};
const forward = (stream, destination) => {
  let pending = '';
  stream.on('data', chunk => {
    destination.write(chunk);
    pending += chunk.toString();
    let newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      handleLine(pending.slice(0, newline).replace(/\r$/, ''));
      pending = pending.slice(newline + 1);
    }
  });
};
forward(child.stdout, process.stdout);
forward(child.stderr, process.stderr);
const interval = setInterval(() => {
  if (!current || stopped) return;
  const elapsed = Date.now() - current.start;
  for (const threshold of thresholds) if (elapsed >= threshold * 1000 && !current.fired.has(threshold)) {
    current.fired.add(threshold);
    void capture(threshold, { elapsed, test: current.test, stage: lastStage }).catch(error => write(`capture failed: ${error.message}`));
  }
}, 250);
const forwardSignal = signal => { child.kill(signal); };
process.on('SIGTERM', () => forwardSignal('SIGTERM'));
process.on('SIGINT', () => forwardSignal('SIGINT'));
child.on('error', error => { write(`native spawn failed: ${error.message}`); stopped = true; clearInterval(interval); process.exitCode = 70; });
child.on('close', (code, signal) => {
  stopped = true;
  clearInterval(interval);
  process.exitCode = signal ? 70 : code ?? 70;
});
