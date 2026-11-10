import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runAppRepeat} from './app-repeat.mjs';
import * as worker from './app-repeat-worker.mjs';

const moduleURL=new URL('./app-compare.mjs',import.meta.url);
const comparison=existsSync(moduleURL)?await import(moduleURL.href):{};
const root=fileURLToPath(new URL('../../',import.meta.url));
const wrappers=[
  'issue521NativePanPassesInIsolatedProcess()',
  'issue527NonCanvasPressesPassInIsolatedProcess()',
  'issue527InactiveFirstClickPassesInIsolatedProcess()',
  'issue527InspectorCanvasPressPassesInIsolatedProcess()',
  'issue564KeyWindowFixturePassesInIsolatedProcess()',
  'retry442NativeKeyboardMatrixPassesInIsolatedProcess()',
];
const proof='issue393LegacyRuntimeProof()';
const baseline=readFileSync(new URL('../tdd/fixtures/i411-baseline.txt',import.meta.url),'utf8');
const hostedSummary=readFileSync(new URL('../tdd/fixtures/i393-hosted/summary.json',import.meta.url),'utf8');
const hostedTests=readFileSync(new URL('../tdd/fixtures/i393-hosted/tests.json',import.meta.url),'utf8');
const result=stdout=>({status:0,signal:null,stdout,stderr:''});
function selectedOutput(names) {
  return "Test Suite 'Selected tests' started at now\nTest Suite 'Selected tests' passed at now\nExecuted 0 tests, with 0 failures (0 unexpected)\n◇ Test run started.\n"+
    names.map(name=>`◇ Test ${name} started.\n${name===proof?'[issue393-legacy] pid=123 executable=/Applications/Xcode.app/Contents/Developer/usr/bin/xctest process=xctest bundle=MadoLegacy393Tests mode=legacy token=token-legacy\n':''}✔ Test ${name} passed after 0.001 seconds.\n`).join('')+
    `✔ Test run with ${names.length} tests in 0 suites passed after 0.001 seconds.\n`;
}
function harness(t,{mode='legacy',scope='focus',native,...options}={}) {
  const dir=mkdtempSync(path.join(tmpdir(),'i393-compare-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const quarantinePath=path.join(dir,'quarantine.json');writeFileSync(quarantinePath,'[]\n');
  const calls=[];let output='';
  assert.equal(typeof comparison.runComparisonIteration,'function','comparison iteration API must exist');
  const env={APP_COMPARE_MODE:mode,APP_COMPARE_SCOPE:scope,PICSEE_APP_LANE_NO_RETRY:'1',
    PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_TEST_RUN_TOKEN:'token-legacy',
    PICSEE_APP_COMPARE_RESULT_PATH:path.join(dir,'comparison.json'),GITHUB_SHA:'same-sha',RUNNER_OS:'macOS'};
  const status=comparison.runComparisonIteration({cwd:root,expectedMode:mode,env,quarantinePath,
    evidencePath:path.join(dir,'attempt.log'),stdout:s=>output+=s,stderr:s=>output+=s,
    spawn:(cmd,args,settings)=>{
      calls.push({cmd,args,settings});
      const injected=native?.(cmd,args,settings,calls.length);if(injected!==undefined)return injected;
      if(args.includes('--show-sdk-platform-path'))return result('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform\n');
      if(args.includes('swiftc'))return result('');
      if(args.includes('test-without-building'))return result('** TEST EXECUTE SUCCEEDED **\n[issue393-host] pid=321 executable=/tmp/Mado.app/Contents/MacOS/Mado\n');
      if(args.includes('xcresulttool'))return result(args.includes('summary')?hostedSummary:hostedTests);
      if(args.includes('xctest')) {
        if(args.at(-1).includes('MadoLegacy393Tests')) {
          // Approved full-context fixture: unfiltered baseline root keeps disabled child metadata.
          if(!args.includes('-XCTest'))return result(selectedOutput([proof,...wrappers]).replaceAll('Selected tests','All tests'));
          const names=(args[args.indexOf('-XCTest')+1]??'').split(',').map(id=>id.slice(id.indexOf('.')+1));
          return result(selectedOutput(names));
        }
        return result(baseline);
      }
      return result('APP_LANE_INVENTORY_BEGIN\n'+[proof,...wrappers,'issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:)']
        .map(name=>'MadoAppTests.'+name).join('\n')+'\nAPP_LANE_INVENTORY_END\n');
    },...options});
  const record=existsSync(env.PICSEE_APP_COMPARE_RESULT_PATH)?JSON.parse(readFileSync(env.PICSEE_APP_COMPARE_RESULT_PATH,'utf8')):null;
  return {status,calls,output,record,dir,env};
}

test('legacy focus proves bare runtime then executes exactly six original parent wrappers',t=>{
  const h=harness(t);
  assert.equal(h.status,0,h.output);
  const runs=h.calls.filter(call=>call.args.includes('xctest'));
  assert.equal(runs.length,2,'runtime proof and six-wrapper behavior phase');
  assert.deepEqual(runs[0].args[runs[0].args.indexOf('-XCTest')+1].split(','),['MadoAppTests.'+proof]);
  assert.deepEqual(new Set(runs[1].args[runs[1].args.indexOf('-XCTest')+1].split(',')),new Set(wrappers.map(name=>'MadoAppTests.'+name)));
  assert.ok(runs.every(call=>call.args.at(-1).endsWith('MadoLegacy393Tests.xctest')));
  assert.equal(h.record.mode,'legacy');assert.equal(h.record.scope,'focus');
  assert.equal(h.record.status,0);assert.equal(h.record.formal,false);assert.equal(h.record.diagnostic,true);
  assert.match(h.record.baseline,/^c5a087f5/);assert.equal(h.record.sha,'same-sha');
  assert.equal(h.calls.some(call=>call.args.includes('test-without-building')),false);
});

// User-approved specification correction: preserve the real complete baseline in one process.
test('legacy full preserves the complete legacy bundle in one process and never executes hosted App',t=>{
  const h=harness(t,{scope:'full'});
  assert.equal(h.status,0,h.output);
  const runs=h.calls.filter(call=>call.args.includes('xctest'));
  assert.equal(runs.length,1);
  assert.equal(runs.filter(call=>call.args.at(-1).endsWith('/MadoAppTests.xctest')).length,0);
  assert.equal(runs.filter(call=>call.args.at(-1).endsWith('/MadoLegacy393Tests.xctest')).length,1);
  assert.equal(h.calls.some(call=>call.args.includes('test-without-building')),false);
});

test('hosted focus executes actual hosted mechanism and excludes legacy/retained runs',t=>{
  const h=harness(t,{mode:'hosted'});
  assert.equal(h.status,0,h.output);
  assert.equal(h.calls.filter(call=>call.args.includes('test-without-building')).length,1);
  assert.equal(h.calls.filter(call=>call.args.includes('xctest')).length,0);
  assert.equal(h.record.mode,'hosted');assert.equal(h.record.formal,false);
});

test('mode/scope/forwarding and retry/quarantine violations fail before native work',t=>{
  for(const patch of [
    {expectedMode:'hosted'},
    {env:{APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'invalid',PICSEE_APP_LANE_NO_RETRY:'1'}},
    {env:{APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'1'}},
    {env:{APP_COMPARE_MODE:'unknown',APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'1'}},
    {env:{APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'0'}},
  ]) {
    const h=harness(t,patch);assert.notEqual(h.status,0,h.output);assert.equal(h.calls.length,0);
  }
});

test('legacy cannot pass using only success labels without runtime proof marker',t=>{
  const h=harness(t,{native:(_cmd,args)=>args.includes('xctest')?result(selectedOutput([proof]).replace(/^\[issue393-legacy\].*\n/m,'')):undefined});
  assert.notEqual(h.status,0,h.output);
  assert.notEqual(h.record?.status,0);
});

test('a failed legacy behavior phase persists failure and cannot become comparison success',t=>{
  const h=harness(t,{native:(_cmd,args)=>args.includes('xctest')&&args.join(' ').includes(wrappers[0])?
    {status:null,signal:'SIGTERM',stdout:'partial legacy behavior\n',stderr:'interrupted\n'}:undefined});
  assert.notEqual(h.status,0,h.output);assert.match(h.output,/partial legacy behavior/);
  assert.notEqual(h.record?.status,0);assert.equal(h.record.formal,false);
});

test('actual worker entry rejects dropped expected-mode forwarding before launching native work',()=>{
  assert.equal(typeof worker.runAppWorker,'function');
  let calls=0,output='';
  const status=worker.runAppWorker({expectedMode:'legacy',env:{APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'1'},
    spawn:()=>{calls++;throw new Error('must not launch');},stdout:s=>output+=s,stderr:s=>output+=s});
  assert.notEqual(status,0,output);assert.equal(calls,0);
});

test('repeat sidecars preserve exact mode, unique tokens, timings and independent worker mode arg',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-repeat-timing-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  let clock=100;const calls=[];
  const status=runAppRepeat({repeat:3,filter:'',out:dir,now:()=>clock,deadline:10000,
    env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1',GITHUB_SHA:'same-sha',RUNNER_OS:'macOS'},
    stdout:()=>{},spawn:(_cmd,args,settings)=>{
      calls.push({args,settings});clock+=25;writeFileSync(args[2],'native evidence\n');
      return result(JSON.stringify({status:calls.length===2?1:0,drained:true}));
    }});
  assert.equal(status,1);
  for(const number of [1,2,3])assert.equal(existsSync(path.join(dir,`iter-0${number}.json`)),true,'every iteration has timing evidence');
  const rows=[1,2,3].map(number=>JSON.parse(readFileSync(path.join(dir,`iter-0${number}.json`),'utf8')));
  assert.deepEqual(rows.map(row=>row.status),[0,1,0]);
  assert.deepEqual(rows.map(row=>row.wallMilliseconds),[25,25,25]);
  assert.ok(rows.every(row=>row.mode==='hosted'&&row.scope==='focus'&&row.sha==='same-sha'&&row.runner==='macos-26'&&row.started===true));
  assert.equal(new Set(calls.map(call=>call.settings.env.PICSEE_TEST_RUN_TOKEN)).size,3);
  for(const call of calls) {
    assert.equal(call.args.at(-1),'hosted');
    assert.equal(call.settings.env.TEST_RUNNER_PICSEE_TEST_RUN_TOKEN,call.settings.env.PICSEE_TEST_RUN_TOKEN);
    assert.equal(call.settings.env.PICSEE_HOST_OWNERSHIP_REQUIRED,'1');
    assert.equal(call.settings.env.PICSEE_HOST_EXECUTABLE,path.resolve('.build/dd-ci/Build/Products/Debug/Mado.app/Contents/MacOS/Mado'));
  }
});

test('repeat records unstarted refused iterations without fabricated execution durations',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-repeat-refused-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const status=runAppRepeat({repeat:2,filter:'',out:dir,now:()=>100,deadline:10000,
    env:{APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1'},stdout:()=>{},
    spawn:(_cmd,args)=>{writeFileSync(args[2],'undrained\n');return result(JSON.stringify({status:70,drained:false}));}});
  assert.equal(status,1);
  assert.equal(existsSync(path.join(dir,'iter-02.json')),true,'refused iteration has explicit evidence');
  const refused=JSON.parse(readFileSync(path.join(dir,'iter-02.json'),'utf8'));
  assert.equal(refused.started,false);assert.equal(refused.nativeWallMilliseconds,null);assert.notEqual(refused.status,0);
});

test('normal retained-only filtered repeat does not require a hosted process that cannot launch',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-retained-filter-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  let captured;
  const status=runAppRepeat({repeat:1,filter:'^MadoAppTests\\.retainedOnly\\(\\)$',out:dir,deadline:10000,now:()=>100,
    env:{PICSEE_HEAVY_LOCK_HELD:'1'},stdout:()=>{},spawn:(_cmd,args,settings)=>{
      captured=settings.env;writeFileSync(args[2],'retained-only\n');return result(JSON.stringify({status:0,drained:true}));
    }});
  assert.equal(status,0);assert.equal(captured.PICSEE_HOST_OWNERSHIP_REQUIRED,undefined);
  assert.equal(captured.PICSEE_HOST_EXECUTABLE,undefined);
});

