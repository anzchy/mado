import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { DIFF_NAME_ARGS, failingTestInDiff, nodeLaneRequired, NODE_LANE_PREFIXES } from '../../mado-verify/scripts/gate-policy.mjs';
import { rerunPlan, selectSuites, failureFact, preflight, inspectLock, workflowNodeTests, expandPattern, readExceptions, nodeLaneFiles, uncoveredWorkflowTests, NODE_LANE_EXCEPTIONS, loadThresholds, parseFacts, loadVerdict, competingHeavyProcesses } from './owner-gates-tools.mjs';

const fixture = name => fs.readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
test('WI-1 skips both optional suites only for reviewed native-only paths', () => {
  assert.deepEqual(selectSuites(['App/MadoApp.swift']), {native:true, agents:false, tdd:false, node:false});
  assert.deepEqual(selectSuites(['Packages/MadoKit/Tests/Foo.swift','TestAssets/foo.png']), {native:true, agents:false, tdd:false, node:false});
  for (const file of ['.github/workflows/pr-body.yml','.github/workflows/ci.yml','.agents/skills/pr/SKILL.md',
    'docs/agents/ui-parity-contract.md','.agents/skills/ci-linux-preflight/scripts/preflight.mjs',
    '.claude/agents/auditor.md','docs/agents/interaction-lifecycle-checklist.md',
    'scripts/agents/lifecycle-checklist-refs.test.mjs','scripts/git-hooks/pre-push','scripts/design/design-check.mjs',
    '.claude/tdd-guardian/config.json','.agents/skills/mado-delegator/scripts/listen-notify.py',
    'scripts/tdd/app-lane.mjs','docs/guide.md']) {
    const selected = selectSuites([file]);
    assert.equal(selected.agents, true, file);
    assert.equal(selected.tdd, true, file);
  }
  assert.deepEqual(selectSuites(['App/MadoApp.swift','docs/guide.md']), {native:true, agents:true, tdd:true, node:false});
});

// #892 (owner 2026-11-25): an implementer runs the node lane only when the diff touches scripts/, .agents/, .github/ or
// .claude/; the delegator's owner-gates run and GitHub CI cover the rest. One rule, shared with evidence.mjs check.
test('892 WI-1 the node lane is required exactly for diffs under scripts/, .agents/, .github/ or .claude/', () => {
  for (const file of ['scripts/ci/foo.mjs', '.agents/skills/pr/SKILL.md', '.github/workflows/ci.yml', '.claude/agents/auditor.md',
    'scripts/tdd/app-lane.test.mjs', '.agents/skills/mado-verify/tests/verify.test.mjs'])
    assert.equal(nodeLaneRequired([file]), true, file);
  for (const file of ['App/MadoApp.swift', 'AppTests/FooTests.swift', 'Packages/MadoKit/Sources/MadoCore/A.swift', 'docs/guide.md',
    'design/DESIGN.md', 'project.yml', 'scriptsfoo/x.mjs', 'docs/scripts/x.md', 'TestAssets/a.png'])
    assert.equal(nodeLaneRequired([file]), false, file);
  assert.equal(nodeLaneRequired(['App/MadoApp.swift', 'scripts/ci/foo.mjs']), true, 'mixed diff');
  assert.equal(nodeLaneRequired([]), true, 'an empty or unreadable diff fails closed');
  assert.deepEqual(NODE_LANE_PREFIXES, ['scripts/', '.agents/', '.github/', '.claude/']);
  assert.equal(selectSuites(['scripts/ci/foo.mjs']).node, true);
  assert.equal(selectSuites([]).node, true);
});

test('892 WI-1 select prints native, agents, tdd and node, one per line', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'select-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  // #892 fix1: the diff file is NUL-delimited (`git diff --name-only -z`).
  for (const [diff, node] of [['App/MadoApp.swift\0', 0], ['App/MadoApp.swift\0scripts/ci/foo.mjs\0', 1]]) {
    fs.writeFileSync(path.join(dir, 'diff.nul'), diff);
    const r = spawnSync(process.execPath, [new URL('./owner-gates-tools.mjs', import.meta.url).pathname, 'select', path.join(dir, 'diff.nul')], {encoding: 'utf8'});
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`^native=1\\nagents=[01]\\ntdd=[01]\\nnode=${node}\\n$`));
  }
});

