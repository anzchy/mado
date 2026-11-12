import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {realpathSync} from 'node:fs';
import {queryHostProcesses,createHostOwnership,createAsyncHostOwnership} from './app-host-ownership.mjs';

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
    assert.equal(result.transport.timeoutMilliseconds,5000);assert.equal(result.transport.status,c.run.status);
    assert.equal(result.transport.signal,c.run.signal??null);
    assert.equal(result.transport.stdoutBytes,Buffer.byteLength(c.run.stdout));assert.equal(result.transport.stderrBytes,Buffer.byteLength(c.run.stderr));
    assert.equal(JSON.stringify(result).includes('secret'),false);assert.equal(JSON.stringify(result).includes('private'),false);
  }
});

test('slow OS inspector can observe a host before the ownership drain deadline',()=>{
  const token='i657-slow-inspector',record=identity({marker:token});
  const reply=JSON.stringify({complete:true,processes:[record],unknown:[]});
  const spawn=(_command,_args,options)=>spawnSync('/usr/bin/python3',
    ['-c','import sys,time;time.sleep(1.5);sys.stdout.write(sys.argv[1])',reply],options);
  const tracker=createHostOwnership({token,executable,uid,
    query:()=>queryHostProcesses({token,executable,uid,spawn})});
  tracker.observe();
  const snapshot=tracker.snapshot();
  assert.equal(snapshot.observed,true,'a 1.5-second OS reply must register as an observation');
  assert.equal(snapshot.drained,false,'a live matching host still prevents drain');
  assert.deepEqual(snapshot.unknown,[]);
  assert.deepEqual(snapshot.queryFailures,[]);
});

test('failed query transport facts survive ownership refusal for diagnosis',()=>{
  const transport={stage:'process',status:null,signal:'SIGTERM',errorCode:'ETIMEDOUT',elapsedMilliseconds:1002,timeoutMilliseconds:1000,stdoutBytes:0,stderrBytes:0};
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,query:()=>({complete:false,processes:[],unknown:[{reason:'OS ownership inspection failed'}],transport})});
  tracker.observe();const result=tracker.snapshot();assert.equal(result.drained,false);
  assert.deepEqual(result.queryFailures?.[0].transport,transport);
});

test('historical transport uncertainty recovers only through full registration and current identity checks',()=>{
  let complete=false,records=[];const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,
    query:()=>({complete,processes:records,unknown:complete?[]:[{reason:'transport unavailable'}],transport:{stage:'process',errorCode:'ETIMEDOUT'}}),
    signal:(pid,name)=>signals.push({pid,name})});
  tracker.observe();assert.equal(tracker.snapshot().drained,false);
  complete=true;records=[identity()];tracker.observe();tracker.signalOwned('SIGTERM');tracker.signalOwned('SIGKILL');
  assert.deepEqual(signals,[{pid:12345,name:'SIGTERM'},{pid:12345,name:'SIGKILL'}]);
  records=[];tracker.observe();assert.equal(tracker.snapshot().drained,true);assert.deepEqual(tracker.snapshot().unknown,[]);
  assert.equal(tracker.snapshot().queryFailures.length,1);assert.equal(tracker.snapshot().queryFailures[0].transport.errorCode,'ETIMEDOUT');
});

test('current unreadable query denies signaling and specific success cannot replace a fresh full scan',()=>{
  let records=[identity()],complete=true;const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,
    query:()=>({complete,processes:records,unknown:complete?[]:[{reason:'unreadable current state'}]}),
    signal:(pid,name)=>signals.push({pid,name})});
  tracker.observe();complete=false;tracker.signalOwned('SIGTERM');assert.deepEqual(signals,[]);
  complete=true;tracker.signalOwned('SIGKILL');assert.deepEqual(signals,[],'specific success cannot restore lost registration');
  tracker.observe();tracker.signalOwned('SIGTERM');assert.deepEqual(signals,[{pid:12345,name:'SIGTERM'}]);
  records=[];tracker.observe();assert.equal(tracker.snapshot().drained,true);
  complete=false;tracker.observe();assert.equal(tracker.snapshot().drained,false);
  complete=true;tracker.signalOwned('SIGKILL');assert.equal(tracker.snapshot().drained,false,'drain requires a subsequent full scan');
  tracker.observe();assert.equal(tracker.snapshot().drained,true);
});

