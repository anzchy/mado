#!/usr/bin/env node
/** Run the compiled App test bundle. Set PICSEE_APP_LANE_NO_RETRY=1 for RED receipts. */
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import path from "node:path";
import { classifyFlaky } from "../ci/flaky-gate.mjs";

const lock = fileURLToPath(new URL("../heavy-lock.sh", import.meta.url));
const bundle = ".build/dd-ci/Build/Products/Debug/PicseeAppTests.xctest";
const crashRecords = [
  /^error: (?:Process '[^'\r\n]+' )?Exited with [^\r\n]*\bsignal\b[^\r\n]*$/i,
  /^(?:[^:\r\n]+\.swift:\d+(?::\d+)?: )?Fatal error:(?: |$)/,
  /^Test (?:Case|Suite) '.+' crashed(?: \([^\r\n]*\))?\.?$/,
  /^✘ Test .+ crashed after \d+(?:\.\d+)? seconds(?: with \d+ issues?)?\.$/,
  /^(?:[^:\r\n]+: )?(?:Segmentation fault|Bus error|Abort trap)(?:: \d+)?\s*$/i,
];
const testName = label => label.endsWith('()') ? label.slice(0, -2) : label;

/** Shared completeness and failure parser. Importing this module never launches native tests. */
export function parseAppResult(run, selection = null) {
  const stdout = run.stdout ?? "", stderr = run.stderr ?? "";
  const output = `${stdout}\n${stderr}`;
  const clean = output.replace(/\x1b\[[0-9;]*m/g, '').replace(/\r/g, '');
  const rootDone = (/Test Suite 'All tests' (?:passed|failed) at /.test(clean) ||
    (selection !== null && /Test Suite 'Selected tests' (?:passed|failed) at /.test(clean))) &&
    /Executed \d+ tests?, with \d+ failures? \(\d+ unexpected\)/.test(clean);
  const rootFailures = [...clean.matchAll(/Executed \d+ tests?, with (\d+) failures? \((\d+) unexpected\)/g)]
    .some(match => Number(match[1]) || Number(match[2]));
  const starts = [...clean.matchAll(/^◇ Test run started\.$/gm)];
  const summaries = [...clean.matchAll(/^[✔✘] Test run with (\d+) tests? in \d+ suites? (passed|failed) after .+ seconds(?:\.| with (\d+) issues?\.)$/gm)];
  const passed = [...clean.matchAll(/^✔ Test (?!run with ).+ passed after /gm)].length;
  const failures = [...clean.matchAll(/^✘ Test (?!run with )(.+) failed after /gm)];
  const failureNames = failures.map(match => testName(match[1]));
  const failed = failures.length;
  const skipped = [...clean.matchAll(/^➜ Test .+ skipped(?::| after |\.)/gm)].length;
  const count = summaries.length === 1 ? Number(summaries[0][1]) : 0;
  const issues = [...clean.matchAll(/^✘ Test (.+) recorded an issue at (.+)$/gm)]
    .map(match => ({ name: testName(match[1]), signature: match[2] }));
  const issueRecords = clean.split('\n').filter(line => line.startsWith('✘') && line.includes('recorded an issue'));
  const unattributedIssues = issueRecords.length !== issues.length || issues.some(issue => !failureNames.includes(issue.name)) ||
    (summaries.length === 1 && Number(summaries[0][3] ?? 0) !== issues.length);
  const crash = clean.split('\n').some(line => crashRecords.some(record => record.test(line)));
  const selected = selection === null ? null : selectionComplete(clean, selection);
  const xctFailed = selected?.failed ?? 0;
  let reliable = !(run.error || run.signal || crash || (selection === null && rootFailures) ||
    (selection === null ? !rootDone : !selected.complete) || starts.length !== 1 || summaries.length !== 1 || !count ||
    passed + failed + skipped !== count || (summaries[0]?.[2] === "failed") !== (failed > 0) ||
    ![0, 1].includes(run.status) || (run.status === 0) !== (failed + xctFailed === 0));
  return { reliable, status: reliable ? run.status : 70, output,
    count: count + (selected?.count ?? 0), passed: passed + (selected?.passed ?? 0),
    failed: failed + xctFailed, skipped: skipped + (selected?.skipped ?? 0), xctFailed,
    failureNames: [...failureNames, ...(selected?.failureNames ?? [])], issues, unattributedIssues };
}

const quarantineFile = fileURLToPath(new URL("./app-quarantine.json", import.meta.url));
const swiftID = /^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+(?:\/[A-Za-z_]\w*)*\((?:[A-Za-z_]\w*:)*\)$/;
const xctID = /^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\/[A-Za-z_]\w*$/;
const shortXCTestID = id => id.slice(id.lastIndexOf('.') + 1);
const swiftLabel = id => id.includes('/') ? id.slice(id.lastIndexOf('/') + 1) : id.slice(id.indexOf('.') + 1);
const terminalLabel = label => label.replace(/ with \d+ test cases?$/, '');

function loadQuarantine(filename) {
  const list = JSON.parse(readFileSync(filename, 'utf8'));
  if (!Array.isArray(list)) throw new Error('quarantine must be an array');
  const ids = new Set();
  for (const entry of list) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry) ||
        typeof entry.id !== 'string' || !(swiftID.test(entry.id) || xctID.test(entry.id)))
      throw new Error('quarantine id must be an exact supported XCTest Class/method or Swift Testing Module.func() identifier');
    if (!Number.isSafeInteger(entry.issue) || entry.issue <= 0) throw new Error('quarantine issue must be a positive integer');
    if (typeof entry.reason !== 'string' || !entry.reason.trim()) throw new Error('quarantine reason must be nonblank');
    if (ids.has(entry.id)) throw new Error(`quarantine duplicate id ${entry.id}`);
    ids.add(entry.id);
  }
  return list;
}