test('WI-2 facts parse captured spec and heavy-lock output', () => {
  assert.equal(failureFact('node', 1, fixture('spec-failure.log'), ['scripts/agents/pre-push.test.mjs']),
    'node: failed=1 tests=documented_bootstrap_propagates_false-success in-diff=yes');
  assert.equal(failureFact('node', 1, fixture('spec-failure.log'), ['docs/guide.md']),
    'node: failed=1 tests=documented_bootstrap_propagates_false-success in-diff=no');
  assert.equal(failureFact('node', 1, 'failure with no test name', []), 'node: failed=unknown tests=unknown in-diff=unknown');
  assert.equal(failureFact('node', 1, '✔ lock wait timeout keeps exit 75\n✖ failing tests:\n✖ unrelated failure (1ms)', []),
    'node: failed=1 tests=unrelated_failure in-diff=no');
  assert.match(failureFact('swift', 75, fixture('heavy-timeout.log') + fixture('held-by.log'), []),
    /^swift: lock-timeout holder=69638 alive=(?:yes|no)$/);
  assert.equal(failureFact('apptests-hosted', 70, 'test runner hung before establishing connection', []), 'apptests-hosted: hung');
  assert.equal(failureFact('design', 1, fixture('design-prereq.log'), []), 'design: prereq=node_modules');
  assert.equal(failureFact('design', 1, 'Error at node_modules/playwright-core/lib/server.js', []), 'design: exit=1');
  assert.equal(failureFact('swift', 1, 'Executed 50 tests, with 2 failures\nTime limit reached', []), 'swift: failed=2 timelimit=unknown other=unknown');
});

test('WI-3 preflight fails only on missing prerequisites or an orphaned held lock', () => {
  assert.match(preflight({scriptsOwn:true, nodeModules:false, playwright:true, holder:null}), /node_modules/);
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:false, holder:null}), /Playwright/);
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:{pid:123, orphaned:true}}), /holder=123/);
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:{pid:123, orphaned:false}}), null);
  assert.match(preflight({scriptsOwn:false, nodeModules:true, playwright:true, holder:null}), /worktree copy/);
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:null}), null);
});

test('WI-3 free lock ignores captured stale owner record', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-lock-'));
  t.after(() => fs.rmSync(dir, {recursive:true, force:true}));
  const lock = path.join(dir, 'heavy.lock');
  fs.writeFileSync(lock, '');
  fs.writeFileSync(`${lock}.guardian-stale.owner`, fixture('guardian.owner'));
  assert.deepEqual(inspectLock(lock), {holder:null, staleRecords:1});
});

test('WI-3 live supervised holder waits instead of refusing', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-held-'));
  t.after(() => fs.rmSync(dir, {recursive:true, force:true}));
  const lock = path.join(dir, 'heavy.lock');
  const child = spawn('/usr/bin/python3', ['-c', 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("READY",flush=True); time.sleep(10)', lock], {stdio:['ignore','pipe','pipe']});
  t.after(() => child.kill());
  await once(child.stdout, 'data');
  const owner = fixture('guardian.owner').replace(/^pid=\d+$/m, `pid=${child.pid}`).replace(/^supervisor=\d+$/m, `supervisor=${process.pid}`);
  fs.writeFileSync(`${lock}.guardian-live.owner`, owner);
  assert.deepEqual(inspectLock(lock), {holder:{pid:child.pid, orphaned:false}, staleRecords:0});
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:inspectLock(lock).holder}), null);
  fs.writeFileSync(`${lock}.guardian-live.owner`, owner.replace(`supervisor=${process.pid}`, 'supervisor=999999'));
  assert.deepEqual(inspectLock(lock), {holder:{pid:child.pid, orphaned:true}, staleRecords:0});
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:inspectLock(lock).holder}), /supervisor=dead/);
});

// #750: the local node lane covers every node test path the workflows run, or lists it as a reviewed exception.
const repo = new URL('../../../..', import.meta.url).pathname;
const workflowTexts = () => fs.readdirSync(path.join(repo, '.github/workflows')).filter(f => /\.ya?ml$/.test(f))
  .map(f => fs.readFileSync(path.join(repo, '.github/workflows', f), 'utf8'));

test('750 workflow parser reads node --test and node-lane commands only', () => {
  const text = [
    '      - run: node --test scripts/a/*.test.mjs scripts/b/x.test.cjs',
    '        run: |',
    '          python3 -m unittest discover -s scripts/device/tests',
    '          node --test --test-reporter=spec "scripts/c/y.test.mjs"',
    '        run: scripts/heavy-lock.sh node scripts/tdd/node-lane.mjs scripts/d/*.test.mjs > .build/out.tap 2>&1',
    '        run: node scripts/ci/cache-key.mjs spm "$MANIFEST"',
  ].join('\n');
  assert.deepEqual(workflowNodeTests(text), ['scripts/a/*.test.mjs', 'scripts/b/x.test.cjs', 'scripts/c/y.test.mjs', 'scripts/d/*.test.mjs']);
});

