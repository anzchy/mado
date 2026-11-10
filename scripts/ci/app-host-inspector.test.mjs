import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {mkdtempSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {prepareHostInspector} from './app-host-inspector.mjs';

const turn=()=>new Promise(resolve=>setImmediate(resolve));
const owned={pid:321,birth:'100:1',uid:501,executable:'/fixture/Mado',marker:'token',ppid:1,pgid:321};
const snapshot={complete:true,processes:[owned],unknown:[]};
// A separate process implements only the external byte-stream protocol.
const fixtureProgram=String.raw`
const readline=require('node:readline'),generation=process.argv[1],automatic=process.argv[2]==='auto';
const emit=value=>process.stdout.write(JSON.stringify(value)+'\n');
const ready=()=>emit({protocol:1,type:'ready',generation});
process.on('message',m=>{if(m.ready)ready();if(m.raw!==undefined)process.stdout.write(m.raw);if(m.bytes)process.stdout.write(Buffer.from(m.bytes));if(m.stderr!==undefined)process.stderr.write(m.stderr);if(m.reply)emit(m.reply);if(m.exit)process.exit(0);});
readline.createInterface({input:process.stdin}).on('line',line=>{const request=JSON.parse(line);process.send({kind:'request',request});});
process.send({kind:'boot'});if(automatic)ready();
`;
function fixture(t,{auto=true}={}){
  const requests=[],waiters=[];let child,bootResolve,exitResolve,generation;
  let time=0,nextTimer=0;const pendingTimers=new Map();
  const timers={setTimeout:(callback,ms)=>{const id=++nextTimer;pendingTimers.set(id,{callback,due:time+ms});return id;},clearTimeout:id=>pendingTimers.delete(id)};
  const boot=new Promise(resolve=>bootResolve=resolve),exited=new Promise(resolve=>exitResolve=resolve);
  const externalSpawn=(_command,args,options)=>{
    generation=args.at(-1);
    child=spawn(process.execPath,['-e',fixtureProgram,args.at(-1),auto?'auto':'gate'],{...options,stdio:['pipe','pipe','pipe','ipc']});
    child.on('message',m=>{if(m.kind==='boot')bootResolve();if(m.kind==='request'){const waiter=waiters.shift();if(waiter)waiter(m.request);else requests.push(m.request);}});
    child.once('close',(code,signal)=>exitResolve({code,signal}));return child;
  };
  t.after(async()=>{if(child){child.kill('SIGKILL');await exited;}});
  return {spawn:externalSpawn,boot,exited,requests,timers,now:()=>time,advance:to=>{time=to;for(const [id,timer] of pendingTimers)if(timer.due<=time){pendingTimers.delete(id);timer.callback();}},get child(){return child;},get generation(){return generation;},
    next:()=>requests.length?Promise.resolve(requests.shift()):new Promise(resolve=>waiters.push(resolve)),
    send:m=>child.send(m),reply:(request,changes={})=>child.send({reply:{protocol:1,type:'result',generation:request.generation,requestId:request.requestId,snapshot,...changes}})};
}
async function ready(t,options={}){
  const f=fixture(t,options),pending=prepareHostInspector({deadline:10000,spawn:f.spawn,now:f.now,timers:f.timers});
  await turn();assert.ok(f.child,'prepared transport must start the external inspector');await f.boot;
  if(options.auto===false)f.send({ready:true});const session=await pending;assert.equal(session.ready,true);
  t.after(()=>session.close());return {f,session};
}

test('READY is explicit and no query authority exists until correlated current response',async t=>{
  const f=fixture(t,{auto:false});let settled=false;
  const pending=prepareHostInspector({deadline:Date.now()+10000,spawn:f.spawn}).then(value=>{settled=true;return value;});
  await turn();assert.ok(f.child,'external inspector must spawn');await f.boot;await turn();assert.equal(settled,false);
  f.send({ready:true});const session=await pending;assert.equal(session.ready,true);
  const result=session.query({token:'token',executable:owned.executable,uid:501,notAfter:Date.now()+1000});
  const request=await f.next();f.reply(request);const actual=await result;
  assert.equal(actual.complete,true);assert.deepEqual(actual.processes,[owned]);
  assert.equal(actual.transport.generation,session.generation);assert.equal(actual.transport.requestId,request.requestId);
  assert.deepEqual(await session.close(),{closed:true,reaped:true});
});

test('expired, cancelled and exited startup cannot produce READY or leave a live process',async t=>{
  await assert.rejects(prepareHostInspector({deadline:Date.now()-1}),/deadline|expired/i);
  const f=fixture(t,{auto:false}),abort=new AbortController();
  const pending=prepareHostInspector({deadline:Date.now()+10000,spawn:f.spawn,signal:abort.signal});
  await turn();assert.ok(f.child,'gated inspector must spawn');await f.boot;abort.abort();
  await assert.rejects(pending,/cancel|abort/i);await f.exited;
  const exited=fixture(t,{auto:false}),startup=prepareHostInspector({deadline:Date.now()+10000,spawn:exited.spawn});
  await turn();assert.ok(exited.child);await exited.boot;exited.send({exit:true});await assert.rejects(startup,/closed|exit/i);
});

test('only one request is in flight and partial frames cannot fulfill it',async t=>{
  const {f,session}=await ready(t);const pending=session.query({notAfter:Date.now()+1000});const request=await f.next();
  const busy=await session.query({notAfter:Date.now()+1000});assert.equal(busy.complete,false);assert.equal(busy.transport.stage,'busy');
  let resolved=false;pending.then(()=>resolved=true);f.send({raw:'{"protocol":1'});await turn();assert.equal(resolved,false);
  f.send({raw:',"type":"result","generation":'+JSON.stringify(request.generation)+',"requestId":'+request.requestId+',"snapshot":'+JSON.stringify(snapshot)+'}\n'});
  assert.equal((await pending).complete,true);assert.equal(f.requests.length,0);
});

for(const corruption of ['generation','requestId','protocol'])test(`wrong ${corruption} reply invalidates current authority and disposes session`,async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:Date.now()+1000}),request=await f.next();
  f.reply(request,{[corruption]:corruption==='generation'?'previous-generation':999});
  const result=await pending;assert.equal(result.complete,false);assert.equal(result.transport.stage,'protocol');
  assert.deepEqual(result.processes,[]);assert.deepEqual(await session.close(),{closed:true,reaped:true});
});

