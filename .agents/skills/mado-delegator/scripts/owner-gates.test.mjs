import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { fixtureEnv } from '../../../../scripts/tdd/fixture-env.mjs';

const root = fileURLToPath(new URL('../../../..', import.meta.url));
const owner = fileURLToPath(new URL('./owner-gates.sh', import.meta.url));
function fixture(t, mode = 'pass', covered = 2, npmInstalled = true, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-bound-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const rel of ['.agents/skills/mado-delegator/scripts/owner-gates.sh', '.agents/skills/mado-delegator/scripts/owner-gates-tools.mjs', 'scripts/ci/native-inputs.mjs', 'scripts/heavy-lock.sh', 'scripts/tdd/heavy-lock.py', 'scripts/ci/test-watchdog.mjs', 'scripts/ci/coverage-atomic.mjs', 'scripts/tdd/unit-lane.mjs', 'scripts/tdd/status-channel.mjs', 'scripts/tdd/unit-locked.mjs', 'scripts/tdd/swift-lcov.sh']) {
    const dest = path.join(dir, rel); fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.copyFileSync(path.join(root, rel), dest);
  }
  if (process.env.OWNER_GATES_SCRIPT_OVERRIDE)
    fs.copyFileSync(process.env.OWNER_GATES_SCRIPT_OVERRIDE, path.join(dir, '.agents/skills/mado-delegator/scripts/owner-gates.sh'));
  fs.writeFileSync(path.join(dir, '.agents/skills/mado-delegator/scripts/fixture.test.mjs'), '');
  for (const group of ['agents', 'tdd', 'ledger', 'name-checks']) { fs.mkdirSync(path.join(dir, 'scripts', group), { recursive: true }); fs.writeFileSync(path.join(dir, 'scripts', group, 'fixture.test.mjs'), ''); }
  fs.mkdirSync(path.join(dir, 'scripts', 'ci'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'scripts', 'ci', 'name-checks-ci.test.mjs'), '');
  // #750: the lane also runs every scripts/ci test and the mado-verify tests, minus the reviewed exceptions.
  fs.writeFileSync(path.join(dir, 'scripts', 'ci', 'for-where-ban.test.mjs'), '');
  fs.mkdirSync(path.join(dir, '.agents/skills/mado-verify/tests'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.agents/skills/mado-verify/tests/fixture.test.mjs'), '');
  const exceptions = path.join(root, '.agents/skills/mado-delegator/scripts/node-lane-exceptions.json');
  if (fs.existsSync(exceptions)) fs.copyFileSync(exceptions, path.join(dir, '.agents/skills/mado-delegator/scripts/node-lane-exceptions.json'));
  const bin = path.join(dir, 'bin'), build = path.join(dir, 'build'), out = path.join(dir, 'out');
  fs.mkdirSync(bin); fs.mkdirSync(path.join(build, 'codecov'), { recursive: true });
  if (npmInstalled) { fs.mkdirSync(path.join(dir, 'node_modules/playwright'), { recursive: true }); fs.writeFileSync(path.join(dir, 'node_modules/playwright/index.mjs'), `export const chromium={executablePath:()=>${JSON.stringify(process.execPath)}};`); }
  fs.mkdirSync(path.join(build, 'MadoKitPackageTests.xctest/Contents/MacOS'), { recursive: true });
  fs.writeFileSync(path.join(build, 'codecov/default.profdata'), 'old profile');
  fs.mkdirSync(path.join(dir, 'coverage')); fs.writeFileSync(path.join(dir, 'coverage/lcov.info'), 'old passing report');
  const exe = (name, body) => fs.writeFileSync(path.join(bin, name), body, { mode: 0o755 });
  exe('swift', `#!${process.execPath}
const fs=require('node:fs');
if(process.argv[2]==='build'){fs.appendFileSync(process.env.EXPORT_MARKER,'discovery\\n');console.log(process.env.BUILD);}
else{console.log('Swift started');if(process.env.MODE==='hang'){setTimeout(()=>process.exit(0),4000);setInterval(()=>{},100);}else{console.log('✔ Test run with 7 tests in 1 suite passed after 0.001 seconds.');process.exit(process.env.MODE==='fail'?1:0);}}
`);
  exe('node', `#!${process.execPath}
const path=require('node:path');
if(process.argv[2].endsWith('owner-gates-tools.mjs')){if(process.argv[3]==='select'&&process.env.SELECT_OUTPUT){console.log(process.env.SELECT_OUTPUT);process.exit(0);}import(path.resolve(process.argv[2])).then(()=>{});const r=require('node:child_process').spawnSync(process.execPath,process.argv.slice(2),{stdio:'inherit'});process.exit(r.status);}
else if(process.argv[2]==='scripts/tdd/unit-lane.mjs'){
 if(process.env.MODE==='coverage-fail'){console.log('✔ Test run with 7 tests in 1 suite passed after 0.001 seconds.');process.exitCode=65;}
 else import(path.resolve(process.argv[2])).then(m=>{process.exitCode=m.runUnit({timeoutSeconds:process.env.MODE==='hang'?2:30,captureSeconds:0.2,graceSeconds:0.1,verifyCoverage:false});});
}
else if(process.argv[2]==='scripts/ci/package-coverage-local.mjs'){require('fs').appendFileSync(process.env.EXPORT_MARKER,'evaluate\\n');console.log('Package: lines ${covered}/2; functions ${covered}/2; raw functions ${covered}/2; exceptions 0; eligible functions ${covered}/2');console.log('Coverage gate: ${covered === 2 ? 'PASS' : 'FAIL'}');process.exit(${covered === 2 ? 0 : 1});}
else if(process.argv[2]==='--test'){
 const fs=require('fs');fs.writeFileSync(process.env.NODE_MARKER,process.argv.slice(2).join('\\n'));
 const handoff=['MADO_HEAVY_LOCK_HELD','MADO_HEAVY_CONTROL_FD','MADO_HEAVY_FLOCK_EXPECTED','MDPRO_HEAVY_LOCK_HELD'];
 const record={argv:process.argv.slice(2),env:Object.fromEntries(handoff.map(k=>[k,process.env[k]??'']))};
 if(process.env.PROBE_COMPETITOR==='1'){
  // #891: a second node lane started now, on this fixture's heavy.lock only (mdpro off), must wait, not run.
  const env={...process.env,MADO_MDPRO_LOCK:'off',MADO_HEAVY_LOCK_WAIT_SECS:'1'};for(const k of handoff)delete env[k];
  const c=require('child_process').spawnSync(process.env.COMPETITOR_LOCK,[process.execPath,'--test',process.env.COMPETITOR_SCRIPT],{env,encoding:'utf8',timeout:30000});
  record.competitor={status:c.status,stderr:c.stderr};
 }
 fs.appendFileSync(process.env.NODE_RECORDS,JSON.stringify(record)+'\\n');
 if(process.env.MODE==='node-fail')process.exit(1);
}
else if(process.argv[2]==='scripts/tdd/app-lane.mjs'){
 const hosted=process.argv[3]?.includes('Hosted') ?? false;
 if(process.env.MODE==='app-hosted-hung'&&hosted){console.log('test runner hung before establishing connection');process.exit(70);}
 if(process.env.MODE!=='app-empty')console.log('Tests run: 2, Failures: 0, Errors: 0, Skipped: 0');
 require('fs').appendFileSync(process.env.EXPORT_MARKER,hosted?'hosted\\n':'retained\\n');
}
else process.exit(0);
`);
  exe('xcrun', `#!${process.execPath}
require('fs').appendFileSync(process.env.EXPORT_MARKER,'export\\n');
console.log('SF:/fixture.swift\\nFN:1,a\\nFN:2,b\\nFNDA:1,a\\nFNDA:${covered === 2 ? 1 : 0},b\\nFNF:2\\nFNH:${covered}\\nDA:1,1\\nDA:2,${covered === 2 ? 1 : 0}\\nLF:2\\nLH:${covered}\\nend_of_record');
`);
  exe('npm', '#!/bin/sh\nexit 0\n');
  exe('xcodegen', '#!/bin/sh\necho "held=$MADO_HEAVY_LOCK_HELD $*" >> "$XCODEGEN_MARKER"\nexit 0\n');
  exe('xcodebuild', '#!/bin/sh\necho "$1" >> "$XCODE_MARKER"\nexit 0\n');
  // #760: injected machine facts (fixtures/owner-gates/sysctl, fakeps). #891: linked, not written, so the probes
  // exec an already assessed file instead of paying macOS's first-exec assessment inside their 5 s timeout.
  for (const name of ['sysctl', 'fakeps']) fs.symlinkSync(fileURLToPath(new URL(`./fixtures/owner-gates/${name}`, import.meta.url)), path.join(bin, name));
  // #891: the competitor lane's test file only leaves a marker when it actually runs.
  fs.writeFileSync(path.join(dir, 'competitor.test.mjs'), `import fs from 'node:fs';\nfs.writeFileSync(process.env.COMPETITOR_MARKER, 'ran');\n`);
  const shell = path.join(dir, 'invoke.zsh');
  fs.writeFileSync(shell, `git() { if [[ "$1" == rev-parse ]]; then print fixture-sha; elif [[ "$1" == merge-base ]]; then print fixture-base; elif [[ "$1" == diff && "$2" == --name-only ]]; then print $DIFF_PATH; fi;  }
node() { export PATH="$FIXTURE_BIN:$PATH"; "$FIXTURE_BIN/node" "$@"; }
xcodegen() { "$FIXTURE_BIN/xcodegen" "$@"; }
source "$OWNER" "$FIXTURE_DIR" fixture-sha run fixture-base
`);
  // #891: start from fixtureEnv so the caller's heavy-lock handoff and timing overrides never reach the
  // fixture's own top-level lock, then apply this fixture's private values.
  const env = fixtureEnv({ PATH: `${bin}:${process.env.PATH}`, FIXTURE_BIN: bin, FIXTURE_DIR: dir, OWNER: path.join(dir, '.agents/skills/mado-delegator/scripts/owner-gates.sh'),
    MODE: mode, BUILD: build, DIFF_PATH: options.diff ?? 'Packages/MadoKit/Sources/MadoCore/Fake.swift', SELECT_OUTPUT:options.selectOutput ?? '', OWNER_GATES_HOSTED: options.hosted ? '1' : '0', XCODE_MARKER: path.join(dir, 'xcode-args'), XCODEGEN_MARKER: path.join(dir, 'xcodegen-args'), HOME: dir, EXPORT_MARKER: path.join(dir, 'exports'), NODE_MARKER: path.join(dir, 'node-args'), NODE_RECORDS: path.join(dir, 'node-records'), MADO_GATES_OUT: out,
    COMPETITOR_LOCK: path.join(dir, 'scripts/heavy-lock.sh'), COMPETITOR_SCRIPT: path.join(dir, 'competitor.test.mjs'), COMPETITOR_MARKER: path.join(dir, 'competitor-ran'),
    MADO_HEAVY_LOCK: path.join(dir, 'heavy.lock'), MADO_MDPRO_LOCK: path.join(dir, 'shared.lock'),
    OWNER_GATES_MAX_LOAD: '', OWNER_GATES_MIN_MEM_FREE: '', OWNER_GATES_MAX_PRESSURE: '', MADO_GATES_PREFLIGHT: '' });
  // The fake tools must win over the real xcodegen/Homebrew directories owner-gates.sh puts in front of PATH.
  env.OWNER_GATES_TOOL_PATH = bin;
  env.OWNER_GATES_SYSCTL = path.join(bin, 'sysctl');
  env.OWNER_GATES_PS = path.join(bin, 'fakeps');
  Object.assign(env, options.env ?? {});
  if (options.staleOwner) fs.writeFileSync(`${env.MADO_HEAVY_LOCK}.guardian-stale.owner`, fs.readFileSync(new URL('./fixtures/guardian.owner', import.meta.url)));
  const result = spawnSync('/bin/zsh', [shell], { env, cwd: dir, encoding: 'utf8', timeout: 90_000 });
  const summary = fs.readFileSync(path.join(out, 'run-summary.txt'), 'utf8');
  if (process.env.OWNER_GATES_SAMPLE === '1') console.log(`SAMPLE mode=${mode} diff=${env.DIFF_PATH} hosted=${env.OWNER_GATES_HOSTED}\n${summary}`);
  if (process.env.OWNER_GATES_SAMPLE === '1') for (const f of fs.readdirSync(out)) console.log(`LOG ${f}\n${fs.readFileSync(path.join(out, f), 'utf8')}`);
  return { dir, out, env, result, nodeRecords: env.NODE_RECORDS, competitorMarker: env.COMPETITOR_MARKER, xcodeMarker: env.XCODE_MARKER, xcodegenMarker: env.XCODEGEN_MARKER, marker: env.EXPORT_MARKER, nodeMarker: env.NODE_MARKER, summary };
}

test('owner node lane runs the name-check tests required by CI', t => {
  const ci = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
  assert.match(ci, /run: node --test scripts\/name-checks\/\*\.test\.mjs scripts\/ci\/name-checks-ci\.test\.mjs/);
  const f = fixture(t);
  assert.equal(f.result.status, 0, f.result.stderr);
  const args = fs.readFileSync(f.nodeMarker, 'utf8').split('\n');
  assert.ok(args.includes('scripts/name-checks/fixture.test.mjs'), args.join('\n'));
  assert.ok(args.includes('scripts/ci/name-checks-ci.test.mjs'), args.join('\n'));
  assert.ok(args.includes('.agents/skills/mado-delegator/scripts/fixture.test.mjs'), args.join('\n'));
});

test('invalid select output refuses before every lane', t => {
  for (const selectOutput of ['native=0\nagents=0', 'native=maybe\nagents=0\ntdd=0', 'native=0\nnative=1\nagents=0\ntdd=0']) {
    const f = fixture(t, 'pass', 2, true, {selectOutput});
    assert.equal(f.result.status, 2, f.result.stderr);
    assert.match(f.summary, /^owner-gates: refused: invalid suite selection/m);
    assert.doesNotMatch(f.summary, /^DONE$/m);
  }
});

test('free lock with a captured stale owner record reports a fact and continues', t => {
  const f = fixture(t, 'pass', 2, true, {staleOwner:true});
  assert.equal(f.result.status, 0, f.result.stderr);
  assert.match(f.summary, /^preflight: stale-owner-records=1$/m);
  assert.match(f.summary, /^DONE$/m);
});

test('owner reports failure and timeout, rejects old coverage and completes later lanes', t => {
  for (const [mode, status] of [['fail', 1], ['hang', 124]]) {
    const f = fixture(t, mode);
    assert.equal(f.result.status, 1, f.result.stderr);
    assert.match(f.summary, new RegExp(`^swift=${status}$`, 'm'));
    assert.match(f.summary, /^lcov=1$/m);
    assert.match(fs.readFileSync(path.join(f.out, 'run-lcov.log'), 'utf8'), /skipped.*Swift.*failed/i);
    assert.equal(fs.existsSync(f.marker), false, 'coverage tools never consume old profile/report');
    for (const lane of ['xcodegen', 'xcodebuild', 'node', 'ledger', 'diffcheck', 'design']) assert.match(f.summary, new RegExp(`^${lane}=0$`, 'm'));
    assert.match(f.summary, /^apptests=skip \(no App-facing change\)$/m);
    assert.equal(f.summary.match(/^DONE$/gm)?.length, 1);
    if (mode === 'hang') assert.match(fs.readFileSync(path.join(f.out, 'run-swift.log'), 'utf8'), /exit 124 \(timed out\)/);
  }
});

test('missing npm dependencies fail preflight before lanes', t => {
  const f = fixture(t, 'pass', 2, false);
  assert.equal(f.result.status, 2, f.result.stderr);
  assert.match(f.summary, /refused: preflight: missing node_modules/);
  assert.doesNotMatch(f.summary, /^DONE$/m);
});

test('owner normal pass keeps full-suite evidence and applies the strict shared coverage verdict', t => {
  for (const covered of [2, 1]) {
    const f = fixture(t, 'pass', covered);
    assert.equal(f.result.status, covered === 2 ? 0 : 1, f.result.stderr);
    assert.match(f.summary, /^swift=0$/m);
    assert.match(f.summary, new RegExp(`^lcov=${covered === 2 ? 0 : 1}$`, 'm'));
    assert.match(f.summary, new RegExp(`lines ${covered}/2; functions ${covered}/2`));
    assert.match(f.summary, /Test run with 7 tests/); assert.match(f.summary, /^DONE$/m);
    assert.equal(fs.readFileSync(f.marker, 'utf8'), 'evaluate\n');
  }
});

test('owner identifies post-test coverage failure and preserves its invalid-evidence report', t => {
  const f = fixture(t, 'coverage-fail', 1);
  assert.equal(f.result.status, 1, f.result.stderr);
  assert.match(f.summary, /^swift=0$/m);
  assert.match(f.summary, /^lcov=1$/m);
  assert.match(f.summary, /coverage failed after Swift tests passed/i);
  assert.match(f.summary, /Coverage gate: FAIL/);
  assert.doesNotMatch(fs.readFileSync(path.join(f.out, 'run-lcov.log'), 'utf8'), /coverage skipped/i);
});

test('tooling-only diff skips native and runs both Node suites', t => {
  const f = fixture(t, 'pass', 2, true, {diff:'docs/guide.md'});
  assert.equal(f.result.status, 0, f.result.stderr);
  assert.match(f.summary, /^swift=skipped \(no native inputs\)$/m);
  assert.match(f.summary, /^lcov=skipped \(no native inputs\)$/m);
  assert.doesNotMatch(f.summary, /^node-agents=skipped /m);
  assert.doesNotMatch(f.summary, /^node-tdd=skipped /m);
  const args = fs.readFileSync(f.nodeMarker, 'utf8');
  assert.match(args, /scripts\/agents\/fixture\.test\.mjs/);
  assert.match(args, /scripts\/tdd\/fixture\.test\.mjs/);
  assert.match(f.summary, /^DONE$/m);
});

test('App-facing diff reuses build-for-testing and optionally runs hosted', t => {
  for (const hosted of [false, true]) {
    const f = fixture(t, 'pass', 2, true, {diff:'App/MadoApp.swift', hosted});
    assert.equal(f.result.status, 0, f.result.stderr);
    assert.equal(fs.readFileSync(f.xcodeMarker, 'utf8'), 'build-for-testing\n');
    assert.match(f.summary, /^apptests-retained=0 2\/0$/m);
    assert.match(f.summary, hosted ? /^apptests-hosted=0$/m : /^apptests-hosted=skipped /m);
    assert.match(f.summary, /^apptests=0$/m);
  }
});

test('App zero-count and hosted hang cannot turn into a passing compatibility line', t => {
  for (const mode of ['app-empty', 'app-hosted-hung']) {
    const f = fixture(t, mode, 2, true, {diff:'App/MadoApp.swift', hosted:true});
    assert.equal(f.result.status, 1, f.result.stderr);
    assert.match(f.summary, mode === 'app-empty' ? /^apptests-retained=1 0\/0$/m : /^apptests-hosted=70$/m);
    assert.match(f.summary, mode === 'app-empty' ? /^apptests=1$/m : /^apptests=70$/m);
    assert.match(f.summary, mode === 'app-empty' ? /apptests-retained: exit=1/ : /apptests-hosted: hung/);
    assert.match(f.summary, /^DONE$/m);
  }
});

test('xcodegen runs through scripts/heavy-lock.sh (758)', t => {
  const f = fixture(t);
  assert.equal(f.result.status, 0, f.result.stderr);
  assert.match(f.summary, /^xcodegen=0$/m);
  assert.equal(fs.readFileSync(f.xcodegenMarker, 'utf8'), 'held=1 generate\n');
});

test('750 node lane runs scripts/ci and the mado-verify tests and names its exceptions', t => {
  for (const diff of ['docs/guide.md', 'App/MadoApp.swift']) {
    const f = fixture(t, 'pass', 2, true, {diff});
    assert.equal(f.result.status, 0, f.result.stderr);
    const args = fs.readFileSync(f.nodeMarker, 'utf8').split('\n');
    for (const file of ['scripts/ci/for-where-ban.test.mjs', 'scripts/ci/name-checks-ci.test.mjs', '.agents/skills/mado-verify/tests/fixture.test.mjs',
      'scripts/ledger/fixture.test.mjs', 'scripts/name-checks/fixture.test.mjs', '.agents/skills/mado-delegator/scripts/fixture.test.mjs'])
      assert.ok(args.includes(file), `${diff}: ${file} in ${args.join(' ')}`);
    assert.equal(args.filter(a => a === 'scripts/ci/name-checks-ci.test.mjs').length, 1, 'each file once');
    assert.match(f.summary, /^node-excepted=\d+ /m);
  }
});

test('760 load preflight writes the facts, refuses over a threshold before any lane, and only notes unreadable facts', t => {
  const under = fixture(t, 'pass', 2, true, {env: {}});
  assert.equal(under.result.status, 0, under.result.stderr);
  assert.match(under.summary, /^load=4\.2 mem_free=55% pressure=1$/m);
  assert.match(under.summary, /^competing-heavy=101:swift-frontend$/m);
  assert.match(under.summary, /^DONE$/m);
  for (const [env, reason] of [[{FAKE_LOADAVG: '{ 23.40 9.00 5.00 }'}, /load 23\.4 over OWNER_GATES_MAX_LOAD=6/],
    [{FAKE_MEM_LEVEL: '9'}, /mem_free 9% under OWNER_GATES_MIN_MEM_FREE=25/], [{FAKE_PRESSURE: '4'}, /pressure 4 over OWNER_GATES_MAX_PRESSURE=1/],
    [{OWNER_GATES_MAX_LOAD: '3'}, /load 4\.2 over OWNER_GATES_MAX_LOAD=3/]]) {
    const over = fixture(t, 'pass', 2, true, {env, diff: 'App/MadoApp.swift'});
    assert.equal(over.result.status, 2, `${JSON.stringify(env)} ${over.result.stderr}`);
    assert.match(over.summary, /^refused: preflight: /m);
    assert.match(over.summary, /^result=no evidence$/m);
    assert.match(over.summary, reason);
    assert.match(over.summary, /^load=\S+ mem_free=\S+ pressure=\S+$/m);
    assert.doesNotMatch(over.summary, /^DONE$/m);
    assert.doesNotMatch(over.summary, /^(swift|xcodegen|xcodebuild|node|design)=/m, 'no lane ran');
    for (const marker of [over.nodeMarker, over.xcodeMarker, over.xcodegenMarker]) assert.equal(fs.existsSync(marker), false, marker);
  }
  const unreadable = fixture(t, 'pass', 2, true, {env: {FAKE_LOADAVG: 'unreadable', FAKE_MEM_LEVEL: 'unreadable', FAKE_PRESSURE: 'unreadable'}});
  assert.equal(unreadable.result.status, 0, unreadable.result.stderr);
  assert.match(unreadable.summary, /^load=unknown mem_free=unknown pressure=unknown$/m);
  assert.equal(unreadable.summary.match(/^preflight-note: .+ unreadable; no refusal on it$/gm)?.length, 3);
  assert.match(unreadable.summary, /^DONE$/m);
});

test('760 explicit off override records bypass while still reporting facts and competitors', t => {
  const f=fixture(t,'pass',2,true,{env:{MADO_GATES_PREFLIGHT:'off',FAKE_LOADAVG:'{ 23.40 9.00 5.00 }',FAKE_MEM_LEVEL:'9',FAKE_PRESSURE:'4'}});
  assert.equal(f.result.status,0,f.result.stderr);
  assert.match(f.summary,/^preflight-guard=off$/m);
  assert.match(f.summary,/^load=23\.4 mem_free=9% pressure=4$/m);
  assert.match(f.summary,/^competing-heavy=101:swift-frontend$/m);
  assert.match(f.summary,/^DONE$/m);
});

test('fix1 a native-only diff still runs the scripts/agents and scripts/tdd suites CI runs on every PR', t => {
  const f = fixture(t, 'pass', 2, true, {diff: 'App/MadoApp.swift'});
  assert.equal(f.result.status, 0, f.result.stderr);
  assert.doesNotMatch(f.summary, /^node-agents=skipped /m);
  assert.doesNotMatch(f.summary, /^node-tdd=skipped /m);
  const args = fs.readFileSync(f.nodeMarker, 'utf8').split('\n');
  for (const file of ['scripts/agents/fixture.test.mjs', 'scripts/tdd/fixture.test.mjs']) assert.ok(args.includes(file), `${file} in ${args.join(' ')}`);
});

test('fix1 the summary records the thresholds in force when one is set by environment', t => {
  const set = fixture(t, 'pass', 2, true, {env: {OWNER_GATES_MAX_LOAD: '999', OWNER_GATES_MIN_MEM_FREE: '5'}});
  assert.equal(set.result.status, 0, set.result.stderr);
  assert.match(set.summary, /^load=4\.2 mem_free=55% pressure=1\nlimits=999\/5%\/1$/m);
  const refused = fixture(t, 'pass', 2, true, {env: {OWNER_GATES_MAX_LOAD: '3'}});
  assert.equal(refused.result.status, 2, refused.result.stderr);
  assert.match(refused.summary, /^limits=3\/25%\/1$/m);
  const defaults = fixture(t, 'pass', 2, true, {env: {}});
  assert.doesNotMatch(defaults.summary, /^limits=/m);
});

// #891: owner-gates runs its node lane under the heavy lock, so this file can inherit the lane's supervision
// handoff and timing overrides. A fixture launches its own top-level lock and must not see them.
test('891 fixture ignores the caller lock supervision and timing overrides', t => {
  const inherited = {MADO_HEAVY_LOCK_HELD: '1', MADO_HEAVY_CONTROL_FD: '99', MADO_HEAVY_FLOCK_EXPECTED: '1',
    MDPRO_HEAVY_LOCK_HELD: '1', MADO_HEAVY_LOCK_EXEC_SECS: '0'};
  const saved = Object.fromEntries(Object.keys(inherited).map(name => [name, process.env[name]]));
  t.after(() => { for (const [name, value] of Object.entries(saved)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; } });
  Object.assign(process.env, inherited);
  const f = fixture(t);
  assert.equal(f.result.status, 0, f.result.stderr + f.summary);
  assert.match(f.summary, /^xcodegen=0$/m);
  assert.equal(fs.readFileSync(f.xcodegenMarker, 'utf8'), 'held=1 generate\n');
  assert.match(f.summary, /^DONE$/m);
});

test('891 fixture also drops the private status channel and wait override of its caller', t => {
  const inherited = {MADO_HEAVY_STATUS_DIR: '/nonexistent', MADO_HEAVY_ATTEST_FD: '99', MADO_HEAVY_LOCK_WAIT_SECS: 'abc'};
  const saved = Object.fromEntries(Object.keys(inherited).map(name => [name, process.env[name]]));
  t.after(() => { for (const [name, value] of Object.entries(saved)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; } });
  Object.assign(process.env, inherited);
  const f = fixture(t);
  assert.equal(f.result.status, 0, f.result.stderr + f.summary);
  assert.match(f.summary, /^xcodegen=0$/m);
  assert.equal(fs.readFileSync(f.xcodegenMarker, 'utf8'), 'held=1 generate\n');
  assert.match(f.summary, /^DONE$/m);
});

test('891 node lane holds the shared heavy lock once, one file at a time, without the lock handoff', t => {
  const f = fixture(t, 'pass', 2, true, {env: {PROBE_COMPETITOR: '1'}});
  assert.equal(f.result.status, 0, f.result.stderr + f.summary);
  assert.match(f.summary, /^node=0$/m);
  assert.match(f.summary, /^DONE$/m);
  const records = fs.readFileSync(f.nodeRecords, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.equal(records.length, 1, 'exactly one node --test invocation');
  const [record] = records;
  // A second lane on the same heavy.lock (mdpro lock off) waited and timed out; its test never ran.
  assert.equal(record.competitor.status, 75, record.competitor.stderr);
  assert.match(record.competitor.stderr, /waiting for .*heavy\.lock/);
  assert.match(record.competitor.stderr, /lock wait timed out/);
  assert.equal(fs.existsSync(f.competitorMarker), false, 'the competitor lane must not run while the node lane holds the lock');
  const files = record.argv.filter(arg => !arg.startsWith('--'));
  assert.deepEqual(record.argv.slice(0, record.argv.length - files.length).sort(), ['--test', '--test-concurrency=1', '--test-reporter=spec']);
  assert.ok(files.includes('scripts/tdd/fixture.test.mjs') && files.includes('.agents/skills/mado-verify/tests/fixture.test.mjs'), files.join(' '));
  assert.deepEqual(record.env, {MADO_HEAVY_LOCK_HELD: '', MADO_HEAVY_CONTROL_FD: '', MADO_HEAVY_FLOCK_EXPECTED: '', MDPRO_HEAVY_LOCK_HELD: ''});
  // Negative control: once the lane has released the lock, the same competitor command runs.
  const env = {...f.env, MADO_MDPRO_LOCK: 'off', MADO_HEAVY_LOCK_WAIT_SECS: '1'};
  const after = spawnSync(f.env.COMPETITOR_LOCK, [process.execPath, '--test', f.env.COMPETITOR_SCRIPT], {env, encoding: 'utf8', timeout: 30000});
  assert.equal(after.status, 0, after.stderr);
  assert.equal(fs.readFileSync(f.competitorMarker, 'utf8'), 'ran');
});

test('891 a failing node lane under the lock is reported, not swallowed', t => {
  const f = fixture(t, 'node-fail');
  assert.equal(f.result.status, 1, f.result.stderr + f.summary);
  assert.match(f.summary, /^node=1$/m);
  assert.match(f.summary, /^DONE$/m);
});

test('891 static sysctl and ps fakes are linked checked-in executables', t => {
  const f = fixture(t);
  assert.equal(f.result.status, 0, f.result.stderr + f.summary);
  const fakes = path.join(root, '.agents/skills/mado-delegator/scripts/fixtures/owner-gates');
  for (const name of ['sysctl', 'fakeps']) {
    const linked = path.join(f.dir, 'bin', name);
    assert.ok(fs.lstatSync(linked).isSymbolicLink(), `bin/${name} must be a symlink`);
    assert.equal(fs.realpathSync(linked), fs.realpathSync(path.join(fakes, name)));
    assert.ok(fs.statSync(linked).mode & 0o111, `${name} must be executable`);
    const index = spawnSync('git', ['ls-files', '-s', '--', path.join(fakes, name)], { cwd: root, encoding: 'utf8' });
    assert.match(index.stdout, /^100755 /, `${name} must be committed as 100755`);
  }
  assert.match(f.summary, /^load=4\.2 mem_free=55% pressure=1$/m);
  assert.match(f.summary, /^competing-heavy=101:swift-frontend$/m);
});