test('750 every node test the workflows run is in the local lane or a reviewed exception', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  const ci = [...new Set(workflowTexts().flatMap(workflowNodeTests).flatMap(p => expandPattern(repo, p)))];
  assert.ok(ci.length > 60, `expanded CI node tests: ${ci.length}`);
  assert.ok(ci.includes('scripts/ci/for-where-ban.test.mjs'));
  assert.deepEqual(uncoveredWorkflowTests(repo, workflowTexts(), exceptions), []);
});

test('750 a CI test directory the lane does not know is reported', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lane-parity-'));
  try {
    for (const rel of ['scripts/ci/a.test.mjs', 'scripts/brand-new/b.test.mjs', 'scripts/ci/integration/c.test.mjs']) {
      fs.mkdirSync(path.dirname(path.join(dir, rel)), {recursive: true}); fs.writeFileSync(path.join(dir, rel), '');
    }
    const text = 'run: node --test scripts/ci/*.test.mjs scripts/brand-new/*.test.mjs\nrun: node scripts/tdd/node-lane.mjs scripts/ci/integration/*.test.mjs';
    assert.deepEqual(uncoveredWorkflowTests(dir, [text], []), ['scripts/brand-new/b.test.mjs', 'scripts/ci/integration/c.test.mjs']);
    assert.deepEqual(uncoveredWorkflowTests(dir, [text], [{file: 'scripts/ci/integration/*.test.mjs', reason: 'x'.repeat(30), ticket: '#1'}]), ['scripts/brand-new/b.test.mjs']);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

test('750 the lane runs scripts/ci (for-where ban included) and the mado-verify tests on every diff', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  for (const choice of [{agents: false, tdd: false}, {agents: true, tdd: true}]) {
    const {files} = nodeLaneFiles(repo, choice, exceptions);
    for (const file of ['scripts/ci/for-where-ban.test.mjs', 'scripts/ci/name-checks-ci.test.mjs', 'scripts/release/appcast.test.mjs',
      'scripts/hooks/git-add-guard.test.mjs', '.agents/skills/mado-verify/tests/verify.test.mjs',
      '.agents/skills/mado-delegator/scripts/owner-gates-tools.test.mjs']) assert.ok(files.includes(file), `${file} with ${JSON.stringify(choice)}`);
    // i760-fix1 F1: pr-body.yml runs scripts/agents and scripts/tdd on every PR, so every selection runs them locally too.
    assert.ok(files.includes('scripts/agents/pre-push.test.mjs'), `scripts/agents with ${JSON.stringify(choice)}`);
    assert.ok(files.some(f => f.startsWith('scripts/tdd/')), `scripts/tdd with ${JSON.stringify(choice)}`);
  }
});

test('fix1 parity holds for every selection owner-gates can make: native-only, tooling-only, mixed, empty', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  for (const diff of [['App/New.swift'], ['Packages/MadoKit/Sources/MadoCore/Model.swift', 'TestAssets/a.png'], ['scripts/agents/tool.mjs'],
    ['App/New.swift', 'docs/notes.md'], []]) {
    const choice = selectSuites(diff);
    assert.deepEqual(uncoveredWorkflowTests(repo, workflowTexts(), exceptions, choice), [], `selection for ${JSON.stringify(diff)}`);
    const {files} = nodeLaneFiles(repo, choice, exceptions);
    assert.ok(files.includes('scripts/agents/pre-push.test.mjs') && files.some(f => f.startsWith('scripts/tdd/')), JSON.stringify(diff));
  }
});

// i760-fix1 F2 / opus M1: every command shape either is read or makes the parity check fail; none is dropped silently.
function shapeRepo(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lane-shapes-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  for (const rel of ['scripts/newchecks/probe.test.mjs', 'scripts/newchecks/helper-check.mjs', 'scripts/deep/x/y.test.mjs', 'tools/c.test.mjs', 'pr-head/scripts/ci/z.test.mjs']) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), {recursive: true}); fs.writeFileSync(path.join(dir, rel), '');
  }
  return dir;
}