test('proven identity violations stay sticky despite later matching records and transport recovery',()=>{
  for(const changed of [identity({birth:'100:123457'}),identity({uid:uid+1}),identity({executable:'/other'}),identity({marker:'old-invocation'})]){
    let records=[identity()];const signals=[];
    const tracker=createHostOwnership({token:'invocation-A',executable,uid,query:()=>({complete:true,processes:records,unknown:[]}),signal:(pid,name)=>signals.push({pid,name})});
    tracker.observe();tracker.signalOwned('SIGTERM');records=[changed];tracker.signalOwned('SIGKILL');
    records=[identity()];tracker.observe();tracker.signalOwned('SIGKILL');records=[];tracker.observe();
    assert.deepEqual(signals,[{pid:12345,name:'SIGTERM'}]);assert.equal(tracker.snapshot().drained,false);
    assert.equal(tracker.snapshot().unknown.some(reason=>reason.includes('identity changed')),true);
  }
});

test('recovery preserves bounded failed-query history without permanent signal veto',()=>{
  let complete=false,records=[];const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,query:()=>({complete,processes:records,unknown:complete?[]:[{reason:'query failed'}]}),signal:(pid,name)=>signals.push({pid,name})});
  for(let i=0;i<20;i++)tracker.observe();assert.equal(tracker.snapshot().queryFailures.length,16);
  complete=true;records=[identity()];tracker.observe();tracker.signalOwned('SIGTERM');records=[];tracker.observe();
  assert.deepEqual(signals,[{pid:12345,name:'SIGTERM'}]);assert.equal(tracker.snapshot().drained,true);
  assert.equal(tracker.snapshot().queryFailures.length,16);
});

test('independently known UID change on a registered PID remains an identity violation',()=>{
  let records=[identity()],unknown=[];const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,query:()=>({complete:true,processes:records,unknown}),signal:(pid,name)=>signals.push({pid,name})});
  tracker.observe();records=[];unknown=[{pid:12345,uid:uid+1,reason:'kernel UID changed'}];tracker.observe();
  records=[identity()];unknown=[];tracker.observe();tracker.signalOwned('SIGTERM');records=[];tracker.observe();
  assert.deepEqual(signals,[]);assert.equal(tracker.snapshot().drained,false);
});

test('a fresh specific live-PID observation invalidates an earlier empty global drain observation',()=>{
  let full=[identity()],specific=[identity()];const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,
    query:({pids})=>({complete:true,processes:pids?specific:full,unknown:[]}),signal:(pid,name)=>signals.push({pid,name})});
  tracker.observe();full=[];tracker.observe();assert.equal(tracker.snapshot().drained,true);
  tracker.signalOwned('SIGTERM');assert.deepEqual(signals,[{pid:12345,name:'SIGTERM'}]);
  assert.equal(tracker.snapshot().drained,false,'newer live-PID evidence supersedes earlier empty scan');
  specific=[];tracker.signalOwned('SIGKILL');assert.equal(tracker.snapshot().drained,false,'specific absence cannot prove full drain');
  tracker.observe();assert.equal(tracker.snapshot().drained,true);
});

test('TERM authorization that crosses the fixed grace boundary does not send an obsolete signal',()=>{
  let time=0;const signals=[];
  const tracker=createHostOwnership({token:'invocation-A',executable,uid,now:()=>time,
    query:({pids})=>{if(pids)time=81;return {complete:true,processes:[identity()],unknown:[]};},
    signal:(pid,name)=>signals.push({pid,name})});
  tracker.observe();tracker.signalOwned('SIGTERM',{notAfter:80});
  assert.deepEqual(signals,[],'the current PID query finished after TERM phase ended');
  tracker.signalOwned('SIGKILL');assert.deepEqual(signals,[{pid:12345,name:'SIGKILL'}]);
});

