#!/usr/bin/env node
// Runs one test command under a deadline and leaves evidence when it hangs (#391). The command's output is copied
// to the terminal and to <out>/test.log. When the deadline passes, the watchdog records `ps` CPU/RSS for the command's
// process tree, samples the test processes (`sample`, then `spindump` when passwordless sudo exists) within a capture
// budget, then sends TERM and, after a grace period, KILL to the command's process group and to every process of the
// tree by pid (swift test starts swiftpm-testing-helper in a process group of its own). The tree is also recorded
// every few seconds while the command runs, so a helper whose parent already exited is still found. Exit status: the
// command's own status, 128+signal when a signal ended it, or 124 when the watchdog ended it.
//
//   node scripts/ci/test-watchdog.mjs --out ci-logs/macui --timeout-seconds 1500 [--deadline-epoch N]
//     [--sample-seconds 10] [--capture-seconds 90] [--grace-seconds 15] [--snapshot-seconds 30] [--no-spindump]
//     [--match 'swiftpm-testing|PackageTests'] -- swift test …
//
// PICSEE_WATCHDOG_NO_SPINDUMP=1 has the same effect as --no-spindump.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const TIMEOUT_STATUS = 124;
const DEFAULTS = { sampleSeconds: 10, captureSeconds: 90, graceSeconds: 15, snapshotSeconds: 30, spindump: true,
  match: 'swiftpm-testing|PackageTests' };
// Extra time a sample or spindump call gets beyond its sampling duration, to write and symbolicate its report.
const REPORT_SECONDS = 20;

/** Options before `--`, the command after it. Throws on anything it does not understand. */
export function parseArgs(argv, env = process.env) {
  const split = argv.indexOf('--');
  if (split < 0 || split === argv.length - 1) throw Error('usage: test-watchdog.mjs [options] -- <command …>');
  const options = { ...DEFAULTS, command: argv.slice(split + 1) };
  if (env.PICSEE_WATCHDOG_NO_SPINDUMP === '1') options.spindump = false;
  const flags = argv.slice(0, split);
  const number = (flag, value) => {
    const n = Number(value);
    if (!Number.isFinite(n) || n <= 0) throw Error(`${flag} needs a positive number, got ${value}`);
    return n;
  };
  for (let i = 0; i < flags.length; i += 2) {
    const [flag, value] = [flags[i], flags[i + 1]];
    if (flag === '--no-spindump') { options.spindump = false; i -= 1; continue; }
    if (value === undefined) throw Error(`${flag} needs a value`);
    switch (flag) {
      case '--out': options.out = value; break;
      case '--timeout-seconds': options.timeoutSeconds = number(flag, value); break;
      case '--deadline-epoch': options.deadlineEpoch = number(flag, value); break;
      case '--sample-seconds': options.sampleSeconds = number(flag, value); break;
      case '--capture-seconds': options.captureSeconds = number(flag, value); break;
      case '--grace-seconds': options.graceSeconds = number(flag, value); break;
      case '--snapshot-seconds': options.snapshotSeconds = number(flag, value); break;
      case '--match': options.match = value; break;
      default: throw Error(`unknown option ${flag}`);
    }
  }
  if (!options.out) throw Error('--out is required');
  if (!options.timeoutSeconds && !options.deadlineEpoch) throw Error('--timeout-seconds or --deadline-epoch is required');
  return options;
}

/** Milliseconds until the earlier of the timeout and the absolute deadline (epoch seconds), never below zero. */
export function budgetMs({ timeoutSeconds, deadlineEpoch }, nowMs) {
  const limits = [];
  if (timeoutSeconds) limits.push(timeoutSeconds * 1000);
  if (deadlineEpoch) limits.push(deadlineEpoch * 1000 - nowMs);
  return Math.max(0, Math.min(...limits));
}

/** Every process in `ps -A -o pid=,ppid=,command=` text, as Map pid → { ppid, command }. */
export function parseProcesses(psText) {
  const processes = new Map();
  for (const line of psText.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    if (m) processes.set(Number(m[1]), { ppid: Number(m[2]), command: m[3] });
  }
  return processes;
}

