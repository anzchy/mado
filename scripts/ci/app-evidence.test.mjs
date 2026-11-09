import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { runAppLane } from '../tdd/app-lane.mjs';
import { reportAppEvidence } from './app-evidence.mjs';

const pass = {stdout:"Test Suite 'All tests' passed at 2026-11-09 00:00:00.000.\n Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds\n◇ Test run started.\n✔ Test passing() passed after 0.001 seconds.\n✔ Test run with 1 test in 0 suites passed after 0.001 seconds.\n",stderr:'',status:0};
const failed = {stdout:readFileSync(new URL('./fixtures/app-a1.txt',import.meta.url),'utf8'),stderr:'',status:1};
const envFor = dir => ({APP_RESULT_PATH:join(dir,'result.json'), APP_RESULT_ID:'this-run', APP_TEST_STEP:'success',EVENT_NAME:'push',APP_TESTS:'true',APP_REPEAT:'1',APP_FILTER:''});
const fixture = t => { const dir=mkdtempSync(join(tmpdir(),'app-structured-')); t.after(()=>rmSync(dir,{recursive:true,force:true})); return dir; };
function lane(dir, sequence=[pass], options={}) {
  let attempts=0, stdout='',stderr='';
  const env={PICSEE_APP_RESULT_PATH:join(dir,'result.json'),PICSEE_APP_RESULT_ID:'this-run',...options.env};
  const status=runAppLane({evidencePath:join(dir,'first.log'),stdout:s=>stdout+=s,stderr:s=>stderr+=s,...options,env,
    spawn:()=>{const next=sequence[attempts++]; if(next instanceof Error)throw next; return next;}});
  assert.equal(existsSync(env.PICSEE_APP_RESULT_PATH),true,'lane must write structured result evidence');
  return {status,attempts,stdout,stderr,record:JSON.parse(readFileSync(env.PICSEE_APP_RESULT_PATH,'utf8'))};
}
test('lane structured direct and retry evidence drives reporter independently of human wording',t=>{
  const dir=fixture(t), env=envFor(dir);
  for(const [sequence,n,status] of [[[pass],1,0],[[failed,pass],2,0],[[failed,failed],2,1],[[failed,{stdout:'',status:70}],2,70]]) {
    const got=lane(dir,sequence);
    assert.equal(got.status,status);assert.equal(got.attempts,n);
    assert.equal(got.record.attempts,n);assert.equal(got.record.status,status);assert.equal(got.record.complete,true);
    writeFileSync(join(dir,'human.log'),'changed or omitted retry words\n');
    const report=reportAppEvidence({...env,APP_TEST_STEP:status?'failure':'success'});
    assert.equal(report.retried,String(n===2));assert.equal(report.formal,status===0);
    assert.match(report.status,status?/failed/:n===2?/passed after the one automatic retry/:/passed directly/);
    if(n===2)assert.equal(readFileSync(join(dir,'first.log'),'utf8'),failed.stdout+'\n');
  }
});
test('reporter rejects missing malformed stale or internally inconsistent structured evidence',t=>{
  const dir=fixture(t), env=envFor(dir);
  assert.equal(reportAppEvidence(env).known,false);
  const good=lane(dir).record;
  const variants=['{',{}, {...good,version:99},{...good,runId:'old-run'},{...good,attempts:0},{...good,attempts:3},{...good,complete:false},{...good,status:1},{...good,attempts:2,retryEnabled:false},{...good,filter:42},{...good,defaultQuarantine:'true'}];
  for(const value of variants) {
    writeFileSync(env.APP_RESULT_PATH,typeof value==='string'?value:JSON.stringify(value));
    const report=reportAppEvidence(env);assert.equal(report.formal,false,JSON.stringify(value));assert.equal(report.known,false);
    assert.equal(report.retried,'unknown');assert.doesNotMatch(report.status,/passed directly|passed after/);
  }
  writeFileSync(env.APP_RESULT_PATH,JSON.stringify(good));
  for(const step of ['cancelled','skipped','','failure'])assert.equal(reportAppEvidence({...env,APP_TEST_STEP:step}).formal,false);
});
test('lane resets reused evidence before usage quarantine and process failures; write error fails closed',t=>{
  const dir=fixture(t), env=envFor(dir);
  for(const options of [{argv:['[']},{quarantinePath:join(dir,'missing.json')}]) {
    lane(dir); const got=lane(dir,[pass],options);
    assert.notEqual(got.status,0);assert.equal(got.record.status,got.status);assert.equal(got.record.attempts,0);
    assert.equal(reportAppEvidence(env).formal,false);
  }
  lane(dir);const thrown=lane(dir,[new Error('fixture spawn error')]);assert.equal(thrown.status,70);assert.equal(thrown.record.status,70);
  const marker=join(dir,'file');writeFileSync(marker,'intact');let stderr='';let calls=0;
  const status=runAppLane({env:{PICSEE_APP_RESULT_PATH:join(marker,'result.json'),PICSEE_APP_RESULT_ID:'this-run'},spawn:()=>{calls++;return pass;},stdout:()=>{},stderr:s=>stderr+=s});
  assert.equal(status,70);assert.equal(calls,0);assert.match(stderr,/structured.*evidence/i);assert.equal(readFileSync(marker,'utf8'),'intact');
});
test('normal full policy is formal; requested and effective diagnostic policies never are',t=>{
  const dir=fixture(t), env=envFor(dir);
  const good=lane(dir).record;
  for(const event of ['push','pull_request','workflow_dispatch'])assert.equal(reportAppEvidence({...env,EVENT_NAME:event}).formal,true);
  for(const patch of [{APP_FILTER:'passing'},{APP_REPEAT:'2'},{PICSEE_APP_LANE_NO_RETRY:'1'}]) {
    const report=reportAppEvidence({...env,EVENT_NAME:'workflow_dispatch',...patch});
    assert.equal(report.formal,false);assert.equal(report.diagnostic,true);assert.match(report.status,/diagnostic/);
  }
  for(const patch of [{filter:'passing'},{retryEnabled:false},{defaultQuarantine:false}]) {
    writeFileSync(env.APP_RESULT_PATH,JSON.stringify({...good,...patch}));
    const report=reportAppEvidence({...env,EVENT_NAME:'workflow_dispatch'});assert.equal(report.formal,false);assert.equal(report.diagnostic,true);
  }
  const noRetry=lane(dir,[pass],{env:{PICSEE_APP_LANE_NO_RETRY:'1'}});assert.equal(noRetry.record.retryEnabled,false);
  const custom=join(dir,'quarantine.json');writeFileSync(custom,'[]');const got=lane(dir,[pass],{quarantinePath:custom});assert.equal(got.record.defaultQuarantine,false);
  const repeat=reportAppEvidence({...env,EVENT_NAME:'workflow_dispatch',APP_REPEAT:'3',APP_RESULT_PATH:join(dir,'absent')});
  assert.equal(repeat.formal,false);assert.equal(repeat.retried,'unknown');assert.match(repeat.status,/diagnostic/);assert.doesNotMatch(repeat.status,/passed directly/);
  const skipped=reportAppEvidence({...env,EVENT_NAME:'workflow_dispatch',APP_TESTS:'false',APP_TEST_STEP:'skipped'});assert.match(skipped.status,/tests not run/);assert.equal(skipped.formal,false);
});
test('real reporter CLI consumes actual lane JSON and retains human exception facts',t=>{
  const dir=fixture(t), env={...envFor(dir),GITHUB_OUTPUT:join(dir,'outputs'),GITHUB_STEP_SUMMARY:join(dir,'summary'),APP_LOG_PATH:join(dir,'human.log')};
  lane(dir,[failed,pass]);writeFileSync(env.APP_LOG_PATH,'app-lane quarantine none\napp-lane known-flaky test=fixture issue=#379\nchanged retry wording\n');
  const r=spawnSync(process.execPath,[fileURLToPath(new URL('./app-evidence.mjs',import.meta.url))],{env:{PATH:process.env.PATH,...env},encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);assert.match(readFileSync(env.GITHUB_OUTPUT,'utf8'),/^retried=true$/m);assert.match(readFileSync(env.GITHUB_OUTPUT,'utf8'),/^formal=true$/m);
  const summary=readFileSync(env.GITHUB_STEP_SUMMARY,'utf8');assert.match(summary,/passed after the one automatic retry/);assert.match(summary,/quarantine none/);assert.match(summary,/known-flaky test=fixture/);
});

test('disabled or unproven dispatch inputs and unknown events never supply formal evidence',t=>{
  const dir=fixture(t),env=envFor(dir);lane(dir);
  for(const APP_TESTS of ['false','',undefined]) {
    const report=reportAppEvidence({...env,EVENT_NAME:'workflow_dispatch',APP_TESTS});
    assert.equal(report.formal,false,`dispatch app_tests=${APP_TESTS}`);
    assert.equal(report.diagnostic,true);
  }
  for(const EVENT_NAME of ['',undefined,'unexpected'])assert.equal(reportAppEvidence({...env,EVENT_NAME}).formal,false);
});