test('fix1 readable shapes: continuation, folded, flags before --test, flag values, plain file arguments', t => {
  const dir = shapeRepo(t);
  const readable = {
    continuation: 'jobs:\n  a:\n    steps:\n      - run: |\n          node --test \\\n            scripts/newchecks/*.test.mjs\n',
    folded: 'jobs:\n  a:\n    steps:\n      - run: >\n          node --test\n          scripts/newchecks/*.test.mjs\n',
    flagsBefore: '      - run: node --experimental-vm-modules --test scripts/newchecks/probe.test.mjs\n',
    flagValue: '      - run: node --test --test-reporter spec scripts/newchecks/probe.test.mjs > out.tap\n',
    plainFile: '      - run: node --test scripts/newchecks/helper-check.mjs\n',
  };
  const expected = {plainFile: ['scripts/newchecks/helper-check.mjs']};
  for (const [shape, text] of Object.entries(readable)) {
    assert.deepEqual(uncoveredWorkflowTests(dir, [text], []), expected[shape] ?? ['scripts/newchecks/probe.test.mjs'], shape);
  }
  assert.deepEqual(workflowNodeTests(readable.continuation), ['scripts/newchecks/*.test.mjs']);
  assert.deepEqual(workflowNodeTests(readable.flagValue), ['scripts/newchecks/probe.test.mjs']);
  // A checkout's working directory is the repository root; comments and step names are not commands.
  const checkout = '      - uses: actions/checkout@v4\n        with:\n          path: pr-head\n      - working-directory: pr-head\n        run: node --test scripts/newchecks/probe.test.mjs\n';
  assert.deepEqual(uncoveredWorkflowTests(dir, [checkout], []), ['scripts/newchecks/probe.test.mjs']);
  assert.deepEqual(uncoveredWorkflowTests(dir, ['      # node --test scripts/gone/*.test.mjs\n      - name: node --test scripts/gone/*.test.mjs\n        run: echo hi\n'], []), []);
});

test('fix1 unreadable shapes and empty patterns fail the parity check', t => {
  const dir = shapeRepo(t);
  const unreadable = {
    globstar: "      - run: node --test 'scripts/deep/**/*.test.mjs'\n",
    variable: '      - run: node --test "$T"\n',
    matrix: '      - run: node --test scripts/${{ matrix.s }}/*.test.mjs\n',
    directory: '      - run: node --test scripts/newchecks/\n',
    directoryNoSlash: '      - run: node --test scripts/newchecks\n',
    cd: '      - run: cd tools && node --test c.test.mjs\n',
    cdEarlierLine: '      - run: |\n          cd tools\n          node --test c.test.mjs\n',
    workingDirectory: '      - working-directory: tools\n        run: node --test c.test.mjs\n',
    noPath: '      - run: node --test\n',
    nodeLaneNoPath: '      - run: scripts/heavy-lock.sh node scripts/tdd/node-lane.mjs > out.tap\n',
    emptyPattern: '      - run: node --test scripts/gone/*.test.mjs\n',
    missingFile: '      - run: node --test scripts/gone/a.test.mjs\n',
  };
  for (const [shape, text] of Object.entries(unreadable)) {
    const problems = uncoveredWorkflowTests(dir, [text], []);
    assert.ok(problems.length > 0 && problems.every(p => /^(unreadable|no path|no files): /.test(p)), `${shape}: ${JSON.stringify(problems)}`);
  }
});

test('750 every exception names a reason and a ticket, matches a CI test, and is not also run', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  const ci = [...new Set(workflowTexts().flatMap(workflowNodeTests).flatMap(p => expandPattern(repo, p)))];
  const {files, excepted} = nodeLaneFiles(repo, {agents: true, tdd: true}, exceptions);
  for (const entry of exceptions) {
    assert.match(entry.ticket, /^#[1-9]\d*$/, entry.file);
    assert.ok(entry.reason.length >= 20, entry.file);
    const matched = expandPattern(repo, entry.file);
    assert.ok(matched.length && matched.every(f => ci.includes(f)), `${entry.file} matches no CI test`);
    for (const file of matched) { assert.ok(!files.includes(file), file); assert.ok(excepted.includes(file), file); }
  }
  for (const bad of [[{file: 'scripts/ci/a.test.mjs', reason: 'x'.repeat(30)}], [{file: 'scripts/ci/a.test.mjs', ticket: '#1'}], [{file: '', reason: 'x'.repeat(30), ticket: '#1'}]]) {
    const file = path.join(os.tmpdir(), `lane-exceptions-${process.pid}.json`);
    fs.writeFileSync(file, JSON.stringify({exceptions: bad}));
    try { assert.throws(() => readExceptions(file), /exception/); } finally { fs.rmSync(file, {force: true}); }
  }
});