// Discovery uses the frameworks' complete runtime trees, without running test bodies.
// Keep this helper here: it is tooling compiled into a temporary directory, never App code.
const inventorySource = `
import Foundation
import XCTest
import Testing
import Darwin
@main struct AppLaneInventory {
 static func main() async {
  guard CommandLine.arguments.count == 2,
    dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_GLOBAL) != nil else {
    fputs("app-lane inventory: bundle load failed\\n", stderr); exit(70)
  }
  print("APP_LANE_INVENTORY_BEGIN")
  func walk(_ node: XCTest) {
   if let suite = node as? XCTestSuite { for child in suite.tests { walk(child) } }
   else { print("XCT_ID=" + node.name) }
  }
  walk(XCTestSuite.default)
  var args = __CommandLineArguments_v0()
  args.listTests = true
  let status: CInt = await __swiftPMEntryPoint(passing: args)
  guard status == 0 else { exit(70) }
  print("APP_LANE_INVENTORY_END")
 }
}
`;

function inventoryRows(output) {
  const lines = output.trim().split('\n').map(line => line.replace(/\r$/, ''));
  if (lines.shift() !== 'APP_LANE_INVENTORY_BEGIN' || lines.pop() !== 'APP_LANE_INVENTORY_END')
    throw new Error('inventory is incomplete or unframed');
  const rows = lines.map(line => {
    const xct = /^XCT_ID=-\[([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*) ([A-Za-z_]\w*)\]$/.exec(line);
    if (xct) return { kind: 'xctest', id: `${xct[1]}/${xct[2]}`, label: shortXCTestID(`${xct[1]}/${xct[2]}`) };
    if (swiftID.test(line)) return { kind: 'swift', id: line, label: swiftLabel(line) };
    throw new Error(`inventory unsupported identifier ${line}`);
  });
  if (!rows.length || new Set(rows.map(row => row.id)).size !== rows.length ||
      new Set(rows.map(row => `${row.kind}:${row.label}`)).size !== rows.length)
    throw new Error('inventory is empty, duplicated or ambiguous');
  return rows;
}

function discoverInventory(spawn, env, bundlePath) {
  // Start the execution deadline only after heavy-lock admits the command.
  // The parent has no spawn timeout, so queue wait uses heavy-lock's own budget.
  const boundedCommand = `
const admitted = Date.now();
const { spawn, spawnSync } = require('node:child_process');
let child, exited = false, closed = false, status = 70, stopping = false, finished = false;
let deadline, poll, escalation, drain;
const snapshot = () => {
  const probe = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,stat='], {
    encoding: 'utf8', timeout: 100, killSignal: 'SIGKILL', maxBuffer: 16 * 1024 * 1024
  });
  if (probe.error || probe.status !== 0) throw new Error('cannot inspect discovery process group');
  return { probe: probe.pid, rows: probe.stdout.trim().split('\\n').map(line => {
    const [pid, parent, group, state] = line.trim().split(/\\s+/);
    return { pid: Number(pid), parent: Number(parent), group: Number(group), state };
  }) };
};
const initial = snapshot(), group = initial.rows.find(row => row.pid === process.pid)?.group;
if (!group) throw new Error('cannot identify discovery process group');
// The local heavy-lock manager gives discovery its own worker group. Protect
// this supervisor and its ancestor chain while inspecting native members.
const protectedPids = new Set([process.pid]);
for (let pid = process.ppid; pid && !protectedPids.has(pid);) {
  protectedPids.add(pid); pid = initial.rows.find(row => row.pid === pid)?.parent;
}
const members = () => {
  let current;
  try { current = snapshot(); } catch { return null; }
  return current.rows.filter(row => row.group === group && !protectedPids.has(row.pid) &&
    row.pid !== current.probe && !row.state?.startsWith('Z'));
};
const groupAlive = () => {
  if (!stopping && (!exited || !closed)) return true;
  const active = members();
  return active === null || active.length > 0;
};
const signalGroup = signal => {
  // If inspection fails, retain failure state and at least stop the known
  // child; the manager still owns every member of this unchanged group.
  const active = members() ?? (child?.pid ? [{ pid: child.pid }] : []);
  for (const member of active) try { process.kill(member.pid, signal); }
  catch (error) { if (error.code !== 'ESRCH') process.stderr.write('app-lane inventory signal failed: ' + error.message + '\\n'); }
};
const finish = code => {
  if (finished) return;
  finished = true;
  clearTimeout(deadline); clearInterval(poll); clearTimeout(escalation); clearTimeout(drain);
  // Native descendants own only these private pipes, never the outer capture.
  // Destroy them at the finite drain bound even if an OS task resists KILL.
  child?.stdout?.destroy(); child?.stderr?.destroy(); child?.unref();
  process.exitCode = code;
};
const check = () => {
  if (finished || groupAlive()) return;
  if (stopping) finish(70);
  else if (exited && closed) finish(status);
};
const stop = reason => {
  if (finished || stopping) return;
  stopping = true;
  process.stderr.write('app-lane inventory command failed: ' + reason + '\\n');
  signalGroup('SIGTERM');
  escalation = setTimeout(() => { signalGroup('SIGKILL'); check(); }, 250);
  drain = setTimeout(() => {
    if (groupAlive()) process.stderr.write('app-lane inventory group survived KILL; closing capture\\n');
    finish(70);
  }, 750);
  check();
};
process.on('SIGTERM', () => stop('cancelled by SIGTERM'));
process.on('SIGINT', () => stop('cancelled by SIGINT'));
// A hard-killed caller closes its capture reader. Cleanup must survive EPIPE.
process.stdout.on('error', () => stop('capture receiver closed'));
process.stderr.on('error', () => stop('capture receiver closed'));
poll = setInterval(check, 10);
child = spawn(process.argv[2], process.argv.slice(3), { stdio: ['ignore', 'pipe', 'pipe'] });
child.stdout.on('data', data => process.stdout.write(data));
child.stderr.on('data', data => process.stderr.write(data));
child.on('error', error => stop(error.message));
child.on('exit', (code, signal) => {
  exited = true; status = signal || code === null ? 70 : code;
  if (signal) stop('command exited with ' + signal);
  check();
});
child.on('close', () => { closed = true; check(); });
deadline = setTimeout(() => stop('execution timeout'), Math.max(1, Number(process.argv[1]) - (Date.now() - admitted)));
`;
  const checked = (args, locked = true) => {
    const options = { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, env };
    const workerEnv = { ...env, PICSEE_HEAVY_LOCK_DRAIN_SECS: '0.25', PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: '0.25' };
    if (env.PICSEE_HEAVY_LOCK_HELD === '1') {
      // Keep the manager in the outer job's group, but let it create a private
      // worker group. Reuse neither the outer flock nor its shared mdpro lock.
      delete workerEnv.PICSEE_HEAVY_LOCK_HELD;
      delete workerEnv.MDPRO_HEAVY_LOCK_HELD;
      workerEnv.PICSEE_HEAVY_LOCK = env.PICSEE_HEAVY_LOCK
        ? `${env.PICSEE_HEAVY_LOCK}.app-discovery`
        : path.join(homedir(), '.picsee/locks/app-discovery.lock');
      workerEnv.PICSEE_MDPRO_LOCK = 'off';
    }
    const run = locked
      ? spawn(lock, [process.execPath, '-e', boundedCommand, '120000', ...args], { ...options, env: workerEnv })
      : spawn(args[0], args.slice(1), { ...options, timeout: 120000 });
    if (run.error || run.signal || run.status !== 0) throw new Error(`inventory command failed: ${run.error?.message ?? run.stderr ?? run.signal ?? run.status}`);
    return run.stdout ?? '';
  };
  const platform = checked(['xcrun', '--show-sdk-platform-path'], false).trim();
  if (!path.isAbsolute(platform) || platform.includes('\n')) throw new Error('inventory invalid SDK platform path');
  const frameworks = path.join(platform, 'Developer/Library/Frameworks');
  const privateFrameworks = path.join(platform, 'Developer/Library/PrivateFrameworks');
  const libraries = path.join(platform, 'Developer/usr/lib');
  const directory = mkdtempSync(path.join(tmpdir(), 'picsee-app-inventory-'));
  try {
    const source = path.join(directory, 'Inventory.swift'), executable = path.join(directory, 'inventory');
    writeFileSync(source, inventorySource);
    checked(['xcrun', 'swiftc', '-parse-as-library', '-F', frameworks, '-L', libraries, '-lXCTestSwiftSupport',
      ...[frameworks, privateFrameworks, libraries].flatMap(p => ['-Xlinker', '-rpath', '-Xlinker', p]), source, '-o', executable]);
    const binary = path.join(path.resolve(bundlePath), 'Contents/MacOS', path.basename(bundlePath, '.xctest'));
    return inventoryRows(checked([executable, binary]));
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

function selectionComplete(clean, selection) {
  const { inventory, retained } = selection;
  const known = new Map(inventory.map(row => [`${row.kind}:${row.label}`, row.id]));
  const expected = new Set(retained.map(row => row.id));
  const started = new Set(), finished = new Set();
  const totals = { count: 0, passed: 0, failed: 0, skipped: 0, failureNames: [] };
  const suites = [];
  let pendingSuite = null, roots = 0, invalid = false;
  const resolve = (kind, label) => known.get(`${kind}:${kind === 'xctest' ? shortXCTestID(label) : terminalLabel(label)}`);
  const begin = (kind, label) => {
    const id = resolve(kind, label);
    if (!id || !expected.has(id) || started.has(id)) invalid = true;
    started.add(id);
  };
  const finish = (kind, label, state) => {
    const skipped = state === 'skipped';
    const id = resolve(kind, label);
    if (!id || !expected.has(id) || finished.has(id) || (!skipped && !started.has(id))) invalid = true;
    finished.add(id);
    if (kind === 'xctest') {
      totals.count++;
      totals[state]++;
      if (state === 'failed') totals.failureNames.push(shortXCTestID(label));
      for (const suite of suites) {
        suite.count++;
        if (skipped) suite.skipped++;
        if (state === 'failed') suite.failed++;
      }
      if (state === 'failed' && suites.length) suites.at(-1).directFailed++;
    }
  };
  for (const line of clean.split('\n')) {
    const suiteStart = /^Test Suite '(.+)' started at /.exec(line);
    const suiteEnd = /^Test Suite '(.+)' (passed|failed) at /.exec(line);
    const summary = /^\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)/.exec(line);
    if (suiteStart) {
      if (pendingSuite) invalid = true;
      if (!suites.length) {
        if (!['All tests', 'Selected tests'].includes(suiteStart[1])) invalid = true;
        roots++;
      }
      suites.push({ name: suiteStart[1], count: 0, skipped: 0, failed: 0, directFailed: 0, childFailures: 0, childUnexpected: 0 });
    } else if (suiteEnd) {
      if (pendingSuite) invalid = true;
      pendingSuite = suites.pop();
      if (pendingSuite?.name !== suiteEnd[1]) invalid = true;
      if ((suiteEnd[2] === 'failed') !== ((pendingSuite?.failed ?? 0) > 0)) invalid = true;
    } else if (summary) {
      const assertionFailures = Number(summary[3]), unexpected = Number(summary[4]);
      if (!pendingSuite || Number(summary[1]) !== pendingSuite.count ||
          Number(summary[2] ?? 0) !== pendingSuite.skipped || unexpected > assertionFailures ||
          // XCTest counts failed assertions, which can exceed failed test cases.
          assertionFailures < pendingSuite.failed || (assertionFailures === 0) !== (pendingSuite.failed === 0) ||
          (pendingSuite.directFailed === 0 ? assertionFailures !== pendingSuite.childFailures :
            assertionFailures < pendingSuite.childFailures + pendingSuite.directFailed) ||
          // Thrown XCTest errors are unexpected failures, still attributed to
          // failed cases. Preserve the subset and enclosing-suite totals.
          (pendingSuite.directFailed === 0 ? unexpected !== pendingSuite.childUnexpected :
            unexpected < pendingSuite.childUnexpected ||
              unexpected - pendingSuite.childUnexpected > assertionFailures - pendingSuite.childFailures)) invalid = true;
      if (suites.length) {
        suites.at(-1).childFailures += assertionFailures;
        suites.at(-1).childUnexpected += unexpected;
      }
      pendingSuite = null;
    }
    const xct = /^Test Case '-\[([^\]\r\n]+) ([A-Za-z_]\w*)\]' (started\.|(passed|failed|skipped) \()/.exec(line);
    if (xct) {
      if (!suites.length || pendingSuite) invalid = true;
      const label = `${xct[1]}/${xct[2]}`;
      if (xct[3] === 'started.') begin('xctest', label);
      else finish('xctest', label, xct[4]);
    }
    const swiftStart = /^◇ Test (?!run started\.|case passing )(.+) started\.$/.exec(line);
    const swiftCase = /^◇ Test case passing .+ to (.+) started\.$/.exec(line);
    if (swiftCase) {
      const id = resolve('swift', swiftCase[1]);
      if (!id || !expected.has(id) || !started.has(id) || finished.has(id)) invalid = true;
    }
    const swiftEnd = /^[✔✘] Test (?!run with )(.+) (?:passed|failed) after /.exec(line);
    const swiftSkip = /^➜ Test (.+?) skipped(?::| after |\.)/.exec(line);
    if (swiftStart) begin('swift', swiftStart[1]);
    if (swiftEnd) finish('swift', swiftEnd[1], 'passed');
    if (swiftSkip) finish('swift', swiftSkip[1], 'skipped');
  }
  return { ...totals, complete: !invalid && roots === 1 && !suites.length && !pendingSuite &&
    finished.size === expected.size && [...started].every(id => finished.has(id)) };
}

function nativeSpawn(env, spawnSync, inclusion = null, bundlePath = bundle) {
  const options = { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: 2100000,
    env: { ...env, SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: "1" } };
  if (inclusion !== null) return spawnSync(lock, ["xcrun", "xctest", "-XCTest", inclusion.join(','), bundlePath], options);
  return spawnSync(lock, ["xcrun", "xctest", bundlePath], options);
}

/** One attempt, plus at most one strictly authorized retry. Inject only the process boundary. */
export function runAppLane({ spawn = spawnSync, env = process.env,
  evidencePath = '.build/app-lane-attempt1.log', quarantinePath = quarantineFile, bundlePath = bundle, stdout = s => process.stdout.write(s), stderr = s => process.stderr.write(s) } = {}) {
  let quarantine, selection = null;
  try {
    quarantine = loadQuarantine(quarantinePath);
    if (quarantine.length) {
      const inventory = discoverInventory(spawn, env, bundlePath);
      for (const entry of quarantine) if (!inventory.some(row => row.id === entry.id)) {
        stderr(`app-lane quarantine warning: missing inventory id=${entry.id} issue=#${entry.issue}\n`);
        throw new Error(`inventory does not contain quarantined id ${entry.id}`);
      }
      const retained = inventory.filter(row => !quarantine.some(entry => entry.id === row.id));
      if (!retained.some(row => row.kind === 'swift')) throw new Error('unsupported quarantine: no remaining Swift Testing tests; retain at least one Swift Testing test');
      selection = { inventory, retained };
      for (const entry of quarantine) stdout(`app-lane quarantine skip=${entry.id} issue=#${entry.issue}\n`);
    } else stdout('app-lane quarantine none\n');
  } catch (error) {
    stderr(`app-lane quarantine: ${error.message}\n`); return 70;
  }
  const execute = () => {
    const run = nativeSpawn(env, spawn, selection?.retained.map(row => row.id) ?? null, bundlePath);
    stdout(run.stdout ?? ''); stderr(run.stderr ?? '');
    return { run, parsed: parseAppResult(run, selection) };
  };
  let attempt = execute();
  if (attempt.parsed.failed) stdout(`\napp-lane: first-attempt failures: ${attempt.parsed.failureNames.join(', ')}\n`);
  if (attempt.parsed.status !== 0) {
    try {
      mkdirSync(path.dirname(evidencePath), { recursive: true });
      writeFileSync(evidencePath, attempt.parsed.output);
    } catch (error) {
      stderr(`app-lane: cannot preserve first-attempt evidence ${evidencePath}: ${error.message}\n`);
      return 70;
    }
    // Classification still uses its strict default parser. Normalize only an already
    // verified selected result; raw evidence above remains byte-for-byte unchanged.
    const forGate = selection && attempt.parsed.reliable ? { ...attempt.run,
      stdout: (attempt.run.stdout ?? '').replaceAll("Test Suite 'Selected tests'", "Test Suite 'All tests'"),
      stderr: (attempt.run.stderr ?? '').replaceAll("Test Suite 'Selected tests'", "Test Suite 'All tests'") } : attempt.run;
    const gate = selection && (!attempt.parsed.reliable || attempt.parsed.xctFailed > 0) ? { decision: 'fail' } : classifyFlaky(forGate);
    if (env.PICSEE_APP_LANE_NO_RETRY !== '1' && gate.decision === 'retry-eligible') {
      stdout(`app-lane: known flaky ${gate.names.join(', ')} (${gate.issues.map(issue => `#${issue}`).join(', ')}); retrying once\n`);
      attempt = execute();
    }
  }
  const final = attempt.parsed;
  if (!final.reliable) stderr('app-lane: no reliable completed App test result; environment failure\n');
  else stdout(`\nTests run: ${final.count}, Failures: ${final.failed}, Errors: 0, Skipped: ${final.skipped}\n`);
  return final.status;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = runAppLane();