test('comparison coordinator requires current matching worker evidence before trusting supervisor success',t=>{
  assert.equal(typeof comparison.runAppCompare,'function');
  for(const variant of ['missing','stale','wrong-mode','wrong-scope','wrong-sha','wrong-status','incomplete','matching']) {
    const dir=mkdtempSync(path.join(tmpdir(),'i393-current-record-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
    const status=comparison.runAppCompare({out:dir,now:()=>100,deadline:10000,stdout:()=>{},
      env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'1',PICSEE_HEAVY_LOCK_HELD:'1',GITHUB_SHA:'final-sha'},
      spawn:(_cmd,args,settings)=>{
        writeFileSync(args[2],'current worker output\n');
        const packet={version:1,runId:settings.env.PICSEE_APP_COMPARE_RESULT_ID,complete:true,status:0,
          mode:'hosted',scope:'focus',sha:'final-sha',diagnostic:true,formal:false,groups:{hosted:0}};
        if(variant==='stale')packet.runId='previous-run';
        if(variant==='wrong-mode')packet.mode='legacy';
        if(variant==='wrong-scope')packet.scope='full';
        if(variant==='wrong-sha')packet.sha='old-sha';
        if(variant==='wrong-status')packet.status=1;
        if(variant==='incomplete')packet.complete=false;
        if(variant!=='missing')writeFileSync(settings.env.PICSEE_APP_COMPARE_RESULT_PATH,JSON.stringify(packet));
        return result(JSON.stringify({status:0,drained:true}));
      }});
    assert.equal(status,variant==='matching'?0:1,variant);
  }
});

test('comparison rows preserve ownership proof and label supervised duration without inventing native time',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-ownership-row-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  let clock=100;
  const hostOwnership={observed:true,drained:true,identities:[{pid:123,birth:'1:2'}],signals:[],unknown:[],live:[]};
  const status=runAppRepeat({repeat:1,filter:'',out:dir,deadline:10000,now:()=>clock,
    env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1'},stdout:()=>{},
    spawn:(_cmd,args)=>{clock+=25;writeFileSync(args[2],'owned host gone\n');return result(JSON.stringify({status:0,drained:true,group:456,hostOwnership}));}});
  assert.equal(status,0);
  const row=JSON.parse(readFileSync(path.join(dir,'iter-01.json'),'utf8'));
  assert.deepEqual(row.hostOwnership,hostOwnership);assert.equal(row.group,456);
  assert.equal(row.wallMilliseconds,25);assert.equal(row.nativeWallMilliseconds,null);
  assert.match(row.durationLabel,/supervised iteration/);
});

