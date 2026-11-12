import test from 'node:test';
import assert from 'node:assert/strict';
import {chmodSync,existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runAppRepeat} from './app-repeat.mjs';
import * as worker from './app-repeat-worker.mjs';
import {spawnSync} from 'node:child_process';
import {mkdirSync} from 'node:fs';
import {randomBytes} from 'node:crypto';

function attestedResult(settings,status,details={}){
  const id=randomBytes(16).toString('hex');
  const statusPath=path.join(settings.env.PICSEE_REPEAT_STATUS_DIR,`${id}.json`);
  writeFileSync(statusPath,JSON.stringify({id,supervisor:43210,cleanup:'complete',commandExit:status})+'\n');
  const output=[];output[Number(settings.env.PICSEE_REPEAT_ATTEST_FD)]=JSON.stringify({id,statusPath,supervisor:43210})+'\n';
  return {...result(JSON.stringify({status,...details})),output};
}

const moduleURL=new URL('./app-compare.mjs',import.meta.url);
const comparison=existsSync(moduleURL)?await import(moduleURL.href):{};
const root=fileURLToPath(new URL('../../',import.meta.url));
test('CI Host ownership lane refuses cleared inherited supervision before tests launch',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i657-ci-clear-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const marker=path.join(dir,'ran');
  const fixture=path.join(dir,'fixture.test.mjs');
  writeFileSync(fixture,`import test from 'node:test';import {writeFileSync} from 'node:fs';test('must not run',()=>writeFileSync(${JSON.stringify(marker)},'ran'));\n`);
  const env={...process.env,PICSEE_HEAVY_CI_BOUNDARY_REQUIRED:'1',PICSEE_HEAVY_LOCK_HELD:'',PICSEE_HEAVY_CONTROL_FD:''};
  delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(process.execPath,[path.join(root,'scripts/tdd/node-lane.mjs'),fixture],{
    env,
    encoding:'utf8',timeout:5000});
  assert.equal(run.status,70,run.stdout+run.stderr);
  assert.equal(existsSync(marker),false);
});
// Owner-approved real-OS lane placement must execute the actual strict runner,
// propagate its status and retain its report for every comparison mode.
for(const mode of ['hosted'])for(const outcome of ['pass','fail','zero','crash'])
test(`ownership integration ${mode} step preserves ${outcome} runner outcome and report`,t=>{
  const yaml=readFileSync(path.join(root,'.github/workflows/ci.yml'),'utf8');
  const job=yaml.slice(yaml.indexOf('\n  app-host-comparison:'));
  assert.match(job,/^    if: github\.event_name == 'workflow_dispatch' && inputs\.app_compare_mode == 'hosted' && !inputs\.app_tests$/m,
    'comparison routing accepts hosted dispatches only');
  const block=/      - name: Host ownership integration\n([\s\S]*?)(?=\n      - name:|$)/.exec(job)?.[1];
  assert.ok(block,'every comparison must have a distinct real ownership integration step');
  assert.doesNotMatch(block,/\bif:|continue-on-error|\|\|\s*true/,'integration cannot be conditional or permissive');
  const command=/^        run: (.+)$/m.exec(block)?.[1];
  assert.ok(command,'the integration step has an executable command');
  assert.ok(job.indexOf('name: Build comparison mechanism')<job.indexOf('name: Host ownership integration'));
  assert.ok(job.indexOf('name: Host ownership integration')<job.indexOf('name: Verify hosted cancellation ownership'));
  const upload=job.slice(job.indexOf('name: Upload App host comparison'));
  assert.match(upload,/if: always\(\)/);assert.match(upload,/\.build\/host-ownership-integration\.tap/);
  const dir=mkdtempSync(path.join(tmpdir(),'i393-integration-step-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  for(const d of ['.build','scripts/tdd','scripts/ci/integration'])mkdirSync(path.join(dir,d),{recursive:true});
  writeFileSync(path.join(dir,'scripts/tdd/node-lane.mjs'),readFileSync(path.join(root,'scripts/tdd/node-lane.mjs')));
  writeFileSync(path.join(dir,'scripts/tdd/heavy-lock.py'),readFileSync(path.join(root,'scripts/tdd/heavy-lock.py')));
  writeFileSync(path.join(dir,'scripts/heavy-lock.sh'),readFileSync(path.join(root,'scripts/heavy-lock.sh')));
  chmodSync(path.join(dir,'scripts/heavy-lock.sh'),0o755);
  writeFileSync(path.join(dir,'scripts/ci/integration/fixture.test.mjs'),
    `import test from 'node:test';import assert from 'node:assert/strict';test('external integration fixture',()=>assert.equal(1,${outcome==='fail'?2:1}));\n`);
  if(outcome==='crash')writeFileSync(path.join(dir,'scripts/ci/integration/fixture.test.mjs'),
    'process.kill(process.ppid,"SIGTERM");process.exit(0);\n'); // Interrupt only this fixture's own test-runner parent.
  const env={...process.env,APP_COMPARE_MODE:mode,GITHUB_ACTIONS:'true',
    PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_MDPRO_LOCK:'off',
    PICSEE_HEAVY_STATUS_PATH:path.join(dir,'.build','cleanup.json')};delete env.NODE_OPTIONS;
  delete env.NODE_TEST_CONTEXT; // This subprocess is a new runner, not an outer test worker.
  if(outcome==='zero'){
    // An empty shard produces a genuine zero-test root. An empty test file
    // can count as one file-level test, and test-worker preloads run too late.
    const hook=path.join(dir,'runner-outcome.mjs');
    writeFileSync(hook,"if(process.argv[1]?.endsWith('node-lane.mjs'))process.argv.splice(2,0,'--test-shard=2/2');\n");
    env.NODE_OPTIONS=`--import=${hook}`;
  }
  const run=spawnSync('/bin/sh',['-c',command],{cwd:dir,env,encoding:'utf8',timeout:10000});
  assert.equal(run.error,undefined);assert.equal(run.signal,null);
  assert.equal(run.status,outcome==='pass'?0:outcome==='fail'?1:70);
  const report=readFileSync(path.join(dir,'.build/host-ownership-integration.tap'),'utf8');
  if(outcome==='pass'||outcome==='fail'){
    assert.match(report,/Tests run: 1, Failures: [01], Errors: 0, Skipped: 0/);
    assert.match(report,outcome==='pass'?/Failures: 0/:/Failures: 1/);
  }else assert.match(report,/node-lane: no reliable completed test result; environment failure/);
  if(outcome==='zero')assert.match(report,/^# tests 0$/m,'the zero fixture must reach the actual runner boundary');
  if(outcome==='crash')assert.doesNotMatch(report,/^# tests \d+$/m,'the interrupted runner must not claim a completed root');
});
const hostedSummary=readFileSync(new URL('../tdd/fixtures/i393-hosted/summary.json',import.meta.url),'utf8');
const hostedTests=readFileSync(new URL('../tdd/fixtures/i393-hosted/tests.json',import.meta.url),'utf8');
const result=stdout=>({status:0,signal:null,stdout,stderr:''});
function harness(t,{mode='hosted',scope='focus',native,...options}={}) {
  const dir=mkdtempSync(path.join(tmpdir(),'i393-compare-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const quarantinePath=path.join(dir,'quarantine.json');writeFileSync(quarantinePath,'[]\n');
  const calls=[];let output='';
  assert.equal(typeof comparison.runComparisonIteration,'function','comparison iteration API must exist');
  const env={APP_COMPARE_MODE:mode,APP_COMPARE_SCOPE:scope,PICSEE_APP_LANE_NO_RETRY:'1',
    PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'5',MADO_TEST_RUN_TOKEN:'token-hosted',
    MADO_APP_COMPARE_RESULT_PATH:path.join(dir,'comparison.json'),GITHUB_SHA:'same-sha',RUNNER_OS:'macOS'};
  const status=comparison.runComparisonIteration({cwd:root,expectedMode:mode,env,quarantinePath,
    evidencePath:path.join(dir,'attempt.log'),stdout:s=>output+=s,stderr:s=>output+=s,
    spawn:(cmd,args,settings)=>{
      calls.push({cmd,args,settings});
      const injected=native?.(cmd,args,settings,calls.length);if(injected!==undefined)return injected;
      if(args.includes('--show-sdk-platform-path'))return result('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform\n');
      if(args.includes('swiftc'))return result('');
      if(args.includes('test-without-building'))return result('** TEST EXECUTE SUCCEEDED **\n[issue393-host] pid=321 executable=/tmp/Mado.app/Contents/MacOS/Mado\n');
      if(args.includes('xcresulttool'))return result(args.includes('summary')?hostedSummary:hostedTests);
      return result('');
    },...options});
  const record=existsSync(env.MADO_APP_COMPARE_RESULT_PATH)?JSON.parse(readFileSync(env.MADO_APP_COMPARE_RESULT_PATH,'utf8')):null;
  return {status,calls,output,record,dir,env};
}

test('hosted focus executes hosted mechanism without unhosted runs',t=>{
  const h=harness(t,{mode:'hosted'});
  assert.equal(h.status,0,h.output);
  assert.equal(h.calls.filter(call=>call.args.includes('test-without-building')).length,1);
  assert.equal(h.calls.filter(call=>call.args.includes('xctest')).length,0);
  assert.equal(h.record.mode,'hosted');assert.equal(h.record.formal,false);
});

test('hostedAppLaunchPassesSupervisionDescriptor',t=>{
  const h=harness(t,{mode:'hosted',env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',
    PICSEE_APP_LANE_NO_RETRY:'1',PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'5',
    MADO_TEST_RUN_TOKEN:'token-hosted',GITHUB_SHA:'same-sha',RUNNER_OS:'macOS'}});
  const call=h.calls.find(entry=>entry.args.includes('test-without-building'));
  assert.ok(call,'hosted native command launched');
  assert.equal(call.settings.stdio?.[5],5,'nested wrapper receives the parent control FD');
});

test('mode/scope/forwarding and retry/quarantine violations fail before native work',t=>{
  for(const patch of [
    {expectedMode:'normal'},
    {env:{APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'invalid',PICSEE_APP_LANE_NO_RETRY:'1'}},
    {env:{APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'1'}},
    {env:{APP_COMPARE_MODE:'unknown',APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'1'}},
    {env:{APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'0'}},
  ]) {
    const h=harness(t,patch);assert.notEqual(h.status,0,h.output);assert.equal(h.calls.length,0);
  }
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
    env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'4',GITHUB_SHA:'same-sha',RUNNER_OS:'macOS'},
    stdout:()=>{},spawn:(_cmd,args,settings)=>{
      calls.push({args,settings});clock+=25;writeFileSync(args[2],'native evidence\n');
      return attestedResult(settings,calls.length===2?1:0,{drained:true});
    }});
  assert.equal(status,1);
  for(const number of [1,2,3])assert.equal(existsSync(path.join(dir,`iter-0${number}.json`)),true,'every iteration has timing evidence');
  const rows=[1,2,3].map(number=>JSON.parse(readFileSync(path.join(dir,`iter-0${number}.json`),'utf8')));
  assert.deepEqual(rows.map(row=>row.status),[0,1,0]);
  assert.deepEqual(rows.map(row=>row.wallMilliseconds),[25,25,25]);
  assert.ok(rows.every(row=>row.mode==='hosted'&&row.scope==='focus'&&row.sha==='same-sha'&&row.runner==='macos-26'&&row.started===true));
  assert.equal(new Set(calls.map(call=>call.settings.env.MADO_TEST_RUN_TOKEN)).size,3);
  for(const call of calls) {
    assert.equal(call.args.at(-1),'hosted');
    assert.equal(call.settings.env.TEST_RUNNER_MADO_TEST_RUN_TOKEN,call.settings.env.MADO_TEST_RUN_TOKEN);
    assert.equal(call.settings.env.MADO_HOST_OWNERSHIP_REQUIRED,'1');
    assert.equal(call.settings.env.MADO_HOST_EXECUTABLE,path.resolve('.build/dd-ci/Build/Products/Debug/Mado.app/Contents/MacOS/Mado'));
  }
});

test('repeat records unstarted refused iterations without fabricated execution durations',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-repeat-refused-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const status=runAppRepeat({repeat:2,filter:'',out:dir,now:()=>100,deadline:10000,
    env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'4'},stdout:()=>{},
    spawn:(_cmd,args)=>{writeFileSync(args[2],'undrained\n');return result(JSON.stringify({status:70,drained:false}));}});
  assert.equal(status,70);
  assert.equal(existsSync(path.join(dir,'iter-02.json')),true,'refused iteration has explicit evidence');
  const refused=JSON.parse(readFileSync(path.join(dir,'iter-02.json'),'utf8'));
  assert.equal(refused.started,false);assert.equal(refused.nativeWallMilliseconds,null);assert.notEqual(refused.status,0);
});