test('duplicate, unsolicited and prior-session output cannot authorize a later request',async t=>{
  const first=await ready(t),pending=first.session.query({notAfter:Date.now()+1000}),request=await first.f.next();
  first.f.reply(request);assert.equal((await pending).complete,true);first.f.reply(request);await turn();
  assert.equal((await first.session.query({notAfter:Date.now()+1000})).complete,false);
  const second=await ready(t),next=second.session.query({notAfter:Date.now()+1000}),current=await second.f.next();
  second.f.reply(current,{generation:request.generation});assert.equal((await next).complete,false);
  assert.notEqual(first.session.generation,second.session.generation);
});

test('query timeout is capped by unchanged global cap and fixed remaining phase; late data stays invalid',async t=>{
  const {f,session}=await ready(t);const expiry=f.now()+80;
  const pending=session.query({notAfter:expiry}),request=await f.next();
  assert.equal(request.budgetMilliseconds>0&&request.budgetMilliseconds<=80,true);
  f.advance(80);
  const result=await pending;assert.equal(result.complete,false);assert.equal(result.transport.stage,'timeout');
  assert.equal(result.transport.timeoutMilliseconds<=80,true);
  assert.deepEqual(await session.close(),{closed:true,reaped:true});
  const other=await ready(t),long=other.session.query({notAfter:Date.now()+5000}),longRequest=await other.f.next();
  assert.equal(longRequest.budgetMilliseconds,1000);other.f.reply(longRequest);assert.equal((await long).complete,true);
  assert.equal((await other.session.query({notAfter:other.f.now()-1})).complete,false);
});

