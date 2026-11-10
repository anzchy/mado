import { knownFlaky } from '../ci/known-flaky.mjs';
import test, { afterEach, after } from 'node:test';
import { spawn, spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runAppLane, parseAppResult } from './app-lane.mjs';

const baseline = readFileSync(new URL('./fixtures/i411-baseline.txt', import.meta.url), 'utf8');
const selected = readFileSync(new URL('./fixtures/i411-selected.txt', import.meta.url), 'utf8');
const ids = ['OtherProbeTests/testSkip', 'ProbeTests/testKeep', 'ProbeTests/testSkip', 'ProbeTests/testSkipSibling', 'Probe.swiftKeep()', 'Probe.swiftSkip()', 'Probe.swiftSkipSibling()'];
const inventory = 'APP_LANE_INVENTORY_BEGIN\n' + ids.map(id => id.includes('(') ? id : `XCT_ID=-[${id.replace('/', ' ')}]`).join('\n') + '\nAPP_LANE_INVENTORY_END\n';
const quarantine = [{owner:'test-owner',expires:'9999-12-31',id:'ProbeTests/testSkip',issue:411,reason:'test failure'}, {owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkip()',issue:425,reason:'test failure'}];
const result = stdout => ({status:0,stdout,stderr:'',signal:null});
const temporaryDirectories = new Set();
afterEach(()=>{
 for(const dir of temporaryDirectories) {
  rmSync(dir,{recursive:true,force:true});
  assert.equal(existsSync(dir),false,`temporary directory remains: ${dir}`);
 }
 temporaryDirectories.clear();
});
after(()=>assert.equal(temporaryDirectories.size,0,'all test-owned temporary directories cleaned'));
function harness(entries = [], options = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'i524-node-'));
  temporaryDirectories.add(dir);
  const quarantinePath = options.quarantinePath ?? path.join(dir, 'quarantine.json');
  if (!options.quarantinePath) writeFileSync(quarantinePath, typeof entries === 'string' ? entries : JSON.stringify(entries));
  let stdout='',stderr='';const calls=[];
  const spawn = (cmd,args,opts) => {
    calls.push({cmd,args,opts});
    if (options.queued && cmd.endsWith('heavy-lock.sh') && opts.timeout && opts.timeout <= 120000) return {...result(''),status:null,error:new Error('simulated lock queue exceeded outer timeout')};
    // Normalize only the process protocol; return values still exercise the real lane.
    if (cmd === process.execPath || args[0] === process.execPath) {
      const wrapper = cmd === process.execPath ? args : args.slice(1);
      args = wrapper.slice(3);
    }
    if(cmd==='xcrun' && args[0]==='--show-sdk-platform-path') return options.sdk ?? result('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform\n');
    if(args[0]==='xcrun' && args[1]==='--show-sdk-platform-path') return result('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform\n');
    if(args.includes('swiftc')) return result('');
    if(args[0]==='xcrun' && args[1]==='xctest') return options.run?.(calls) ?? result(entries.length ? selected : baseline);
    return options.discovery ?? result(inventory);
  };
  const status=runAppLane({spawn,env:{EXAMPLE:'kept',PICSEE_APP_LANE_NO_RETRY:'1'},quarantinePath,evidencePath:path.join(dir,'evidence.log'),stdout:s=>stdout+=s,stderr:s=>stderr+=s,...options, ...(options.spawn ? {} : {spawn})});
  return {status,stdout,stderr,calls,dir,quarantinePath};
}
const nativeCalls = h => h.calls.filter(c=>c.args[0]==='xcrun'&&c.args[1]==='xctest');

test('empty quarantine keeps exact native argv/env and prints none before results',()=>{
 const h=harness();assert.equal(h.status,0,h.stderr);assert.equal(h.calls.length,1);
 assert.deepEqual(h.calls[0].args,['xcrun','xctest','.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);
 assert.deepEqual(h.calls[0].opts.env,{EXAMPLE:'kept',PICSEE_APP_LANE_NO_RETRY:'1',SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:'1'});
 assert.ok(h.stdout.startsWith('app-lane quarantine none\n'));assert.match(h.stdout,/Tests run: 3, Failures: 0/);
});
test('default parser and empty lane reject recorded Selected tests even with complete counts',()=>{
 assert.equal(parseAppResult(result(baseline)).status,0);assert.equal(parseAppResult(result(selected)).status,70);
 const h=harness([],{run:()=>result(selected)});assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);
});
test('two entries select inventory minus both exact IDs; combined selected count includes both frameworks',()=>{
 const h=harness(quarantine);assert.equal(h.status,0,h.stderr);
 const native=nativeCalls(h);assert.equal(native.length,1);assert.deepEqual(native[0].args,['xcrun','xctest','-XCTest','OtherProbeTests/testSkip,ProbeTests/testKeep,ProbeTests/testSkipSibling,Probe.swiftKeep(),Probe.swiftSkipSibling()','.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);
 assert.ok(h.stdout.startsWith('app-lane quarantine skip=ProbeTests/testSkip issue=#411\napp-lane quarantine skip=Probe.swiftSkip() issue=#425\n'));
 assert.match(h.stdout,/Tests run: 5, Failures: 0/);
});
for(const [label,entries] of [
 ['missing issue',[{owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkip()',reason:'failure'}]],['invalid issue',[{owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkip()',issue:0,reason:'failure'}]],
 ['missing reason',[{owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkip()',issue:411}]],['blank reason',[{owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkip()',issue:411,reason:'  '}]],
 ['malformed JSON','{'],['object root','{}'],['null entry',[null]],['invalid id',[{owner:'test-owner',expires:'9999-12-31',id:'foo.*',issue:411,reason:'failure'}]],
 ['duplicate id',[quarantine[0],quarantine[0]]],['atomic validation',[quarantine[0],{owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkip()',reason:'failure'}]],
]) test(`${label} fails with 70 before any process`,()=>{
 const h=harness(entries);assert.equal(h.status,70);assert.equal(h.calls.length,0);assert.match(h.stderr,/quarantine/);assert.doesNotMatch(h.stdout,/quarantine skip=|Tests run:/);
});
test('missing and unreadable file fail closed before any process',()=>{
 for(const p of [path.join(tmpdir(),'i411-does-not-exist.json'),tmpdir()]) {const h=harness([],{quarantinePath:p});assert.equal(h.status,70);assert.equal(h.calls.length,0);assert.match(h.stderr,/quarantine/);}
});
test('missing quarantined ID warns and fails before test execution',()=>{
 const h=harness([{owner:'test-owner',expires:'9999-12-31',id:'Probe.absent()',issue:411,reason:'failure'}]);assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/warn.*Probe\.absent\(\)/i);assert.doesNotMatch(h.stdout,/Tests run:/);
});
for(const [label,discovery] of [
 ['truncated',result(inventory.replace('APP_LANE_INVENTORY_END\n',''))],['malformed',result('garbage\n')],
 ['duplicate',result(inventory.replace('APP_LANE_INVENTORY_END','Probe.swiftKeep()\nAPP_LANE_INVENTORY_END'))],
 ['ambiguous',result(inventory.replace('APP_LANE_INVENTORY_END','Probe.Other/swiftKeep()\nAPP_LANE_INVENTORY_END'))],
 ['signal',{...result(inventory),signal:'SIGTERM',status:null}],['failure',{...result(inventory),status:1}],
]) test(`inventory ${label} fails closed before xctest`,()=>{
 const h=harness(quarantine,{discovery});assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/inventory|quarantine/i);
});
for(const [label,output] of [
 ['still ran quarantined Swift test',selected.replace('◇ Test swiftKeep()', '◇ Test swiftSkip()').replace('✔ Test swiftKeep()', '✔ Test swiftSkip()')],
 ['three Swift tests despite exclusion',baseline.replaceAll("'All tests'","'Selected tests'")],
 ['duplicate Swift identity',selected.replaceAll('swiftSkipSibling()','swiftKeep()')],
 ['missing Swift test with self-consistent counts',selected.replace(/^.*swiftSkipSibling\(\).*\n/gm,'').replace('2 tests in 0 suites','1 test in 0 suites')],
 ['wrong XCTest identity',selected.replaceAll('testKeep]', 'testSkip]')],
 ['XCTest root count mismatch',selected.replace('Executed 3 tests, with 0 failures','Executed 4 tests, with 0 failures')],
]) test(`selected ${label} returns 70 without a success summary`,()=>{
 const h=harness(quarantine,{run:()=>result(output)});assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);assert.equal(nativeCalls(h).length,1);
});
test('parameterized Swift terminal suffix is normalized only for identity comparison',()=>{
 const h=harness(quarantine,{run:()=>result(selected.replace('swiftKeep() passed after','swiftKeep() with 2 test cases passed after'))});assert.equal(h.status,0,h.stderr);
});
test('same configuration path rereads empty -> populated -> empty and restores invocation',()=>{
 const h1=harness();writeFileSync(h1.quarantinePath,JSON.stringify(quarantine));const h2=harness(quarantine,{quarantinePath:h1.quarantinePath});
 writeFileSync(h1.quarantinePath,'[]');const h3=harness([],{quarantinePath:h1.quarantinePath});
 assert.equal(h1.status,0);assert.equal(h2.status,0,h2.stderr);assert.equal(h3.status,0);assert.deepEqual(h1.calls[0].args,h3.calls[0].args);assert.deepEqual(h1.calls[0].opts.env,h3.calls[0].opts.env);assert.match(h3.stdout,/quarantine none/);assert.doesNotMatch(h3.stdout,/quarantine skip=/);
});

test('selection with no remaining Swift tests fails before xctest',()=>{
 const allSwift=ids.filter(id=>id.includes('(')).map(id=>({owner:'test-owner',expires:'9999-12-31',id,issue:411,reason:'failure'}));
 const h=harness(allSwift);assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/no remaining/);
});
for(const [label,output] of [
 ['unexpected Swift start',selected.replace('◇ Test swiftKeep() started.','◇ Test swiftSkip() started.\n◇ Test swiftKeep() started.')],
 ['duplicate Swift start',selected.replace('◇ Test swiftKeep() started.','◇ Test swiftKeep() started.\n◇ Test swiftKeep() started.')],
 ['unfinished Swift start',selected.replace('✔ Test swiftKeep() passed after 0.001 seconds.','')],
 ['unexpected XCTest start',selected.replace("Test Suite 'ProbeTests' started", "Test Case '-[Probe.ProbeTests testSkip]' started.\nTest Suite 'ProbeTests' started")],
 ['duplicate XCTest start',selected.replace("Test Case '-[Probe.ProbeTests testKeep]' started.","Test Case '-[Probe.ProbeTests testKeep]' started.\nTest Case '-[Probe.ProbeTests testKeep]' started.")],
 ['actual root count mismatch',selected.replace(/(Test Suite 'Selected tests' passed[^\n]*\n\s*Executed )3/, '$14')],
]) test(`selected ${label} cannot borrow a valid completion`,()=>{
 const h=harness(quarantine,{run:()=>result(output)});assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);
});

test('parameterized case events require their retained parent without becoming separate tests',()=>{
 const output=selected.replace('◇ Test swiftKeep() started.','◇ Test swiftKeep() started.\n◇ Test case passing 1 argument value → 1 to swiftKeep() started.');
 const h=harness(quarantine,{run:()=>result(output)});assert.equal(h.status,0,h.stderr);
 const bad=harness(quarantine,{run:()=>result(output.replace('to swiftKeep() started.','to swiftSkip() started.'))});assert.equal(bad.status,70);
});
test('selected known flaky retry retains exclusions and original evidence bytes',()=>{
 const name='t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves';
 const discovery=result(inventory.replaceAll('Probe.swiftKeep()',`Probe.${name}()`));
 const passing=selected.replaceAll('swiftKeep()',`${name}()`);
 const failing=passing.replace(`✔ Test ${name}() passed after 0.001 seconds.`,`✘ Test ${name}() recorded an issue at LostAccessRecoveryTests.swift:1315:13: Time limit was exceeded: 180.000 seconds\n✘ Test ${name}() failed after 180.045 seconds with 1 issue.`).replace('✔ Test run with 2 tests in 0 suites passed after 0.001 seconds.','✘ Test run with 2 tests in 0 suites failed after 180.045 seconds with 1 issue.');
 let attempts=0;
 const h=harness(quarantine,{env:{},discovery,run:()=>++attempts===1?{...result(failing),status:1}:result(passing)});
 assert.equal(h.status,0,h.stderr);assert.equal(attempts,2);assert.match(h.stdout,/known flaky .*retrying once/);
 assert.deepEqual(nativeCalls(h)[0].args,nativeCalls(h)[1].args);
 assert.equal(readFileSync(path.join(h.dir,'evidence.log'),'utf8'),failing+'\n');
 assert.equal(h.stdout.match(/quarantine skip=/g).length,2);
 const bad=harness(quarantine,{env:{},discovery,run:()=>({...result(failing.replaceAll('swiftSkipSibling()','swiftSkip()')),status:1})});
 assert.equal(bad.status,70);assert.equal(nativeCalls(bad).length,1);assert.doesNotMatch(bad.stdout,/retrying once/);
});

test('framed inventory with an unsupported identity fails before xctest',()=>{
 const h=harness(quarantine,{discovery:result(inventory.replace('Probe.swiftKeep()','Probe.unsupported.*'))});
 assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/inventory unsupported identifier/);assert.doesNotMatch(h.stdout,/Tests run:/);
});