// #760: load and memory preflight. Injected facts: under, over (each threshold, and a configured one), unreadable.
test('760 preflight verdict: under, over each threshold, configured threshold, unreadable', () => {
  const defaults = loadThresholds({});
  assert.deepEqual([defaults.maxLoad.value, defaults.minMemFree.value, defaults.maxPressure.value], [6, 25, 1]);
  const under = loadVerdict({load: 4.2, memFree: 55, pressure: 1}, defaults);
  assert.deepEqual(under, {line: 'load=4.2 mem_free=55% pressure=1', notes: [], refuse: null});
  assert.match(loadVerdict({load: 7, memFree: 55, pressure: 1}, defaults).refuse, /^load 7 over OWNER_GATES_MAX_LOAD=6$/);
  assert.match(loadVerdict({load: 4.2, memFree: 24, pressure: 1}, defaults).refuse, /^mem_free 24% under OWNER_GATES_MIN_MEM_FREE=25$/);
  assert.match(loadVerdict({load: 4.2, memFree: 55, pressure: 2}, defaults).refuse, /^pressure 2 over OWNER_GATES_MAX_PRESSURE=1$/);
  assert.equal(loadVerdict({load: 6, memFree: 25, pressure: 1}, defaults).refuse, null, 'the thresholds themselves pass');
  const configured = loadThresholds({OWNER_GATES_MAX_LOAD: '4', OWNER_GATES_MIN_MEM_FREE: '60'});
  assert.equal(loadVerdict({load: 4.2, memFree: 55, pressure: 1}, configured).refuse,
    'load 4.2 over OWNER_GATES_MAX_LOAD=4; mem_free 55% under OWNER_GATES_MIN_MEM_FREE=60');
  assert.throws(() => loadThresholds({OWNER_GATES_MAX_LOAD: 'high'}), /OWNER_GATES_MAX_LOAD=high/);
  const unreadable = loadVerdict(parseFacts({loadavg: null, level: '', pressure: 'n/a'}), defaults);
  assert.equal(unreadable.line, 'load=unknown mem_free=unknown pressure=unknown');
  assert.equal(unreadable.refuse, null);
  assert.equal(unreadable.notes.length, 3);
  for (const note of unreadable.notes) assert.match(note, /^preflight-note: .+ unreadable; no refusal on it$/);
  assert.deepEqual(parseFacts({loadavg: '{ 5.30 3.88 3.81 }', level: '56\n', pressure: '1'}), {load: 5.3, memFree: 56, pressure: 1});
});

test('735 competing heavy processes list only names and PIDs', () => {
  const rows='101 /usr/bin/swift-frontend swift-frontend -frontend -primary-file secret.swift\n102 /bin/sleep sleep 20\n103 /usr/bin/python3 python3 scripts/tdd/heavy-lock.py --guardian 5 8\n104 /usr/bin/node node scripts/tdd/unit-lane.mjs\n';
  assert.deepEqual(competingHeavyProcesses(rows, 999), ['101:swift-frontend', '103:python3', '104:node']);
  assert.equal(competingHeavyProcesses('bad process output', 999), null);
});