for(const channel of ['stdout','stderr','combined'])test(`${channel} byte bound over four MiB disposes without exposing payload`,async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:Date.now()+1000});await f.next();
  const payload='PRIVATE_PAYLOAD'.repeat(Math.ceil(4*1024*1024/15)+1);
  if(channel==='stdout')f.send({raw:payload});
  else if(channel==='stderr')f.send({stderr:payload});
  else {f.send({raw:'x'.repeat(2*1024*1024)});f.send({stderr:'y'.repeat(2*1024*1024+1)});}
  const result=await pending;assert.equal(result.complete,false);assert.equal(result.transport.stage,'overflow');
  assert.equal(JSON.stringify(result).includes('PRIVATE_PAYLOAD'),false);
  assert.deepEqual(await session.close(),{closed:true,reaped:true});
});

test('exact four-MiB combined envelope remains bounded and accepts complete current JSON',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:Date.now()+1000}),request=await f.next();
  const reply=JSON.stringify({protocol:1,type:'result',generation:request.generation,requestId:request.requestId,snapshot})+'\n';
  const bytes=4*1024*1024-Buffer.byteLength(reply);let received=0;
  const stderrReceived=new Promise(resolve=>f.child.stderr.on('data',chunk=>{received+=chunk.length;if(received>=bytes)resolve();}));
  f.send({stderr:'x'.repeat(bytes)});await stderrReceived;f.send({raw:reply});
  const result=await pending;assert.equal(result.complete,true);assert.deepEqual(result.processes,[owned]);
});

test('EOF and closed session resolve pending work once and never leak process text',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:Date.now()+1000});await f.next();
  f.send({stderr:'PRIVATE_TRACEBACK'});f.send({exit:true});const result=await pending;
  assert.equal(result.complete,false);assert.equal(JSON.stringify(result).includes('PRIVATE_TRACEBACK'),false);
  assert.deepEqual(await session.close(),{closed:true,reaped:true});
});

test('close remains bounded and reports unreaped transport without inventing disappearance',async()=>{
  let child,time=0,next=0;const scheduled=new Map();
  const timers={setTimeout:(fn,ms)=>{scheduled.set(++next,{fn,due:time+ms});return next;},clearTimeout:id=>scheduled.delete(id)};
  const pending=prepareHostInspector({deadline:10000,now:()=>time,timers,spawn:(_cmd,args)=>{
    child=new EventEmitter();child.pid=12345;child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();
    child.kill=()=>true;child.unref=()=>{};
    queueMicrotask(()=>child.stdout.write(JSON.stringify({protocol:1,type:'ready',generation:args.at(-1)})+'\n'));return child;
  }});
  await turn();assert.ok(child,'external process boundary must be reached');const session=await pending;
  const closing=session.close({notAfter:80});time=80;for(const [id,timer] of scheduled)if(timer.due<=time){scheduled.delete(id);timer.fn();}
  assert.deepEqual(await closing,{closed:false,reaped:false});assert.equal((await session.query({notAfter:1000})).complete,false);
  child.emit('close',null,'SIGKILL');child.stdin.destroy();child.stdout.destroy();child.stderr.destroy();
});

test('framing preserves UTF8 split inside a multibyte identity field',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:1000}),request=await f.next();
  const unicode={...owned,marker:'token-🚀'},payload=Buffer.from(JSON.stringify({protocol:1,type:'result',generation:request.generation,requestId:request.requestId,snapshot:{complete:true,processes:[unicode],unknown:[]}})+'\n');
  const split=payload.indexOf(Buffer.from('🚀'))+2;f.send({bytes:[...payload.subarray(0,split)]});f.send({bytes:[...payload.subarray(split)]});
  const actual=await pending;assert.equal(actual.complete,true);assert.deepEqual(actual.processes,[unicode]);
});

