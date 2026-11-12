// Deterministic R2 orchestration regressions follow; real OS assertions moved intact to integration/.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,existsSync,rmSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {randomUUID} from 'node:crypto';
import {prepareHostInspector} from './app-host-inspector.mjs';
import {runProcessGroup} from './app-repeat-process.mjs';
import {externalInspectorFixture} from './fixtures/host-inspector-process.mjs';
const turn=()=>new Promise(resolve=>setImmediate(resolve));
function directory(t){return mkdtempSync(path.join(tmpdir(),'r2-supervisor-'));}
function finish(t,pending,o){t.after(async()=>{process.emit('SIGTERM');await pending;rmSync(path.dirname(o.logPath),{recursive:true,force:true});});}
async function waitForFileText(file,needle,pending){
  const until=Date.now()+5000;
  while(Date.now()<until){
    if(existsSync(file)&&readFileSync(file,'utf8').includes(needle))return;
    if(await Promise.race([pending.then(()=>true),new Promise(resolve=>setTimeout(()=>resolve(false),10))]))break;
  }
  assert.fail(`expected ${needle} before supervisor settled; log: ${existsSync(file)?readFileSync(file,'utf8'):'missing'}`);
}
const identity=token=>({pid:43210,birth:'100:1',uid:process.getuid(),executable:realpathSync(process.execPath),marker:token,ppid:1,pgid:43210});
function options(t,extra={}){
  const dir=directory(t),token='r2-'+path.basename(dir),marker=path.join(dir,'worker');
  return {command:process.execPath,args:['-e',`require('node:fs').writeFileSync(${JSON.stringify(marker)},'started');setInterval(()=>{},1000)`],
    env:{...process.env,MADO_TEST_RUN_TOKEN:token,MADO_HOST_EXECUTABLE:realpathSync(process.execPath),MADO_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath:path.join(dir,'log'),deadline:Date.now()+10000,graceMs:80,drainMs:1000,marker,...extra};
}

test('worker cannot start before inspector READY or after cancelled startup',async t=>{
  const f=externalInspectorFixture(t,{gated:true}),abort=new AbortController(),o=options(t);
  const result=runProcessGroup({...o,inspectorSpawn:f.spawn,signal:abort.signal});finish(t,result,o);
  await turn();assert.ok(f.child,'inspector must start before worker');await f.boot;
  assert.equal(existsSync(o.marker),false);abort.abort();const stopped=await result;
  assert.equal(stopped.status,70);assert.equal(stopped.drained,false);assert.equal(existsSync(o.marker),false);
  assert.equal(stopped.inspector.closed,true);assert.equal(stopped.inspector.reaped,true);
});

test('READY releases exactly one worker and supervisor closes its transferred inspector',async t=>{
  const f=externalInspectorFixture(t,{gated:true}),o=options(t);
  o.args=['-e',`require('node:fs').appendFileSync(${JSON.stringify(o.marker)},${JSON.stringify('one\n')})`];
  const pending=runProcessGroup({...o,inspectorSpawn:f.spawn});finish(t,pending,o);
  await turn();assert.ok(f.child);await f.boot;assert.equal(existsSync(o.marker),false);f.send({ready:true});
  const result=await pending;assert.equal(existsSync(o.marker),true);assert.equal(readFileSync(o.marker,'utf8'),'one\n');
  assert.equal(result.status,70);assert.equal(result.hostOwnership.observed,false);
  assert.equal(result.inspector.closed,true);assert.equal(result.inspector.reaped,true);
});

test('pending async query allows stop notification and event-loop sentinel without overlapping control',async t=>{
  const f=externalInspectorFixture(t),o=options(t),abort=new AbortController();let release,active=0,maximum=0,queries=0;
  const journal=[],hostQuery=async()=>{queries++;active++;maximum=Math.max(maximum,active);
    try{if(queries===1)return await new Promise(resolve=>release=resolve);return {complete:true,processes:[],unknown:[]};}
    finally{active--;}};
  const pending=runProcessGroup({...o,inspectorSpawn:f.spawn,hostQuery,signal:abort.signal});finish(t,pending,o);
  await turn();assert.ok(f.child);await f.boot;
  while(!release)await turn();abort.abort();await turn();journal.push('event-loop-sentinel');
  assert.deepEqual(journal,['event-loop-sentinel']);assert.equal(active,1);assert.equal(maximum,1);
  release({complete:true,processes:[identity(o.env.MADO_TEST_RUN_TOKEN)],unknown:[]});
  const result=await pending;assert.equal(result.status,70);assert.equal(result.hostOwnership.signals.length,0);
  assert.equal(maximum,1);assert.equal(result.inspector.closed,true);
});

test('fixed cleanup phases include first awaited authorization and recover only current KILL phase',async t=>{
  const f=externalInspectorFixture(t),o=options(t);let now=1000,records=[identity(o.env.MADO_TEST_RUN_TOKEN)],killFailures=0;
  const signals=[],budgets=[];
  const hostQuery=async request=>{
    budgets.push({signal:request.cleanupSignal,notAfter:request.notAfter});
    if(request.cleanupSignal==='SIGTERM')now=1080;
    if(request.cleanupSignal==='SIGKILL'&&killFailures++===0)return {complete:false,processes:[],unknown:[{reason:'first KILL query failed'}]};
    return {complete:true,processes:records,unknown:[]};
  };
  const hostSignal=(pid,name)=>{signals.push({pid,name,at:now});records=[];};
  const pending=runProcessGroup({...o,deadline:5000,now:()=>now,inspectorSpawn:f.spawn,hostQuery,hostSignal,cancelOnHostObserved:true});finish(t,pending,o);
  await turn();assert.ok(f.child);const result=await pending;
  assert.equal(result.cleanup.graceStartedAt,1000);assert.equal(result.cleanup.graceDeadline,1080);assert.equal(result.cleanup.drainDeadline,2080);
  assert.deepEqual(signals,[{pid:43210,name:'SIGKILL',at:1080}]);assert.equal(killFailures>=2,true);
  assert.equal(budgets.filter(b=>b.signal==='SIGTERM').every(b=>b.notAfter===1080),true);
  assert.equal(budgets.filter(b=>b.signal==='SIGKILL').every(b=>b.notAfter===2080),true);
  assert.equal(result.drained,true);assert.equal(result.inspector.reaped,true);
});

test('expired startup and unreaped inspector cannot claim drain or launch a next worker',async t=>{
  const o=options(t,{deadline:Date.now()-1});let spawns=0;
  const result=await runProcessGroup({...o,inspectorSpawn:()=>{spawns++;throw new Error('unexpected spawn');}});
  assert.equal(result.drained,false,'expired hosted preparation has no ownership/drain proof');
  assert.equal(result.status,70);assert.equal(spawns,0);assert.equal(existsSync(o.marker),false);rmSync(path.dirname(o.logPath),{recursive:true,force:true});
  const f=externalInspectorFixture(t,{gated:true}),abort=new AbortController(),next=options(t);
  const pending=runProcessGroup({...next,inspectorSpawn:f.spawn,signal:abort.signal});finish(t,pending,next);
  await turn();assert.ok(f.child);await f.boot;abort.abort();const stopped=await pending;
  assert.equal(stopped.drained,false);assert.equal(stopped.inspector.reaped,true);
});

test('deadline timer rechecks the clock before beginning cleanup',async t=>{
  const o=options(t,{env:{},deadline:Date.now()+200,graceMs:20,drainMs:200});
  let reads=0;
  const now=()=>Date.now()+(++reads<=2?30:0);
  const pending=runProcessGroup({...o,now});finish(t,pending,o);
  const result=await pending;
  assert.equal(result.status,70);
  assert.ok(result.cleanup.graceStartedAt>=o.deadline,
    `cleanup started before the original deadline: ${JSON.stringify(result.cleanup)}`);
});

test('awaited authorization consuming the original final drain never sends a signal or renews cleanup',async t=>{
  const f=externalInspectorFixture(t),o=options(t);let time=1000;const signals=[];
  const hostQuery=async({pids})=>{if(pids)time=2080;return {complete:true,processes:[identity(o.env.MADO_TEST_RUN_TOKEN)],unknown:[]};};
  const pending=runProcessGroup({...o,deadline:5000,now:()=>time,inspectorSpawn:f.spawn,hostQuery,
    hostSignal:(pid,name)=>signals.push({pid,name}),cancelOnHostObserved:true});finish(t,pending,o);
  await turn();assert.ok(f.child);const result=await pending;
  assert.equal(result.cleanup.graceDeadline,1080);assert.equal(result.cleanup.drainDeadline,2080);
  assert.equal(result.drained,false);assert.deepEqual(signals,[]);assert.equal(result.status,70);
});

test('host and group drain cannot hide an inspector whose close and reap remain unproven',async t=>{
  const o=options(t);let child,records=[identity(o.env.MADO_TEST_RUN_TOKEN)];
  const inspectorSpawn=(_command,args)=>{
    child=new EventEmitter();child.pid=76543;child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();
    child.kill=()=>true;child.unref=()=>{};
    child.stdin.on('data',chunk=>{for(const line of chunk.toString().trim().split('\n')){const request=JSON.parse(line);
      child.stdout.write(JSON.stringify({protocol:1,type:'result',generation:request.generation,requestId:request.requestId,
        snapshot:{complete:true,processes:records,unknown:[]}})+'\n');}});
    queueMicrotask(()=>child.stdout.write(JSON.stringify({protocol:1,type:'ready',generation:args.at(-1)})+'\n'));return child;
  };
  t.after(()=>{if(child){child.emit('close',null,'SIGKILL');child.stdin.destroy();child.stdout.destroy();child.stderr.destroy();}});
  const pending=runProcessGroup({...o,inspectorSpawn,hostSignal:()=>{records=[];},cancelOnHostObserved:true});finish(t,pending,o);
  await turn();assert.ok(child,'external inspector must be prepared');const result=await pending;
  assert.equal(result.status,70);assert.equal(result.hostOwnership.drained,true);assert.equal(result.drained,false);
  assert.equal(result.inspector.closed,false);assert.equal(result.inspector.reaped,false);
});

test('pending process-group query is awaitable and does not block interruption or overlap another group query',async t=>{
  const o=options(t),abort=new AbortController();let release,settled=false,active=0,maximum=0;
  const groupQuery=async()=>{active++;maximum=Math.max(maximum,active);try{
    if(!release)return await new Promise(resolve=>release=resolve);return [];
  }finally{active--;}};
  const pending=runProcessGroup({...o,env:{},args:['-e','console.log("group-query")'],groupQuery,signal:abort.signal});
  pending.then(()=>settled=true);finish(t,pending,o);
  while(!release&&!settled)await turn();assert.equal(typeof release,'function');
  abort.abort();let sentinel=false;await turn();sentinel=true;
  assert.equal(sentinel,true);assert.equal(maximum,1);release([]);
  const result=await pending;assert.equal(result.status,70);assert.equal(maximum,1);
});

test('stop notification freezes cleanup journal before a later held query reply is released',async t=>{
  const f=externalInspectorFixture(t),o=options(t),abort=new AbortController();let now=1000,release,queries=0;
  const hostQuery=async()=>{if(queries++===0)return await new Promise(resolve=>release=resolve);return {complete:true,processes:[],unknown:[]};};
  const pending=runProcessGroup({...o,deadline:5000,now:()=>now,inspectorSpawn:f.spawn,hostQuery,signal:abort.signal});finish(t,pending,o);
  await turn();assert.ok(f.child);await f.boot;while(!release)await turn();
  abort.abort();await turn();assert.equal(existsSync(o.logPath),true);
  const records=readFileSync(o.logPath,'utf8').split('\n').filter(line=>line.startsWith('app-repeat: cleanup '));
  assert.equal(records.length,1,'stop journal must exist while the query is still held');
  const frozen=JSON.parse(records[0].slice('app-repeat: cleanup '.length));
  assert.equal(frozen.graceStartedAt,1000);assert.equal(frozen.graceDeadline,1080);assert.equal(frozen.drainDeadline,2080);
  now=1100;release({complete:true,processes:[identity(o.env.MADO_TEST_RUN_TOKEN)],unknown:[]});await turn();now=2080;
  const result=await pending;assert.deepEqual(result.cleanup,frozen);assert.equal(result.hostOwnership.signals.length,0);
  assert.equal(result.status,70);assert.equal(result.drained,false);
});

test('stale pre-host observation cannot declare registration missing after leader exit',async t=>{
  const f=externalInspectorFixture(t),o=options(t);
  o.args=['-e',`require('node:fs').writeFileSync(${JSON.stringify(o.marker)},String(process.pid))`];
  let releaseFirst,leaderExited,queries=0,groupQueries=0;
  const exitObserved=new Promise(resolve=>leaderExited=resolve);
  const hostQuery=async()=>{
    queries++;
    if(queries===1)return await new Promise(resolve=>releaseFirst=resolve);
    if(queries===2)return {complete:true,processes:[identity(o.env.MADO_TEST_RUN_TOKEN)],unknown:[]};
    return {complete:true,processes:[],unknown:[]};
  };
  const groupQuery=async()=>{groupQueries++;return [];};
  const pending=runProcessGroup({...o,inspectorSpawn:f.spawn,hostQuery,groupQuery,onLeaderExit:leaderExited});finish(t,pending,o);
  const until=Date.now()+3000;
  while((!releaseFirst||!existsSync(o.marker))&&Date.now()<until)await turn();
  assert.equal(typeof releaseFirst,'function','the ownership query starts before the leader exits');
  assert.equal(existsSync(o.marker),true,'the leader starts and exits while the first query is held');
  let exitTimer;
  try{await Promise.race([exitObserved,new Promise((_,reject)=>{
    exitTimer=setTimeout(()=>reject(new Error('leader exit was not observed')),3000);
  })]);}finally{clearTimeout(exitTimer);}
  // Release only after the supervisor has stored childExit. A host first seen
  // after the fresh snapshot, or born and gone between snapshots, still fails
  // closed with 70; this test covers the stale first snapshot ordering only.
  releaseFirst({complete:true,processes:[],unknown:[]});
  const result=await pending;
  assert.equal(result.status,0,readFileSync(o.logPath,'utf8'));
  assert.equal(result.hostOwnership.observed,true,'a fresh post-exit query registers the host');
  assert.equal(result.drained,true);
  assert.equal(result.cleanup,undefined,'natural drain needs no forced cleanup');
  assert.ok(groupQueries>=1,'the empty leader group is observed');
  assert.ok(queries>=3,'the host is observed and then proven drained');
});

test('owned host may exit shortly after its iteration leader without forced cleanup',async t=>{
  const dir=directory(t),token=randomUUID(),marker=path.join(dir,'host-pid'),release=path.join(dir,'release');
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const inspector=await prepareHostInspector({deadline:Date.now()+10000});
  assert.equal(inspector.ready,true);t.after(()=>inspector.close());
  const hostSource=`const fs=require('node:fs');fs.writeFileSync(${JSON.stringify(marker)},String(process.pid));process.send('ready');const poll=setInterval(()=>{if(fs.existsSync(${JSON.stringify(release)})){clearInterval(poll);setTimeout(()=>process.exit(0),500);}},10);`;
  const leaderSource=`const {spawn}=require('node:child_process');const host=spawn(process.execPath,['-e',${JSON.stringify(hostSource)}],{detached:true,stdio:['ignore','ignore','ignore','ipc']});host.once('message',()=>process.exit(0));`;
  const logPath=path.join(dir,'iteration.log');
  const pending=runProcessGroup({command:process.execPath,args:['-e',leaderSource],preparedInspector:inspector,
    env:{...process.env,MADO_TEST_RUN_TOKEN:token,MADO_HOST_EXECUTABLE:realpathSync(process.execPath),MADO_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath,deadline:Date.now()+4000,graceMs:80,drainMs:1000});
  await waitForFileText(logPath,'iteration leader exited; waiting for 1 live owned/group processes',pending);
  writeFileSync(release,'go');
  const result=await pending;
  assert.equal(existsSync(marker),true,'the host must start before its leader exits');
  assert.equal(result.hostOwnership.observed,true,'the real inspector must observe the owned host');
  assert.equal(result.status,0,readFileSync(logPath,'utf8'));
  assert.equal(result.drained,true);
  assert.equal(result.cleanup,undefined,'natural host exit should not enter cleanup');
  assert.match(readFileSync(logPath,'utf8'),/iteration leader exited; waiting for 1 live owned\/group processes/);
});

test('owned host that outlives the run deadline is killed and proven drained',async t=>{
  const dir=directory(t),token=randomUUID(),marker=path.join(dir,'host-pid');
  t.after(()=>{if(existsSync(marker))try{process.kill(Number(readFileSync(marker,'utf8')),'SIGKILL');}catch{}rmSync(dir,{recursive:true,force:true});});
  const inspector=await prepareHostInspector({deadline:Date.now()+10000});
  assert.equal(inspector.ready,true);t.after(()=>inspector.close());
  const hostSource=`require('node:fs').writeFileSync(${JSON.stringify(marker)},String(process.pid));process.on('SIGTERM',()=>{});process.send('ready');setInterval(()=>{},1000);`;
  const leaderSource=`const {spawn}=require('node:child_process');const host=spawn(process.execPath,['-e',${JSON.stringify(hostSource)}],{detached:true,stdio:['ignore','ignore','ignore','ipc']});host.once('message',()=>process.exit(0));`;
  const logPath=path.join(dir,'iteration.log'),deadline=Date.now()+1500;
  const result=await runProcessGroup({command:process.execPath,args:['-e',leaderSource],preparedInspector:inspector,
    env:{...process.env,MADO_TEST_RUN_TOKEN:token,MADO_HOST_EXECUTABLE:realpathSync(process.execPath),MADO_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath,deadline,graceMs:80,drainMs:1000});
  assert.equal(existsSync(marker),true);
  assert.equal(result.hostOwnership.observed,true);
  assert.equal(result.status,70);
  assert.equal(result.drained,true);
  assert.equal(result.hostOwnership.drained,true);
  assert.equal(result.hostOwnership.signals.some(sent=>sent.signal==='SIGKILL'),true);
  assert.equal(result.cleanup.graceStartedAt>=deadline-2,true,
    'cleanup begins at the original run deadline, allowing timer rounding\n'+readFileSync(logPath,'utf8'));
  assert.equal(result.cleanup.graceStartedAt<=deadline+250,true,
    'cleanup must not extend the original run deadline\n'+readFileSync(logPath,'utf8'));
});

test('leader group member that exits shortly later completes without cleanup',async t=>{
  const dir=directory(t),marker=path.join(dir,'member-pid'),release=path.join(dir,'release'),logPath=path.join(dir,'iteration.log');
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const memberSource=`const fs=require('node:fs');fs.writeFileSync(${JSON.stringify(marker)},String(process.pid));process.send('ready');const poll=setInterval(()=>{if(fs.existsSync(${JSON.stringify(release)})){clearInterval(poll);setTimeout(()=>process.exit(0),400);}},10);`;
  const leaderSource=`const {spawn}=require('node:child_process');const member=spawn(process.execPath,['-e',${JSON.stringify(memberSource)}],{stdio:['ignore','ignore','ignore','ipc']});member.once('message',()=>process.exit(0));`;
  const pending=runProcessGroup({command:process.execPath,args:['-e',leaderSource],logPath,deadline:Date.now()+4000});
  await waitForFileText(logPath,'iteration leader exited; waiting for 1 live owned/group processes',pending);
  writeFileSync(release,'go');
  const result=await pending;
  assert.equal(existsSync(marker),true);
  assert.equal(result.status,0,readFileSync(logPath,'utf8'));
  assert.equal(result.drained,true);
  assert.equal(result.cleanup,undefined,'a short-lived group member should finish naturally');
  const log=readFileSync(logPath,'utf8');
  assert.equal(log.match(/iteration leader exited; waiting for 1 live owned\/group processes/g)?.length,1);
});