test('async authority preserves exact identity mutations, recovery history and global drain semantics',async()=>{
  for(const change of [{birth:'100:2'},{uid:uid+1},{executable:'/other'},{marker:'other'}]){
    let records=[identity()],complete=true;const signals=[];
    const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,
      query:async()=>({complete,processes:records,unknown:complete?[]:[{reason:'unreadable'}]}),signal:(pid,name)=>signals.push({pid,name})});
    await tracker.observe();assert.equal(tracker.snapshot().observed,true);
    records=[identity(change)];await tracker.signalOwned('SIGTERM');records=[identity()];await tracker.observe();
    await tracker.signalOwned('SIGKILL');records=[];await tracker.observe();
    assert.deepEqual(signals,[]);assert.equal(tracker.snapshot().drained,false);
  }
  let records=[identity()],complete=false;const signals=[];
  const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,
    query:async()=>({complete,processes:records,unknown:complete?[]:[{reason:'transport'}]}),signal:(pid,name)=>signals.push({pid,name})});
  await tracker.observe();complete=true;await tracker.observe();await tracker.signalOwned('SIGTERM');
  records=[];await tracker.signalOwned('SIGKILL');assert.equal(tracker.snapshot().drained,false);
  await tracker.observe();assert.equal(tracker.snapshot().drained,true);assert.equal(tracker.snapshot().queryFailures.length,1);
  assert.deepEqual(signals,[{pid:12345,name:'SIGTERM'}]);
});

test('async pending observation cannot apply expired epoch authority or overlap a second operation',async()=>{
  let release,requests=0,epoch=0;const signals=[];
  const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,
    query:()=>{requests++;return new Promise(resolve=>release=resolve);},signal:(pid,name)=>signals.push({pid,name})});
  const pending=tracker.observe({notAfter:Date.now()+1000,isCurrent:()=>epoch===0});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(typeof release,'function');
  await tracker.signalOwned('SIGTERM');assert.equal(requests,1);assert.deepEqual(signals,[]);
  epoch++;release({complete:true,processes:[identity()],unknown:[]});await pending;
  assert.equal(tracker.snapshot().observed,false);assert.equal(tracker.snapshot().drained,false);
});

test('async before-signal authorization obeys fixed expiry after await and never signals sentinel',async()=>{
  let time=0,records=[identity(),identity({pid:54321,marker:'sentinel'})];const signals=[];
  const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,now:()=>time,
    query:async({pids})=>{if(pids)time=80;return {complete:true,processes:records,unknown:[]};},signal:(pid,name)=>signals.push({pid,name})});
  await tracker.observe();assert.equal(tracker.snapshot().observed,true);
  await tracker.signalOwned('SIGTERM',{notAfter:80});assert.deepEqual(signals,[]);
  await tracker.signalOwned('SIGKILL',{notAfter:1080});assert.deepEqual(signals,[{pid:12345,name:'SIGKILL'}]);
  records=[identity({pid:54321,marker:'sentinel'})];await tracker.observe();assert.equal(tracker.snapshot().drained,true);
});

test('async adapter retains at most sixteen failed-query diagnostics through recovery',async()=>{
  let complete=false,records=[identity()];
  const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,
    query:async()=>({complete,processes:records,unknown:complete?[]:[{reason:'unreadable'}]}),signal:()=>{}});
  for(let i=0;i<20;i++)await tracker.observe();assert.equal(tracker.snapshot().queryFailures.length,16);
  complete=true;await tracker.observe();await tracker.signalOwned('SIGTERM');records=[];await tracker.observe();
  assert.equal(tracker.snapshot().drained,true);assert.equal(tracker.snapshot().queryFailures.length,16);
});