test('startup framing over four MiB fails closed before READY',async t=>{
  const f=fixture(t,{auto:false}),pending=prepareHostInspector({deadline:Date.now()+10000,spawn:f.spawn});
  await turn();assert.ok(f.child);await f.boot;f.send({raw:'x'.repeat(4*1024*1024+1)});
  await assert.rejects(pending,/overflow|bound/i);await f.exited;
});

test('busy request diagnostic history is bounded to sixteen entries',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:1000}),request=await f.next();
  for(let i=0;i<40;i++)assert.equal((await session.query({notAfter:1000})).complete,false);
  assert.equal(session.diagnostics.events.length<=16,true);f.reply(request);assert.equal((await pending).complete,true);
});

test('startup import and binding stage frames never release worker authority before READY',async t=>{
  const f=fixture(t,{auto:false}),dir=mkdtempSync(path.join(tmpdir(),'r2-ready-stages-')),marker=path.join(dir,'worker');
  const gates=new Map();let settled=false,worker,workerExit,session;
  const prepared=prepareHostInspector({deadline:Date.now()+10000,spawn:f.spawn,onStage:frame=>gates.get(frame.stage)?.()});
  const launch=prepared.then(value=>{session=value;settled=true;worker=spawn(process.execPath,['-e',`require('node:fs').writeFileSync(${JSON.stringify(marker)},'one')`],{stdio:'ignore'});workerExit=new Promise(resolve=>worker.once('close',resolve));return workerExit;});
  launch.catch(()=>{});t.after(async()=>{if(worker){worker.kill('SIGKILL');await workerExit;}if(session)await session.close();rmSync(dir,{recursive:true,force:true});});
  await turn();assert.ok(f.child);await f.boot;
  for(const stage of ['interpreter-boot','imports-ready','os-bindings-ready']){
    const observed=new Promise(resolve=>gates.set(stage,resolve));
    f.send({raw:JSON.stringify({protocol:1,type:'stage',generation:f.generation,stage,elapsedMilliseconds:0})+'\n'});
    await observed;assert.equal(settled,false);assert.equal(existsSync(marker),false);
  }
  f.send({ready:true});await launch;assert.equal(settled,true);assert.equal(existsSync(marker),true);
});

test('UTF8 bytes over four MiB invalidate a frame even when JS character count is below the bound',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:1000});await f.next();
  const payload='🚀'.repeat(1024*1024+1);
  assert.equal(payload.length<4*1024*1024,true);assert.equal(Buffer.byteLength(payload)>4*1024*1024,true);
  f.send({raw:payload});const result=await pending;
  assert.equal(result.complete,false);assert.equal(result.transport.stage,'overflow');
  assert.deepEqual(await session.close(),{closed:true,reaped:true});
});

test('initially valid startup deadline expires while READY is held and late READY cannot launch worker',async t=>{
  const f=fixture(t,{auto:false});let workers=0;
  const pending=prepareHostInspector({deadline:80,spawn:f.spawn,now:f.now,timers:f.timers});
  pending.then(()=>workers++,()=>{});
  await turn();assert.ok(f.child);await f.boot;assert.equal(workers,0);
  f.advance(80);await assert.rejects(pending,/deadline|expired|timeout/i);
  f.child.stdout.emit('data',Buffer.from(JSON.stringify({protocol:1,type:'ready',generation:f.generation})+'\n'));
  await turn();assert.equal(workers,0);await f.exited;
  assert.equal(f.child.exitCode!==null||f.child.signalCode!==null,true,'expired startup process actually exited');
});