test('760 fix1 TERM-resistant probes expire as unknown within the hard deadline', {timeout:40000}, t => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gate-probe-'));
  const probePids=path.join(dir,'probe-pids');
  t.after(()=>{
    if(fs.existsSync(probePids)) for(const pid of fs.readFileSync(probePids,'utf8').trim().split('\n').map(Number)){
      if(Number.isSafeInteger(pid) && pid>0) { try { process.kill(pid,'SIGKILL'); } catch(error) { if(error.code!=='ESRCH') throw error; } }
    }
    fs.rmSync(dir,{recursive:true,force:true});
  });
  const sysctl=path.join(dir,'sysctl'), ps=path.join(dir,'ps');
  const healthySysctl=path.join(dir,'healthy-sysctl'), healthyPs=path.join(dir,'healthy-ps');
  const healthyMarker=path.join(dir,'healthy-sysctl-hit');
  fs.writeFileSync(sysctl,`#!${process.execPath}\nif(process.argv[3]==='vm.loadavg'){require('node:fs').appendFileSync(${JSON.stringify(probePids)},process.pid+'\\n');process.on('SIGTERM',()=>{});setInterval(()=>{},1000);}else console.log(process.argv[3]==='kern.memorystatus_level'?'55':'1');\n`,{mode:0o755});
  fs.writeFileSync(ps,`#!${process.execPath}\nrequire('node:fs').appendFileSync(${JSON.stringify(probePids)},process.pid+'\\n');process.on('SIGTERM',()=>{});setInterval(()=>{},1000);\n`,{mode:0o755});
  fs.writeFileSync(healthySysctl,`#!${process.execPath}\nrequire('node:fs').appendFileSync(${JSON.stringify(healthyMarker)},'hit\\n');console.log(process.argv[3]==='vm.loadavg'?'{ 1.00 1.00 1.00 }':process.argv[3]==='kern.memorystatus_level'?'55':'1');\n`,{mode:0o755});
  fs.writeFileSync(healthyPs,`#!${process.execPath}\nconsole.log('102 /bin/sleep sleep 20');\n`,{mode:0o755});
  const tool=new URL('./owner-gates-tools.mjs',import.meta.url).pathname;
  for(const [env,expected] of [[{OWNER_GATES_SYSCTL:sysctl,OWNER_GATES_PS:healthyPs},'preflight-note: load average unreadable'],
    [{OWNER_GATES_SYSCTL:healthySysctl,OWNER_GATES_PS:ps},'preflight-note: competing heavy process query unreadable']]){
    const run=spawnSync(process.execPath,[tool,'load-preflight'],{env:{...process.env,...env,
      OWNER_GATES_MAX_LOAD:'1000',OWNER_GATES_MIN_MEM_FREE:'0',OWNER_GATES_MAX_PRESSURE:'9',MADO_GATES_PREFLIGHT:''},
      encoding:'utf8',timeout:15000,killSignal:'SIGKILL'});
    assert.ifError(run.error);
    assert.equal(run.status,0,run.stderr);
    assert.match(run.stdout,new RegExp(expected));
    if(expected.includes('competing heavy')) assert.ok(fs.existsSync(healthyMarker),'case 2 must use the fake sysctl');
  }
  for(const pid of fs.readFileSync(probePids,'utf8').trim().split('\n').map(Number)) {
    assert.throws(()=>process.kill(pid,0), {code:'ESRCH'}, `probe ${pid} must be gone`);
  }
});

// #892 WI-2: the spec reporter's failing block, as node 22 prints it: `test at <file>:<line>:<col>` before each `✖ <name> (<ms>ms)`.
const failingBlock = tests => `ℹ fail ${tests.length}\n\n✖ failing tests:\n\n` +
  tests.map(([file, name]) => `${file === null ? '' : `test at ${file}:12:3\n`}✖ ${name} (12.5ms)\n  AssertionError [ERR_ASSERTION]: boom\n`).join('\n');
test('892 WI-2 rerun plan: out-of-diff failures rerun their files once; the exact names are kept', () => {
  const out = failingBlock([['scripts/tdd/b.test.mjs', 'b times out, first exec'], ['scripts/agents/a.test.mjs', 'a, with comma'],
    ['scripts/tdd/b.test.mjs', 'b second']]);
  assert.deepEqual(rerunPlan(out, ['docs/guide.md', 'App/MadoApp.swift'], '/wt'), {rerun: true, reason: null,
    files: ['scripts/agents/a.test.mjs', 'scripts/tdd/b.test.mjs'],
    tests: [{file: 'scripts/tdd/b.test.mjs', name: 'b times out, first exec'}, {file: 'scripts/agents/a.test.mjs', name: 'a, with comma'},
      {file: 'scripts/tdd/b.test.mjs', name: 'b second'}]});
});

test('892 WI-2 rerun plan: an in-diff failure never reruns (file, sibling source, name, absolute and file:// paths)', () => {
  const one = (file, name = 'x fails') => failingBlock([[file, name]]);
  for (const [out, diff] of [
    [one('scripts/tdd/b.test.mjs'), ['scripts/tdd/b.test.mjs']],
    [one('scripts/tdd/b.test.mjs'), ['scripts/tdd/heavy-lock.py']],
    [one('scripts/ci/x.test.mjs', 'pre-push keeps the hook'), ['scripts/agents/pre-push.test.mjs']],
    [one('/wt/scripts/tdd/b.test.mjs'), ['scripts/tdd/b.test.mjs']],
    [one('file:///wt/scripts/tdd/b.test.mjs'), ['scripts/tdd/b.test.mjs']],
    [failingBlock([['scripts/agents/a.test.mjs', 'a'], ['scripts/tdd/b.test.mjs', 'b']]), ['scripts/tdd/b.test.mjs']]]) {
    const plan = rerunPlan(out, diff, '/wt');
    assert.equal(plan.rerun, false, `${diff} ${out}`);
    assert.equal(plan.reason, 'in-diff=yes', `${diff}`);
  }
  // The same absolute path outside the diff reruns, as a repository-relative file.
  assert.deepEqual(rerunPlan(one('/wt/scripts/tdd/b.test.mjs'), ['docs/x.md'], '/wt').files, ['scripts/tdd/b.test.mjs']);
});

