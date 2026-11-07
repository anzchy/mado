#!/usr/bin/env node
// P3-08 (#146) measurement orchestrator for a signed Release Mado on a real desktop. Run it through
// scripts/perf/measure-p3-08.sh; see docs/validation/P3.md「P3-08 测量方法」.
//
// It never drives the UI itself: `--driver` (the delegator's GUI step) opens the fixture folder once per sample.
// It owns only the Mado processes it spawned as its own children (the child handle, never a pid read from a process
// list or by name), SIGTERMs only those, never escalates, and refuses to start while another Mado runs, and never deletes a cache: a cold sample moves mado's thumbnail cache
// into the run directory. Evidence stays in the run directory; nothing is written to the checkout.
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { MIN_SAMPLES, SUBSYSTEM, UNKNOWN, analyze, mergeSampleLogs, parseNdjson, renderReport, renderResources } from './p308-parse.mjs';

export const CACHE_STATES = ['cold-app', 'warm-disk', 'warm-memory'];
export const TIERS = ['S1', 'S2', 'S3', 'S4', 'S5', 'S6'];

/** Parses and validates arguments; throws with a usage message. Pure. */
export function parseArgs(argv) {
  const [mode, ...rest] = argv;
  if (!['run', 'resources', 'parse'].includes(mode)) throw new Error(USAGE);
  const options = { mode, allowUnder30: false, rounds: 3, timeoutSeconds: 180 };
  const names = { '--app': 'app', '--fixture': 'fixture', '--tier': 'tier', '--cache-state': 'cacheState', '--samples': 'samples',
    '--driver': 'driver', '--browse': 'browse', '--out': 'out', '--rounds': 'rounds', '--manifest': 'manifest',
    '--disk-high-water-bytes': 'diskHighWaterBytes', '--timeout': 'timeoutSeconds', '--tuning': 'tuning', '--content': 'content' };
  for (let i = 0; i < rest.length; i += 1) {
    const flag = rest[i];
    if (flag === '--allow-under-30') { options.allowUnder30 = true; continue; }
    if (mode === 'parse' && !flag.startsWith('--') && !options.out) { options.out = flag; continue; }
    const key = names[flag];
    if (!key || i + 1 >= rest.length) throw new Error(`unknown or incomplete option ${flag}\n${USAGE}`);
    options[key] = rest[++i];
  }
  for (const key of ['samples', 'rounds', 'diskHighWaterBytes', 'timeoutSeconds']) {
    if (options[key] === undefined) continue;
    const n = Number(options[key]);
    if (!Number.isInteger(n) || n < 1) throw new Error(`--${key} must be a positive integer`);
    options[key] = n;
  }
  if (!options.out) throw new Error(`--out <run directory> is required\n${USAGE}`);
  if (mode === 'parse') return options;
  for (const key of ['app', 'fixture', 'driver', 'tier']) if (!options[key]) throw new Error(`--${key} is required\n${USAGE}`);
  if (!TIERS.includes(options.tier)) throw new Error(`--tier must be one of ${TIERS.join(', ')}`);
  if (mode === 'run') {
    if (!CACHE_STATES.includes(options.cacheState)) throw new Error(`--cache-state must be one of ${CACHE_STATES.join(', ')}`);
    if (!options.samples) throw new Error('--samples is required');
    if (options.samples < MIN_SAMPLES && !options.allowUnder30) {
      throw new Error(`--samples ${options.samples} < ${MIN_SAMPLES}: p95 would not be claimable; pass --allow-under-30 for a trial`);
    }
  }
  if (mode === 'resources' && options.rounds < 3) throw new Error('--rounds must be at least 3 (plan §10.2: three rounds)');
  return options;
}

