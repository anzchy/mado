#!/usr/bin/env node
// Runs one test command under a deadline and leaves evidence when it hangs (#391). The command's output is copied
// to the terminal and to <out>/test.log. When the deadline passes, the watchdog samples the test processes (`sample`,
// and `spindump` when passwordless sudo exists), records `ps` CPU/RSS for the whole tree, then sends TERM and, after a
// grace period, KILL to the command's process group and to every process of the tree by pid (swift test starts
// swiftpm-testing-helper in a process group of its own). Exit status: the command's own status, 128+signal when a
// signal ended it, or 124 when the watchdog ended it.
//
//   node scripts/ci/test-watchdog.mjs --out ci-logs/macui --timeout-seconds 1500 [--deadline-epoch N]
//     [--sample-seconds 10] [--grace-seconds 15] [--match 'swiftpm-testing|PackageTests'] -- swift test …
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const TIMEOUT_STATUS = 124;
const DEFAULTS = { sampleSeconds: 10, graceSeconds: 15, match: 'swiftpm-testing|PackageTests' };

/** Options before `--`, the command after it. Throws on anything it does not understand. */
export function parseArgs(argv) {
  const split = argv.indexOf('--');
  if (split < 0 || split === argv.length - 1) throw Error('usage: test-watchdog.mjs [options] -- <command …>');
  const options = { ...DEFAULTS, command: argv.slice(split + 1) };
  const flags = argv.slice(0, split);
  const number = (flag, value) => {
    const n = Number(value);
    if (!Number.isFinite(n) || n <= 0) throw Error(`${flag} needs a positive number, got ${value}`);
    return n;
  };
  for (let i = 0; i < flags.length; i += 2) {
    const [flag, value] = [flags[i], flags[i + 1]];
    if (value === undefined) throw Error(`${flag} needs a value`);
    switch (flag) {
      case '--out': options.out = value; break;
      case '--timeout-seconds': options.timeoutSeconds = number(flag, value); break;
      case '--deadline-epoch': options.deadlineEpoch = number(flag, value); break;
      case '--sample-seconds': options.sampleSeconds = number(flag, value); break;
      case '--grace-seconds': options.graceSeconds = number(flag, value); break;
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

/** Pids of `root` and all its descendants, from `ps -A -o pid=,ppid=,command=` text. */
export function processTree(psText, root) {
  const children = new Map(), commands = new Map();
  for (const line of psText.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    const [pid, ppid] = [Number(m[1]), Number(m[2])];
    commands.set(pid, m[3]);
    if (!children.has(ppid)) children.set(ppid, []);
    children.get(ppid).push(pid);
  }
  const tree = [], queue = [root];
  while (queue.length) {
    const pid = queue.shift();
    if (tree.some(p => p.pid === pid)) continue;
    if (pid !== root && !commands.has(pid)) continue;
    tree.push({ pid, command: commands.get(pid) ?? '' });
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
  if (signal) return 128 + ({ SIGHUP: 1, SIGINT: 2, SIGKILL: 9, SIGTERM: 15 }[signal] ?? 0);
  return code ?? 1;
}

const run = (cmd, args, options = {}) => spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options });

/** Samples the hung tree into <out>/stacks; returns the paths it wrote and the tree it found. */
export function captureDiagnostics({ root, out, sampleSeconds, match, log }) {
  const dir = path.join(out, 'stacks');
  fs.mkdirSync(dir, { recursive: true });
  const written = [];
  const psFields = ['-o', 'pid=,ppid=,%cpu=,rss=,etime=,state=,command='];
  const tree = processTree(run('ps', ['-A', '-o', 'pid=,ppid=,command=']).stdout ?? '', root);
  const psFile = path.join(dir, 'ps.txt');
  const header = 'PID PPID %CPU RSS(KB) ELAPSED STATE COMMAND\n';
  const rows = tree.map(p => run('ps', [...psFields, '-p', String(p.pid)]).stdout?.trim()).filter(Boolean);
  fs.writeFileSync(psFile, header + rows.join('\n') + '\n');
  written.push(psFile);
  const sudo = run('sudo', ['-n', 'true']).status === 0;
  for (const { pid, command } of sampleTargets(tree, match)) {
    log(`watchdog: sampling ${pid} for ${sampleSeconds} s: ${command}`);
    const sampleFile = path.join(dir, `sample-${pid}.txt`);
    const sample = run('sample', [String(pid), String(sampleSeconds), '-file', sampleFile]);
    if (fs.existsSync(sampleFile)) written.push(sampleFile);
    else log(`watchdog: sample ${pid} wrote nothing (status ${sample.status}): ${(sample.stderr ?? '').trim()}`);
    if (sudo) {
      const spinFile = path.join(dir, `spindump-${pid}.txt`);
      run('sudo', ['-n', 'spindump', String(pid), String(sampleSeconds), '-file', spinFile]);
      if (fs.existsSync(spinFile)) written.push(spinFile);
    }
  }
  if (!sudo) log('watchdog: no passwordless sudo, spindump skipped');
  return { written, tree };
}

const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function watch(options, { log = line => process.stderr.write(`${line}\n`), now = Date.now } = {}) {
  fs.mkdirSync(options.out, { recursive: true });
  const logFile = fs.createWriteStream(path.join(options.out, 'test.log'));
  const budget = budgetMs(options, now());
  log(`watchdog: ${options.command.join(' ')} (deadline in ${Math.round(budget / 1000)} s, log ${options.out}/test.log)`);
  const child = spawn(options.command[0], options.command.slice(1), { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const [stream, sink] of [[child.stdout, process.stdout], [child.stderr, process.stderr]])
    stream.on('data', chunk => { sink.write(chunk); logFile.write(chunk); });
  let timedOut = false, pids = [], killTimer;
  const signal = name => {
    for (const target of [-child.pid, ...pids]) { try { process.kill(target, name); } catch { /* already gone */ } }
  };
  const kill = () => {
    if (!pids.some(alive) && !alive(child.pid)) return;
    log('watchdog: sending KILL');
    signal('SIGKILL');
  };
  const timer = setTimeout(() => {
    timedOut = true;
    log(`watchdog: deadline passed after ${Math.round(budget / 1000)} s; capturing diagnostics`);
    const { written, tree } = captureDiagnostics({ root: child.pid, out: options.out,
      sampleSeconds: options.sampleSeconds, match: options.match, log });
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
  if (timedOut) {
    // The leader can exit on TERM while the test helper, in its own group, keeps running: give it the grace period.
    const until = Date.now() + options.graceSeconds * 1000;
    while (pids.some(alive) && Date.now() < until) await sleep(200);
    clearTimeout(killTimer);
    kill();
    const survivors = pids.filter(alive);
    if (survivors.length) log(`watchdog: still alive after KILL: ${survivors.join(', ')}`);
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