test('892 WI-2 rerun plan: unknown failing tests or files never rerun', () => {
  assert.deepEqual(rerunPlan('crashed before the reporter ran', [], '/wt'), {rerun: false, reason: 'failing tests unknown', files: [], tests: []});
  assert.equal(rerunPlan(failingBlock([[null, 'no location']]), ['docs/x.md'], '/wt').reason, 'failed files unknown');
  assert.equal(rerunPlan(failingBlock([['scripts/agents/a.test.mjs', 'a'], [null, 'no location']]), ['docs/x.md'], '/wt').reason, 'failed files unknown');
  assert.equal(rerunPlan(failingBlock([['/elsewhere/scripts/tdd/b.test.mjs', 'b']]), ['docs/x.md'], '/wt').reason, 'failed files unknown');
});

test('892 review rerun plan: a failing block that does not account for every failure never reruns', () => {
  const two = failingBlock([['scripts/tdd/b.test.mjs', 'b'], ['scripts/agents/a.test.mjs', 'a']]);
  // One failure the parser cannot read (another duration format) must not let the readable one turn into a flake.
  const partial = two.replace('✖ a (12.5ms)', '✖ a (1.2s)');
  assert.deepEqual(rerunPlan(partial, ['docs/x.md'], '/wt'), {rerun: false, reason: 'failing tests incomplete', files: [], tests: []});
  assert.equal(rerunPlan(two.replace('ℹ fail 2', 'ℹ fail 3'), ['docs/x.md'], '/wt').reason, 'failing tests incomplete');
  assert.equal(rerunPlan(two.replace('ℹ fail 2\n', ''), ['docs/x.md'], '/wt').reason, 'failing tests incomplete');
  assert.equal(rerunPlan(two, ['docs/x.md'], '/wt').rerun, true);
});

// #892 fix1 WI-1 (gpt F1 / opus M1): owner-gates lists the diff with the shared NUL-delimited arguments, and every
// owner-gates-tools command reads that file with the shared parser. Real git, core.quotePath at its default.
const tools = new URL('./owner-gates-tools.mjs', import.meta.url).pathname;
const runGit = (cwd, ...args) => { const r = spawnSync('git', args, {cwd, encoding: 'utf8'}); assert.equal(r.status, 0, r.stderr); return r.stdout; };
test('892 fix1 WI-1 owner-gates.sh lists the gated diff with the shared NUL-delimited arguments', () => {
  const owner = fs.readFileSync(new URL('./owner-gates.sh', import.meta.url), 'utf8');
  assert.ok(owner.includes(`git ${DIFF_NAME_ARGS.join(' ')} "$mb" HEAD > "$diff_file"`), 'owner-gates.sh uses DIFF_NAME_ARGS');
  assert.doesNotMatch(owner, /git diff --name-only(?! -z)/, 'no display-form listing left');
});

test('892 fix1 WI-1 select and rerun-plan read real git -z output: a non-ASCII tooling path selects node', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'select-z-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  runGit(dir, 'init', '-q'); runGit(dir, 'config', 'user.email', 'f@example.invalid'); runGit(dir, 'config', 'user.name', 'F');
  runGit(dir, 'config', 'core.quotePath', 'true');
  fs.writeFileSync(path.join(dir, 'README'), 'x\n'); runGit(dir, 'add', '-A'); runGit(dir, 'commit', '-qm', 'base');
  fs.mkdirSync(path.join(dir, 'App')); fs.mkdirSync(path.join(dir, 'scripts'));
  fs.writeFileSync(path.join(dir, 'App/视图.swift'), 'x\n'); fs.writeFileSync(path.join(dir, 'scripts/测试.test.mjs'), 'x\n');
  runGit(dir, 'add', '-A'); runGit(dir, 'commit', '-qm', 'change');
  const diff = path.join(dir, 'diff.nul');
  fs.writeFileSync(diff, runGit(dir, ...DIFF_NAME_ARGS, 'HEAD~1', 'HEAD'));
  const sel = spawnSync(process.execPath, [tools, 'select', diff], {encoding: 'utf8'});
  assert.equal(sel.status, 0, sel.stderr);
  assert.match(sel.stdout, /^node=1$/m);
  // rerun-plan: a test beside a changed helper is in the diff; the old newline split read one NUL-joined string.
  const log = path.join(dir, 'node.log');
  fs.writeFileSync(log, failingBlock([['scripts/tdd/b.test.mjs', 'b']]));
  fs.writeFileSync(diff, 'App/x.swift\0scripts/tdd/helper.mjs\0');
  const plan = spawnSync(process.execPath, [tools, 'rerun-plan', log, diff, dir], {encoding: 'utf8'});
  assert.equal(plan.status, 0, plan.stderr);
  assert.equal(plan.stdout, 'skip in-diff=yes\n');
});