const USAGE = `usage:
  measure-p3-08.sh run --app <signed Release Mado.app> --fixture <folder> --tier S1..S6
      --cache-state cold-app|warm-disk|warm-memory --samples N (≥ ${MIN_SAMPLES}) --driver '<cmd that opens the folder>'
      --out <new run dir> [--manifest <file>] [--tuning <text>] [--content <what the files are>] [--timeout <s>] [--allow-under-30]
  measure-p3-08.sh resources --app … --fixture … --tier … --driver '<cmd>' --browse '<cmd>' --out <new run dir>
      [--rounds 3] [--disk-high-water-bytes N]
  measure-p3-08.sh parse <run dir>
The driver and browse commands get PICSEE_P308_PID, PICSEE_P308_FIXTURE, PICSEE_P308_SAMPLE and PICSEE_P308_RUN_DIR.`;

/** mado's thumbnail cache inside its sandbox container (ThumbnailDiskCache's default directory). Pure. */
export function cacheDirectory(bundleID, home = homedir()) {
  if (!/^[A-Za-z0-9.-]+$/.test(bundleID)) throw new Error(`unexpected bundle identifier ${bundleID}`);
  return path.join(home, 'Library/Containers', bundleID, 'Data/Library/Caches/Mado/Thumbnails');
}

/**
 * Where a cold sample moves the cache, or why it must not. Never deletes. Every component from the App's container
 * down to the cache must be a plain directory (no symlink anywhere), the resolved cache must stay inside the real
 * container, and only ENOENT means "no cache yet": any other error (EACCES, EPERM, …) refuses, so a cache the script
 * cannot see is never reported as cold. `fs` is injectable for tests; the default is the real filesystem.
 */
export function planCacheAside(cache, runDir, sample, { bundleID, home = homedir(), fs = { lstatSync, existsSync, realpathSync } } = {}) {
  const expected = cacheDirectory(bundleID, home);
  if (path.resolve(cache) !== expected) return { action: 'refuse', reason: `not mado's cache directory: ${cache}` };
  const target = path.join(runDir, 'cache-aside', String(sample).padStart(3, '0'));
  if (fs.existsSync(target)) return { action: 'refuse', reason: `aside target already exists: ${target}` };
  const containers = path.join(home, 'Library/Containers');
  let component = containers;
  for (const part of path.relative(containers, expected).split(path.sep)) {
    component = path.join(component, part);
    let stat;
    try { stat = fs.lstatSync(component); } catch (error) {
      if (error?.code === 'ENOENT') return { action: 'none', reason: `no cache directory yet (already cold): ${component} absent` };
      return { action: 'refuse', reason: `cannot inspect ${component} (${error?.code ?? error}); a cache the script cannot see is not cold` };
    }
    if (stat.isSymbolicLink()) return { action: 'refuse', reason: `symlink in the cache path: ${component}` };
    if (!stat.isDirectory()) return { action: 'refuse', reason: `not a plain directory in the cache path: ${component}` };
  }
  let real, container;
  try { real = fs.realpathSync(expected); container = fs.realpathSync(path.join(containers, bundleID)); } catch (error) {
    return { action: 'refuse', reason: `cannot resolve ${expected} (${error?.code ?? error})` };
  }
  if (!real.startsWith(container + path.sep)) return { action: 'refuse', reason: `cache resolves outside the App container: ${real}` };
  return { action: 'move', from: expected, to: target };
}

// ---- Native steps (launch, quit and cache aside are tested with real child processes and temp trees; the rest is device only) ----

