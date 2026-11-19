#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { skippable } from '../../../../scripts/ci/native-inputs.mjs';

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
// `agents` and `tdd` stay optional for reviewed native-only diffs (selectSuites); CI runs them on every PR.
export const NODE_LANE = Object.freeze({
  always: ['scripts/ci/*.test.mjs', 'scripts/ledger/*.test.mjs', 'scripts/name-checks/*.test.mjs', 'scripts/release/*.test.mjs',
    'scripts/perf/*.test.mjs', 'scripts/hooks/*.test.mjs', 'scripts/device/tests/*.test.cjs',
    '.agents/skills/mado-delegator/scripts/*.test.mjs', '.agents/skills/mado-verify/tests/*.test.mjs'],
  agents: ['scripts/agents/*.test.mjs'],
  tdd: ['scripts/tdd/*.test.mjs'],
});
export const NODE_LANE_EXCEPTIONS = path.join(path.dirname(fileURLToPath(import.meta.url)), 'node-lane-exceptions.json');

// Text match, no YAML parser: the test paths of each `node --test …` or `node scripts/tdd/node-lane.mjs …` command.
export function workflowNodeTests(text) {
  const paths = [];
  for (const line of text.split('\n')) {
    const command = /\bnode\s+(?:--test\b|scripts\/tdd\/node-lane\.mjs\b)(.*)$/.exec(line);
    if (!command) continue;
    for (const raw of command[1].split(/\s*(?:[<>|;]|&&)/)[0].trim().split(/\s+/)) {
      const token = raw.replace(/^["']|["']$/g, '');
      if (!token.startsWith('-') && /\.test\.[cm]?js$/.test(token) && !paths.includes(token)) paths.push(token);
    }
  }
  return paths;
}

// `dir/name` or `dir/*.test.mjs` (one `*` level, as the workflows use); returns existing files, repo-relative, sorted.
export function expandPattern(root, pattern) {
  const dir = path.posix.dirname(pattern), base = path.posix.basename(pattern);
  if (!base.includes('*')) return fs.existsSync(path.join(root, pattern)) ? [pattern] : [];
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

export function nodeLaneFiles(root, {agents, tdd}, exceptions) {
  const patterns = [...NODE_LANE.always, ...(agents ? NODE_LANE.agents : []), ...(tdd ? NODE_LANE.tdd : [])];
  const excepted = [...new Set(exceptions.flatMap(entry => expandPattern(root, entry.file)))].sort();
  const files = [...new Set(patterns.flatMap(pattern => expandPattern(root, pattern)))].filter(file => !excepted.includes(file));
  return {files, excepted};
}

export function uncoveredWorkflowTests(root, texts, exceptions) {
  const ci = [...new Set(texts.flatMap(workflowNodeTests).flatMap(pattern => expandPattern(root, pattern)))];
  const {files, excepted} = nodeLaneFiles(root, {agents: true, tdd: true}, exceptions);
  return ci.filter(file => !files.includes(file) && !excepted.includes(file)).sort();
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'select') {
    const files = fs.readFileSync(args[0], 'utf8').split('\n').filter(Boolean);
    const choice = selectSuites(files);
    for (const [key, value] of Object.entries(choice)) console.log(`${key}=${value ? 1 : 0}`);
  } else if (cmd === 'fact') {
    const [lane, code, log, diff] = args;
    console.log(failureFact(lane, Number(code), fs.readFileSync(log, 'utf8'), fs.readFileSync(diff, 'utf8').split('\n').filter(Boolean)));
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
    const [wt, agents, tdd] = args;
    const {files, excepted} = nodeLaneFiles(wt, {agents: agents === '1', tdd: tdd === '1'}, readExceptions(NODE_LANE_EXCEPTIONS));
    if (!files.length) throw new Error('node lane matched no test files');
    console.log(`excepted=${excepted.length} (${excepted.join(', ') || 'none'})`);
    for (const file of files) console.log(file);
  } else { console.error('usage: owner-gates-tools.mjs select|fact|preflight|node-suites'); process.exitCode = 2; }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
