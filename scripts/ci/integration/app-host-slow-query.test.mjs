import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,realpathSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {prepareHostInspector} from '../app-host-inspector.mjs';
import {runProcessGroup} from '../app-repeat-process.mjs';
import {queryHostProcesses} from '../app-host-ownership.mjs';
import {runAppRepeat} from '../app-repeat.mjs';

// Modify only response delivery in the REAL Python inspector. Kernel enumeration,
// identity checks, byte-stream transport, ownership and supervisor all stay real.
async function scenario(t,{delay=1.25,hostLife=2400,workerLife=2700,deadlineMs=6000}={}){
  const dir=mkdtempSync(path.join(tmpdir(),'i393-k-')),journal=path.join(dir,'queries'),logPath=path.join(dir,'run.log');
  const token=randomUUID();let inspector,result;
  t.after(async()=>{
    for(const identity of result?.hostOwnership?.identities??[]){
      const current=queryHostProcesses({token,executable:identity.executable,pids:[identity.pid]});
      if(!current.complete||current.unknown.length||!current.processes.some(p=>p.pid===identity.pid&&p.birth===identity.birth&&p.marker===token&&p.uid===identity.uid&&p.executable===identity.executable))continue;
      try{process.kill(identity.pid,'SIGKILL');}catch(error){if(error.code!=='ESRCH')throw error;}}
    if(inspector)await inspector.close({notAfter:Date.now()+1000});
    rmSync(dir,{recursive:true,force:true});
  });
  inspector=await prepareHostInspector({deadline:Date.now()+10000,spawn:(command,args,options)=>{
    const changed=[...args],index=changed.indexOf('-c')+1;
    changed[index]=changed[index].replace('for line in sys.stdin:',
      'delay_next=False;delayed=False\nfor line in sys.stdin:').replace("    emit(dict(protocol=1,type='result'",
      `    open(${JSON.stringify(journal)},'a').write(str(message['requestId'])+'\\n')\n`+
      `    if delay_next and not delayed: time.sleep(${delay});delayed=True\n`+
      "    if any(r.get('marker')==request.get('token') and r.get('ppid')!=os.getppid() for r in records): delay_next=True\n"+
      "    emit(dict(protocol=1,type='result'");
    return spawn(command,changed,options);
  }});
  const hostSource=`process.send('ready');setTimeout(()=>process.exit(0),${hostLife})`;
  const workerSource=`const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(hostSource)}],{detached:true,stdio:['ignore','ignore','ignore','ipc']});c.on('message',()=>setTimeout(()=>process.exit(0),${workerLife}));`;
  writeFileSync(logPath,'');
  const started=Date.now(),deadline=started+deadlineMs;
  result=await runProcessGroup({command:process.execPath,args:['-e',workerSource],preparedInspector:inspector,
    env:{...process.env,MADO_TEST_RUN_TOKEN:token,MADO_HOST_EXECUTABLE:realpathSync(process.execPath),MADO_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath,deadline,graceMs:250,drainMs:1500});
  const requests=readFileSync(journal,'utf8').trim().split('\n').map(Number);
  t.diagnostic(JSON.stringify({result,requests,elapsed:Date.now()-started,log:readFileSync(logPath,'utf8')}));
  return {result,requests,elapsed:Date.now()-started,deadline};
}

for(const workerLife of [2700,900])test(`one slow real inspector query recovers without retry when worker exits at ${workerLife}ms`,async t=>{
  const observed=await scenario(t,{workerLife,hostLife:workerLife===900?650:2400});
  const {result}=observed;
  assert.equal(result.hostOwnership.observed,true,'real host was registered before delayed query');
  assert.equal(result.status,0);assert.equal(result.drained,true);
  assert.equal(result.hostOwnership.queryFailures.some(f=>f.transport?.stage==='timeout'),true);
  assert.equal(observed.requests.some(id=>id>result.hostOwnership.queryFailures.find(f=>f.transport?.stage==='timeout').transport.requestId),true);
  assert.equal(result.hostOwnership.unknown.length,0);assert.deepEqual(result.hostOwnership.live,[]);
  assert.equal(result.inspector.closed,true);assert.equal(result.inspector.reaped,true);
});

for(const hostLife of [650,10000])test(`permanently hung real query blocks overlap at unchanged drain deadline, host life ${hostLife}ms`,async t=>{
  const {result,requests,elapsed,deadline}=await scenario(t,{delay:30,hostLife,workerLife:900,deadlineMs:1800});
  assert.equal(result.hostOwnership.observed,true);
  assert.equal(result.status,70);assert.equal(result.drained,false);
  assert.equal(result.hostOwnership.unknown.length>0,true);
  assert.equal(result.cleanup.graceDeadline-result.cleanup.graceStartedAt,250);
  assert.equal(result.cleanup.drainDeadline-result.cleanup.graceDeadline,1500);
  assert.ok(result.cleanup.graceStartedAt>=deadline,'uncertainty must not stop the worker early');
  assert.ok(elapsed<4800,'hung query cannot extend run plus cleanup deadlines');
  assert.equal(result.inspector.diagnostics.events.filter(e=>e.stage==='request').length,requests.length,'no second physical query queued behind hang');
  assert.equal(result.inspector.diagnostics.events.some(e=>e.stage==='expired-reply'),false);
  assert.equal(result.inspector.diagnostics.events.filter(e=>e.stage==='request').at(-1).requestId,requests.at(-1));
  assert.equal(typeof result.inspector.reaped,'boolean','bounded teardown reports whether reap was proven');
  const reapDeadline=Date.now()+1000;
  let inspectorAlive=true;
  while(inspectorAlive&&Date.now()<reapDeadline){
    try{process.kill(result.inspector.pid,0);}catch(error){if(error.code==='ESRCH')inspectorAlive=false;else throw error;}
    if(inspectorAlive)await new Promise(resolve=>setTimeout(resolve,10));
  }
  assert.equal(inspectorAlive,false,'drain deadline actually terminates the physical inspector');
  assert.deepEqual(result.hostOwnership.signals,[],'a hung query cannot authorize a direct host signal');
  const identity=result.hostOwnership.identities[0];
  const actual=queryHostProcesses({token:result.hostOwnership.token,executable:identity.executable,pids:[identity.pid]});
  assert.equal(actual.complete,true);assert.equal(actual.unknown.length,0);
  assert.equal(actual.processes.some(p=>p.birth===identity.birth&&p.marker===identity.marker),hostLife===10000,'kernel proves live host case and exited-but-unverifiable case');
  const out=mkdtempSync(path.join(tmpdir(),'i393-k-overlap-'));t.after(()=>rmSync(out,{recursive:true,force:true}));
  let launches=0;
  const status=runAppRepeat({repeat:2,out,deadline:Date.now()+10000,env:{PICSEE_HEAVY_LOCK_HELD:'1'},stdout:()=>{},spawn:()=>{
    launches++;return {status:0,stdout:JSON.stringify(result),stderr:''};
  }});
  assert.equal(status,1);assert.equal(launches,1,'real failed drain result prevents the next iteration');
  assert.match(readFileSync(path.join(out,'iter-02.log'),'utf8'),/refusing to overlap/);
});
