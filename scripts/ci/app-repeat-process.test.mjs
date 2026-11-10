import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { runProcessGroup } from './app-repeat-process.mjs';

const livePids = () => new Set(spawnSync('ps', ['-axo','pid=,stat='], {encoding:'utf8'}).stdout.trim().split('\n')
  .map(line => line.trim().split(/\s+/)).filter(([,state]) => !state.startsWith('Z')).map(([pid]) => Number(pid)));
function directory(t) {
  const dir = mkdtempSync(path.join(tmpdir(), 'app-repeat-group-'));
  t.after(() => rmSync(dir, {recursive:true,force:true}));
  return dir;
}
function fixture(dir, exitLeader) {
  const pids = path.join(dir,'pids');
  const grandchild = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(pids)},process.pid+'\\n');process.on('SIGTERM',()=>{});process.send('ready');setInterval(()=>{},1000);`;
  const middle = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(pids)},process.pid+'\\n');process.on('SIGTERM',()=>{});const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(grandchild)}],{stdio:['ignore','ignore','ignore','ipc']});c.on('message',()=>process.send('ready'));setInterval(()=>{},1000);`;
  const root = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(pids)},process.pid+'\\n');process.on('SIGTERM',()=>{});const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(middle)}],{stdio:['ignore','ignore','ignore','ipc']});c.on('message',()=>{console.log('grandchild ready');${exitLeader ? 'process.exit(0)' : ''}});setInterval(()=>{},1000);`;
  return {pids, command:process.execPath,args:['-e',root]};
}
for (const exitLeader of [false,true]) test(`process group drains TERM-resistant descendants when ${exitLeader ? 'leader exits early' : 'deadline expires'}`, async t => {
  const dir = directory(t), logPath = path.join(dir,'iteration.log');
  const f = fixture(dir,exitLeader);
  const started = Date.now();
  const result = await runProcessGroup({...f,logPath,deadline:Date.now()+1200,graceMs:80,drainMs:1000});
  assert.equal(result.drained,true);
  assert.equal(result.status,70);
  assert.ok(existsSync(f.pids),'fixture must start before the cleanup claim can pass');
  const pids = readFileSync(f.pids,'utf8').trim().split('\n').map(Number);
  assert.equal(pids.length,3,'the fixture includes a grandchild');
  const live = livePids();
  for (const pid of pids) assert.ok(!live.has(pid),`descendant ${pid} survived cleanup`);
  assert.match(readFileSync(logPath,'utf8'), /grandchild ready/);
  assert.ok(Date.now()-started < 5000);
  // A following iteration can observe that every process from the prior iteration is gone.
  const next = await runProcessGroup({command:process.execPath,args:['-e','console.log("next iteration")'],logPath:path.join(dir,'next.log'),deadline:Date.now()+2000});
  assert.equal(next.status,0);
  assert.equal(next.drained,true);
  assert.equal(readFileSync(path.join(dir,'next.log'),'utf8'),'next iteration\n');
});

test('interrupting the supervisor drains its worker process group', async t => {
  const {spawn} = await import('node:child_process');
  const dir=directory(t), f=fixture(dir,false), logPath=path.join(dir,'interrupt.log');
  const supervisor = spawn(process.execPath,[new URL('./app-repeat-process.mjs',import.meta.url).pathname,
    String(Date.now()+10000),logPath,f.command,...f.args],{stdio:['ignore','pipe','pipe']});
  let output='',error='';
  supervisor.stdout.on('data',chunk=>output+=chunk); supervisor.stderr.on('data',chunk=>error+=chunk);
  const ended = new Promise(resolve=>supervisor.on('close',(code,signal)=>resolve({code,signal})));
  const readyUntil=Date.now()+5000;
  while ((!existsSync(f.pids) || readFileSync(f.pids,'utf8').trim().split('\n').length<3) && Date.now()<readyUntil)
    await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(existsSync(f.pids));
  const pids=readFileSync(f.pids,'utf8').trim().split('\n').map(Number);
  assert.equal(pids.length,3);
  supervisor.kill('SIGTERM');
  const end=await ended;
  assert.equal(end.code,0,error);
  assert.equal(end.signal,null);
  assert.equal(JSON.parse(output).drained,true);
  assert.equal(JSON.parse(output).status,70);
  const live=livePids();
  for (const pid of pids) assert.ok(!live.has(pid),`interrupted descendant ${pid} survived`);
  assert.match(readFileSync(logPath,'utf8'),/supervisor interrupted/);
});

test('deadline drains exact escaped host before next iteration while unrelated same executable survives',async t=>{
  const {spawn}=await import('node:child_process');const {randomUUID}=await import('node:crypto');const {realpathSync}=await import('node:fs');
  const dir=directory(t),token=randomUUID();
  const launch=marker=>spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,PICSEE_TEST_RUN_TOKEN:marker},stdio:['ignore','ignore','ignore','ipc']});
  const host=launch(token),sentinel=launch('unrelated-'+token);
  t.after(()=>{host.kill('SIGKILL');sentinel.kill('SIGKILL');host.unref();sentinel.unref();});
  await Promise.all([host,sentinel].map(child=>new Promise(resolve=>child.once('message',resolve))));
  const env={...process.env,PICSEE_TEST_RUN_TOKEN:token,PICSEE_HOST_EXECUTABLE:realpathSync(process.execPath),PICSEE_HOST_OWNERSHIP_REQUIRED:'1'};
  const result=await runProcessGroup({command:process.execPath,args:['-e','setInterval(()=>{},1000)'],env,
    logPath:path.join(dir,'escaped.log'),deadline:Date.now()+1000,graceMs:80,drainMs:1000});
  assert.equal(result.drained,true);assert.equal(result.status,70);
  const live=livePids();assert.equal(live.has(host.pid),false,'escaped owned host must be gone before next');
  assert.equal(live.has(sentinel.pid),true,'unrelated same executable must survive');
  assert.equal(result.hostOwnership.observed,true);assert.equal(result.hostOwnership.drained,true);
  t.diagnostic(JSON.stringify({escapedDeadline:result}));
  const next=await runProcessGroup({command:process.execPath,args:['-e','console.log("after-host-drain")'],
    logPath:path.join(dir,'after.log'),deadline:Date.now()+2000});
  assert.equal(next.status,0);assert.match(readFileSync(path.join(dir,'after.log'),'utf8'),/after-host-drain/);
});

test('required host with no actual invocation association refuses drain even after worker success',async t=>{
  const {realpathSync}=await import('node:fs');const dir=directory(t);
  const result=await runProcessGroup({command:process.execPath,args:['-e','console.log("worker-only")'],
    env:{...process.env,PICSEE_TEST_RUN_TOKEN:'missing-current-host',PICSEE_HOST_EXECUTABLE:realpathSync(process.execPath),PICSEE_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath:path.join(dir,'missing.log'),deadline:Date.now()+2000,graceMs:50,drainMs:150});
  assert.equal(result.status,70);assert.equal(result.drained,false);assert.equal(result.hostOwnership.observed,false);
});

for(const mode of ['leader-exit','SIGTERM','SIGINT'])test(`escaped host is drained on ${mode} with registered identity evidence`,async t=>{
  const {spawn}=await import('node:child_process');const {randomUUID}=await import('node:crypto');const {realpathSync}=await import('node:fs');
  const dir=directory(t),token=randomUUID(),host=spawn(process.execPath,
    ['-e','process.on("SIGTERM",()=>{});process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,PICSEE_TEST_RUN_TOKEN:token},stdio:['ignore','ignore','ignore','ipc']});
  t.after(()=>{host.kill('SIGKILL');host.unref();});await new Promise(resolve=>host.once('message',resolve));
  const logPath=path.join(dir,'registered.log');
  const env={...process.env,PICSEE_TEST_RUN_TOKEN:token,PICSEE_HOST_EXECUTABLE:realpathSync(process.execPath),PICSEE_HOST_OWNERSHIP_REQUIRED:'1'};
  const supervisor=spawn(process.execPath,[new URL('./app-repeat-process.mjs',import.meta.url).pathname,String(Date.now()+5000),logPath,
    process.execPath,'-e',mode==='leader-exit'?'console.log("leader exits")':'setInterval(()=>{},1000)'],{env,stdio:['ignore','pipe','pipe']});
  t.after(()=>supervisor.kill('SIGKILL'));let output='';supervisor.stdout.on('data',chunk=>output+=chunk);
  const ended=new Promise(resolve=>supervisor.once('close',resolve));
  if(mode!=='leader-exit'){
    const until=Date.now()+2000;
    while((!existsSync(logPath)||!readFileSync(logPath,'utf8').includes('owned host registered'))&&Date.now()<until)
      await new Promise(resolve=>setTimeout(resolve,10));
    assert.equal(existsSync(logPath),true);assert.match(readFileSync(logPath,'utf8'),/owned host registered/);
    supervisor.kill(mode);
  }
  await ended;const result=JSON.parse(output);assert.equal(result.status,70);assert.equal(result.drained,true);
  t.diagnostic(JSON.stringify({transition:mode,...result}));
  assert.equal(livePids().has(host.pid),false);assert.equal(result.hostOwnership.observed,true);
  assert.equal(result.hostOwnership.signals.some(s=>s.signal==='SIGKILL'),true);
  assert.match(readFileSync(logPath,'utf8'),/owned host registered/);
});

test('initial observed responsive host cancellation lets the supervisor process exit after proven drain',async t=>{
  const {spawn}=await import('node:child_process');const {randomUUID}=await import('node:crypto');const {realpathSync}=await import('node:fs');
  const dir=directory(t),token=randomUUID(),host=spawn(process.execPath,['-e','process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,PICSEE_TEST_RUN_TOKEN:token},stdio:['ignore','ignore','ignore','ipc']});
  t.after(()=>{host.kill('SIGKILL');host.unref();});await new Promise(resolve=>host.once('message',resolve));
  const options={command:process.execPath,args:['-e','setInterval(()=>{},1000)'],deadline:Date.now()+5000,
    logPath:path.join(dir,'responsive.log'),cancelOnHostObserved:true};
  const source=`import {runProcessGroup} from ${JSON.stringify(new URL('./app-repeat-process.mjs',import.meta.url).href)};console.log(JSON.stringify(await runProcessGroup(${JSON.stringify(options)})));`;
  const supervisor=spawn(process.execPath,['--input-type=module','-e',source],{env:{...process.env,
    PICSEE_TEST_RUN_TOKEN:token,PICSEE_HOST_EXECUTABLE:realpathSync(process.execPath),PICSEE_HOST_OWNERSHIP_REQUIRED:'1'},stdio:['ignore','pipe','pipe']});
  t.after(()=>supervisor.kill('SIGKILL'));let output='',errors='';
  supervisor.stdout.on('data',chunk=>output+=chunk);supervisor.stderr.on('data',chunk=>errors+=chunk);
  let expiry;const ended=new Promise(resolve=>supervisor.once('close',(code,signal)=>resolve({code,signal})));
  const end=await Promise.race([ended,new Promise(resolve=>{expiry=setTimeout(()=>resolve({timedOut:true}),2000);})]);clearTimeout(expiry);
  assert.equal(output.trim().startsWith('{'),true,'supervisor must return its drain result');
  const result=JSON.parse(output);assert.equal(result.drained,true);assert.equal(result.cancelledOnHostObserved,true);
  assert.equal(end.timedOut,undefined,'resolved supervisor must exit without a leaked ownership interval');
  assert.equal(end.code,0,errors);assert.equal(end.signal,null);assert.equal(livePids().has(host.pid),false);
});

test('true orphan adopted outside worker group is drained while unrelated sentinel survives',async t=>{
  const {spawn}=await import('node:child_process');const {randomUUID}=await import('node:crypto');
  const {realpathSync}=await import('node:fs');const {queryHostProcesses}=await import('./app-host-ownership.mjs');
  const dir=directory(t),token=randomUUID(),executable=realpathSync(process.execPath),pidFile=path.join(dir,'orphan.json');
  const childSource=`const fs=require('node:fs');process.on('SIGTERM',()=>{});fs.writeFileSync(${JSON.stringify(pidFile)},JSON.stringify({pid:process.pid,parent:process.ppid}));process.send('ready');process.disconnect();setInterval(()=>{},1000);`;
  const middleSource=`const child=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(childSource)}],{detached:true,stdio:['ignore','ignore','ignore','ipc']});child.once('message',()=>process.exit(0));`;
  const middle=spawn(process.execPath,['-e',middleSource],{env:{...process.env,PICSEE_TEST_RUN_TOKEN:token},stdio:'ignore'});
  let hostPid;
  t.after(()=>{middle.kill('SIGKILL');if(hostPid){const q=queryHostProcesses({token,executable,pids:[hostPid]});
    if(q.processes.some(p=>p.pid===hostPid&&p.marker===token))try{process.kill(hostPid,'SIGKILL');}catch{}}});
  const middleExit=await new Promise(resolve=>middle.once('close',(code,signal)=>resolve({code,signal})));
  assert.equal(middleExit.code,0);assert.equal(middleExit.signal,null);assert.equal(existsSync(pidFile),true);
  const created=JSON.parse(readFileSync(pidFile,'utf8'));hostPid=created.pid;assert.equal(created.parent,middle.pid);
  const adopted=queryHostProcesses({token,executable,pids:[hostPid]});assert.equal(adopted.complete,true);
  assert.equal(adopted.processes.length,1);const identity=adopted.processes[0];
  assert.notEqual(identity.ppid,middle.pid);if(process.platform==='darwin')assert.equal(identity.ppid,1);
  assert.equal(identity.pgid,hostPid);t.diagnostic(JSON.stringify({adoptedHost:identity,formerParent:middle.pid}));
  const sentinel=spawn(process.execPath,['-e','process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,PICSEE_TEST_RUN_TOKEN:'sentinel-'+token},stdio:['ignore','ignore','ignore','ipc']});
  t.after(()=>{sentinel.kill('SIGKILL');sentinel.unref();});await new Promise(resolve=>sentinel.once('message',resolve));
  const result=await runProcessGroup({command:process.execPath,args:['-e','setInterval(()=>{},1000)'],
    env:{...process.env,PICSEE_TEST_RUN_TOKEN:token,PICSEE_HOST_EXECUTABLE:executable,PICSEE_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath:path.join(dir,'orphan.log'),deadline:Date.now()+1000,graceMs:50,drainMs:1000});
  assert.equal(result.status,70);assert.equal(result.drained,true);assert.equal(result.hostOwnership.drained,true);
  assert.equal(result.hostOwnership.identities.some(p=>p.pid===hostPid&&p.birth===identity.birth&&p.ppid===identity.ppid),true);
  assert.equal(livePids().has(hostPid),false);assert.equal(livePids().has(sentinel.pid),true);
  const next=await runProcessGroup({command:process.execPath,args:['-e','console.log("after-orphan-drain")'],
    logPath:path.join(dir,'next-orphan.log'),deadline:Date.now()+2000});
  assert.equal(next.status,0);assert.equal(next.drained,true);assert.match(readFileSync(path.join(dir,'next-orphan.log'),'utf8'),/after-orphan-drain/);
  t.diagnostic(JSON.stringify({orphanDrain:result}));
});