test('async current unreadable PID reply cannot authorize matching-looking identities or targeted-only recovery',async()=>{
  let complete=true,reads=0;const signals=[];
  const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,
    query:async()=>{reads++;return {complete,processes:[identity()],unknown:[]};},signal:(pid,name)=>signals.push({pid,name})});
  await tracker.observe();assert.equal(tracker.snapshot().observed,true);
  complete=false;await tracker.signalOwned('SIGTERM');await tracker.signalOwned('SIGKILL');
  assert.deepEqual(signals,[]);assert.equal(tracker.snapshot().drained,false);
  complete=true;await tracker.signalOwned('SIGKILL');assert.deepEqual(signals,[],'a targeted success cannot restore full registration');
  await tracker.observe();await tracker.signalOwned('SIGKILL');assert.deepEqual(signals,[{pid:12345,name:'SIGKILL'}]);
  assert.equal(reads>=4,true);assert.equal(tracker.snapshot().queryFailures.length>=1,true);
});

for(const mode of ['expired','superseded'])test(`async ${mode} observation invalidates prior successful drain while held and after late reply`,async()=>{
  let records=[identity()],holding=false,release,time=0,epoch=0;const signals=[];
  const tracker=createAsyncHostOwnership({token:'invocation-A',executable,uid,now:()=>time,
    query:async()=>holding?await new Promise(resolve=>release=resolve):{complete:true,processes:records,unknown:[]},signal:(pid,name)=>signals.push({pid,name})});
  await tracker.observe();records=[];await tracker.observe();assert.equal(tracker.snapshot().drained,true);
  holding=true;const pending=tracker.observe({notAfter:80,isCurrent:()=>epoch===0});await new Promise(resolve=>setImmediate(resolve));
  try{
    assert.equal(typeof release,'function');assert.equal(tracker.snapshot().drained,false,'pending required observation invalidates older drain');
    if(mode==='expired')time=80;else epoch++;
    holding=false;records=[identity()];release({complete:true,processes:records,unknown:[]});await pending;
    assert.equal(tracker.snapshot().drained,false);
    await tracker.signalOwned('SIGKILL');assert.deepEqual(signals,[],'late data cannot restore current registration');
    await tracker.observe();await tracker.signalOwned('SIGKILL');assert.deepEqual(signals,[{pid:12345,name:'SIGKILL'}]);
  }finally{holding=false;release?.({complete:true,processes:[],unknown:[]});await pending;}
});

for(const kind of ['sync','async'])test(`correlated privacy fields cannot escape through the ${kind} ownership policy`,async()=>{
  let complete=true,records=[{...identity(),extra:'PRIVATE_ENV_CONTENT'}];
  const result=()=>({complete,processes:records,unknown:complete?[]:[{pid:12345,reason:'PRIVATE_ENV_CONTENT'}],
    transport:{stage:'process',status:null,signal:null,errorCode:'ETIMEDOUT',elapsedMilliseconds:1000,timeoutMilliseconds:1000,
      stdoutBytes:0,stderrBytes:0,stdout:'PRIVATE_ENV_CONTENT',env:{payload:'PRIVATE_ENV_CONTENT'}}});
  const tracker=(kind==='sync'?createHostOwnership:createAsyncHostOwnership)({token:'invocation-A',executable,uid,
    query:kind==='sync'?result:async()=>result(),signal:()=>{}});
  await tracker.observe();assert.equal(JSON.stringify(tracker.snapshot()).includes('PRIVATE_ENV_CONTENT'),false);
  complete=false;records=[];await tracker.observe();assert.equal(JSON.stringify(tracker.snapshot()).includes('PRIVATE_ENV_CONTENT'),false);
});

for(const kind of ['sync','async'])test(`non-string birth cannot register or prove drain in ${kind} ownership`,async()=>{
  let records=[identity({birth:['100:123456']})];const signals=[];
  const result=()=>({complete:true,processes:records,unknown:[]});
  const tracker=(kind==='sync'?createHostOwnership:createAsyncHostOwnership)({token:'invocation-A',executable,uid,
    query:kind==='sync'?result:async()=>result(),signal:(pid,name)=>signals.push({pid,name})});
  await tracker.observe();assert.equal(tracker.snapshot().observed,false);
  await tracker.signalOwned('SIGTERM');records=[];await tracker.observe();
  assert.equal(tracker.snapshot().drained,false);assert.deepEqual(signals,[]);
});