/** Pids of `root` and all its descendants, from `ps -A -o pid=,ppid=,command=` text. */
export function processTree(psText, root) {
  const processes = parseProcesses(psText), children = new Map();
  for (const [pid, { ppid }] of processes) {
    if (!children.has(ppid)) children.set(ppid, []);
    children.get(ppid).push(pid);
  }
  const tree = [], queue = [root];
  while (queue.length) {
    const pid = queue.shift();
    if (tree.some(p => p.pid === pid)) continue;
    if (pid !== root && !processes.has(pid)) continue;
    tree.push({ pid, command: processes.get(pid)?.command ?? '' });
    queue.push(...(children.get(pid) ?? []));
  }
  return tree;
}

/** The processes worth sampling: those matching `match`, or the whole tree when none does. */
export function sampleTargets(tree, match) {
  const re = new RegExp(match);
  const matched = tree.filter(p => re.test(p.command));
  return matched.length ? matched : tree;
}

export function exitStatus({ timedOut, code, signal }) {
  if (timedOut) return TIMEOUT_STATUS;
  if (signal) return 128 + (os.constants.signals[signal] ?? 0);
  return code ?? 1;
}

export const defaultRun = (cmd, args, options = {}) =>
  spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options });
const LIST = ['-A', '-o', 'pid=,ppid=,command='];
const failed = result => result.error || result.status !== 0;
const describe = (what, result) => `${what} failed (status ${result.status ?? 'none'}` +
  `${result.signal ? `, ${result.signal}` : ''}${result.error ? `, ${result.error.message}` : ''})` +
  `${(result.stderr ?? '').trim() ? `: ${result.stderr.trim()}` : ''}`;

/**
 * Records and samples the hung tree into <out>/stacks within `captureSeconds`, and returns the paths it wrote, the
 * tree it found and the captures it skipped. `known` holds processes seen by earlier snapshots; one is kept only
 * while `ps` still lists it with the same command, so a reused pid is never signalled.
 */
export function captureDiagnostics({ root, known = [], out, sampleSeconds, captureSeconds, spindump = true, match,
  log, run = defaultRun, now = Date.now }) {
  const started = now();
  const left = () => captureSeconds * 1000 - (now() - started);
  const dir = path.join(out, 'stacks');
  fs.mkdirSync(dir, { recursive: true });
  const written = [], skipped = [], notes = [];
  const listing = run('ps', LIST, { timeout: 10_000 });
  let tree;
  if (failed(listing)) {
    // Without a process list only the command's own group can be signalled.
    const note = `${describe('ps', listing)}; only the command's process group will be signalled`;
    log(`watchdog: ${note}`);
    notes.push(note);
    tree = [{ pid: root, command: '' }];
  } else {
    tree = processTree(listing.stdout, root);
    const current = parseProcesses(listing.stdout);
    for (const p of known)
      if (!tree.some(t => t.pid === p.pid) && current.get(p.pid)?.command === p.command) tree.push(p);
  }
  const psFile = path.join(dir, 'ps.txt');
  const rows = [];
  for (const p of tree) {
    const row = run('ps', ['-o', 'pid=,ppid=,%cpu=,rss=,etime=,state=,command=', '-p', String(p.pid)], { timeout: 10_000 });
    if (!failed(row) && row.stdout.trim()) rows.push(row.stdout.trim());
  }
  fs.writeFileSync(psFile, ['PID PPID %CPU RSS(KB) ELAPSED STATE COMMAND', ...rows, ...notes.map(n => `# ${n}`)].join('\n') + '\n');
  written.push(psFile);

  const targets = sampleTargets(tree, match);
  // A capture starts only when its whole sampling duration fits in what is left, and is cut off at that budget.
  const capture = (label, cmd, args, file, start) => {
    if (left() < (sampleSeconds + 1) * 1000) { skipped.push(label); return; }
    log(`watchdog: ${start}`);
    const result = run(cmd, args, { timeout: Math.min((sampleSeconds + REPORT_SECONDS) * 1000, left()) });
    if (fs.existsSync(file)) written.push(file);
    else log(`watchdog: ${describe(label, result)}, no report written`);
  };
  for (const { pid, command } of targets) {
    const file = path.join(dir, `sample-${pid}.txt`);
    capture(`sample ${pid}`, 'sample', [String(pid), String(sampleSeconds), '-file', file], file,
      `sampling ${pid} for ${sampleSeconds} s: ${command}`);
  }
  if (!spindump) log('watchdog: spindump disabled');
  else if (left() < (sampleSeconds + 1) * 1000) skipped.push(...targets.map(({ pid }) => `spindump ${pid}`));
  else if (failed(run('sudo', ['-n', 'true'], { timeout: 5_000 }))) log('watchdog: no passwordless sudo, spindump skipped');
  else for (const { pid } of targets) {
    const file = path.join(dir, `spindump-${pid}.txt`);
    capture(`spindump ${pid}`, 'sudo', ['-n', 'spindump', String(pid), String(sampleSeconds), '-file', file], file,
      `spindump of ${pid} for ${sampleSeconds} s`);
  }
  if (skipped.length) log(`watchdog: capture budget of ${captureSeconds} s spent; skipped ${skipped.join(', ')}`);
  return { written, tree, skipped };
}