const sh = (file, args, options = {}) => execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options }).trim();
const quiet = (file, args) => { try { return sh(file, args); } catch { return null; } };
const nowMicros = () => Date.now() * 1000;
const logDate = (us) => {
  const d = new Date(us / 1000);
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function madoPIDs() {
  const out = quiet('/usr/bin/pgrep', ['-x', 'Mado']);
  return out ? out.split('\n').map(Number).filter(Boolean) : [];
}

// Children this script spawned, by pid. Ownership is the child handle itself, never a pid read from a process list.
const children = new Map();

/**
 * Starts the bundle's executable as a child of this script and owns exactly that child. Refuses while any other
 * Mado runs (it would share the container cache); a Mado that appears meanwhile is never claimed.
 */
export async function launch(app, run, { spawn: spawnChild = spawn, madoPIDs: list = madoPIDs, sleep: wait = sleep, readyMs = 2000 } = {}) {
  const before = list();
  if (before.length) throw new Error(`another Mado is running (pid ${before.join(', ')}); ask its owner to quit it`);
  const executable = path.join(app, 'Contents/MacOS/Mado');
  const child = spawnChild(executable, [], { stdio: 'ignore' });
  if (!child?.pid) throw new Error(`could not start ${executable}`);
  child.on('error', () => {});
  await wait(readyMs);
  if (child.exitCode !== null || child.signalCode !== null) {
    throw new Error(`Mado exited during start-up (${child.exitCode ?? child.signalCode}); nothing owned`);
  }
  children.set(child.pid, child);
  const record = { pid: child.pid, executable, birth: quiet('/bin/ps', ['-o', 'lstart=', '-p', String(child.pid)]), child: true };
  run.owned.push(record);
  return record;
}

/** SIGTERM to a child this script spawned that is still running; never escalates and never signals anything else. */
export async function quit(record, { sleep: wait = sleep } = {}) {
  const child = record && children.get(record.pid);
  if (!child) throw new Error(`pid ${record?.pid} is not a child this script spawned; no signal sent`);
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  if (exited()) { children.delete(record.pid); return 'already exited; no signal sent'; }
  child.kill('SIGTERM');
  for (let i = 0; i < 100; i += 1) {
    if (exited()) { children.delete(record.pid); return 'terminated'; }
    await wait(100);
  }
  throw new Error(`pid ${record.pid} did not exit 10 s after SIGTERM; no escalation sent`);
}

function signpostLog(pid, startUs) {
  const r = spawnSync('/usr/bin/log', ['show', '--signpost', '--info', '--style', 'ndjson', '--start', logDate(startUs - 1_000_000),
    '--predicate', `subsystem == "${SUBSYSTEM}" AND processID == ${pid}`], { encoding: 'utf8', maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error(`log show failed: ${r.stderr.trim()}`);
  return r.stdout;
}

function runCommand(command, env) {
  const r = spawnSync('/bin/zsh', ['-c', command], { stdio: 'inherit', env: { ...process.env, ...env } });
  if (r.status !== 0) throw new Error(`command failed (${r.status}): ${command}`);
}

/** Runs the driver once and waits for the GridFirstThumbnails end of a scan begun after it started. */
async function sample(options, run, record, index, priming) {
  const startUs = nowMicros();
  runCommand(options.driver, { PICSEE_P308_PID: String(record.pid), PICSEE_P308_FIXTURE: options.fixture,
    PICSEE_P308_SAMPLE: String(index), PICSEE_P308_RUN_DIR: options.out });
  const deadline = Date.now() + options.timeoutSeconds * 1000;
  let text = '';
  while (Date.now() < deadline) {
    text = signpostLog(record.pid, startUs);
    const { events } = parseNdjson(text);
    const scans = events.filter((e) => e.name === 'FolderScan' && e.type === 'begin' && e.us >= startUs);
    const generations = new Set(scans.map((e) => /generation=(\d+)/.exec(e.message)?.[1]));
    if (events.some((e) => e.name === 'GridFirstThumbnails' && e.type === 'end' && generations.has(/generation=(\d+)/.exec(e.message)?.[1]))) break;
    await sleep(1000);
  }
  const endUs = nowMicros();
  const file = path.join(options.out, 'samples', `${String(index).padStart(3, '0')}${priming ? '-priming' : ''}.ndjson`);
  writeFileSync(file, text);
  run.windows.push({ index, pid: record.pid, startUs, endUs, priming, file: path.relative(options.out, file) });
}

/** Plans and moves in one step, so the checks hold immediately before the rename. */
export function moveCacheAside(out, run, index, { home = homedir() } = {}) {
  const plan = planCacheAside(run.cache, out, index, { bundleID: run.bundleID, home });
  run.cacheMoves.push({ sample: index, ...plan });
  if (plan.action === 'refuse') throw new Error(`cold cache refused: ${plan.reason}`);
  if (plan.action === 'move') { mkdirSync(path.dirname(plan.to), { recursive: true }); renameSync(plan.from, plan.to); }
}

function plist(app, key) { return quiet('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', path.join(app, 'Contents/Info.plist')]); }

function describeBuild(app) {
  const codesign = spawnSync('/usr/bin/codesign', ['-dv', '--verbose=2', app], { encoding: 'utf8' });
  const authority = [...(codesign.stderr ?? '').matchAll(/^Authority=(.+)$/gm)].map((m) => m[1]);
  const team = /^TeamIdentifier=(.+)$/m.exec(codesign.stderr ?? '')?.[1];
  const verified = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]).status === 0;
  const debugDylib = existsSync(path.join(app, 'Contents/MacOS/Mado.debug.dylib'));
  return {
    buildSHA: plist(app, 'MadoGitSHA') ?? UNKNOWN,
    signing: authority.length ? `${authority[0]}（team ${team ?? UNKNOWN}，codesign --verify ${verified ? '通过' : '失败'}）` : UNKNOWN,
    // Xcode's Debug builds carry a debug dylib; its absence does not prove Release.
    configuration: debugDylib ? 'Debug（含 Mado.debug.dylib）' : `${UNKNOWN}（无 debug dylib，不能据此证明 Release）`,
  };
}