test('legacy runtime proof marker must carry this invocation token',t=>{
  const h=harness(t,{native:(_cmd,args)=>args.includes('xctest')&&args.join(' ').includes(proof)?
    result(selectedOutput([proof]).replace('token=token-legacy','token=previous-run')):undefined});
  h.output=JSON.stringify(h.output); // Keep embedded native count lines out of the receipt root parser.
  assert.notEqual(h.status,0,h.output);
});

test('legacy full runs retained tests, six parents and proof in one unfiltered root with child-only bodies skipped',t=>{
  const children=[
    'issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:)',
    'issue527InspectorCloseCanvasPressPans()',
    'issue527NonCanvasPressPreservesFocusAndImage(target:)',
    'issue527InactiveFirstClickKeepsFocusConsistent()',
    'issue564KeyWindowFixtureHandlesDelayedAndNeverKey()',
    'retry442NativeKeyboardMatrix()',
  ];
  const retained='retainedStateSurvivesPriorAppTests()';
  const names=[retained,proof,...wrappers,...children];
  const h=harness(t,{scope:'full',native:(_cmd,args)=>{
    if(args.includes('xctest')) {
      const passed=[retained,proof,...wrappers];
      const output=selectedOutput(passed).replaceAll('Selected tests','All tests')
        .replace(`✔ Test run with ${passed.length} tests`,children.map(name=>`➜ Test ${name} skipped.\n`).join('')+`✔ Test run with ${names.length} tests`);
      return result(output);
    }
    if(args.length===1&&args[0].endsWith('/MadoLegacy393Tests'))
      return result('APP_LANE_INVENTORY_BEGIN\n'+names.map(name=>'MadoAppTests.'+name).join('\n')+'\nAPP_LANE_INVENTORY_END\n');
  }});
  assert.equal(h.status,0,JSON.stringify(h.output));
  const runs=h.calls.filter(call=>call.args.includes('xctest'));
  assert.equal(runs.length,1,'cross-test AppKit leftovers stay inside the same original bundle process');
  assert.equal(runs[0].args.includes('-XCTest'),false,'baseline full run remains unfiltered');
  for(const name of [retained,proof,...wrappers]) {
    assert.equal(h.output.split('\n').filter(line=>line===`◇ Test ${name} started.`).length,1);
    assert.equal(h.output.split('\n').filter(line=>line===`✔ Test ${name} passed after 0.001 seconds.`).length,1);
  }
  for(const name of children) {
    assert.equal(h.output.includes(`◇ Test ${name} started.`),false);
    assert.equal(h.output.includes(`➜ Test ${name} skipped.`),true);
  }
  assert.equal(h.record.runtimeProof.pid,123);
  assert.deepEqual(h.record.groups,{legacyFull:0});
});
