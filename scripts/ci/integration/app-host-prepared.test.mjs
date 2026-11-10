import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,appendFileSync,readFileSync,existsSync,realpathSync,rmSync,watch} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {prepareHostInspector} from '../app-host-inspector.mjs';
import {runProcessGroup} from '../app-repeat-process.mjs';

function waitForFile(p,deadline){
  if(existsSync(p))return Promise.resolve(true);
  return new Promise(resolve=>{const observer=watch(path.dirname(p),()=>{if(existsSync(p))finish(true);});
    const timer=setTimeout(()=>finish(false),Math.max(0,deadline-Date.now()));
    function finish(value){observer.close();clearTimeout(timer);resolve(value);}
  });
}
function waitForRegistration(p,deadline){
  const registered=()=>existsSync(p)&&readFileSync(p,'utf8').includes('owned host registered');
  if(registered())return Promise.resolve(true);
  return new Promise(resolve=>{const observer=watch(path.dirname(p),()=>{if(registered())finish(true);});
    const timer=setTimeout(()=>finish(false),Math.max(0,deadline-Date.now()));
    function finish(value){observer.close();clearTimeout(timer);resolve(value);}
  });
}
const alive=pid=>{try{process.kill(pid,0);return true;}catch(error){if(error.code==='ESRCH')return false;throw error;}};

test('isolated prepared Python excludes a proven active sitecustomize gate and queries the actual kernel',async t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'r2-isolation-')),gate=path.join(dir,'gate'),baselineMarker=path.join(dir,'baseline-hook'),isolatedMarker=path.join(dir,'isolated-hook');
  writeFileSync(path.join(dir,'sitecustomize.py'),"import os,time\nopen(os.environ['MADO_HOOK_MARKER'],'w').write('hook')\nwhile not os.path.exists(os.environ['MADO_HOOK_GATE']): time.sleep(0.01)\n");
  const baseline=spawn('/usr/bin/python3',['-c','print("released",flush=True)'],{env:{...process.env,PYTHONPATH:dir,MADO_HOOK_MARKER:baselineMarker,MADO_HOOK_GATE:gate},stdio:'ignore'});
  const ended=new Promise(resolve=>baseline.once('close',resolve));let inspector,host;
  t.after(async()=>{writeFileSync(gate,'release');baseline.kill('SIGKILL');await ended;if(host){host.kill('SIGKILL');host.unref();}if(inspector)await inspector.close();rmSync(dir,{recursive:true,force:true});});
  assert.equal(await waitForFile(baselineMarker,Date.now()+10000),true,'non-isolated fixture must execute the controlled hook');
  inspector=await prepareHostInspector({deadline:Date.now()+10000,env:{...process.env,PYTHONPATH:dir,MADO_HOOK_MARKER:isolatedMarker,MADO_HOOK_GATE:gate}});
  assert.equal(inspector.ready,true);assert.equal(existsSync(isolatedMarker),false);
  assert.equal(inspector.diagnostics.startup.isolated,true);assert.equal(inspector.diagnostics.startup.noSite,true);
  assert.equal(typeof inspector.diagnostics.startup.elapsedMilliseconds,'number');
  assert.deepEqual(inspector.diagnostics.startup.stages.map(s=>s.stage),['interpreter-boot','imports-ready','os-bindings-ready']);
  const token=randomUUID();host=spawn(process.execPath,['-e','process.send("ready");setInterval(()=>{},1000)'],{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:token},stdio:['ignore','ignore','ignore','ipc']});
  await new Promise(resolve=>host.once('message',resolve));
  const result=await inspector.query({token,executable:realpathSync(process.execPath),uid:process.getuid(),pids:[host.pid],notAfter:Date.now()+1000});
  assert.equal(result.complete,true);assert.equal(result.processes[0].pid,host.pid);assert.equal(result.processes[0].marker,token);
  assert.equal(result.transport.stage,'complete');assert.equal(result.transport.timeoutMilliseconds<=1000,true);
  assert.equal(typeof result.transport.processingMilliseconds,'number');
  const pid=inspector.pid;assert.deepEqual(await inspector.close(),{closed:true,reaped:true});assert.equal(alive(pid),false);
  t.diagnostic(JSON.stringify({startup:inspector.diagnostics.startup,query:result.transport}));
});

