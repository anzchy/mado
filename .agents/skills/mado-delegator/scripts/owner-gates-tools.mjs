#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { skippable } from '../../../../scripts/ci/native-inputs.mjs';
import { failingTestInDiff, nodeLaneRequired, parseNulPaths } from '../../mado-verify/scripts/gate-policy.mjs';

// CI's classifier remains the one definition of native inputs. Optional Node suites
// are skipped only for paths this reviewed set does not read.
const NODE_SKIP_SAFE = ['App/', 'AppTests/', 'UITests/', 'Packages/MadoKit/Sources/',
  'Packages/MadoKit/Tests/', 'TestAssets/'];
export function selectSuites(files) {
  const nodeSafe = files.length > 0 && files.every(file => NODE_SKIP_SAFE.some(prefix => file.startsWith(prefix)));
  return {
    native: !files.length || files.some(file => !skippable(file)),
    agents: !nodeSafe,
    tdd: !nodeSafe,
    // #892: whether an implementer run needs the node lane (owner-gates.sh --role implementer); the delegator's always runs it.
    node: nodeLaneRequired(files),
  };
}

const safe = value => value.replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 80);
export function failureFact(lane, code, output, files = []) {
  if (code === 0) return '';
  const lock = /^\[heavy-lock\] lock wait timed out after \d+s$/m.test(output);
  if (code === 75 || lock) {
    const holder = /held by: pid=(\d+)/.exec(output)?.[1] ?? 'unknown';
    const alive = holder === 'unknown' ? 'unknown' : (() => { try { process.kill(Number(holder), 0); return 'yes'; } catch { return 'no'; } })();
    return `${lane}: lock-timeout holder=${holder} alive=${alive}`;
  }
  if (/hung before establishing connection/i.test(output)) return `${lane}: hung`;
  if (lane === 'design') {
    if (/^(?:design|preflight): missing node_modules\b/m.test(output)) return 'design: prereq=node_modules';
    if (/^(?:design|preflight): missing Playwright\b/m.test(output)) return 'design: prereq=Playwright';
  }
  if (lane === 'swift') {
    const failed = /Executed (\d+) tests?, with (\d+) failures?/i.exec(output)?.[2] ?? /(?:failed|failure)[=: ]+(\d+)/i.exec(output)?.[1] ?? 'unknown';
    return `swift: failed=${failed} timelimit=unknown other=unknown`;
  }
  if (lane === 'node') {
    const block = output.split(/^✖ failing tests:\s*$/m)[1] ?? '';
    const names = [...block.matchAll(/^✖ (.+?) \(\d+(?:\.\d+)?ms\)$/gm)].map(m => safe(m[1]));
    const locations = [...block.matchAll(/^test at ([^:\n]+\.test\.mjs):\d+(?::\d+)?$/gm)].map(m => m[1]);
    const relevant = locations.some(location => files.includes(location)) ||
      names.some(name => files.some(file => name.includes(path.basename(file).replace(/\.test\.mjs$/, ''))));
    return `node: failed=${names.length || 'unknown'} tests=${names.length ? names.join(',') : 'unknown'} in-diff=${names.length ? (relevant ? 'yes' : 'no') : 'unknown'}`;
  }
  const tests = /Tests run: (\d+), Failures: (\d+)/.exec(output);
  if (tests) return `${lane}: tests=${tests[1]} failed=${tests[2]}`;
  return `${lane}: exit=${code}`;
}