// WI-2: derived mutations of the recorded mixed native output, retaining the
// clean sibling XCTest summary that made the old generic parser look complete.
function withSkippedXCTest(output, failed = false, unexpected = 0) {
 return output
  .replace(/Test Suite '(ProbeTests|Probe\.xctest|Selected tests)' passed/g, `Test Suite '$1' ${failed ? 'failed' : 'passed'}`)
  .replace("Test Case '-[Probe.ProbeTests testKeep]' passed (",`Test Case '-[Probe.ProbeTests testKeep]' ${failed ? 'failed' : 'passed'} (`)
  .replace("Test Case '-[Probe.ProbeTests testSkipSibling]' passed (","Test Case '-[Probe.ProbeTests testSkipSibling]' skipped (")
  .replace('Executed 2 tests, with 0 failures (0 unexpected)',`Executed 2 tests, with 1 test skipped and ${failed ? 1 : 0} failures (${unexpected} unexpected)`)
  .replaceAll('Executed 3 tests, with 0 failures (0 unexpected)',`Executed 3 tests, with 1 test skipped and ${failed ? 1 : 0} failures (${unexpected} unexpected)`);
}
test('selected failed and skipped XCTest cannot authorize retry of a known Swift failure',()=>{
 const name='t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves';
 const discovery=result(inventory.replaceAll('Probe.swiftKeep()',`Probe.${name}()`));
 const output=withSkippedXCTest(selected.replaceAll('swiftKeep()',`${name}()`),true)
  .replace(`✔ Test ${name}() passed after 0.001 seconds.`,`✘ Test ${name}() recorded an issue at LostAccessRecoveryTests.swift:1315:13: Time limit was exceeded: 180.000 seconds\n✘ Test ${name}() failed after 180.045 seconds with 1 issue.`)
  .replace('✔ Test run with 2 tests in 0 suites passed after 0.001 seconds.','✘ Test run with 2 tests in 0 suites failed after 180.045 seconds with 1 issue.');
 const h=harness(quarantine,{env:{},discovery,run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.equal(nativeCalls(h).length,1);assert.doesNotMatch(h.stdout,/retrying once/);
 assert.match(h.stdout,/Tests run: 5, Failures: 2, Errors: 0, Skipped: 1/);
});
test('selected successful XCTest skip retains the exact complete survivor set',()=>{
 const h=harness(quarantine,{run:()=>result(withSkippedXCTest(selected))});
 assert.equal(h.status,0,h.stderr);assert.equal(nativeCalls(h).length,1);assert.match(h.stdout,/Tests run: 5, Failures: 0, Errors: 0, Skipped: 1/);
});
test('selected skipped XCTest summary with unexpected failure fails closed',()=>{
 const h=harness(quarantine,{run:()=>result(withSkippedXCTest(selected,false,1))});
 assert.equal(h.status,70);assert.equal(nativeCalls(h).length,1);assert.doesNotMatch(h.stdout,/retrying once|Tests run:/);
});

test('selected XCTest failed terminal cannot hide behind zero-failure summaries',()=>{
 const output=selected.replace("Test Case '-[Probe.ProbeTests testKeep]' passed (","Test Case '-[Probe.ProbeTests testKeep]' failed (");
 const h=harness(quarantine,{run:()=>result(output)});assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);
});
test('selected XCTest skipped summary count must agree with observed skipped terminals',()=>{
 const output=withSkippedXCTest(selected).replaceAll('with 1 test skipped and','with 2 tests skipped and');
 const h=harness(quarantine,{run:()=>result(output)});assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);
});

// #524 synthetic assertion-failure transcript derived from the recorded mixed run.
// Preserve real XCTest failure-line text from the recorded assertion fixture;
// only its synthetic file and test identity are remapped for the mixed fixture.
const assertionFailureLine=readFileSync(new URL('./fixtures/xctest-two-assertions.txt',import.meta.url),'utf8')
 .split('\n').find(line=>line.includes('XCTAssertEqual failed:'))
 .replace('/SCRATCH/LaneFixtures/Tests/LaneTests/FixtureTests.swift','/FIXTURE/Probe.swift')
 .replace('-[LaneTests.FixtureTests testTwoFailures]','-[Probe.ProbeTests testKeep]');
