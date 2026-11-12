import baseTest from 'node:test';
import {AsyncLocalStorage} from 'node:async_hooks';
import {prepareHostInspector} from '../app-host-inspector.mjs';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,readFileSync,existsSync,rmSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {runHostedCancelProbe as realCancelProbe} from '../hosted-cancel-probe.mjs';


const sessions=new AsyncLocalStorage();
function test(name,body){return baseTest(name,async t=>{
  const inspector=await prepareHostInspector({deadline:Date.now()+10000});
  assert.equal(inspector.ready,true,'integration setup requires explicit READY');
  t.after(()=>inspector.close());return sessions.run(inspector,()=>body(t));
});}
const runHostedCancelProbe=options=>realCancelProbe({...options,preparedInspector:sessions.getStore()});

test('real observed escaped host cancellation yields diagnostic success only after exact host drain',async t=>{
  const out=mkdtempSync(path.join(tmpdir(),'hosted-cancel-'));t.after(()=>rmSync(out,{recursive:true,force:true}));
  const token=randomUUID(),host=spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:token},stdio:['ignore','ignore','ignore','ipc']});
  t.after(()=>{host.kill('SIGKILL');host.unref();});await new Promise(resolve=>host.once('message',resolve));
  const status=await runHostedCancelProbe({out,token,executable:realpathSync(process.execPath),command:process.execPath,
    args:['-e','setInterval(()=>{},1000)'],deadline:Date.now()+3000,graceMs:50,drainMs:500});
  if(status!==0){
    const resultPath=path.join(out,'result.json');
    const failed=existsSync(resultPath)?JSON.parse(readFileSync(resultPath,'utf8')):null;
    t.diagnostic(JSON.stringify({cancelProbe:failed,
      nativeLog:failed?.attemptPath&&existsSync(path.join(failed.attemptPath,'native.log'))?
        readFileSync(path.join(failed.attemptPath,'native.log'),'utf8'):null}));
  }
  assert.equal(status,0);assert.equal(existsSync(path.join(out,'result.json')),true,'current cancellation evidence required');
  const result=JSON.parse(readFileSync(path.join(out,'result.json'),'utf8'));
  assert.equal(result.diagnostic,true);assert.equal(result.formal,false);assert.equal(result.complete,true);
  assert.equal(result.status,0);assert.equal(result.supervisor.status,70);assert.equal(result.supervisor.drained,true);
  assert.equal(result.supervisor.cancelledOnHostObserved,true);assert.equal(result.supervisor.hostOwnership.observed,true);
  assert.equal(result.supervisor.hostOwnership.identities.some(p=>p.pid===host.pid),true);
  assert.equal(result.supervisor.hostOwnership.signals.some(s=>s.signal==='SIGKILL'),true);
});
test('missing host association cannot become a successful cancellation probe',async t=>{
  const out=mkdtempSync(path.join(tmpdir(),'hosted-cancel-missing-'));t.after(()=>rmSync(out,{recursive:true,force:true}));
  const status=await runHostedCancelProbe({out,token:randomUUID(),executable:realpathSync(process.execPath),command:process.execPath,
    args:['-e','console.log("no host")'],deadline:Date.now()+1000,graceMs:30,drainMs:100});
  assert.equal(status,70);assert.equal(existsSync(path.join(out,'result.json')),true,'failed attempt evidence required');
  const result=JSON.parse(readFileSync(path.join(out,'result.json'),'utf8'));assert.equal(result.status,70);assert.equal(result.formal,false);
});