for(const trigger of ['observed','deadline','interrupt'])test(`direct owned signal precedes coupled control-session teardown on ${trigger}`,async t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'r2-coupled-')),journal=path.join(dir,'journal'),workerMarker=path.join(dir,'worker');
  let inspector,sentinel,pending;
  t.after(async()=>{if(pending)await pending;if(sentinel){sentinel.kill('SIGKILL');sentinel.unref();}if(inspector)await inspector.close();rmSync(dir,{recursive:true,force:true});});
  inspector=await prepareHostInspector({deadline:Date.now()+10000});assert.equal(inspector.ready,true);
  const token=randomUUID(),executable=realpathSync(process.execPath);
  sentinel=spawn(process.execPath,['-e','process.send("ready");setInterval(()=>{},1000)'],{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:'sentinel-'+token},stdio:['ignore','ignore','ignore','ipc']});
  await new Promise(resolve=>sentinel.once('message',resolve));
  const hostSource=`const fs=require('node:fs');process.on('SIGTERM',()=>{fs.appendFileSync(${JSON.stringify(journal)},'host-term\\n');process.exit(0)});process.on('disconnect',()=>{fs.appendFileSync(${JSON.stringify(journal)},'control-session-lost\\n');process.exit(0)});process.send('ready');setInterval(()=>{},1000);`;
  const workerSource=`const fs=require('node:fs');process.on('SIGTERM',()=>{fs.appendFileSync(${JSON.stringify(journal)},'worker-term\\n');process.exit(0)});fs.writeFileSync(${JSON.stringify(workerMarker)},String(process.pid));const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(hostSource)}],{detached:true,stdio:['ignore','ignore','ignore','ipc']});c.on('message',()=>{});setInterval(()=>{},1000);`;
  const abort=new AbortController(),logPath=path.join(dir,'native.log');
  pending=runProcessGroup({command:process.execPath,args:['-e',workerSource],preparedInspector:inspector,
    env:{...process.env,MADO_TEST_RUN_TOKEN:token,MADO_HOST_EXECUTABLE:executable,MADO_HOST_OWNERSHIP_REQUIRED:'1'},
    logPath,deadline:Date.now()+1000,graceMs:80,drainMs:1000,cancelOnHostObserved:trigger==='observed',signal:abort.signal,
    hostSignal:(pid,name)=>{appendFileSync(journal,'direct-'+name+'\n');process.kill(pid,name);},
    groupSignal:(group,name)=>{appendFileSync(journal,'group-'+name+'\n');process.kill(-group,name);}});
  if(trigger==='interrupt'){assert.equal(await waitForRegistration(logPath,Date.now()+10000),true);abort.abort();}
  const result=await pending;assert.equal(result.status,70);assert.equal(result.drained,true);
  assert.equal(result.hostOwnership.observed,true);assert.equal(result.hostOwnership.signals.length>0,true);
  const entries=readFileSync(journal,'utf8').trim().split('\n'),direct=entries.findIndex(s=>s.startsWith('direct-'));
  assert.equal(direct>=0,true);assert.equal(entries.findIndex(s=>s.startsWith('group-'))>direct,true,'direct host action precedes every worker-group teardown signal');
  assert.equal(alive(sentinel.pid),true);assert.equal(result.inspector.closed,true);assert.equal(result.inspector.reaped,true);
  assert.equal(alive(inspector.pid),false);assert.equal(result.hostOwnership.live.length,0);
  const nextMarker=path.join(dir,'next');const next=await runProcessGroup({command:process.execPath,args:['-e',`require('node:fs').writeFileSync(${JSON.stringify(nextMarker)},'after-drain')`],logPath:path.join(dir,'next.log'),deadline:Date.now()+2000});
  assert.equal(next.status,0);assert.equal(next.drained,true);assert.equal(readFileSync(nextMarker,'utf8'),'after-drain');
  t.diagnostic(JSON.stringify({trigger,result,entries}));
});
