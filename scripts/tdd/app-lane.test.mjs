import test from 'node:test';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { runAppLane, parseAppResult } from './app-lane.mjs';

const baseline = readFileSync(new URL('./fixtures/i411-baseline.txt', import.meta.url), 'utf8');
const selected = readFileSync(new URL('./fixtures/i411-selected.txt', import.meta.url), 'utf8');
const ids = ['OtherProbeTests/testSkip', 'ProbeTests/testKeep', 'ProbeTests/testSkip', 'ProbeTests/testSkipSibling', 'Probe.swiftKeep()', 'Probe.swiftSkip()', 'Probe.swiftSkipSibling()'];
const inventory = 'APP_LANE_INVENTORY_BEGIN\n' + ids.map(id => id.includes('(') ? id : `XCT_ID=-[${id.replace('/', ' ')}]`).join('\n') + '\nAPP_LANE_INVENTORY_END\n';
const quarantine = [{id:'ProbeTests/testSkip',issue:411,reason:'test failure'}, {id:'Probe.swiftSkip()',issue:425,reason:'test failure'}];
const result = stdout => ({status:0,stdout,stderr:'',signal:null});
function harness(entries = [], options = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'i411-node-'));
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
 assert.deepEqual(h.calls[0].args,['xcrun','xctest','.build/dd-ci/Build/Products/Debug/PicseeAppTests.xctest']);
 assert.deepEqual(h.calls[0].opts.env,{EXAMPLE:'kept',PICSEE_APP_LANE_NO_RETRY:'1',SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:'1'});
 assert.ok(h.stdout.startsWith('app-lane quarantine none\n'));assert.match(h.stdout,/Tests run: 3, Failures: 0/);
});
test('default parser and empty lane reject recorded Selected tests even with complete counts',()=>{
 assert.equal(parseAppResult(result(baseline)).status,0);assert.equal(parseAppResult(result(selected)).status,70);
 const h=harness([],{run:()=>result(selected)});assert.equal(h.status,70);assert.doesNotMatch(h.stdout,/Tests run:/);
});
test('two entries select inventory minus both exact IDs; combined selected count includes both frameworks',()=>{
 const h=harness(quarantine);assert.equal(h.status,0,h.stderr);
 const native=nativeCalls(h);assert.equal(native.length,1);assert.deepEqual(native[0].args,['xcrun','xctest','-XCTest','OtherProbeTests/testSkip,ProbeTests/testKeep,ProbeTests/testSkipSibling,Probe.swiftKeep(),Probe.swiftSkipSibling()','.build/dd-ci/Build/Products/Debug/PicseeAppTests.xctest']);
 assert.ok(h.stdout.startsWith('app-lane quarantine skip=ProbeTests/testSkip issue=#411\napp-lane quarantine skip=Probe.swiftSkip() issue=#425\n'));
 assert.match(h.stdout,/Tests run: 5, Failures: 0/);
});
for(const [label,entries] of [
 ['missing issue',[{id:'Probe.swiftSkip()',reason:'failure'}]],['invalid issue',[{id:'Probe.swiftSkip()',issue:0,reason:'failure'}]],
 ['missing reason',[{id:'Probe.swiftSkip()',issue:411}]],['blank reason',[{id:'Probe.swiftSkip()',issue:411,reason:'  '}]],
 ['malformed JSON','{'],['object root','{}'],['null entry',[null]],['invalid id',[{id:'foo.*',issue:411,reason:'failure'}]],
 ['duplicate id',[quarantine[0],quarantine[0]]],['atomic validation',[quarantine[0],{id:'Probe.swiftSkip()',reason:'failure'}]],
]) test(`${label} fails with 70 before any process`,()=>{
 const h=harness(entries);assert.equal(h.status,70);assert.equal(h.calls.length,0);assert.match(h.stderr,/quarantine/);assert.doesNotMatch(h.stdout,/quarantine skip=|Tests run:/);
});
test('missing and unreadable file fail closed before any process',()=>{
 for(const p of [path.join(tmpdir(),'i411-does-not-exist.json'),tmpdir()]) {const h=harness([],{quarantinePath:p});assert.equal(h.status,70);assert.equal(h.calls.length,0);assert.match(h.stderr,/quarantine/);}
});
test('missing quarantined ID warns and fails before test execution',()=>{
 const h=harness([{id:'Probe.absent()',issue:411,reason:'failure'}]);assert.equal(h.status,70);assert.equal(nativeCalls(h).length,0);assert.match(h.stderr,/warn.*Probe\.absent\(\)/i);assert.doesNotMatch(h.stdout,/Tests run:/);
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
 const allSwift=ids.filter(id=>id.includes('(')).map(id=>({id,issue:411,reason:'failure'}));
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
function withFailedXCTest(output) {
 return output
  .replace("Test Case '-[Probe.ProbeTests testKeep]' passed (","Test Case '-[Probe.ProbeTests testKeep]' failed (")
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
 const run=(budget,args)=>spawnSync(process.execPath,['-e',code,String(budget),...args],{encoding:'utf8',timeout:10000});
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