// #892 fix1 WI-2 (gpt F2 / opus M2): a node test's inputs outside its directory are not proven (imports, copied fixtures,
// spawned scripts), so any changed tooling path counts as in the diff for every failing node test: no rerun, stays red.
test('892 fix1 WI-2 a changed tooling file anywhere makes every node failure in-diff (this repo\'s cross-directory inputs)', () => {
  for (const [file, changed] of [
    // owner-gates-tools.test.mjs imports mado-verify's gate-policy.mjs.
    ['.agents/skills/mado-delegator/scripts/owner-gates-tools.test.mjs', '.agents/skills/mado-verify/scripts/gate-policy.mjs'],
    // owner-gates.test.mjs copies and runs these into its fixture.
    ['.agents/skills/mado-delegator/scripts/owner-gates.test.mjs', 'scripts/heavy-lock.sh'],
    ['.agents/skills/mado-delegator/scripts/owner-gates.test.mjs', 'scripts/tdd/heavy-lock.py'],
    ['.agents/skills/mado-delegator/scripts/owner-gates.test.mjs', 'scripts/ci/native-inputs.mjs'],
    ['scripts/tdd/b.test.mjs', '.github/workflows/ci.yml'], ['scripts/tdd/b.test.mjs', '.claude/tdd-guardian/config.json']]) {
    assert.equal(failingTestInDiff({file, name: 'x'}, ['App/MadoApp.swift', changed]), true, `${file} <- ${changed}`);
    assert.deepEqual(rerunPlan(failingBlock([[file, 'x']]), [changed], '/wt'), {rerun: false, reason: 'in-diff=yes', files: [], tests: []}, changed);
  }
  // A product-only diff still allows the one rerun.
  assert.equal(failingTestInDiff({file: 'scripts/tdd/b.test.mjs', name: 'x'}, ['App/MadoApp.swift', 'docs/guide.md', 'Packages/MadoKit/Sources/MadoCore/A.swift']), false);
});

test('892 fix1 WI-2 owner-gates.sh and SKILL.md no longer claim a product-only diff cannot change a tooling test', () => {
  const owner = fs.readFileSync(new URL('./owner-gates.sh', import.meta.url), 'utf8');
  const skill = fs.readFileSync(new URL('../../mado-verify/SKILL.md', import.meta.url), 'utf8');
  assert.doesNotMatch(owner, /cannot change a tooling test/);
  assert.match(owner, /node tests also read product files/);
  assert.match(skill, /node tests also read product files/);
  assert.match(skill, /any changed path under `scripts\/`, `\.agents\/`, `\.github\/` or `\.claude\/` puts every failing node test in the diff/);
});

// #892 fix1 L1 (opus L1): a failing subtest inside a parent. Real node v22.22.3 spec output (fixtures/spec-subtest-failure.log,
// paths rewritten): `ℹ fail 2` counts the child and its parent, but the failing block lists only the child, so the plan is
// incomplete and there is no rerun. This fails closed: such a failure stays red.
test('892 fix1 L1 a failing subtest inside a parent is never rerun: the block does not account for the parent', () => {
  const out = fixture('spec-subtest-failure.log');
  assert.match(out, /^ℹ fail 2$/m);
  assert.equal((out.split(/^✖ failing tests:\s*$/m)[1].match(/^✖ /gm) ?? []).length, 1);
  assert.deepEqual(rerunPlan(out, ['docs/guide.md'], '/wt'), {rerun: false, reason: 'failing tests incomplete', files: [], tests: []});
});