// #892: the failing tests of a node run, from the spec reporter's `✖ failing tests:` block (`test at <file>:<line>:<col>`
// before each `✖ <name> (<ms>ms)`). Only failures outside the diff, each with a known file in the worktree, get the one
// serial rerun of their files; anything else (in the diff, no location, nothing parsed) is not rerun and stays a failure.
export function rerunPlan(output, diffFiles, root) {
  const none = reason => ({rerun: false, reason, files: [], tests: []});
  const block = output.split(/^✖ failing tests:\s*$/m)[1];
  if (block === undefined) return none('failing tests unknown');
  const found = [];
  let at = null;
  for (const line of block.split('\n')) {
    const location = /^test at (.+?):\d+(?::\d+)?$/.exec(line);
    if (location) { at = location[1]; continue; }
    const failed = /^✖ (.+?) \(\d+(?:\.\d+)?ms\)$/.exec(line);
    if (failed) { found.push({file: at, name: failed[1]}); at = null; }
  }
  if (!found.length) return none('failing tests unknown');
  // Every failure the run counted must be one we read; otherwise an unread real failure could hide behind a passing rerun.
  const counted = /^ℹ fail (\d+)$/m.exec(output.split(/^✖ failing tests:\s*$/m)[0])?.[1];
  if (counted === undefined || Number(counted) !== found.length) return none('failing tests incomplete');
  const relative = file => {
    if (file === null) return null;
    let text = file;
    if (text.startsWith('file://')) { try { text = fileURLToPath(text); } catch { return null; } }
    if (!path.isAbsolute(text)) return path.posix.normalize(text).startsWith('../') ? null : path.posix.normalize(text);
    const rel = path.relative(root, text);
    return rel && !rel.startsWith('..') && !path.isAbsolute(rel) ? rel.split(path.sep).join('/') : null;
  };
  const tests = found.map(t => ({file: relative(t.file), name: t.name}));
  if (tests.some(t => t.file === null)) return none('failed files unknown');
  if (tests.some(t => failingTestInDiff(t, diffFiles))) return none('in-diff=yes');
  return {rerun: true, reason: null, files: [...new Set(tests.map(t => t.file))].sort(), tests};
}

export function preflight({ scriptsOwn, nodeModules, playwright, holder }) {
  if (!scriptsOwn) return 'script is not the gated worktree copy';
  if (!nodeModules) return 'missing node_modules; run npm ci --ignore-scripts';
  if (!playwright) return 'missing Playwright Chromium; run npx playwright install chromium';
  if (holder?.orphaned) return `heavy-lock holder=${holder.pid ?? 'unknown'} supervisor=dead`;
  return null;
}
export function inspectLock(lock) {
  const dir = path.dirname(lock), basename = path.basename(lock);
  let records;
  try { records = fs.readdirSync(dir).filter(name => name.startsWith(`${basename}.guardian-`) && name.endsWith('.owner')); }
  catch { return {holder:null, staleRecords:0}; }
  if (!fs.existsSync(lock)) return {holder:null, staleRecords:records.length};
  // Probe the kernel flock on a separate descriptor, and release it immediately.
  const probe = spawnSync('/usr/bin/python3', ['-c',
    'import fcntl,os,sys; f=os.open(sys.argv[1],os.O_RDONLY);\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)\nexcept BlockingIOError: sys.exit(1)', lock], {encoding:'utf8'});
  if (probe.status === 0) return {holder:null, staleRecords:records.length};
  if (probe.status !== 1) return {holder:null, staleRecords:0};
  const holders = spawnSync('lsof', ['-t', lock], {encoding:'utf8'}).stdout?.split(/\s+/).filter(Boolean) ?? [];
  for (const record of records) {
    let content;
    try { content = fs.readFileSync(path.join(dir, record), 'utf8'); } catch { continue; }
    const pid = Number(/^pid=(\d+)$/m.exec(content)?.[1]);
    const supervisor = Number(/^supervisor=(\d+)$/m.exec(content)?.[1]);
    if (!pid || !supervisor || !holders.includes(String(pid))) continue;
    const supervisorAlive = spawnSync('ps', ['-p', String(supervisor), '-o', 'pid='], {encoding:'utf8'}).stdout?.trim() === String(supervisor);
    return {holder:{pid, orphaned:!supervisorAlive}, staleRecords:0};
  }
  return {holder:null, staleRecords:0};
}

// #750: the local node lane runs every node test the workflows run (.github/workflows/*.yml `node --test` and
// node-lane.mjs commands), except the reviewed entries of node-lane-exceptions.json; owner-gates-tools.test.mjs checks it.
// i760-fix1: pr-body.yml runs scripts/agents and scripts/tdd on every PR, so the lane runs them for every selection too.
export const NODE_LANE = Object.freeze({
  always: ['scripts/ci/*.test.mjs', 'scripts/ledger/*.test.mjs', 'scripts/name-checks/*.test.mjs', 'scripts/release/*.test.mjs',
    'scripts/site/*.test.mjs',
    'scripts/perf/*.test.mjs', 'scripts/hooks/*.test.mjs', 'scripts/device/tests/*.test.cjs', 'scripts/agents/*.test.mjs',
    'scripts/tdd/*.test.mjs', '.agents/skills/mado-delegator/scripts/*.test.mjs', '.agents/skills/mado-verify/tests/*.test.mjs'],
});
// #916 WI-4 (item 6, #909): the Swift-source scans an implementer run keeps when it skips the node lane on a product-only
// diff (owner-gates.sh --role implementer). Both are light node-lane files that read the tracked Swift sources: the #358
// for … where ban and the code-identity scan. The delegator's full node lane runs them too.
export const SOURCE_SCANS = Object.freeze(['scripts/ci/for-where-ban.test.mjs', 'scripts/name-checks/module-name.test.mjs']);
export const NODE_LANE_EXCEPTIONS = path.join(path.dirname(fileURLToPath(import.meta.url)), 'node-lane-exceptions.json');