test('normal retained-only filtered repeat does not require a hosted process that cannot launch',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-retained-filter-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  let captured;
  const status=runAppRepeat({repeat:1,filter:'^MadoAppTests\\.retainedOnly\\(\\)$',out:dir,deadline:10000,now:()=>100,
    env:{PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'4'},stdout:()=>{},spawn:(_cmd,args,settings)=>{
      captured=settings.env;writeFileSync(args[2],'retained-only\n');return attestedResult(settings,0,{drained:true});
    }});
  assert.equal(status,0);assert.equal(captured.MADO_HOST_OWNERSHIP_REQUIRED,undefined);
  assert.equal(captured.MADO_HOST_EXECUTABLE,undefined);
});

test('comparison coordinator requires current matching worker evidence before trusting supervisor success',t=>{
  assert.equal(typeof comparison.runAppCompare,'function');
  for(const variant of ['missing','stale','wrong-mode','wrong-scope','wrong-sha','wrong-status','incomplete','matching']) {
    const dir=mkdtempSync(path.join(tmpdir(),'i393-current-record-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
    const status=comparison.runAppCompare({out:dir,now:()=>100,deadline:10000,stdout:()=>{},
      env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'1',PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'4',GITHUB_SHA:'final-sha'},
      spawn:(_cmd,args,settings)=>{
        writeFileSync(args[2],'current worker output\n');
        const packet={version:1,runId:settings.env.MADO_APP_COMPARE_RESULT_ID,complete:true,status:0,
          mode:'hosted',scope:'focus',sha:'final-sha',diagnostic:true,formal:false,groups:{hosted:0}};
        if(variant==='stale')packet.runId='previous-run';
        if(variant==='wrong-mode')packet.mode='legacy';
        if(variant==='wrong-scope')packet.scope='full';
        if(variant==='wrong-sha')packet.sha='old-sha';
        if(variant==='wrong-status')packet.status=1;
        if(variant==='incomplete')packet.complete=false;
        if(variant!=='missing')writeFileSync(settings.env.MADO_APP_COMPARE_RESULT_PATH,JSON.stringify(packet));
        return attestedResult(settings,0,{drained:true});
      }});
    assert.equal(status,variant==='matching'?0:70,variant);
  }
});

test('hosted compare refuses the next native iteration after contradictory worker evidence',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i657-compare-stop-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  let launched=0;
  const status=comparison.runAppCompare({out:dir,now:()=>100,deadline:10000,stdout:()=>{},
    env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'2',
      PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'4'},
    spawn:(_cmd,args,settings)=>{
      launched++;
      writeFileSync(args[2],'worker completed\n');
      return attestedResult(settings,0,{drained:true});
    }});
  assert.equal(status,70);
  assert.equal(launched,1);
  const second=JSON.parse(readFileSync(path.join(dir,'iter-02.json'),'utf8'));
  assert.equal(second.started,false);
});

test('comparison rows preserve ownership proof and label supervised duration without inventing native time',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'i393-ownership-row-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  let clock=100;
  const hostOwnership={observed:true,drained:true,identities:[{pid:123,birth:'1:2'}],signals:[],unknown:[],live:[]};
  const status=runAppRepeat({repeat:1,filter:'',out:dir,deadline:10000,now:()=>clock,
    env:{APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CONTROL_FD:'4'},stdout:()=>{},
    spawn:(_cmd,args,settings)=>{clock+=25;writeFileSync(args[2],'owned host gone\n');return attestedResult(settings,0,{drained:true,group:456,hostOwnership});}});
  assert.equal(status,0);
  const row=JSON.parse(readFileSync(path.join(dir,'iter-01.json'),'utf8'));
  assert.deepEqual(row.hostOwnership,hostOwnership);assert.equal(row.group,456);
  assert.equal(row.wallMilliseconds,25);assert.equal(row.nativeWallMilliseconds,null);
  assert.match(row.durationLabel,/supervised iteration/);
});
