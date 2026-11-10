import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {realpathSync} from 'node:fs';
import {queryHostProcesses,createHostOwnership} from './app-host-ownership.mjs';

const executable=realpathSync(process.execPath),uid=process.getuid();
const identity=(overrides={})=>({pid:12345,birth:'100:123456',uid,executable,marker:'invocation-A',ppid:1,pgid:12345,...overrides});
function harness(){
  let records=[identity()],complete=true;const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,
    query:()=>({complete,processes:records,unknown:[]}),signal:(pid,name)=>signals.push({pid,name})});
  return {tracker,signals,set:r=>records=r,incomplete:()=>complete=false};
}
test('owned identity requires current token, uid, canonical executable and microsecond birth',()=>{
  const h=harness();h.tracker.observe();assert.equal(h.tracker.snapshot().observed,true);
  h.tracker.signalOwned('SIGTERM');assert.deepEqual(h.signals,[{pid:12345,name:'SIGTERM'}]);
  h.set([]);h.tracker.observe();assert.equal(h.tracker.snapshot().drained,true);
  assert.equal(h.tracker.snapshot().identities[0].birth,'100:123456');
});
test('missing registration, malformed or unreadable identity never proves drain',()=>{
  for(const records of [[],[identity({marker:'old'})],[identity({uid:uid+1})],[identity({birth:null})],
    [identity({executable:'/unrelated/Mado'})]]){
    const h=harness();h.set(records);h.tracker.observe();h.tracker.signalOwned('SIGTERM');
    assert.equal(h.tracker.snapshot().drained,false);assert.deepEqual(h.signals,[]);
  }
  const h=harness();h.incomplete();h.tracker.observe();assert.equal(h.tracker.snapshot().drained,false);
});
test('identity changes immediately before TERM or KILL invalidate authority and refuse overlap',()=>{
  for(const changed of [identity({birth:'100:123457'}),identity({marker:'previous'}),identity({uid:uid+1}),identity({executable:'/other'})]){
    const h=harness();h.tracker.observe();h.set([changed]);h.tracker.signalOwned('SIGTERM');h.tracker.signalOwned('SIGKILL');
    assert.deepEqual(h.signals,[]);assert.equal(h.tracker.snapshot().drained,false);
  }
});
test('same executable sentinel with another marker remains untouched throughout escalation',()=>{
  const h=harness(),sentinel=identity({pid:54321,marker:'unrelated'});
  h.set([identity(),sentinel]);h.tracker.observe();h.tracker.signalOwned('SIGTERM');h.tracker.signalOwned('SIGKILL');
  assert.deepEqual(h.signals,[{pid:12345,name:'SIGTERM'},{pid:12345,name:'SIGKILL'}]);
  h.set([sentinel]);h.tracker.observe();assert.equal(h.tracker.snapshot().drained,true);
});
test('real kernel query observes escaped process birth uid executable and actual environment marker',async t=>{
  const token=randomUUID();
  const host=spawn(process.execPath,['-e','process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,PICSEE_TEST_RUN_TOKEN:token},stdio:['ignore','ignore','ignore','ipc']});
  t.after(()=>{host.kill('SIGKILL');host.unref();});
  await new Promise(resolve=>host.once('message',resolve));
  const snapshot=queryHostProcesses({token,executable,uid,pids:[host.pid]});
  t.diagnostic(JSON.stringify({kernelQuery:snapshot}));
  assert.equal(snapshot.complete,true);assert.equal(snapshot.processes.length,1);
  const actual=snapshot.processes[0];assert.equal(actual.pid,host.pid);assert.equal(actual.uid,uid);
  t.diagnostic(JSON.stringify({kernelHost:actual}));
  assert.equal(actual.executable,executable);assert.equal(actual.marker,token);assert.match(actual.birth,/^\d+:\d+$/);
});

test('PID birth changed between TERM and KILL is never signaled again',()=>{
  const h=harness();h.tracker.observe();h.tracker.signalOwned('SIGTERM');
  h.set([identity({birth:'200:654321'})]);h.tracker.signalOwned('SIGKILL');
  assert.deepEqual(h.signals,[{pid:12345,name:'SIGTERM'}]);assert.equal(h.tracker.snapshot().drained,false);
});

test('unreadable unrelated uid does not poison drain but a known PID with changed uid fails closed',()=>{
  let records=[identity()],unknown=[{pid:54321,uid:uid+1,reason:'unreadable unrelated executable'}];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,
    query:()=>({complete:true,processes:records,unknown}),signal:()=>assert.fail('no signaling expected')});
  tracker.observe();records=[];tracker.observe();assert.equal(tracker.snapshot().drained,true);
  unknown=[{pid:12345,uid:uid+1,reason:'known PID changed uid'}];tracker.observe();
  assert.equal(tracker.snapshot().drained,false);
});

test('OS query failures expose bounded transport facts without leaking child output or environment',()=>{
  const cases=[
    {run:{status:null,signal:'SIGTERM',error:{code:'ETIMEDOUT'},stdout:'secret stdout',stderr:'secret stderr'},stage:'process',code:'ETIMEDOUT'},
    {run:{status:1,stdout:'',stderr:'private traceback'},stage:'process',code:null},
    {run:{status:0,stdout:'malformed private payload',stderr:''},stage:'json',code:null},
    {run:{status:0,stdout:'{}',stderr:''},stage:'schema',code:null}
  ];
  for(const c of cases){let time=100;
    const result=queryHostProcesses({token:'invocation-A',executable,uid,now:()=>{time+=25;return time;},spawn:()=>c.run});
    assert.equal(result.complete,false);assert.equal(result.transport?.stage,c.stage);
    assert.equal(result.transport.errorCode,c.code);assert.equal(result.transport.elapsedMilliseconds,25);
    assert.equal(result.transport.timeoutMilliseconds,1000);assert.equal(result.transport.status,c.run.status);
    assert.equal(result.transport.signal,c.run.signal??null);
    assert.equal(result.transport.stdoutBytes,Buffer.byteLength(c.run.stdout));assert.equal(result.transport.stderrBytes,Buffer.byteLength(c.run.stderr));
    assert.equal(JSON.stringify(result).includes('secret'),false);assert.equal(JSON.stringify(result).includes('private'),false);
  }
});

test('failed query transport facts survive ownership refusal for diagnosis',()=>{
  const transport={stage:'process',status:null,signal:'SIGTERM',errorCode:'ETIMEDOUT',elapsedMilliseconds:1002,timeoutMilliseconds:1000,stdoutBytes:0,stderrBytes:0};
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,query:()=>({complete:false,processes:[],unknown:[{reason:'OS ownership inspection failed'}],transport})});
  tracker.observe();const result=tracker.snapshot();assert.equal(result.drained,false);
  assert.deepEqual(result.queryFailures?.[0].transport,transport);
});
