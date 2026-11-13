import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { loadManifest, discoveryVerdict, parseListing, scenarioFilter, swiftFlags, TRASH_LIMITS } from './trash-lane.mjs';

const root = process.cwd();
const scratch = mkdtempSync(path.join(os.tmpdir(), 'mado-trash-lane-'));
after(() => rmSync(scratch, { recursive: true, force: true }));
const lock = path.join(root, 'scripts/heavy-lock.sh');
const driver = path.join(root, 'scripts/tdd/fixtures/trash-lane-driver.mjs');
const packageTests = path.join(root, 'Packages/MadoKit/Tests');

function swiftSources(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? swiftSources(full) : entry.name.endsWith('.swift') ? [full] : [];
  });
}

/** Line ranges inside `#if MADO_TRASH_INTEGRATION … #endif`, nesting-aware. */
function integrationRegions(source) {
  const lines = source.split('\n');
  const stack = [];
  const inside = lines.map(line => {
    const trimmed = line.trim();
    if (/^#if\b/.test(trimmed)) { stack.push(trimmed === '#if MADO_TRASH_INTEGRATION'); return stack.includes(true); }
    if (/^#endif\b/.test(trimmed)) { const was = stack.includes(true); stack.pop(); return was; }
    if (/^#else\b|^#elseif\b/.test(trimmed) && stack.at(-1)) stack[stack.length - 1] = false;
    return stack.includes(true);
  });
  return { lines, inside };
}

test('trashLaneDefaultSourcesKeepRealTrashBehindTheIntegrationDefine', () => {
  const manifest = loadManifest();
  const expected = new Set(manifest.scenarios.map(id => id.slice(id.indexOf('.') + 1, id.indexOf('('))));
  const found = new Set();
  const outside = [];
  for (const file of swiftSources(packageTests)) {
    const { lines, inside } = integrationRegions(readFileSync(file, 'utf8'));
    lines.forEach((line, index) => {
      if (/\btrashItem\s*\(/.test(line) && !/^\s*\/\//.test(line) && !inside[index])
        outside.push(`${path.relative(root, file)}:${index + 1}`);
    });
    const region = lines.map((line, index) => inside[index] ? line : '').join('\n');
    for (const match of region.matchAll(/@Test\b[\s\S]*?\bfunc\s+(\w+)/g)) found.add(match[1]);
  }
  assert.deepEqual(outside, [], 'real trashItem calls outside #if MADO_TRASH_INTEGRATION run in the default lane');
  assert.deepEqual([...found].sort(), [...expected].sort(), 'integration-only tests and the manifest must match');
});

test('trashLaneManifestAndFixedLimits', () => {
  const manifest = loadManifest();
  assert.equal(manifest.define, 'MADO_TRASH_INTEGRATION');
  assert.ok(manifest.scenarios.length >= 8);
  assert.deepEqual(swiftFlags(manifest), ['--package-path', 'Packages/MadoKit', '--scratch-path',
    '.build/trash-integration', '-Xswiftc', '-DMADO_TRASH_INTEGRATION']);
  assert.deepEqual({ ...TRASH_LIMITS }, { scenarioSeconds: 120, graceSeconds: 10, killWaitSeconds: 5,
    commandSeconds: 600, drainSeconds: 2 });
  const bad = path.join(scratch, 'bad.json');
  for (const value of [{ define: 'X', scratchPath: 'a', scenarios: ['M.a()'] },
    { define: 'MADO_TRASH_INTEGRATION', scratchPath: 'a', scenarios: [] },
    { define: 'MADO_TRASH_INTEGRATION', scratchPath: 'a', scenarios: ['M.a()', 'M.a()'] },
    { define: 'MADO_TRASH_INTEGRATION', scratchPath: 'a', scenarios: ['M.a(); rm -rf /'] }]) {
    writeFileSync(bad, JSON.stringify(value));
    assert.throws(() => loadManifest(bad), /invalid trash-integration manifest/);
  }
});

test('trashLaneDiscoveryProvesBothDirections', () => {
  const scenarios = ['M.realTrash()', 'M.realTrash2(_:)'];
  const defaults = ['M.deterministic()', 'M.other()'];
  assert.deepEqual(discoveryVerdict({ defaultIDs: defaults, integrationIDs: [...defaults, ...scenarios], scenarios }),
    { ok: true, lines: [] });
  const leaked = discoveryVerdict({ defaultIDs: [...defaults, 'M.realTrash()'], integrationIDs: [...defaults, ...scenarios], scenarios });
  assert.equal(leaked.ok, false);
  assert.match(leaked.lines.join('\n'), /default lane still lists M\.realTrash\(\)/);
  const lost = discoveryVerdict({ defaultIDs: defaults, integrationIDs: [...defaults, 'M.realTrash()'], scenarios });
  assert.match(lost.lines.join('\n'), /integration lane is missing M\.realTrash2\(_:\)/);
  const extra = discoveryVerdict({ defaultIDs: defaults, integrationIDs: [...defaults, ...scenarios, 'M.surprise()'], scenarios });
  assert.match(extra.lines.join('\n'), /not in manifest: M\.surprise\(\)/);
  const dropped = discoveryVerdict({ defaultIDs: defaults, integrationIDs: scenarios, scenarios });
  assert.match(dropped.lines.join('\n'), /default test missing from integration build/);
  assert.equal(discoveryVerdict({ defaultIDs: [], integrationIDs: [], scenarios }).ok, false);
});

test('trashLaneListingAndFilterShapes', () => {
  assert.deepEqual(parseListing('Building for debugging...\nM.a()\n  M.Suite/b(x:)\r\nwarning: x\n\n'),
    ['M.a()', 'M.Suite/b(x:)']);
  assert.equal(scenarioFilter('MadoInfrastructureTests.t231X(action:)'), '^MadoInfrastructureTests\\.t231X\\(');
});

// Only Swift is replaced; the real heavy-lock supervises the lane and each scenario.
const fakeSwift = path.join(scratch, 'swift');
writeFileSync(fakeSwift, `#!${process.execPath}
const fs=require('node:fs');
const filter=process.argv[process.argv.indexOf('--filter')+1];
const name=/\\\\\\.(\\w+)\\\\\\(/.exec(filter)[1];
fs.appendFileSync(process.env.TRASH_FAKE_LOG, name+'\\n');
const mode=JSON.parse(process.env.TRASH_FAKE_PLAN)[name]??'pass';
const start='◇ Test run started.\\n';
const pass='✔ Test '+name+'() passed after 0.001 seconds.\\n✔ Test run with 1 test in 0 suites passed after 0.002 seconds.\\n';
const fail='✘ Test '+name+'() failed after 0.001 seconds with 1 issue.\\n✘ Test run with 1 test in 0 suites failed after 0.002 seconds with 1 issue.\\n';
const skip='➜ Test '+name+'() skipped.\\n✔ Test run with 1 test in 0 suites passed after 0.002 seconds.\\n';
fs.writeFileSync(process.env.TRASH_FAKE_PIDS+'/'+name, String(process.pid));
if(mode==='pass'){process.stdout.write(start+pass);}
else if(mode==='fail'){process.stdout.write(start+fail);process.exitCode=1;}
else if(mode==='skip'){process.stdout.write(start+skip);}
else if(mode==='garbled'){process.stdout.write(start);}
else if(mode==='two'){process.stdout.write(start+'✔ Test a() passed after 0.001 seconds.\\n✔ Test b() passed after 0.001 seconds.\\n✔ Test run with 2 tests in 0 suites passed after 0.002 seconds.\\n');}
else if(mode==='hang'){process.stdout.write(start);setInterval(()=>{},1000);}
else if(mode==='term-resist'){process.on('SIGTERM',()=>{});process.stdout.write(start);setInterval(()=>{},1000);}
else if(mode==='orphan'){
  const child=require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});
  fs.writeFileSync(process.env.TRASH_FAKE_PIDS+'/'+name+'.orphan', String(child.pid));
  child.unref();
  process.stdout.write(start+pass);
}
`, { mode: 0o755 });

function environment() {
  const home = mkdtempSync(path.join(scratch, 'home-'));
  const env = { ...process.env, HOME: home, PICSEE_HEAVY_LOCK: path.join(home, '.picsee/locks/heavy.lock'),
    PICSEE_MDPRO_LOCK: 'off', MDPRO_HEAVY_LOCK_HELD: '', PICSEE_HEAVY_LOCK_WAIT_SECS: '15', PICSEE_HEAVY_LOCK_HELD: '',
    PICSEE_HEAVY_LOCK_EXEC_SECS: '30' };
  delete env.PICSEE_HEAVY_CONTROL_FD;
  delete env.PICSEE_HEAVY_FLOCK_FD;
  return env;
}

// Only the hang cases use a 1s deadline; completing fakes get 15s so a loaded machine cannot time them out.
function lane(plan, { scenarios = ['M.first()', 'M.second()'], scenarioSeconds = 15, graceSeconds = 0.3,
  drainSeconds = 0.3, childEnv = {}, underLock = true } = {}) {
  const env = environment();
  const pids = mkdtempSync(path.join(scratch, 'pids-'));
  const log = path.join(pids, 'calls.log');
  writeFileSync(log, '');
  Object.assign(env, { TRASH_FAKE_PLAN: JSON.stringify(plan), TRASH_FAKE_LOG: log, TRASH_FAKE_PIDS: pids });
  const options = JSON.stringify({ swift: fakeSwift, cwd: root, scenarios, scenarioSeconds, graceSeconds, drainSeconds,
    childEnv, manifest: { define: 'MADO_TRASH_INTEGRATION', scratchPath: path.join(scratch, 'unused'), scenarios } });
  const started = Date.now();
  const result = underLock
    ? spawnSync(lock, [process.execPath, driver, options], { env, cwd: root, encoding: 'utf8', timeout: 60000 })
    : spawnSync(process.execPath, [driver, options], { env, cwd: root, encoding: 'utf8', timeout: 60000 });
  const calls = readFileSync(log, 'utf8').split('\n').filter(Boolean);
  return { ...result, output: `${result.stdout}${result.stderr}`, calls, pids, elapsed: (Date.now() - started) / 1000 };
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code !== 'ESRCH'; }
}

test('trashLaneCountsOnlyCompletedScenarios', () => {
  const ok = lane({});
  assert.equal(ok.status, 0, ok.output);
  assert.deepEqual(ok.calls, ['first', 'second']);
  assert.match(ok.stdout, /Tests run: 2, Failures: 0, Errors: 0, Skipped: 0/);
  const failed = lane({ first: 'fail' });
  assert.equal(failed.status, 1, failed.output);
  assert.deepEqual(failed.calls, ['first', 'second'], 'an ordinary failure is not a stop condition');
  assert.match(failed.stdout, /FAILED M\.first\(\)/);
  assert.match(failed.stdout, /Tests run: 2, Failures: 1, Errors: 0, Skipped: 0/);
});

test('trashLaneStopsAtFirstTimeoutWithoutRetry', () => {
  const result = lane({ first: 'hang' }, { scenarioSeconds: 1 });
  assert.equal(result.status, 70, result.output);
  assert.deepEqual(result.calls, ['first'], 'no retry and no later scenario after a timeout');
  assert.match(result.stdout, /TIMEOUT M\.first\(\): no result within 1s; lane stopped, no retry/);
  assert.doesNotMatch(result.stdout, /Tests run:/);
  assert.equal(alive(Number(readFileSync(path.join(result.pids, 'first'), 'utf8'))), false);
});

test('trashLaneTermResistantScenarioIsKilledAndStopsTheLane', () => {
  const result = lane({ first: 'term-resist' }, { scenarioSeconds: 1 });
  assert.equal(result.status, 70, result.output);
  assert.deepEqual(result.calls, ['first']);
  assert.match(result.stdout, /TIMEOUT M\.first\(\)/);
  assert.equal(alive(Number(readFileSync(path.join(result.pids, 'first'), 'utf8'))), false, 'KILL after grace');
  assert.ok(result.elapsed < 1 + 0.3 + 5 + 10, `bounded by deadline, grace and KILL wait: ${result.elapsed}s`);
});

test('trashLaneLeaderExitWithSurvivingDescendantStopsTheLane', () => {
  const result = lane({ first: 'orphan' });
  assert.equal(result.status, 70, result.output);
  assert.deepEqual(result.calls, ['first']);
  assert.match(result.stdout, /SURVIVOR M\.first\(\): leader exited with surviving descendants; lane stopped, no retry/);
  assert.doesNotMatch(result.stdout, /Tests run:|PASSED/);
  assert.equal(alive(Number(readFileSync(path.join(result.pids, 'first.orphan'), 'utf8'))), false);
});

test('trashLaneUnverifiedCleanupStopsTheLane', () => {
  // Injected unknown process state stands in for an unkillable survivor.
  const result = lane({}, { childEnv: { PICSEE_HEAVY_FAULT_QUERY: '1' } });
  assert.equal(result.status, 70, result.output);
  assert.deepEqual(result.calls, ['first']);
  assert.match(result.stdout, /SURVIVOR M\.first\(\): cleanup not verified/);
  assert.doesNotMatch(result.stdout, /Tests run:/);
});

test('trashLaneIncompleteOrForeignOutputIsNeverGreen', () => {
  for (const mode of ['garbled', 'two']) {
    const result = lane({ first: mode });
    assert.equal(result.status, 70, `${mode}: ${result.output}`);
    assert.deepEqual(result.calls, ['first']);
    assert.match(result.stdout, /INCOMPLETE M\.first\(\)/);
    assert.doesNotMatch(result.stdout, /Tests run:/);
  }
});

test('trashLaneSkippedScenarioIsAMissingPrerequisiteNotAPass', () => {
  const result = lane({ first: 'skip' });
  assert.equal(result.status, 70, result.output);
  assert.deepEqual(result.calls, ['first', 'second'], 'later scenarios still report');
  assert.match(result.stdout, /PREREQUISITE MISSING M\.first\(\): scenario skipped; not counted as a pass/);
  assert.match(result.stdout, /PREREQUISITE MISSING for 1 scenario\(s\): M\.first\(\)/);
  assert.doesNotMatch(result.stdout, /Tests run:/);
});

test('trashLaneRunPhaseRefusesToRunOutsideTheHeavyLock', () => {
  const result = lane({}, { underLock: false });
  assert.equal(result.status, 70, result.output);
  assert.deepEqual(result.calls, []);
  assert.match(result.stdout, /refused: the run phase must run inside one heavy-lock admission/);
});

test('trashLaneCliRejectsUnknownArguments', () => {
  const result = spawnSync(process.execPath, ['scripts/tdd/trash-lane.mjs', '--retry'], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /usage: node scripts\/tdd\/trash-lane\.mjs \[--discover\]/);
  assert.equal(statSync(path.join(root, 'scripts/tdd/trash-lane.mjs')).isFile(), true);
  assert.equal(existsSync(path.join(root, 'scripts/tdd/trash-integration.json')), true);
});