const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function watch(options, { log = line => process.stderr.write(`${line}\n`), now = Date.now,
  run = defaultRun } = {}) {
  fs.mkdirSync(options.out, { recursive: true });
  const logFile = fs.createWriteStream(path.join(options.out, 'test.log'));
  const budget = budgetMs(options, now());
  log(`watchdog: ${options.command.join(' ')} (deadline in ${Math.round(budget / 1000)} s, log ${options.out}/test.log)`);
  const child = spawn(options.command[0], options.command.slice(1), { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const [stream, sink] of [[child.stdout, process.stdout], [child.stderr, process.stderr]])
    stream.on('data', chunk => { sink.write(chunk); logFile.write(chunk); });
  let timedOut = false, pids = [], killTimer;
  const known = [];
  const snapshot = setInterval(() => {
    const listing = run('ps', LIST, { timeout: 10_000 });
    if (failed(listing) || child.pid === undefined) return;
    for (const p of processTree(listing.stdout, child.pid))
      if (p.pid !== child.pid && !known.some(k => k.pid === p.pid)) known.push(p);
  }, options.snapshotSeconds * 1000);
  const signal = name => {
    for (const target of [-child.pid, ...pids]) { try { process.kill(target, name); } catch { /* already gone */ } }
  };
  const kill = () => {
    if (!pids.some(alive) && !alive(child.pid) && !alive(-child.pid)) return;
    log('watchdog: sending KILL');
    signal('SIGKILL');
  };
  const timer = setTimeout(() => {
    timedOut = true;
    clearInterval(snapshot);
    log(`watchdog: deadline passed after ${Math.round(budget / 1000)} s; capturing diagnostics`);
    const { written, tree } = captureDiagnostics({ root: child.pid, known, out: options.out,
      sampleSeconds: options.sampleSeconds, captureSeconds: options.captureSeconds, spindump: options.spindump,
      match: options.match, log, run, now });
    pids = tree.map(p => p.pid).filter(pid => pid !== child.pid);
    log(`watchdog: wrote ${written.join(', ')}`);
    log('watchdog: sending TERM');
    signal('SIGTERM');
    killTimer = setTimeout(kill, options.graceSeconds * 1000);
  }, budget);
  const result = await new Promise(resolve => {
    child.on('error', error => resolve({ code: 127, error }));
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
  clearTimeout(timer);
  clearInterval(snapshot);
  if (timedOut) {
    // The leader can exit on TERM while the test helper, in its own group, keeps running: give it the grace period.
    const until = Date.now() + options.graceSeconds * 1000;
    while (pids.some(alive) && Date.now() < until) await sleep(200);
    clearTimeout(killTimer);
    kill();
    const survivors = pids.filter(alive);
    if (survivors.length) log(`watchdog: still alive after KILL: ${survivors.join(', ')}`);
  } else if (child.pid !== undefined && alive(-child.pid)) {
    // The command finished but left members of its process group behind; they must not outlive the step.
    log('watchdog: command exited; killing what is left of its process group');
    try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
  }
  await new Promise(resolve => logFile.end(resolve));
  if (result.error) log(`watchdog: cannot start ${options.command[0]}: ${result.error.message}`);
  const status = exitStatus({ timedOut, ...result });
  log(`watchdog: exit ${status}${timedOut ? ' (timed out)' : ''}`);
  return status;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let options;
  try { options = parseArgs(process.argv.slice(2)); } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
  process.exitCode = await watch(options);
}