function describeMachine(fixture) {
  const scale = quiet('/usr/bin/osascript', ['-l', 'JavaScript', '-e', "ObjC.import('AppKit'); Number($.NSScreen.mainScreen.backingScaleFactor)"]);
  const mount = quiet('/bin/df', ['-P', fixture])?.split('\n')[1]?.split(/\s+/)[0];
  const solid = mount ? /Solid State:\s+(\w+)/.exec(quiet('/usr/sbin/diskutil', ['info', mount]) ?? '')?.[1] : null;
  const memory = Number(quiet('/usr/sbin/sysctl', ['-n', 'hw.memsize']));
  return {
    machine: `${quiet('/usr/sbin/sysctl', ['-n', 'hw.model']) ?? UNKNOWN} / ${quiet('/usr/sbin/sysctl', ['-n', 'machdep.cpu.brand_string']) ?? UNKNOWN}`
      + ` / ${memory ? `${Math.round(memory / 2 ** 30)} GiB` : UNKNOWN}`,
    macOS: quiet('/usr/bin/sw_vers', ['-productVersion']) ?? UNKNOWN,
    scale: scale ?? UNKNOWN,
    storage: solid === 'Yes' ? `SSD（${mount}）` : solid === 'No' ? `非 SSD（${mount}）` : UNKNOWN,
  };
}

function describeFixture(options) {
  let files = 0;
  const walk = (dir) => { for (const e of readdirSync(dir, { withFileTypes: true })) { if (e.isDirectory()) walk(path.join(dir, e.name)); else files += 1; } };
  walk(options.fixture);
  const manifest = options.manifest
    ? `${options.manifest} sha256 ${createHash('sha256').update(readFileSync(options.manifest)).digest('hex').slice(0, 16)}…` : UNKNOWN;
  return { fixtureFiles: files, manifest };
}

function prepareRun(options) {
  if (existsSync(options.out)) throw new Error(`run directory exists: ${options.out}; use a new one`);
  if (!statSync(options.fixture).isDirectory()) throw new Error(`fixture is not a folder: ${options.fixture}`);
  mkdirSync(path.join(options.out, 'samples'), { recursive: true });
  const bundleID = plist(options.app, 'CFBundleIdentifier');
  if (!bundleID) throw new Error(`cannot read CFBundleIdentifier from ${options.app}`);
  const meta = { runID: path.basename(options.out), app: options.app, fixture: options.fixture, tier: options.tier,
    cacheState: options.cacheState, tuning: options.tuning ?? UNKNOWN, content: options.content, diskHighWaterBytes: options.diskHighWaterBytes,
    ...describeBuild(options.app), ...describeMachine(options.fixture), ...describeFixture(options) };
  return { meta, bundleID, cache: cacheDirectory(bundleID), owned: [], windows: [], cacheMoves: [] };
}