test('correlated privacy failure frames cannot copy arbitrary unknown reason text into diagnostics',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:1000}),request=await f.next();
  f.reply(request,{snapshot:{complete:false,processes:[],unknown:[{pid:321,reason:'PRIVATE_ENV_CONTENT',extra:'PRIVATE_ENV_CONTENT'}]}});
  const actual=await pending;assert.equal(actual.complete,false);
  assert.equal(JSON.stringify(actual).includes('PRIVATE_ENV_CONTENT'),false);
});

test('correlated privacy identity frames retain only the allowed kernel identity fields',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:1000}),request=await f.next();
  f.reply(request,{snapshot:{complete:true,processes:[{...owned,extra:'PRIVATE_ENV_CONTENT'}],unknown:[]}});
  const actual=await pending;assert.equal(actual.complete,true);
  assert.equal(JSON.stringify(actual).includes('PRIVATE_ENV_CONTENT'),false);
  assert.deepEqual(actual.processes,[owned]);
});

test('non-string birth identity in a correlated frame cannot become an owned snapshot',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:1000}),request=await f.next();
  f.reply(request,{snapshot:{complete:true,processes:[{...owned,birth:[owned.birth]}],unknown:[]}});
  const actual=await pending;assert.equal(actual.complete,false);assert.deepEqual(actual.processes,[]);
});

test('expired reply clears only its physical slot and a fresh correlated request can recover',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:80}),request=await f.next();
  f.advance(80);const expired=await pending;assert.equal(expired.complete,false);
  assert.equal(session.ready,true,'query expiry must not destroy an otherwise healthy prepared process');
  assert.equal(session.busy,true);
  const busy=await session.query({notAfter:1000});assert.equal(busy.complete,false);assert.equal(busy.transport.stage,'busy');
  f.reply(request);
  while(session.ready&&!session.diagnostics.events.some(e=>e.stage==='expired-reply'&&e.requestId===request.requestId))await turn();
  assert.equal(session.ready,true);assert.deepEqual(expired.processes,[]);
  assert.equal(session.busy,false);
  const next=session.query({notAfter:1000}),current=await f.next();
  assert.equal(current.requestId>request.requestId,true);assert.equal(current.generation,request.generation);
  f.reply(current,{snapshot:{complete:true,processes:[],unknown:[]}});
  const recovered=await next;assert.equal(recovered.complete,true);assert.deepEqual(recovered.processes,[]);
  const started=f.now(),stuck=session.query({notAfter:started+80});await f.next();
  f.advance(started+80);assert.equal((await stuck).complete,false);assert.equal(session.ready,true);
  assert.equal((await session.query({notAfter:started+2000})).transport.stage,'busy');
  f.advance(started+999);assert.equal(session.ready,true);
  f.advance(started+1000);assert.equal(session.ready,true,'logical expiry retains the single physical slot until reply or supervisor teardown');
  assert.equal(session.busy,true);
  assert.deepEqual(await session.close(),{closed:true,reaped:true});
});


test('1003ms reply is discarded without destroying its generation; only fresh observation authorizes success',async t=>{
  const {f,session}=await ready(t),pending=session.query({notAfter:5000}),request=await f.next();
  f.advance(1003);const expired=await pending;
  assert.equal(expired.complete,false);assert.deepEqual(expired.processes,[]);
  assert.equal(expired.transport.stage,'timeout');assert.equal(session.ready,true);assert.equal(session.busy,true);
  assert.equal((await session.query({notAfter:5000})).transport.stage,'busy');
  f.reply(request,{snapshot:{complete:true,processes:[],unknown:[]}});
  while(session.ready&&session.busy)await turn();
  assert.equal(session.ready,true);assert.equal(session.busy,false);assert.equal(expired.complete,false);
  const fresh=session.query({notAfter:5000}),current=await f.next();
  assert.equal(current.generation,request.generation);assert.equal(current.requestId>request.requestId,true);
  f.reply(current);const actual=await fresh;
  assert.equal(actual.complete,true);assert.deepEqual(actual.processes,[owned]);
});