// Text match, no YAML parser. Each step's `run:` value is read whole (plain, quoted, `|` literal, `>` folded), shell `\`
// continuations are joined, and every `node [flags] --test …` or `node scripts/tdd/node-lane.mjs …` command gives its
// arguments. Shapes this cannot read are reported as problems, so the parity check fails closed instead of dropping them.
const VALUE_FLAGS = new Set(['--test-reporter', '--test-reporter-destination', '--test-name-pattern', '--test-skip-pattern',
  '--test-concurrency', '--test-timeout', '--test-shard', '--import', '--require', '-r', '--loader', '--experimental-loader',
  '--conditions', '-C', '--env-file', '--input-type']);
const NODE_TEST = /(?:^|[\s;&|(])node((?:\s+-\S+)*)\s+(--test(?=\s|$)|scripts\/tdd\/node-lane\.mjs(?=\s|$))(.*)$/;

function runBlocks(text) {
  const lines = text.split('\n'), steps = [], checkouts = new Set();
  let step = null;
  const flush = () => {
    if (step && /^actions\/checkout@/.test(step.uses ?? '') && step.path) checkouts.add(step.path);
    if (step) steps.push(step);
  };
  const scalar = value => value.trim().replace(/^(["'])(.*)\1$/, '$2');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*#/.test(line) || !line.trim()) continue;
    const item = /^(\s*)-\s+(.*)$/.exec(line);
    if (item) { flush(); step = {runs: [], indent: item[1].length + 2}; }
    const body = item ? `${' '.repeat(item[1].length + 2)}${item[2]}` : line;
    const key = /^(\s*)([A-Za-z-]+):\s*(.*)$/.exec(body);
    if (!key) continue;
    const [, indent, name, value] = key;
    step ??= {runs: []};
    if (name === 'uses') step.uses = scalar(value);
    else if (name === 'path') step.path = scalar(value);
    else if (name === 'working-directory') step.workingDirectory = scalar(value);
    else if (name === 'run') {
      const block = /^([|>])[-+]?\d*\s*(?:#.*)?$/.exec(value);
      if (!block && value.trim()) { step.runs.push(scalar(value)); continue; }
      const body = [];
      while (i + 1 < lines.length && (!lines[i + 1].trim() || /^\s*/.exec(lines[i + 1])[0].length > indent.length)) body.push(lines[++i].trim());
      while (body.length && !body.at(-1)) body.pop();
      if (block?.[1] === '>') step.runs.push(body.join(' ').replace(/\s{2,}/g, ' '));
      else step.runs.push(body.join('\n'));
    }
  }
  flush();
  return steps.flatMap(s => s.runs.map(run => ({run, workingDirectory: s.workingDirectory, checkouts})));
}

export function parseWorkflowNodeTests(text) {
  const paths = [], problems = [];
  for (const {run, workingDirectory, checkouts} of runBlocks(text)) {
    let cd = false;
    for (const line of run.replace(/\\\n\s*/g, ' ').split('\n')) {
      const match = NODE_TEST.exec(line);
      const before = match ? line.slice(0, match.index + 1) : line;
      if (/(?:^|[\s;&|(])(?:cd|pushd)\s/.test(before)) cd = true;
      if (!match) continue;
      const command = match[0].trim();
      if (cd) { problems.push(`unreadable: cd before the node command (paths are read from the repository root) in: ${command}`); continue; }
      if (workingDirectory && !checkouts.has(workingDirectory)) {
        problems.push(`unreadable: working-directory ${workingDirectory} is not a checkout path in: ${command}`); continue;
      }
      const args = match[3].split(/\s*(?:&&|\|\||[;|&<>]|\d>)/)[0].trim().split(/\s+/).filter(Boolean);
      let found = 0;
      for (let k = 0; k < args.length; k++) {
        const token = args[k].replace(/^["']|["']$/g, '');
        if (token.startsWith('-')) { if (VALUE_FLAGS.has(token)) k++; continue; }
        found++;
        if (/[$`]/.test(token)) problems.push(`unreadable: ${token} (shell or workflow variable) in: ${command}`);
        else if (token.includes('**')) problems.push(`unreadable: ${token} (** is not expanded here) in: ${command}`);
        else if (/[{}[\]?]/.test(token)) problems.push(`unreadable: ${token} (glob syntax other than one *) in: ${command}`);
        else if (token.endsWith('/')) problems.push(`unreadable: ${token} (directory argument; node 22 runs no directory) in: ${command}`);
        else if (!paths.includes(token)) paths.push(token);
      }
      if (!found) problems.push(`no path: ${command}`);
    }
  }
  return {paths, problems};
}
export function workflowNodeTests(text) { return parseWorkflowNodeTests(text).paths; }

// `dir/name` or `dir/*.test.mjs` (one `*` level, as the workflows use); returns existing files, repo-relative, sorted.
export function expandPattern(root, pattern) {
  const dir = path.posix.dirname(pattern), base = path.posix.basename(pattern);
  if (!base.includes('*')) {
    try { return fs.statSync(path.join(root, pattern)).isFile() ? [pattern] : []; } catch { return []; }
  }
  const re = new RegExp(`^${base.split('*').map(part => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*')}$`);
  let names;
  try { names = fs.readdirSync(path.join(root, dir), {withFileTypes: true}); } catch { return []; }
  return names.filter(entry => entry.isFile() && re.test(entry.name)).map(entry => `${dir}/${entry.name}`).sort();
}

export function readExceptions(file) {
  const list = JSON.parse(fs.readFileSync(file, 'utf8')).exceptions;
  if (!Array.isArray(list)) throw new Error(`invalid node lane exception list in ${file}`);
  for (const entry of list)
    if (typeof entry?.file !== 'string' || !entry.file || typeof entry.reason !== 'string' || entry.reason.trim().length < 20 ||
        typeof entry.ticket !== 'string' || !/^#[1-9]\d*$/.test(entry.ticket))
      throw new Error(`invalid node lane exception ${JSON.stringify(entry)}: needs file, reason and ticket (#n)`);
  return list;
}

// The selection (selectSuites) no longer narrows the node lane: every CI node suite runs for every diff.
export function nodeLaneFiles(root, _selection, exceptions) {
  const excepted = [...new Set(exceptions.flatMap(entry => expandPattern(root, entry.file)))].sort();
  const files = [...new Set(NODE_LANE.always.flatMap(pattern => expandPattern(root, pattern)))].filter(file => !excepted.includes(file));
  return {files, excepted};
}

// Uncovered CI test files, then every problem: an unreadable command shape, a command with no path, or a path that
// matches no file (`no files: …`, also a directory given without a trailing slash). Empty means the lane covers CI.
export function uncoveredWorkflowTests(root, texts, exceptions, selection = {agents: true, tdd: true}) {
  const parsed = texts.map(parseWorkflowNodeTests);
  const problems = parsed.flatMap(p => p.problems);
  const patterns = [...new Set(parsed.flatMap(p => p.paths))];
  const ci = [];
  for (const pattern of patterns) {
    const files = expandPattern(root, pattern);
    if (!files.length) {
      let directory = false;
      try { directory = fs.statSync(path.join(root, pattern)).isDirectory(); } catch {}
      problems.push(directory ? `unreadable: ${pattern} (directory argument; node 22 runs no directory)` : `no files: ${pattern}`);
    }
    for (const file of files) if (!ci.includes(file)) ci.push(file);
  }
  const {files, excepted} = nodeLaneFiles(root, selection, exceptions);
  return [...ci.filter(file => !files.includes(file) && !excepted.includes(file)).sort(), ...problems];
}

// #760: machine facts before any lane. A loaded machine gives "no evidence" (exit 2), never a red lane.
// Defaults for this four-performance-core mini: load 6 is 1.5x performance cores. During Mado builds free memory
// was 44-55%; 25% leaves margin below that observed range. VM pressure 1 is normal; 2 or higher defers evidence.
// The owner can tune each limit. This preflight only reports/refuses; it never kills a competing process.
export const LOAD_THRESHOLDS = Object.freeze({
  maxLoad: {env: 'OWNER_GATES_MAX_LOAD', value: 6},
  minMemFree: {env: 'OWNER_GATES_MIN_MEM_FREE', value: 25},
  maxPressure: {env: 'OWNER_GATES_MAX_PRESSURE', value: 1},
});
export function loadThresholds(env = process.env) {
  const out = {};
  for (const [key, {env: name, value}] of Object.entries(LOAD_THRESHOLDS)) {
    const raw = env[name];
    if (raw === undefined || raw === '') { out[key] = {name, value}; continue; }
    const number = Number(raw);
    if (!Number.isFinite(number) || number < 0) throw new Error(`${name}=${raw} is not a non-negative number`);
    out[key] = {name, value: number};
  }
  return out;
}
export function parseFacts({loadavg, level, pressure}) {
  const load = /^\{\s*(\d+(?:\.\d+)?)\s/.exec(loadavg ?? '')?.[1];
  const integer = text => /^\d+$/.test((text ?? '').trim()) ? Number(text.trim()) : null;
  return {load: load === undefined ? null : Number(load), memFree: integer(level), pressure: integer(pressure)};
}
export function loadVerdict(facts, thresholds) {
  const show = value => value === null ? 'unknown' : String(value);
  const line = `load=${show(facts.load)} mem_free=${facts.memFree === null ? 'unknown' : `${facts.memFree}%`} pressure=${show(facts.pressure)}`;
  const notes = [], over = [];
  const check = (value, label, test, text) => {
    if (value === null) notes.push(`preflight-note: ${label} unreadable; no refusal on it`);
    else if (test(value)) over.push(text(value));
  };
  check(facts.load, 'load average', v => v > thresholds.maxLoad.value, v => `load ${v} over ${thresholds.maxLoad.name}=${thresholds.maxLoad.value}`);
  check(facts.memFree, 'kern.memorystatus_level', v => v < thresholds.minMemFree.value, v => `mem_free ${v}% under ${thresholds.minMemFree.name}=${thresholds.minMemFree.value}`);
  check(facts.pressure, 'kern.memorystatus_vm_pressure_level', v => v > thresholds.maxPressure.value, v => `pressure ${v} over ${thresholds.maxPressure.name}=${thresholds.maxPressure.value}`);
  return {line, notes, refuse: over.length ? over.join('; ') : null};
}
export function readFacts(sysctl = process.env.OWNER_GATES_SYSCTL || '/usr/sbin/sysctl') {
  const read = name => { const r = spawnSync(sysctl, ['-n', name], {encoding: 'utf8', timeout: 5000, killSignal: 'SIGKILL'}); return r.status === 0 ? r.stdout.trim() : null; };
  return parseFacts({loadavg: read('vm.loadavg'), level: read('kern.memorystatus_level'), pressure: read('kern.memorystatus_vm_pressure_level')});
}

// Read one bounded process snapshot. Only a command name and PID are ever returned;
// arguments are used for classification and never written into the gate summary.
export function competingHeavyProcesses(output, selfPid = process.pid) {
  const found = [];
  for (const line of output.trim().split('\n')) {
    const match = /^\s*(\d+)\s+(\S+)\s+(.+)$/.exec(line);
    if (!match) return null;
    const pid = Number(match[1]), name = path.basename(match[2]), args = match[3];
    if (pid === selfPid) continue;
    const nativeHeavy = /^(?:swift|swift-frontend|xcodebuild|xcodegen|clang|clang\+\+|ld|metal|actool|ibtoold)$/.test(name);
    const wrapper = /(?:^|\s)(?:scripts\/heavy-lock\.sh|scripts\/tdd\/heavy-lock\.py)(?:\s|$)/.test(args);
    const nodeHeavy = name === 'node' && /(?:scripts\/tdd\/(?:unit-lane|app-lane|trash-lane)\.mjs|node --test)/.test(args);
    if (nativeHeavy || wrapper || nodeHeavy) found.push(`${pid}:${name}`);
  }
  return found;
}
export function readCompetingHeavyProcesses(ps = process.env.OWNER_GATES_PS || '/bin/ps') {
  const result = spawnSync(ps, ['-axo', 'pid=,comm=,args='], {encoding:'utf8', timeout:5000, killSignal:'SIGKILL', maxBuffer:16*1024*1024});
  return result.status === 0 ? competingHeavyProcesses(result.stdout) : null;
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'select') {
    // #892 fix1: owner-gates.sh writes the diff NUL-delimited (`git diff --name-only -z`).
    const files = parseNulPaths(fs.readFileSync(args[0], 'utf8'));
    const choice = selectSuites(files);
    for (const [key, value] of Object.entries(choice)) console.log(`${key}=${value ? 1 : 0}`);
  } else if (cmd === 'fact') {
    const [lane, code, log, diff] = args;
    console.log(failureFact(lane, Number(code), fs.readFileSync(log, 'utf8'), parseNulPaths(fs.readFileSync(diff, 'utf8'))));
  } else if (cmd === 'rerun-plan') {
    const [log, diff, root] = args;
    const plan = rerunPlan(fs.readFileSync(log, 'utf8'), parseNulPaths(fs.readFileSync(diff, 'utf8')), root);
    if (!plan.rerun) { console.log(`skip ${plan.reason}`); return; }
    console.log('run');
    for (const file of plan.files) console.log(`file ${file}`);
    for (const t of plan.tests) console.log(`test ${t.file} :: ${t.name}`);
  } else if (cmd === 'preflight') {
    const [wt, script] = args;
    let own = false;
    try { own = fs.realpathSync(script) === fs.realpathSync(path.join(wt, '.agents/skills/mado-delegator/scripts/owner-gates.sh')); }
    catch { own = false; }
    let playwright = false;
    if (fs.existsSync(path.join(wt, 'node_modules/playwright'))) {
      try {
        const imported = await import(path.join(wt, 'node_modules/playwright/index.mjs'));
        playwright = fs.existsSync(imported.chromium.executablePath());
      } catch { playwright = false; }
    }
    const lock = process.env.MADO_HEAVY_LOCK ?? path.join(process.env.HOME, '.mado/locks/heavy.lock');
    const inspected = inspectLock(lock);
    const reason = preflight({scriptsOwn:own, nodeModules:fs.existsSync(path.join(wt, 'node_modules')),
      playwright, holder:inspected.holder});
    if (reason) { console.log(`preflight: ${reason}`); process.exitCode = 2; }
    else {
      if (inspected.staleRecords) console.log(`preflight: stale-owner-records=${inspected.staleRecords}`);
      console.log('preflight: ok');
    }
  } else if (cmd === 'node-suites') {
    const [wt] = args;
    const {files, excepted} = nodeLaneFiles(wt, null, readExceptions(NODE_LANE_EXCEPTIONS));
    if (!files.length) throw new Error('node lane matched no test files');
    console.log(`excepted=${excepted.length} (${excepted.join(', ') || 'none'})`);
    for (const file of files) console.log(file);
  } else if (cmd === 'source-scans') {
    const [wt] = args;
    const missing = SOURCE_SCANS.filter(file => !fs.existsSync(path.join(wt, file)));
    if (missing.length) { for (const file of missing) console.error(`missing source scan: ${file}`); process.exitCode = 2; return; }
    for (const file of SOURCE_SCANS) console.log(file);
  } else if (cmd === 'load-preflight') {
    let verdict;
    try { verdict = loadVerdict(readFacts(), loadThresholds()); }
    catch (error) { console.log(`refuse: ${error.message}`); process.exitCode = 2; return; }
    console.log(verdict.line);
    // i760-fix1 L1: a run with a threshold set by environment says which limits were in force.
    if (Object.values(LOAD_THRESHOLDS).some(({env}) => (process.env[env] ?? '') !== '')) {
      const t = loadThresholds();
      console.log(`limits=${t.maxLoad.value}/${t.minMemFree.value}%/${t.maxPressure.value}`);
    }
    const competing = readCompetingHeavyProcesses();
    console.log(`competing-heavy=${competing === null ? 'unknown' : competing.join(',') || 'none'}`);
    if (competing === null) console.log('preflight-note: competing heavy process query unreadable');
    if (process.env.MADO_GATES_PREFLIGHT === 'off') console.log('preflight-guard=off');
    for (const note of verdict.notes) console.log(note);
    if (verdict.refuse && process.env.MADO_GATES_PREFLIGHT !== 'off') { console.log(`refuse: ${verdict.refuse}`); process.exitCode = 2; }
  } else { console.error('usage: owner-gates-tools.mjs select|fact|rerun-plan|preflight|node-suites|source-scans|load-preflight'); process.exitCode = 2; }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