function withFailedXCTest(output) {
 return output
  .replace("Test Case '-[Probe.ProbeTests testKeep]' passed (",assertionFailureLine+"\nTest Case '-[Probe.ProbeTests testKeep]' failed (")
  .replace(/Test Suite '(ProbeTests|Probe\.xctest|Selected tests)' passed/g,"Test Suite '$1' failed")
  .replace('Executed 2 tests, with 0 failures (0 unexpected)','Executed 2 tests, with 1 failure (0 unexpected)')
  .replaceAll('Executed 3 tests, with 0 failures (0 unexpected)','Executed 3 tests, with 1 failure (0 unexpected)');
}
test('selected genuine XCTest assertion failure returns one with combined counts and evidence',()=>{
 const output=withFailedXCTest(selected);
 const h=harness(quarantine,{env:{},run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.equal(nativeCalls(h).length,1);
 assert.match(h.stdout,/Tests run: 5, Failures: 1, Errors: 0, Skipped: 0/);
 assert.match(h.stdout,/first-attempt failures: ProbeTests\/testKeep/);
 assert.doesNotMatch(h.stdout+h.stderr,/retrying once|environment failure/);
 assert.equal(readFileSync(path.join(h.dir,'evidence.log'),'utf8'),output+'\n');
});
test('selected XCTest assertion failure with skip is reliable and never retried',()=>{
 const h=harness(quarantine,{env:{},run:()=>({...result(withSkippedXCTest(selected,true)),status:1})});
 assert.equal(h.status,1,h.stderr);assert.equal(nativeCalls(h).length,1);
 assert.match(h.stdout,/Tests run: 5, Failures: 1, Errors: 0, Skipped: 1/);
 assert.doesNotMatch(h.stdout+h.stderr,/retrying once|environment failure/);
});
test('selected XCTest with multiple assertion failures counts one failed test and reconciles suite totals',()=>{
 const output=withFailedXCTest(selected).replaceAll('with 1 failure (0 unexpected)','with 2 failures (0 unexpected)');
 const h=harness(quarantine,{env:{},run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.equal(nativeCalls(h).length,1);
 assert.match(h.stdout,/Tests run: 5, Failures: 1, Errors: 0, Skipped: 0/);
 assert.doesNotMatch(h.stdout,/retrying once/);
});
for(const [label,mutate,runOptions] of [
 ['zero exit',s=>s,{status:0}],
 ['signal',s=>s,{signal:'SIGTERM'}],
 ['missing failed terminal',s=>s.replace(/^Test Case .*testKeep\]' failed.*\n/gm,''),{}],
 ['suite failure count mismatch',s=>s.replace('Executed 2 tests, with 1 failure','Executed 2 tests, with 0 failures'),{}],
 ['root failure count mismatch',s=>s.replace(/(Test Suite 'Selected tests' failed[^\n]*\n\s*Executed 3 tests, with )1 failure/,'$12 failures'),{}],
 ['passed suite with failed test',s=>s.replace("Test Suite 'ProbeTests' failed","Test Suite 'ProbeTests' passed"),{}],
 ['missing root summary',s=>s.replace(/(Test Suite 'Selected tests' failed[^\n]*\n)\s*Executed [^\n]*\n/,'$1'),{}],
 ['unexpected failure',s=>s.replace('(0 unexpected)','(1 unexpected)'),{}],
 ['duplicate failed terminal',s=>s.replace(/^(Test Case .*testKeep\]' failed.*)$/m,'$1\n$1'),{}],
]) test(`selected XCTest failure ${label} remains an environment failure`,()=>{
 const output=mutate(withFailedXCTest(selected));
 const h=harness(quarantine,{env:{},run:()=>({...result(output),status:1,...runOptions})});
 assert.equal(h.status,70);assert.equal(nativeCalls(h).length,1);
 assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);
});

// #524 WI-2: the lock queue and the native execution budget are separate.
test('discovery queued beyond 120 seconds still completes within its own execution budget',()=>{
 const h=harness(quarantine,{queued:true});
 assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 5, Failures: 0/);
 const sdk=h.calls.find(c=>c.cmd==='xcrun');
 assert.ok(sdk,'SDK lookup must bypass the heavy lock');
 assert.deepEqual(sdk.args,['--show-sdk-platform-path']);assert.equal(sdk.opts.timeout,120000);
 const discovery=h.calls.filter(c=>c.cmd.endsWith('heavy-lock.sh') && c.args[0]===process.execPath);
 assert.equal(discovery.length,2);
 for(const call of discovery) {assert.equal(call.opts.timeout,undefined);assert.equal(call.args[3],'120000');}
});
test('discovery timeout runner executes real success, failure, spawn error and timeout commands',()=>{
 const h=harness(quarantine);assert.equal(h.status,0,h.stderr);
 const wrapped=h.calls.find(c=>c.cmd.endsWith('heavy-lock.sh') && c.args[0]===process.execPath);
 assert.ok(wrapped,'discovery must retain a bounded native execution runner');
 const code=wrapped.args[2];
 const run=(budget,args)=>spawnSync(process.execPath,['-e',code,String(budget),...args],{encoding:'utf8',timeout:10000,detached:true});
 const ok=run(2000,[process.execPath,'-e',"process.stdout.write('runner-ok')"]);
 assert.equal(ok.status,0,ok.stderr);assert.equal(ok.stdout,'runner-ok');
 assert.equal(run(2000,[process.execPath,'-e','process.exit(9)']).status,9);
 const missing=run(2000,['/i524-missing-executable']);assert.equal(missing.status,70);assert.match(missing.stderr,/inventory|ENOENT/);
 const slow=run(30,[process.execPath,'-e','setTimeout(()=>{},5000)']);assert.equal(slow.status,70);assert.match(slow.stderr,/inventory|ETIMEDOUT|timeout/i);
});
for(const [label,sdk] of [
 ['nonzero',{...result(''),status:1,stderr:'SDK unavailable'}],
 ['signal',{...result(''),status:null,signal:'SIGTERM'}],
 ['spawn error',{...result(''),status:null,error:new Error('SDK process error')}],
 ['relative',result('relative/platform')],['multiline',result('/platform\n/other')],
]) test(`SDK ${label} fails before test execution`,()=>{
 const h=harness(quarantine,{sdk});assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/inventory|quarantine/);
});

// #524 WI-3: explicit support boundary and resource cleanup.
for(const [label,excluded] of [
 ['all Swift tests',ids.filter(id=>id.includes('('))],['every test',ids],
]) test(`quarantine of ${label} explains the retained Swift requirement`,()=>{
 const entries=excluded.map(id=>({owner:'test-owner',expires:'9999-12-31',id,issue:524,reason:'limit test'}));
 const h=harness(entries);assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);
 assert.match(h.stderr,/unsupported.*retain at least one Swift Testing test/i);
 assert.doesNotMatch(h.stdout,/quarantine skip=|Tests run:/);
});
test('one retained Swift Testing test is supported',()=>{
 const entries=[...quarantine,{owner:'test-owner',expires:'9999-12-31',id:'Probe.swiftSkipSibling()',issue:524,reason:'boundary'}];
 const output=selected.replace(/^.*swiftSkipSibling\(\).*\n/gm,'').replace('2 tests in 0 suites','1 test in 0 suites');
 const h=harness(entries,{run:()=>result(output)});assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 4, Failures: 0/);
});
test('empty quarantine custom bundle keeps native arguments and completes',()=>{
 const h=harness([],{bundlePath:'/tmp/custom-probe.xctest'});assert.equal(h.status,0,h.stderr);
 assert.deepEqual(h.calls[0].args,['xcrun','xctest','/tmp/custom-probe.xctest']);assert.ok(h.stdout.startsWith('app-lane quarantine none\n'));
});
if(process.env.PICSEE_I524_CLEANUP_PROBE) test('cleanup failure sentinel',()=>{
 const h=harness();writeFileSync(process.env.PICSEE_I524_CLEANUP_PROBE,h.dir);
 assert.fail('intentional assertion failure to exercise teardown');
});
test('harness removes its directories after a failing assertion in a real test process',()=>{
 const h=harness();const marker=path.join(h.dir,'child-directory.txt');
 const childEnv={...process.env,PICSEE_I524_CLEANUP_PROBE:marker};
 delete childEnv.NODE_TEST_CONTEXT; // The subprocess is a new runner, not a recursive worker.
 const child=spawnSync(process.execPath,['--test','--test-name-pattern=cleanup failure sentinel',fileURLToPath(import.meta.url)],{
  encoding:'utf8',timeout:10000,env:childEnv,
 });
 assert.equal(child.status,1,child.stderr);assert.match(child.stdout,/intentional assertion failure/);
 const owned=readFileSync(marker,'utf8');assert.equal(existsSync(owned),false,'child test directory must be removed despite assertion failure');
});

// Audit regression: safely cap the caller, then inspect live processes before
// fallback teardown. RED must not leak a TERM-ignoring process into later tests.
const pause = ms => new Promise(resolve=>setTimeout(resolve,ms));
const processExists = pid => {
 try {process.kill(pid,0);return true;} catch(error) {if(error.code==='ESRCH')return false;throw error;}
};
async function discoveryProcessCase(kind, cancellation = null) {
 const h=harness(quarantine),marker=path.join(h.dir,'native-pids.json');
 const code=h.calls.find(c=>c.cmd.endsWith('heavy-lock.sh')&&c.args[0]===process.execPath).args[2];
 const childCode=`process.on('SIGTERM',()=>{});setInterval(()=>{},1000);`;
 const command=kind.startsWith('descendant')
  ? `const {spawn}=require('node:child_process');const child=spawn(process.execPath,['-e',${JSON.stringify(childCode)}],{stdio:${JSON.stringify(kind==='descendant-no-pipes'?'ignore':'inherit')}});require('node:fs').writeFileSync(${JSON.stringify(marker)},JSON.stringify([process.pid,child.pid]));process.exit(0);`
  : `process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(${JSON.stringify(marker)},JSON.stringify([process.pid]));setInterval(()=>{},1000);`;
 const runner=spawn(process.execPath,['-e',code,cancellation?'10000':'350',process.execPath,'-e',command],{
  detached:true,stdio:['ignore','pipe','pipe'],
 });
 let stdout='',stderr='',capped=false;
 runner.stdout.on('data',s=>stdout+=s);runner.stderr.on('data',s=>stderr+=s);
 const pids=()=>existsSync(marker)?JSON.parse(readFileSync(marker,'utf8')):[];
 const killOwned=()=>{
  for(const pid of [...pids(),runner.pid]) {
   try {process.kill(-pid,'SIGKILL');} catch(error) {if(error.code!=='ESRCH')throw error;}
   try {process.kill(pid,'SIGKILL');} catch(error) {if(error.code!=='ESRCH')throw error;}
  }
 };
 const started=Date.now();
 const safety=setTimeout(()=>{capped=true;killOwned();},2500);
 const completion=new Promise((resolve,reject)=>{runner.once('error',reject);runner.once('close',(status,signal)=>resolve({status,signal}));});
 try {
  if(cancellation) {
   while(!existsSync(marker)&&Date.now()-started<1500) await pause(10);
   assert.ok(existsSync(marker),'native command must start before cancellation');
   process.kill(runner.pid,cancellation);
  }
  const outcome=await completion;
  assert.equal(capped,false,'caller safety cap must not supply discovery termination');
  assert.equal(outcome.status,70,stderr);assert.equal(outcome.signal,null);
  assert.ok(Date.now()-started<1800,'admitted discovery must finish within its budget plus grace/drain');
  const owned=pids();assert.ok(owned.length>0,'native PID evidence must exist');
  for(let retry=0;retry<50&&owned.some(processExists);retry++) await pause(10);
  assert.deepEqual(owned.filter(processExists),[],'completed discovery must leave no live owned process');
  for(const pid of owned) {
   let groupExists=false;try {process.kill(-pid,0);groupExists=true;} catch(error) {if(error.code!=='ESRCH')throw error;}
   assert.equal(groupExists,false,`native process group ${pid} must be gone`);
  }
  assert.match(stderr,/inventory|timeout|cancel/i);
  return stdout;
 } finally {
  clearTimeout(safety);killOwned();runner.stdout.destroy();runner.stderr.destroy();
 }
}
test('discovery timeout escalates for a real TERM-ignoring command and leaves no live group',async()=>{
 await discoveryProcessCase('direct');
});
test('discovery bounds a successful child with a TERM-ignoring descendant holding output pipes',async()=>{
 await discoveryProcessCase('descendant');
});
for(const signal of ['SIGTERM','SIGINT']) test(`discovery ${signal} cancellation terminates its native process group`,async()=>{
 await discoveryProcessCase('direct',signal);
});
test('discovery does not accept successful root exit while a pipe-less descendant remains alive',async()=>{
 await discoveryProcessCase('descendant-no-pipes');
});

for(const mode of ['managed-wrapper','nested-wrapper','managed-caller']) test(`actual checked discovery preserves native ownership after hard death (${mode})`,async()=>{
 const nested=mode==='nested-wrapper',callerDeath=mode==='managed-caller';
 const h=harness(),script=path.join(h.dir,'checked.mjs'),supervisorFile=path.join(h.dir,'supervisor-pid'),nativeFile=path.join(h.dir,'native-pid'),callerFile=path.join(h.dir,'caller-pid');
 writeFileSync(h.quarantinePath,JSON.stringify(quarantine));
 const nativeCode=`process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(${JSON.stringify(nativeFile)},String(process.pid));setInterval(()=>{},1000);`;
 writeFileSync(script,`
import {spawnSync} from 'node:child_process';
import {writeFileSync} from 'node:fs';
import {runAppLane} from ${JSON.stringify(new URL('./app-lane.mjs',import.meta.url).href)};
writeFileSync(${JSON.stringify(callerFile)},String(process.pid));
const status=runAppLane({quarantinePath:${JSON.stringify(h.quarantinePath)},env:process.env,spawn:(cmd,args,opts)=>{
 if(cmd==='xcrun') return {status:0,stdout:'/platform\\n',stderr:''};
 const source="require('node:fs').writeFileSync("+${JSON.stringify(JSON.stringify(supervisorFile))}+",String(process.pid));\\n"+args[2];
 return spawnSync(cmd,[args[0],'-e',source,${JSON.stringify(callerDeath?'350':'10000')},process.execPath,'-e',${JSON.stringify(nativeCode)}],opts);
}});
process.exitCode=status;
`);
 const lockEnv={...process.env,PICSEE_HEAVY_LOCK:path.join(h.dir,'heavy.lock'),PICSEE_MDPRO_LOCK:path.join(h.dir,'shared.lock'),PICSEE_HEAVY_LOCK_WAIT_SECS:'5'};
 if(nested) lockEnv.PICSEE_HEAVY_LOCK_HELD='1';else delete lockEnv.PICSEE_HEAVY_LOCK_HELD;
 delete lockEnv.MDPRO_HEAVY_LOCK_HELD;delete lockEnv.NODE_TEST_CONTEXT;
 const realLock=fileURLToPath(new URL('../heavy-lock.sh',import.meta.url));
 const runner=spawn(callerDeath?realLock:process.execPath,callerDeath?[process.execPath,script]:[script],{env:lockEnv,detached:true,stdio:['ignore','pipe','pipe']});
 let stderr='';runner.stdout.resume();runner.stderr.on('data',s=>stderr+=s);
 const known=()=>[supervisorFile,nativeFile,callerFile].filter(existsSync).map(p=>Number(readFileSync(p,'utf8')));
 const cleanup=()=>{for(const pid of [...known(),runner.pid])for(const target of [-pid,pid])try{process.kill(target,'SIGKILL');}catch(error){if(error.code!=='ESRCH')throw error;}};
 let capped=false;const cap=setTimeout(()=>{capped=true;cleanup();},5000);
 const completion=new Promise((resolve,reject)=>{runner.once('error',reject);runner.once('close',(status,signal)=>resolve({status,signal}));});
 try {
  const start=Date.now();while(!existsSync(nativeFile)&&Date.now()-start<2000)await pause(10);
  assert.ok(existsSync(nativeFile),stderr);const [supervisor,native]=known();
  process.kill(callerDeath?Number(readFileSync(callerFile,'utf8')):supervisor,'SIGKILL');
  let competitor;
  if(!nested) {
   const lock=fileURLToPath(new URL('../heavy-lock.sh',import.meta.url));
   competitor=spawn(lock,[process.execPath,'-e',`let live=true;try{process.kill(${native},0);}catch(e){if(e.code==='ESRCH')live=false;else throw e;}console.log(JSON.stringify({live}));`],{env:lockEnv,stdio:['ignore','pipe','pipe']});
  }
  const competitorResult=competitor?new Promise((resolve,reject)=>{let out='',err='';competitor.stdout.on('data',s=>out+=s);competitor.stderr.on('data',s=>err+=s);competitor.once('error',reject);competitor.once('close',status=>resolve({status,out,err}));}):null;
  const outcome=await completion;assert.equal(capped,false,stderr);
  if(callerDeath)assert.notEqual(outcome.status,0,stderr);else assert.equal(outcome.status,70,stderr);
  assert.equal(outcome.signal,null);
  if(competitorResult) {const acquired=await competitorResult;assert.equal(acquired.status,0,acquired.err);assert.equal(JSON.parse(acquired.out).live,false,'heavy-lock must retain ownership until native tasks are gone');}
  for(let retry=0;retry<50&&processExists(native);retry++)await pause(10);
  assert.equal(processExists(native),false,'checked discovery must clean native task after supervisor hard death');
  assert.ok(Date.now()-start<3500,'hard-death cleanup must use bounded discovery drain');
 } finally {clearTimeout(cap);cleanup();runner.stdout.destroy();runner.stderr.destroy();}
});

// Fix round1: thrown errors are XCTest test failures (unexpected is a subset
// of failures), provided the selected test and all suite totals reconcile.
function withThrownXCTest(output) {
 return withFailedXCTest(output)
  .replace(assertionFailureLine,'<EXPR>:0: error: -[Probe.ProbeTests testKeep] : threw error "FixtureError.failed"')
  .replaceAll('with 1 failure (0 unexpected)','with 1 failure (1 unexpected)');
}
test('selected complete thrown XCTest error returns one, preserves evidence and cannot retry',()=>{
 const output=withThrownXCTest(selected);
 const h=harness(quarantine,{env:{},run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.match(h.stdout,/Tests run: 5, Failures: 1, Errors: 0, Skipped: 0/);
 assert.equal(nativeCalls(h).length,1);assert.doesNotMatch(h.stdout+h.stderr,/retrying once|environment failure/);
 assert.equal(readFileSync(path.join(h.dir,'evidence.log'),'utf8'),output+'\n');
});
test('selected thrown error with a skipped XCTest sibling remains a completed test failure',()=>{
 const output=withSkippedXCTest(selected,true,1);
 const h=harness(quarantine,{env:{},run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.match(h.stdout,/Tests run: 5, Failures: 1, Errors: 0, Skipped: 1/);
 assert.equal(nativeCalls(h).length,1);assert.doesNotMatch(h.stdout,/retrying once/);
});
test('selected assertion and thrown error counts can share one failed XCTest case',()=>{
 const output=withThrownXCTest(selected).replaceAll('with 1 failure (1 unexpected)','with 2 failures (1 unexpected)');
 const h=harness(quarantine,{env:{},run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.match(h.stdout,/Tests run: 5, Failures: 1/);assert.equal(nativeCalls(h).length,1);
});
for(const [label,mutate,runOptions] of [
 ['unexpected exceeds total failures',s=>s.replaceAll('(1 unexpected)','(2 unexpected)'),{}],
 ['parent unexpected count mismatch',s=>s.replace(/(Test Suite 'Selected tests' failed[^\n]*\n\s*Executed [^\n]*\()1 unexpected/,'$10 unexpected'),{}],
 ['child unexpected count mismatch',s=>s.replace(/(Test Suite 'ProbeTests' failed[^\n]*\n\s*Executed [^\n]*\()1 unexpected/,'$10 unexpected'),{}],
 ['missing failed terminal',s=>s.replace(/^Test Case .*testKeep\]' failed.*\n/gm,''),{}],
 ['passed failed-case terminal',s=>s.replace("testKeep]' failed (","testKeep]' passed ("),{}],
 ['zero exit',s=>s,{status:0}],
 ['native signal',s=>s,{signal:'SIGTERM'}],
]) test(`selected thrown XCTest error ${label} still fails closed`,()=>{
 const h=harness(quarantine,{env:{},run:()=>({...result(mutate(withThrownXCTest(selected))),status:1,...runOptions})});
 assert.equal(h.status,70);assert.equal(nativeCalls(h).length,1);assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);
});
test('empty-list XCTest thrown failure retains the original environment-failure limit and invocation',()=>{
 const output=withThrownXCTest(selected).replaceAll("'Selected tests'","'All tests'");
 const h=harness([],{run:()=>({...result(output),status:1})});
 assert.equal(h.status,70);assert.equal(h.calls.length,1);
 assert.deepEqual(h.calls[0].args,['xcrun','xctest','.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);
 assert.ok(h.stdout.startsWith('app-lane quarantine none\n'));assert.doesNotMatch(h.stdout,/Tests run:/);
});

// Real inherited-lock jobs must preserve processes discovery did not start.
const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
for(const shape of ['pipeline','background']) for(const nativeExit of [0,3])
test(`inherited discovery preserves ${shape} sibling on native exit ${nativeExit}`,async()=>{
 const h=harness(),lane=path.join(h.dir,'lane.mjs'),shell=path.join(h.dir,'job.sh');
 const laneStatus=path.join(h.dir,'lane-status'),siblingState=path.join(h.dir,'sibling-state');
 const siblingPid=path.join(h.dir,'sibling-pid'),siblingSignal=path.join(h.dir,'sibling-signaled');
 const supervisors=path.join(h.dir,'supervisors'),nativePids=path.join(h.dir,'native-pids');
 writeFileSync(h.quarantinePath,JSON.stringify(quarantine));
 const nativePrefix=`require('node:fs').appendFileSync(${JSON.stringify(nativePids)},String(process.pid)+'\\n');`;
 writeFileSync(lane,`
import {spawnSync} from 'node:child_process';
import {writeFileSync} from 'node:fs';
import {runAppLane} from ${JSON.stringify(new URL('./app-lane.mjs',import.meta.url).href)};
let stage=0;
const status=runAppLane({env:process.env,quarantinePath:${JSON.stringify(h.quarantinePath)},evidencePath:${JSON.stringify(path.join(h.dir,'evidence.log'))},spawn:(cmd,args,opts)=>{
 if(cmd==='xcrun')return {status:0,stdout:'/platform\\n',stderr:''};
 if(args[0]===process.execPath){
  const prefix="require('node:fs').appendFileSync("+${JSON.stringify(JSON.stringify(supervisors))}+",String(process.pid)+'\\\\n');\\n";
  const native=++stage===1?${JSON.stringify(nativePrefix+`process.exit(${nativeExit});`)}:${JSON.stringify(nativePrefix+`process.stdout.write(${JSON.stringify(inventory)});`)};
  return spawnSync(cmd,[args[0],'-e',prefix+args[2],'500',process.execPath,'-e',native],opts);
 }
 return {status:0,stdout:${JSON.stringify(selected)},stderr:'',signal:null};
}});
writeFileSync(${JSON.stringify(laneStatus)},String(status));process.exitCode=status;
`);
 const sibling=path.join(h.dir,'sibling.cjs');
 writeFileSync(sibling,`process.on('SIGTERM',()=>{require('node:fs').writeFileSync(${JSON.stringify(siblingSignal)},'TERM');process.exit(19);});require('node:fs').writeFileSync(${JSON.stringify(siblingPid)},String(process.pid));setInterval(()=>{},1000);`);
 const node=shellQuote(process.execPath),quotedLane=shellQuote(lane);
 writeFileSync(shell,shape==='pipeline'
  ? `${node} ${quotedLane} | /bin/cat\nstatus=$?\nprintf '%s' "$status" > ${shellQuote(siblingState)}\nexit "$status"\n`
  : `${node} ${shellQuote(sibling)} >/dev/null 2>&1 &\nsibling=$!\nwhile [ ! -s ${shellQuote(siblingPid)} ]; do sleep 0.01; done\n${node} ${quotedLane}\nif kill -0 "$sibling" 2>/dev/null; then printf alive; else printf dead; fi > ${shellQuote(siblingState)}\nkill -KILL "$sibling" 2>/dev/null\nwait "$sibling" 2>/dev/null\nexit 0\n`);
 const env={...process.env,PICSEE_HEAVY_LOCK:path.join(h.dir,'heavy.lock'),PICSEE_MDPRO_LOCK:path.join(h.dir,'shared.lock'),PICSEE_HEAVY_LOCK_WAIT_SECS:'5'};
 delete env.PICSEE_HEAVY_LOCK_HELD;delete env.MDPRO_HEAVY_LOCK_HELD;delete env.NODE_TEST_CONTEXT;
 const lock=fileURLToPath(new URL('../heavy-lock.sh',import.meta.url));
 const runner=spawn(lock,['/bin/sh',shell],{env,detached:true,stdio:['ignore','pipe','pipe']});
 let stdout='',stderr='',capped=false;runner.stdout.on('data',s=>stdout+=s);runner.stderr.on('data',s=>stderr+=s);
 const owned=()=>[supervisors,nativePids,siblingPid].filter(existsSync).flatMap(p=>readFileSync(p,'utf8').trim().split(/\s+/).filter(Boolean).map(Number));
 const cleanup=()=>{for(const pid of [...owned(),runner.pid])for(const target of [-pid,pid])try{process.kill(target,'SIGKILL');}catch(error){if(error.code!=='ESRCH')throw error;}};
 const start=Date.now(),cap=setTimeout(()=>{capped=true;cleanup();},5000);
 try {
  const outcome=await new Promise((resolve,reject)=>{runner.once('error',reject);runner.once('close',(status,signal)=>resolve({status,signal}));});
  assert.equal(capped,false,stderr);assert.equal(outcome.status,0,stderr);assert.equal(outcome.signal,null);
  assert.equal(readFileSync(laneStatus,'utf8'),nativeExit===0?'0':'70',stderr);
  assert.equal(readFileSync(siblingState,'utf8'),shape==='pipeline'?'0':'alive','unrelated sibling must survive discovery');
  assert.equal(existsSync(siblingSignal),false,'discovery must not signal its background sibling');
  assert.ok(Date.now()-start<3500,'discovery must not wait for unrelated siblings');
  if(nativeExit===0)assert.match(stdout,/Tests run: 5, Failures: 0/);
 } finally {clearTimeout(cap);cleanup();runner.stdout.destroy();runner.stderr.destroy();}
});

// Startup metadata failures are environment results; the native command must
// never start after either a failed ps invocation or unusable process identity.
for(const fault of ['snapshot timeout','missing supervisor identity'])
test(`discovery startup ${fault} returns 70 before native launch`,()=>{
 const h=harness(quarantine),marker=path.join(h.dir,'native-started');
 const code=h.calls.find(c=>c.cmd.endsWith('heavy-lock.sh')&&c.args[0]===process.execPath).args[2];
 const setup=fault==='snapshot timeout'
  ? "require('node:child_process').spawnSync=()=>({status:null,error:Object.assign(new Error('forced ps timeout'),{code:'ETIMEDOUT'}),stdout:'',stderr:''});\n"
  : "require('node:child_process').spawnSync=()=>({status:0,stdout:'',stderr:''});\n";
 const native=`require('node:fs').writeFileSync(${JSON.stringify(marker)},'started');`;
 const run=spawnSync(process.execPath,['-e',setup+code,'1000',process.execPath,'-e',native],{
  encoding:'utf8',timeout:5000,detached:true,
 });
 assert.equal(run.status,70,run.stderr);assert.equal(run.signal,null);
 assert.match(run.stderr,/app-lane inventory.*cannot (inspect|identify) discovery process group/);
 assert.equal(existsSync(marker),false,'failed startup metadata must prevent native launch');
});

// #195: filter at the public lane boundary, with real parser and fake native processes.
const filteredRoot = `Test Suite 'Selected tests' started at now.
Test Suite 'Selected tests' passed at now.
 Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds
`;
const swiftOutput = names => filteredRoot + '◇ Test run started.\n' + names.map(name =>
 `◇ Test ${name}() started.\n✔ Test ${name}() passed after 0.001 seconds.\n`).join('') +
 `✔ Test run with ${names.length} tests in 0 suites passed after 0.001 seconds.\n`;
const oneSwift = swiftOutput(['swiftKeep']);
const twoSwift = swiftOutput(['swiftKeep','swiftSkipSibling']);
const filterOptions = (filter, output = oneSwift) => ({env:{PICSEE_APP_FILTER:filter,PICSEE_APP_LANE_NO_RETRY:'1'},run:()=>result(output)});

test('filter inherited from env runs one exact Swift identity and prints filter before counts',()=>{
 const h=harness([],filterOptions('swiftKeep'));
 assert.equal(h.status,0,h.stderr);
 assert.deepEqual(nativeCalls(h)[0].args,['xcrun','xctest','-XCTest','Probe.swiftKeep()','.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);
 assert.match(h.stdout,/app-lane filter=swiftKeep\nTests run: 1, Failures: 0, Errors: 0, Skipped: 0/);
});
test('positional filter overrides env without interpreting shell-like filter text',()=>{
 const h=harness([],{...filterOptions('swiftSkip'),argv:['swiftKeep']});
 assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/app-lane filter=swiftKeep\nTests run: 1/);
 assert.equal(nativeCalls(h)[0].args[3],'Probe.swiftKeep()');
 const literal=harness([],filterOptions('swiftKeep|\nabsent;$(false)'));
 assert.equal(literal.status,0,literal.stderr);
 assert.match(literal.stdout,/app-lane filter=swiftKeep\|\\nabsent;\$\(false\)\nTests run: 1/);
});
test('narrowing a filter rejects the formerly valid broader execution set',()=>{
 const broad=harness([],filterOptions('swiftKeep|swiftSkipSibling',twoSwift));
 assert.equal(broad.status,0,broad.stderr);assert.match(broad.stdout,/Tests run: 2, Failures: 0/);
 assert.equal(nativeCalls(broad)[0].args[3],'Probe.swiftKeep(),Probe.swiftSkipSibling()');
 const narrow=harness([],filterOptions('swiftKeep',twoSwift));
 assert.equal(narrow.status,70);assert.doesNotMatch(narrow.stdout,/Tests run:/);
 const exact=harness([],filterOptions('swiftKeep',oneSwift));assert.equal(exact.status,0,exact.stderr);
});
for (const [label,options] of [
 ['blank argument',{argv:[' ']}],['blank env',filterOptions(' ')],
 ['extra arguments',{argv:['swiftKeep','swiftSkip']}],['invalid regex',filterOptions('[')],
]) test(`filter ${label} is usage failure before processes`,()=>{
 const h=harness([],options);assert.equal(h.status,64);assert.equal(h.calls.length,0);
 assert.match(h.stderr,/filter|usage/);assert.doesNotMatch(h.stdout,/Tests run:/);
});
test('zero matching filter and fully quarantined match fail without running bundle',()=>{
 for(const [entries,filter] of [[[],'absentTest'],[quarantine,'swiftSkip$|swiftSkip\\(\\)$']]) {
  const h=harness(entries,filterOptions(filter));assert.equal(h.status,70);
  assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/no.*match|zero.*match/i);assert.doesNotMatch(h.stdout,/Tests run:/);
 }
});
test('filter intersects quarantine rather than reintroducing excluded tests',()=>{
 const h=harness(quarantine,filterOptions('swiftKeep|swiftSkip',twoSwift));
 assert.equal(h.status,0,h.stderr);assert.equal(nativeCalls(h)[0].args[3],'Probe.swiftKeep(),Probe.swiftSkipSibling()');
 assert.match(h.stdout,/quarantine skip=Probe.swiftSkip\(\) issue=#425/);assert.match(h.stdout,/Tests run: 2, Failures: 0/);
});
const oneXCTest = `Test Suite 'Selected tests' started at now.
Test Suite 'ProbeTests' started at now.
Test Case '-[Probe.ProbeTests testKeep]' started.
Test Case '-[Probe.ProbeTests testKeep]' passed (0.001 seconds).
Test Suite 'ProbeTests' passed at now.
 Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds
Test Suite 'Selected tests' passed at now.
 Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds
`;
test('XCTest-only filter accepts a completed zero Swift root and counts the XCTest',()=>{
 const h=harness([],filterOptions('ProbeTests/testKeep',oneXCTest+swiftOutput([]).slice(filteredRoot.length)));
 assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 1, Failures: 0/);
 assert.equal(nativeCalls(h)[0].args[3],'ProbeTests/testKeep');
});
test('mixed filter counts both selected frameworks',()=>{
 const h=harness([],filterOptions('ProbeTests/testKeep|swiftKeep',oneXCTest+oneSwift.slice(filteredRoot.length)));
 assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 2, Failures: 0/);
 assert.equal(nativeCalls(h)[0].args[3],'ProbeTests/testKeep,Probe.swiftKeep()');
});
for(const [label,run] of [
 ['zero execution',result(swiftOutput([]))],
 ['missing terminal',result(oneSwift.replace('✔ Test swiftKeep() passed after 0.001 seconds.\n',''))],
 ['missing XCTest root',result(oneSwift.replace("Test Suite 'Selected tests' passed at now.\n",''))],
 ['missing Swift root',result(oneSwift.replace('✔ Test run with 1 tests in 0 suites passed after 0.001 seconds.\n',''))],
 ['signal',{...result(oneSwift),status:null,signal:'SIGTERM'}],
 ['status mismatch',{...result(oneSwift),status:1}],
 ['unselected identity',result(swiftOutput(['swiftSkip']))],
]) test(`filtered ${label} returns 70 without counts`,()=>{
 const h=harness([],{...filterOptions('swiftKeep'),run:()=>run});
 assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);assert.equal(nativeCalls(h).length,1);
});
test('filtered assertion RED returns one failure and preserves the native output',()=>{
 const failing=oneSwift.replace('✔ Test swiftKeep() passed after 0.001 seconds.',
  '✘ Test swiftKeep() recorded an issue at Probe.swift:1:1: Expectation failed\n✘ Test swiftKeep() failed after 0.001 seconds with 1 issue.')
  .replace('✔ Test run with 1 tests in 0 suites passed after 0.001 seconds.','✘ Test run with 1 tests in 0 suites failed after 0.001 seconds with 1 issue.');
 const h=harness([],{...filterOptions('swiftKeep'),run:()=>({...result(failing),status:1})});
 assert.equal(h.status,1,h.stderr);assert.match(h.stdout,/app-lane filter=swiftKeep\nTests run: 1, Failures: 1, Errors: 0, Skipped: 0/);
 assert.equal(nativeCalls(h).length,1);assert.equal(readFileSync(path.join(h.dir,'evidence.log'),'utf8'),failing+'\n');
});
test('absent filter keeps full bundle output without filter diagnostics',()=>{
 const h=harness();assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 3, Failures: 0/);
 assert.doesNotMatch(h.stdout,/app-lane filter=/);assert.deepEqual(nativeCalls(h)[0].args,['xcrun','xctest','.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);
});
test('CLI forwards positional arguments and inherited filter into validation',()=>{
 const dir=mkdtempSync(path.join(tmpdir(),'i195-cli-'));temporaryDirectories.add(dir);
 writeFileSync(path.join(dir,'xcrun'),'#!/bin/sh\nexit 0\n',{mode:0o755});
 for(const [argv,env] of [[[' '],{}],[['keep','extra'],{}],[[],{PICSEE_APP_FILTER:' '}]]) {
  const run=spawnSync(process.execPath,[fileURLToPath(new URL('./app-lane.mjs',import.meta.url)),...argv],{
   encoding:'utf8',env:{...process.env,PATH:dir+path.delimiter+process.env.PATH,PICSEE_APP_FILTER:undefined,...env},timeout:10000,
  });
  assert.equal(run.status,64,run.stderr);assert.match(run.stderr,/filter|usage/);assert.doesNotMatch(run.stdout,/Tests run:/);
 }
});

for (const started of [true, false]) {
 test(`filtered Swift all-skipped selection with start=${started} fails closed`,()=>{
  const skipped=oneSwift.replace('✔ Test swiftKeep() passed after 0.001 seconds.', '➜ Test swiftKeep() skipped: disabled');
  const output=started ? skipped : skipped.replace('◇ Test swiftKeep() started.\n','');
  const h=harness([],filterOptions('swiftKeep',output));
  assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);assert.equal(nativeCalls(h).length,1);
 });
 test(`filtered XCTest all-skipped selection with start=${started} fails closed`,()=>{
  const skipped=oneXCTest.replace("passed (0.001 seconds).", "skipped (0.001 seconds).")
   .replaceAll('with 0 failures', 'with 1 test skipped and 0 failures');
  const output=(started ? skipped : skipped.replace("Test Case '-[Probe.ProbeTests testKeep]' started.\n",''))+swiftOutput([]).slice(filteredRoot.length);
  const h=harness([],filterOptions('ProbeTests/testKeep',output));
  assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);assert.equal(nativeCalls(h).length,1);
 });
}
test('filtered mixed pass and skip cannot hide a skipped selection',()=>{
 for(const [filter,output] of [
  ['swiftKeep|swiftSkipSibling',twoSwift.replace('✔ Test swiftKeep() passed after 0.001 seconds.','➜ Test swiftKeep() skipped: disabled')],
  ['ProbeTests/testKeep|swiftKeep',oneXCTest.replace('passed (0.001 seconds).','skipped (0.001 seconds).').replaceAll('with 0 failures','with 1 test skipped and 0 failures')+oneSwift.slice(filteredRoot.length)],
 ]) {
  const h=harness([],filterOptions(filter,output));
  assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);
 }
});
test('filtered XCTest-only missing case fails closed despite completed zero Swift root',()=>{
 const h=harness([],filterOptions('ProbeTests/testKeep',swiftOutput([])));
 assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);
});
test('filtered XCTest-only failing case returns assertion failure with counts',()=>{
 const output=oneXCTest.replace('passed (0.001 seconds).','failed (0.001 seconds).')
  .replaceAll('passed at now.','failed at now.').replaceAll('with 0 failures','with 1 failure')+swiftOutput([]).slice(filteredRoot.length);
 const h=harness([],{...filterOptions('ProbeTests/testKeep'),run:()=>({...result(output),status:1})});
 assert.equal(h.status,1,h.stderr);assert.match(h.stdout,/Tests run: 1, Failures: 1, Errors: 0, Skipped: 0/);
 assert.doesNotMatch(h.stdout,/retrying once/);assert.equal(nativeCalls(h).length,1);
});
test('inherited filter warns on stderr with full-run unset guidance only when used',()=>{
 const inherited=harness([],filterOptions('swiftKeep'));
 assert.equal(inherited.status,0);assert.match(inherited.stderr,/PICSEE_APP_FILTER.*unset PICSEE_APP_FILTER/);
 for(const h of [harness(),harness([],{...filterOptions('swiftSkip'),argv:['swiftKeep']})]) {
  assert.equal(h.status,0,h.stderr);assert.doesNotMatch(h.stderr,/PICSEE_APP_FILTER/);
 }
});

test('filtered failure plus selected skip is environment failure without counts',()=>{
 const failedSwift=oneSwift.replace('✔ Test swiftKeep() passed after 0.001 seconds.',
  '✘ Test swiftKeep() recorded an issue at Probe.swift:1:1: Expectation failed\n✘ Test swiftKeep() failed after 0.001 seconds with 1 issue.')
  .replace('✔ Test run with 1 tests in 0 suites passed after 0.001 seconds.','✘ Test run with 1 tests in 0 suites failed after 0.001 seconds with 1 issue.');
 const swiftSkip=failedSwift.replace('✘ Test run with 1 tests', '➜ Test swiftSkipSibling() skipped: disabled\n✘ Test run with 2 tests');
 const xctSkip=oneXCTest.replace('passed (0.001 seconds).','skipped (0.001 seconds).').replaceAll('with 0 failures','with 1 test skipped and 0 failures')+failedSwift.slice(filteredRoot.length);
 for(const [filter,output] of [['swiftKeep|swiftSkipSibling',swiftSkip],['ProbeTests/testKeep|swiftKeep',xctSkip]]) {
  const h=harness([],{...filterOptions(filter),run:()=>({...result(output),status:1})});
  assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:|retrying once/);
 }
});


// #587 WI-1: validation uses the real quarantine file and rejects before discovery.
function i587Rejected(entries, diagnostic) {
 const h=harness(entries);
 assert.equal(h.status,70,h.stderr);
 assert.match(h.stderr,diagnostic);
 assert.equal(h.calls.length,0);
 assert.doesNotMatch(h.stdout,/quarantine skip=|Tests run:/);
 return h;
}
for(const owner of [undefined,null,7,'','  ']) test(`i587 quarantine rejects owner ${JSON.stringify(owner)}`,()=>{
 const entry={...quarantine[0],owner};
 if(owner===undefined)delete entry.owner;
 i587Rejected([entry,quarantine[1]],/quarantine.*owner.*nonblank/i);
});
for(const expires of [undefined,null,7,'','2026-1-01','2099-02-30','2099-02-29','2099-13-01','2099-01-00','2099-01-01T00:00:00Z']) test(`i587 quarantine rejects invalid calendar expiry ${JSON.stringify(expires)}`,()=>{
 const entry={...quarantine[0],expires};
 if(expires===undefined)delete entry.expires;
 const h=i587Rejected([entry,quarantine[1]],/quarantine.*expires.*ISO.*date/i);
 assert.doesNotMatch(h.stderr,/expired/i);
});
test('i587 valid future leap day is accepted',()=>{
 const h=harness(quarantine.map(entry=>({...entry,expires:'2096-02-29'})));
 assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 5, Failures: 0/);
 assert.match(h.stdout,/quarantine skip=ProbeTests\/testSkip issue=#411/);
});
test('i587 expired metadata rejects atomically in either order',()=>{
 for(const patch of [{owner:undefined},{expires:'2000-01-01'}]) {
  const invalid={...quarantine[0],...patch};
  for(const entries of [[invalid,quarantine[1]],[quarantine[1],invalid]]) {
   i587Rejected(entries,patch.expires?/quarantine.*expired.*2000-01-01/i:/quarantine.*owner/i);
  }
 }
});
for(const issue of [0,-1,1.5,Number.MAX_SAFE_INTEGER+1,'454','TBD-12345','TBD-','TBD-0','TBD-xyz','anything',[],null]) test(`i587 quarantine rejects issue reference ${JSON.stringify(issue)}`,()=>{
 i587Rejected([{...quarantine[0],issue},quarantine[1]],/quarantine.*issue/i);
});
for(const issue of [411]) test(`i587 quarantine accepts tracking reference ${issue}`,()=>{
 const h=harness([{...quarantine[0],issue},quarantine[1]]);
 assert.equal(h.status,0,h.stderr);
 assert.ok(h.stdout.includes(`quarantine skip=ProbeTests/testSkip issue=#${issue}\n`));
 assert.match(h.stdout,/Tests run: 5, Failures: 0/);
});

// Run the same frozen-clock cases in real processes whose local days differ.
// No App process is launched: only the existing native-boundary fixture is used.
if(process.env.I587_TZ_PROBE==='1') test('i587 UTC expiry probe',(t)=>{
 t.mock.timers.enable({apis:['Date'],now:Date.parse('2026-11-08T00:01:00Z')});
 for(const instant of ['2026-11-08T00:01:00Z','2026-11-08T23:59:00Z']) {
  t.mock.timers.setTime(Date.parse(instant));
  const statuses=[];
  for(const expires of ['2026-11-07','2026-11-08','2026-11-09']) {
   const h=harness(quarantine.map(entry=>({...entry,expires})));
   statuses.push(h.status);
   if(expires==='2026-11-07') {
    assert.match(h.stderr,/expired.*2026-11-07/);assert.equal(h.calls.length,0);
    assert.doesNotMatch(h.stdout,/quarantine skip=|Tests run:/);
   } else {
    assert.match(h.stdout,/quarantine skip=ProbeTests\/testSkip issue=#411/);
    assert.match(h.stdout,/Tests run: 5, Failures: 0/);
   }
  }
  assert.deepEqual(statuses,[70,0,0],`${process.env.TZ} at ${instant}`);
 }
 t.mock.timers.setTime(Date.parse('2026-11-09T00:00:00Z'));
 i587Rejected(quarantine.map(entry=>({...entry,expires:'2026-11-08'})),/expired.*2026-11-08/);
});
test('i587 UTC expiry is independent of the process timezone',()=>{
 // This synchronous test starts a fresh runner, not an inherited test worker.
 // Keep the original recorded assertions; normalize only runner transport.
 const outerContext=process.env.NODE_TEST_CONTEXT;
 delete process.env.NODE_TEST_CONTEXT;
 try {
 for(const TZ of ['Pacific/Kiritimati','Etc/GMT+12']) {
  const r=spawnSync(process.execPath,['--test','--test-name-pattern','^i587 UTC expiry probe$',fileURLToPath(import.meta.url)],{
   encoding:'utf8',timeout:30000,env:{...process.env,TZ,I587_TZ_PROBE:'1'},
  });
  assert.equal(r.status,0,`${TZ}\n${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout,/i587 UTC expiry probe/);
 }
 } finally {
  if(outerContext===undefined)delete process.env.NODE_TEST_CONTEXT;
  else process.env.NODE_TEST_CONTEXT=outerContext;
 }
});


// #587 WI-3: clean runs expose the configured exceptions, without retrying.
for(const [label,entries,options] of [
 ['full empty quarantine',[],{}],['full populated quarantine',quarantine,{}],
 ['selected empty quarantine',[],filterOptions('swiftKeep')],
 ['selected populated quarantine',quarantine,filterOptions('swiftKeep')],
]) test(`i587 every-run exception roster: ${label}`,()=>{
 const h=harness(entries,options);
 assert.equal(h.status,0,h.stderr);assert.equal(nativeCalls(h).length,1);
 assert.doesNotMatch(h.stdout,/retrying once/);
 const lines=h.stdout.split('\n');
 assert.deepEqual(lines.filter(line=>line.startsWith('app-lane known-flaky test=')).sort(),
  knownFlaky.map(entry=>`app-lane known-flaky test=${entry.name} issue=#${entry.issue}`).sort());
 assert.deepEqual(lines.filter(line=>line.startsWith('app-lane quarantine skip=')).sort(),
  entries.map(entry=>`app-lane quarantine skip=${entry.id} issue=#${entry.issue}`).sort());
 assert.deepEqual(lines.filter(line=>line.startsWith('app-lane quarantine owner=')).sort(),
  entries.map(entry=>`app-lane quarantine owner=${entry.owner} expires=${entry.expires} id=${entry.id}`).sort());
});
test('i587 invalid quarantine cannot print a partly validated exception roster',()=>{
 const h=i587Rejected([quarantine[0],{...quarantine[1],owner:''}],/owner/);
 assert.equal(h.stdout,'');
});


// #587 fix2 M1 explicitly restores the positive-safe-integer issue contract.
test('i587 integer issue schema rejects invalid entries atomically in either order',()=>{
 for(const issue of ['TBD-12345','411',Number.MAX_SAFE_INTEGER+1]) {
  const invalid={...quarantine[0],issue};
  for(const entries of [[invalid,quarantine[1]],[quarantine[1],invalid]]) {
   const h=i587Rejected(entries,/quarantine.*issue/i);
   assert.equal(h.stdout,'');
  }
 }
});

// #393: the hosted result must prove every selected identity completed exactly once.
const { parseHostedResult } = await import('./hosted-app-lane.mjs');
const hostedExpected = ['hostProof()', 'pan(tabCount:)'];
function hostedFixture() {
 return {
  run: {status:0,signal:null,stdout:'** TEST EXECUTE SUCCEEDED **\n',stderr:''},
  summary: {totalTestCount:2,passedTests:2,failedTests:0,skippedTests:0,testFailures:[],result:'Passed'},
  tree: {testNodes:[{nodeType:'Test Plan',children:[
   {nodeType:'Test Case',nodeIdentifier:'hostProof()',result:'Passed'},
   {nodeType:'Test Case',nodeIdentifier:'pan(tabCount:)',result:'Passed'}]}]},
 };
}
test('hosted successful results require the selected identities and complete artifact totals',()=>{
 const f=hostedFixture();const r=parseHostedResult(f.run,f.summary,f.tree,hostedExpected);
 assert.equal(r.status,0);assert.equal(r.reliable,true);assert.equal(r.count,2);assert.equal(r.failed,0);
});
test('hosted assertion failure remains a completed failure with names',()=>{
 const f=hostedFixture();f.run.status=65;f.run.stdout='** TEST EXECUTE FAILED **\n';
 f.summary.passedTests=1;f.summary.failedTests=1;f.summary.result='Failed';
 f.summary.testFailures=[{testName:'pan(tabCount:)'}];f.tree.testNodes[0].children[1].result='Failed';
 const r=parseHostedResult(f.run,f.summary,f.tree,hostedExpected);
 assert.equal(r.status,1);assert.equal(r.reliable,true);assert.equal(r.failed,1);assert.deepEqual(r.failureNames,['pan(tabCount:)']);
});
for (const [name,corrupt] of [
 ['missing summary',f=>f.summary=null], ['missing tree',f=>f.tree=null],
 ['missing test',f=>f.tree.testNodes[0].children.pop()],
 ['duplicate test',f=>f.tree.testNodes[0].children.push(f.tree.testNodes[0].children[0])],
 ['wrong identity',f=>f.tree.testNodes[0].children[0].nodeIdentifier='unrelated()'],
 ['zero tests',f=>{f.summary.totalTestCount=0;f.summary.passedTests=0;f.tree.testNodes=[];}],
 ['skipped only',f=>{f.summary.passedTests=0;f.summary.skippedTests=2;f.tree.testNodes[0].children.forEach(n=>n.result='Skipped');}],
 ['cancelled',f=>{f.run.status=null;f.run.signal='SIGTERM';}],
 ['crash',f=>{f.run.status=65;f.run.stderr='error: Process exited with signal 11';}],
 ['spawn error',f=>f.run.error=new Error('test launch unavailable')],
 ['contradictory exit',f=>f.run.status=65],
 ['contradictory total',f=>f.summary.totalTestCount=3],
 ['missing completion',f=>f.run.stdout='partial output'],
]) test(`hosted corrupt ${name} never authorizes completed counts`,()=>{
 const f=hostedFixture();corrupt(f);const r=parseHostedResult(f.run,f.summary,f.tree,hostedExpected);
 assert.equal(r.status,70);assert.equal(r.reliable,false);assert.equal(r.count,0);
});

const { runCompleteAppLane } = await import('./app-lane.mjs');
const { hostedTestNames } = await import('./hosted-app-lane.mjs');
function combinedHarness({filter,unhostedStatus=0,hostedStatus=0,missingResult=false}={}) {
 const dir=mkdtempSync(path.join(tmpdir(),'i393-combined-'));temporaryDirectories.add(dir);
 const quarantinePath=path.join(dir,'quarantine.json');writeFileSync(quarantinePath,'[]');
 let stdout='',stderr='';const mechanisms=[];
 const names=filter ? hostedTestNames.filter(n=>new RegExp(filter).test('MadoHostedFocusTests.'+n)) : hostedTestNames;
 const spawn=(cmd,args,opts)=>{
  if(cmd==='xcrun'&&args[0]==='--show-sdk-platform-path') return result('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform\n');
  if(args.includes('swiftc')) return result('');
  if(args.includes('xctest')) {mechanisms.push('unhosted');return {...result(baseline),status:unhostedStatus};}
  if(args.includes('xcodebuild')) {mechanisms.push('hosted');return {status:hostedStatus,stdout:hostedStatus===0?'** TEST EXECUTE SUCCEEDED **\n':'** TEST EXECUTE FAILED **\n'};}
  if(args.includes('xcresulttool')) {
   if(missingResult) return {status:1,stdout:''};
   if(args.includes('summary')) return result(JSON.stringify(i393ProtocolSubset(names,hostedStatus!==0).summary));
   return result(JSON.stringify(i393ProtocolSubset(names,hostedStatus!==0).tree));
  }
  return result(inventory);
 };
 const destination=path.join(dir,'result.json');
 const env={PICSEE_APP_LANE_NO_RETRY:'1',PICSEE_APP_RESULT_PATH:destination,PICSEE_APP_RESULT_ID:'current',...(filter?{PICSEE_APP_FILTER:filter}:{})};
 const status=runCompleteAppLane({spawn,env,quarantinePath,evidencePath:path.join(dir,'attempt.log'),stdout:s=>stdout+=s,stderr:s=>stderr+=s});
 return {status,stdout,stderr,mechanisms,record:existsSync(destination)?JSON.parse(readFileSync(destination)):null};
}
test('complete App lane conserves both groups and only succeeds when both complete',()=>{
 const h=combinedHarness();assert.equal(h.status,0,h.stderr);assert.deepEqual(h.mechanisms,['unhosted','hosted']);
 assert.match(h.stdout,/Tests run: 10, Failures: 0/);assert.equal(h.record.complete,true);assert.equal(h.record.status,0);
});
test('focused filter runs hosted bodies exactly once without requiring retained tests',()=>{
 const h=combinedHarness({filter:'issue521'});assert.equal(h.status,0,h.stderr);assert.deepEqual(h.mechanisms,['hosted']);
 assert.match(h.stdout,/Tests run: 1, Failures: 0/);
});
test('retained-only filter does not run hosted bodies',()=>{
 const h=combinedHarness({filter:'Probe'});assert.equal(h.status,0,h.stderr);assert.match(h.stdout,/Tests run: 7, Failures: 0/);assert.deepEqual(h.mechanisms,['unhosted']);
});
for(const options of [{unhostedStatus:1},{hostedStatus:65},{missingResult:true},{filter:'doesNotExist'}])
 test('complete App lane refuses an unsuccessful or absent required group '+JSON.stringify(options),()=>{
  const h=combinedHarness(options);assert.notEqual(h.status,0);assert.equal(h.record.status,h.status);assert.equal(h.record.complete,true);
 });

function hostedParameterizedFixture() {
 const name='issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:)';
 return {name,run:{status:0,stdout:'** TEST EXECUTE SUCCEEDED **\n'},
  summary:{totalTestCount:1,passedTests:1,failedTests:0,skippedTests:0,devicesAndConfigurations:[{passedTests:3,failedTests:0,skippedTests:0}]},
  tree:{testNodes:[{nodeType:'Test Case',nodeIdentifier:name,result:'Passed',children:[0,1,2].map(n=>({nodeType:'Arguments',name:String(n),result:'Passed'}))}]}};
}
test('hosted parameterized cases preserve all three distinct drag inputs',()=>{
 const f=hostedParameterizedFixture();const r=parseHostedResult(f.run,f.summary,f.tree,[f.name]);
 assert.equal(r.status,0);assert.equal(r.count,1);assert.equal(r.caseCount,3);
});
for(const [name,corrupt] of [
 ['missing argument with consistent totals',f=>{f.tree.testNodes[0].children.pop();f.summary.devicesAndConfigurations[0].passedTests=2;}],
 ['duplicate argument',f=>f.tree.testNodes[0].children[2].name=f.tree.testNodes[0].children[1].name],
 ['parent contradiction',f=>f.tree.testNodes[0].result='Failed'],
]) test(`hosted parameterized ${name} fails closed`,()=>{
 const f=hostedParameterizedFixture();corrupt(f);const r=parseHostedResult(f.run,f.summary,f.tree,[f.name]);
 assert.equal(r.status,70);assert.equal(r.reliable,false);
});

const { runHostedAppLane } = await import('./hosted-app-lane.mjs');
test('hosted local derived-data override selects the available outside-Documents build',()=>{
 const directory=mkdtempSync(path.join(tmpdir(),'i393-dd-'));temporaryDirectories.add(directory);
 const available=path.join(directory,'dd');const selected=['hostProof()'];let launched=false;
 const spawn=(command,args)=>{
  if(args.includes('xcodebuild')) {
   launched=args[args.indexOf('-derivedDataPath')+1]===available;
   return {status:launched?0:65,stdout:launched?'** TEST EXECUTE SUCCEEDED **\n':'build not available at selected derived-data path'};
  }
  return result(JSON.stringify(args.includes('summary')
   ? {totalTestCount:1,passedTests:1,failedTests:0,skippedTests:0}
   : {testNodes:[{nodeType:'Test Case',nodeIdentifier:'hostProof()',result:'Passed'}]}));
 };
 let stdout='',stderr='';
 const r=runHostedAppLane({spawn,selected,env:{PICSEE_APP_DERIVED_DATA_PATH:available},stdout:s=>stdout+=s,stderr:s=>stderr+=s,evidencePath:path.join(directory,'attempt.log')});
 assert.equal(r.status,0,stderr);assert.equal(r.count,1);assert.equal(launched,true);
 assert.match(stdout,/hosted-app-lane Tests run: 1, Failures: 0/);
});

test('hosted attempt persists native process outcome even when result parsing fails',()=>{
 const directory=mkdtempSync(path.join(tmpdir(),'i393-process-'));temporaryDirectories.add(directory);
 const r=runHostedAppLane({env:{},selected:['hostProof()'],evidencePath:path.join(directory,'attempt.log'),stdout:()=>{},stderr:()=>{},
  spawn:(_command,args)=>args.includes('xcodebuild')?{status:0,signal:null,stdout:'** TEST EXECUTE SUCCEEDED **\n'}:{status:1,stdout:''}});
 assert.equal(r.status,70);assert.equal(r.reliable,false);
 const metadata=path.join(path.dirname(r.resultPath),'process.json');
 assert.equal(existsSync(metadata),true,'native process outcome must survive an unrecognized or missing result artifact');
 const record=JSON.parse(readFileSync(metadata,'utf8'));
 assert.equal(record.status,0);assert.equal(record.signal,null);assert.deepEqual(record.selected,['hostProof()']);
 assert.equal(record.derivedDataPath,'.build/dd-ci');assert.equal(record.resultPath,r.resultPath);
});

test('combined App lane emits one unambiguous generic completion summary',()=>{
 const h=combinedHarness();assert.equal(h.status,0,h.stderr);
 assert.equal((h.stdout.match(/Tests run: \d+, Failures:/g)??[]).length,1);
 assert.match(h.stdout,/Tests run: 10, Failures: 0/);
});

const i393ActualProcess=JSON.parse(readFileSync(new URL('./fixtures/i393-hosted/process.json',import.meta.url),'utf8'));
const i393ActualSummary=JSON.parse(readFileSync(new URL('./fixtures/i393-hosted/summary.json',import.meta.url),'utf8'));
const i393ActualTests=JSON.parse(readFileSync(new URL('./fixtures/i393-hosted/tests.json',import.meta.url),'utf8'));
function i393ActualFixture() {
 return {run:{...structuredClone(i393ActualProcess),stdout:'** TEST EXECUTE SUCCEEDED **\n',stderr:''},
  summary:structuredClone(i393ActualSummary),tree:structuredClone(i393ActualTests)};
}
function i393ActualCases(f) {return f.tree.testNodes[0].children[0].children;}
test('actual CI hosted artifact reports seven functions and twelve distinct executions',()=>{
 const f=i393ActualFixture();const r=parseHostedResult(f.run,f.summary,f.tree,i393ActualProcess.selected);
 assert.equal(r.status,0);assert.equal(r.reliable,true);assert.equal(r.count,7);assert.equal(r.caseCount,12);
 assert.equal(r.failed,0);assert.equal(r.caseFailed,0);
});
for(const [name,corrupt] of [
 ['missing drag argument',f=>{i393ActualCases(f)[1].children.pop();f.summary.devicesAndConfigurations[0].passedTests=11;}],
 ['all drag arguments missing',f=>{delete i393ActualCases(f)[1].children;f.summary.devicesAndConfigurations[0].passedTests=10;}],
 ['duplicate drag argument',f=>i393ActualCases(f)[1].children[2].name='1'],
 ['foreign drag argument',f=>i393ActualCases(f)[1].children[2].name='3'],
 ['foreign non-canvas argument',f=>i393ActualCases(f)[2].children[0].name='"foreign"'],
 ['parameter parent contradicts passing children',f=>i393ActualCases(f)[1].result='Failed'],
 ['device totals contradict executions',f=>f.summary.devicesAndConfigurations[0].passedTests=11],
 ['function totals contradict test identities',f=>{f.summary.totalTestCount=12;f.summary.passedTests=12;}],
 ['duplicate configuration',f=>f.summary.devicesAndConfigurations.push(structuredClone(f.summary.devicesAndConfigurations[0]))],
 ['plan result contradicts descendants',f=>f.tree.testNodes[0].result='Failed'],
 ['summary result contradicts descendants',f=>f.summary.result='Failed'],
]) test(`actual hosted evidence corruption ${name} fails closed`,()=>{
 const f=i393ActualFixture();corrupt(f);const r=parseHostedResult(f.run,f.summary,f.tree,i393ActualProcess.selected);
 assert.equal(r.status,70);assert.equal(r.reliable,false);assert.equal(r.count,0);
});
test('actual hosted parameter failure preserves function and execution counts separately',()=>{
 const f=i393ActualFixture();f.run.status=65;f.run.stdout='** TEST EXECUTE FAILED **\n';
 const drag=i393ActualCases(f)[1];drag.result='Failed';drag.children[1].result='Failed';
 f.tree.testNodes[0].result='Failed';f.tree.testNodes[0].children[0].result='Failed';
 f.summary.result='Failed';f.summary.passedTests=6;f.summary.failedTests=1;
 f.summary.devicesAndConfigurations[0].passedTests=11;f.summary.devicesAndConfigurations[0].failedTests=1;
 f.summary.testFailures=[{testName:drag.name,targetName:'MadoHostedFocusTests',failureText:'assertion failed'}];
 const r=parseHostedResult(f.run,f.summary,f.tree,i393ActualProcess.selected);
 assert.equal(r.status,1);assert.equal(r.count,7);assert.equal(r.caseCount,12);assert.equal(r.failed,1);assert.equal(r.caseFailed,1);
 assert.deepEqual(r.failureNames,[drag.name]);
});

// User approved real-format fixture correction (Report-Task i393-20261110-e).
// Subsets preserve xcresult's function/argument levels independently of parser code.
function i393ProtocolSubset(names,failed) {
 const tree=JSON.parse(readFileSync(new URL('./fixtures/i393-hosted/tests.json',import.meta.url),'utf8'));
 const summary=JSON.parse(readFileSync(new URL('./fixtures/i393-hosted/summary.json',import.meta.url),'utf8'));
 const rows=tree.testNodes[0].children[0].children.filter(row=>names.includes(row.nodeIdentifier));
 let cases=0,failedCases=0;
 for(const row of rows) {
  const isFailed=failed&&row.nodeIdentifier===names[0];row.result=isFailed?'Failed':'Passed';
  if(row.children) for(const child of row.children) {child.result=row.result;cases++;if(isFailed)failedCases++;}
  else {cases++;if(isFailed)failedCases++;}
 }
 tree.testNodes[0].children[0].children=rows;
 tree.testNodes[0].result=tree.testNodes[0].children[0].result=failed?'Failed':'Passed';
 summary.totalTestCount=names.length;summary.failedTests=failed?1:0;summary.passedTests=names.length-summary.failedTests;
 summary.result=failed?'Failed':'Passed';
 summary.devicesAndConfigurations[0].failedTests=failedCases;summary.devicesAndConfigurations[0].passedTests=cases-failedCases;
 summary.testFailures=failed?[{testName:names[0],targetName:'MadoHostedFocusTests',failureText:'assertion failed'}]:[];
 const parameters=rows.filter(row=>row.children?.length);
 summary.statistics=parameters.length?[{title:`${parameters.length} tests ran with dynamic parameters`,subtitle:`${parameters.reduce((sum,row)=>sum+row.children.length,0)} test runs`}]:[];
 return {summary,tree};
}

test('actual hosted null device record returns an unreliable result without throwing',()=>{
 const f=i393ActualFixture();f.summary.devicesAndConfigurations=[null];let r;
 assert.doesNotThrow(()=>{r=parseHostedResult(f.run,f.summary,f.tree,i393ActualProcess.selected);});
 assert.equal(r.status,70);assert.equal(r.reliable,false);assert.equal(r.count,0);
});
for (const [label, contents, diagnostic] of [
 ['invalid JSON', '{', /JSON|Expected/],
 ['non-array JSON', 'null', /quarantine must be an array/],
 ['invalid entry', '[{"id":"bad"}]', /quarantine id/],
]) test('combined lane rejects '+label+' quarantine before filtered native discovery',()=>{
 const dir=mkdtempSync(path.join(tmpdir(),'i393-quarantine-order-'));temporaryDirectories.add(dir);
 const quarantinePath=path.join(dir,'quarantine.json'),destination=path.join(dir,'result.json');
 writeFileSync(quarantinePath,contents);
 writeFileSync(destination,JSON.stringify({version:1,runId:'stale',complete:true,status:0}));
 let nativeCalls=0,stdout='',stderr='';
 const status=runCompleteAppLane({quarantinePath,
  env:{PICSEE_APP_FILTER:'issue521',PICSEE_APP_RESULT_PATH:destination,PICSEE_APP_RESULT_ID:'current'},
  spawn:()=>{nativeCalls++;return result('');},stdout:s=>stdout+=s,stderr:s=>stderr+=s});
 assert.equal(status,70);assert.equal(nativeCalls,0);
 assert.match(stderr,diagnostic);assert.doesNotMatch(stdout,/Tests run:/);
 const record=JSON.parse(readFileSync(destination,'utf8'));
 assert.equal(record.runId,'current');assert.equal(record.status,70);assert.equal(record.attempts,0);
 assert.equal(record.complete,true);assert.deepEqual(record.groups,{});
});