async function measure(options) {
  const run = prepareRun(options);
  const save = () => writeFileSync(path.join(options.out, 'run.json'), JSON.stringify(run, null, 2));
  try {
    if (options.cacheState === 'warm-memory') {
      const record = await launch(options.app, run);
      await sample(options, run, record, 0, true);
      for (let i = 1; i <= options.samples; i += 1) { await sample(options, run, record, i, false); save(); }
      await quit(record);
    } else {
      if (options.cacheState === 'warm-disk') {
        const record = await launch(options.app, run);
        await sample(options, run, record, 0, true);
        await quit(record);
      }
      for (let i = 1; i <= options.samples; i += 1) {
        if (options.cacheState === 'cold-app') moveCacheAside(options.out, run, i);
        const record = await launch(options.app, run);
        await sample(options, run, record, i, false);
        await quit(record);
        save();
      }
    }
  } finally {
    save();
    for (const record of run.owned) if (children.has(record.pid)) await quit(record).catch((e) => console.error(String(e)));
  }
  report(options.out);
}

async function resources(options) {
  const run = prepareRun(options);
  run.meta.cacheState = 'repeated browsing';
  const rounds = [];
  const record = await launch(options.app, run);
  try {
    for (let round = 1; round <= options.rounds; round += 1) {
      await sample(options, run, record, round, false);
      if (options.browse) runCommand(options.browse, { PICSEE_P308_PID: String(record.pid), PICSEE_P308_FIXTURE: options.fixture,
        PICSEE_P308_SAMPLE: String(round), PICSEE_P308_RUN_DIR: options.out });
      const rss = Number(quiet('/bin/ps', ['-o', 'rss=', '-p', String(record.pid)]));
      const du = quiet('/usr/bin/du', ['-sk', run.cache]);
      const snapshots = parseNdjson(signpostLog(record.pid, run.windows[0].startUs)).events.filter((e) => e.name === 'ResourceSnapshot');
      rounds.push({ round, rssKB: rss || UNKNOWN, diskBytes: du ? Number(du.split(/\s+/)[0]) * 1024 : UNKNOWN,
        snapshot: snapshots.at(-1)?.message ?? UNKNOWN });
    }
  } finally {
    await quit(record);
    writeFileSync(path.join(options.out, 'run.json'), JSON.stringify({ ...run, rounds }, null, 2));
  }
  writeFileSync(path.join(options.out, 'resources.md'), renderResources(run.meta, rounds));
  console.log(readFileSync(path.join(options.out, 'resources.md'), 'utf8'));
}

/** Re-parses a run directory's saved samples; usable offline. */
export function report(out) {
  const run = JSON.parse(readFileSync(path.join(out, 'run.json'), 'utf8'));
  const { events } = mergeSampleLogs(run.windows.map((w) => readFileSync(path.join(out, w.file), 'utf8')));
  const markdown = renderReport(run.meta, analyze(events, run.windows));
  writeFileSync(path.join(out, 'report.md'), markdown);
  console.log(markdown);
  return markdown;
}

async function main() {
  let options;
  try { options = parseArgs(process.argv.slice(2)); } catch (e) { console.error(e.message); return 64; }
  try {
    if (options.mode === 'parse') report(options.out);
    else if (options.mode === 'run') await measure(options);
    else await resources(options);
    return 0;
  } catch (e) {
    console.error(`FAIL ${options.mode} — ${e.message}`);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().then((code) => { process.exitCode = code; });
}
