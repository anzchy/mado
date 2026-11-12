import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';

const lock=fileURLToPath(new URL('../../heavy-lock.sh',import.meta.url));
const owner=fileURLToPath(new URL('../../tdd/hosted-xcode-owner.mjs',import.meta.url));
const alive=pid=>{const probe=spawnSync('/bin/ps',['-p',String(pid),'-o','stat='],{encoding:'utf8'});
  return probe.status===0&&probe.stdout.trim()&&!probe.stdout.trim().startsWith('Z');};
const ownerEvents=(stderr,kind)=>stderr.split('\n').filter(line=>line.startsWith(`hosted-owner: ${kind} `))
  .map(line=>JSON.parse(line.slice(`hosted-owner: ${kind} `.length)));
test('hostedOwnerClearsTransientUnrelatedUnknownBeforeCleanupDecision',t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host ownership inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-owner-transient-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const runner=path.join(dir,'runner.mjs'),hostPath=path.join(dir,'host.pid');
  const loader=path.join(dir,'loader.mjs');
  const ownershipURL=new URL('../app-host-ownership.mjs',import.meta.url).href;
  writeFileSync(loader,`export async function load(url,context,nextLoad){
    if(url!==${JSON.stringify(ownershipURL)})return nextLoad(url,context);
    return {format:'module',shortCircuit:true,source:
      'import {queryHostProcesses as real} from '+JSON.stringify(url+'?real')+';'+
      'let injected=false; export function queryHostProcesses(options){const snapshot=real(options);'+
      'if(!injected&&snapshot.complete&&snapshot.processes.some(p=>p.marker===options.token)){' +
      'injected=true; return {...snapshot,unknown:[...snapshot.unknown,{pid:999999,reason:"transient unrelated unreadable PID"}]};}'+
      'return snapshot;}'};
  }\n`);
  writeFileSync(runner,`import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';\n`+
    `const host=spawn(process.execPath,['-e','setTimeout(()=>{},850)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `writeFileSync(${JSON.stringify(hostPath)},String(host.pid));host.unref();setTimeout(()=>{},250);\n`);
  const env={...process.env,PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    PICSEE_HEAVY_STATUS_PATH:path.join(dir,'status.json'),PICSEE_HEAVY_LOCK:path.join(dir,'heavy.lock'),
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath,MADO_HOST_QUERY_DIAGNOSTICS:'1'};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  delete env.MDPRO_HEAVY_LOCK_HELD;
  const run=spawnSync(lock,[process.execPath,'--loader',loader,owner,process.execPath,runner],
    {env,encoding:'utf8',timeout:8000});
  assert.match(run.stderr,/transient unrelated unreadable PID/,run.stdout+run.stderr);
  assert.equal(run.status,0,run.stdout+run.stderr);
  assert.ok(ownerEvents(run.stderr,'registration').some(event=>event.result==='registered'));
  assert.equal(JSON.parse(readFileSync(env.PICSEE_HEAVY_STATUS_PATH,'utf8')).cleanup,'complete');
});
for(const failure of [
  {name:'unrelated PID',reply:'{...snapshot,unknown:[...snapshot.unknown,{pid:999999,reason:"unreadable kernel birth identity"}]}'},
  {name:'PID-free transport timeout',reply:'{complete:false,processes:[],unknown:[{reason:"OS ownership inspection failed"}],transport:{stage:"process",status:null,signal:"SIGTERM",errorCode:"ETIMEDOUT"}}'}
])test(`hostedOwnerRequeriesAfterPostDrain${failure.name.replace(/[^A-Za-z]/g,'')}Uncertainty`,t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host ownership inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-owner-post-drain-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const runner=path.join(dir,'runner.mjs'),loader=path.join(dir,'loader.mjs');
  const ownershipURL=new URL('../app-host-ownership.mjs',import.meta.url).href;
  writeFileSync(loader,`export async function load(url,context,nextLoad){
    if(url!==${JSON.stringify(ownershipURL)})return nextLoad(url,context);
    return {format:'module',shortCircuit:true,source:
      'import {queryHostProcesses as real} from '+JSON.stringify(url+'?real')+';'+
      'let seen=false,injected=false; export function queryHostProcesses(options){const snapshot=real(options);'+
      'const hosts=snapshot.processes.filter(p=>p.marker===options.token&&p.ppid===1);'+
      'if(hosts.length)seen=true;'+
      'if(seen&&!injected&&snapshot.complete&&hosts.length===0){injected=true;return '+
      ${JSON.stringify(failure.reply)}+';}return snapshot;}'};
  }\n`);
  writeFileSync(runner,`import {spawn} from 'node:child_process';\n`+
    `const host=spawn(process.execPath,['-e','setTimeout(()=>{},850)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `host.unref();setTimeout(()=>{},250);\n`);
  const env={...process.env,PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    PICSEE_HEAVY_STATUS_PATH:path.join(dir,'status.json'),PICSEE_HEAVY_LOCK:path.join(dir,'heavy.lock'),
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  delete env.MDPRO_HEAVY_LOCK_HELD;
  const run=spawnSync(lock,[process.execPath,'--loader',loader,owner,process.execPath,runner],
    {env,encoding:'utf8',timeout:8000});
  const queries=ownerEvents(run.stderr,'query');
  const uncertain=queries.find(event=>event.snapshot.unknown.some(item=>item.reason===
    (failure.name==='unrelated PID'?'unreadable kernel birth identity':'OS ownership inspection failed')));
  assert.ok(uncertain,run.stderr);
  assert.equal(uncertain.child.exited,true,'the child has exited before this post-drain uncertainty');
  assert.equal(run.status,0,run.stdout+run.stderr);
  const registered=ownerEvents(run.stderr,'registration').find(event=>event.result==='registered');
  assert.ok(registered);
  assert.equal(uncertain.matching.some(row=>row.pid===registered.pid),false,
    `registered host has drained; registration=${JSON.stringify(registered)} uncertainty=${JSON.stringify(uncertain)} stderr=${run.stderr}`);
  const [decision]=ownerEvents(run.stderr,'decision');
  assert.equal(decision?.result,'complete');
  assert.deepEqual(decision.lastSnapshot.unknown,[]);
  assert.equal(decision.hostAlive,false);
});
test('hostedAppLaunchServicesHostIsRegisteredBeforeCleanupCompletes',t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host ownership inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-owner-native-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const runner=path.join(dir,'runner.mjs'),pidPath=path.join(dir,'host.pid');
  writeFileSync(runner,`import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';\n`+
    `const host=spawn(process.execPath,['-e','setTimeout(()=>{},600)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `writeFileSync(${JSON.stringify(pidPath)},String(host.pid));host.unref();setTimeout(()=>{},150);\n`);
  const env={...process.env,PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    PICSEE_HEAVY_STATUS_PATH:path.join(dir,'status.json'),PICSEE_HEAVY_LOCK:path.join(dir,'heavy.lock'),
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath};
  delete env.MADO_HOST_QUERY_DIAGNOSTICS;
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const startedAt=Date.now();
  const run=spawnSync(lock,[process.execPath,owner,process.execPath,runner],{env,encoding:'utf8',timeout:8000});
  if(process.env.PICSEE_HOST_TRACE_TAP!=='0')t.diagnostic(JSON.stringify({startedAt,endedAt:Date.now(),status:run.status,signal:run.signal,
    error:run.error?.message??null,stdout:run.stdout,stderr:run.stderr,
    files:readdirSync(dir).sort().filter(name=>name==='status.json'||name==='host.pid'||
      name.includes('.guardian-')).map(name=>({name,content:readFileSync(path.join(dir,name),'utf8')}))},null,2));
  assert.equal(run.status,0,run.stdout+run.stderr);
  const pid=Number(readFileSync(pidPath,'utf8'));
  assert.ok(Number.isInteger(pid)&&pid>0);
  assert.ok(ownerEvents(run.stderr,'registration').some(event=>event.result==='registered'&&event.pid===pid));
  assert.equal(JSON.parse(readFileSync(env.PICSEE_HEAVY_STATUS_PATH,'utf8')).cleanup,'complete');
  const queries=ownerEvents(run.stderr,'query');
  const registrations=ownerEvents(run.stderr,'registration');
  const [decision]=ownerEvents(run.stderr,'decision');
  assert.ok(queries.length>=2,'real lane emits every query without a diagnostic flag');
  assert.ok(queries.every(event=>Number.isFinite(event.snapshot.transport.elapsedMilliseconds)&&
    event.snapshot.transport.timeoutMilliseconds===5000),'every query line carries the OS transport timing budget');
  assert.ok(registrations.some(event=>event.result==='registered'&&event.pid===pid));
  assert.equal(decision?.result,'complete');
  assert.equal(decision.observed,true);
  assert.deepEqual(decision.registeredPids,[pid]);
  assert.equal(decision.lastSnapshot.complete,true);
  assert.deepEqual(decision.lastSnapshot.unknown,[]);
  assert.equal(decision.hostAlive,false);
  assert.equal(decision.child.code,0);
  assert.equal(decision.child.signal,null);
  assert.deepEqual(decision.refusedBy,[]);
});

test('hostedAppLaunchServicesMissingRegistrationFailsClosed',async t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host ownership inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-owner-missing-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const runner=path.join(dir,'runner.mjs');writeFileSync(runner,'setTimeout(()=>{},100);\n');
  const env={...process.env,PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    PICSEE_HEAVY_STATUS_PATH:path.join(dir,'status.json'),PICSEE_HEAVY_LOCK:path.join(dir,'heavy.lock'),
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(lock,[process.execPath,owner,process.execPath,runner],{env,encoding:'utf8',timeout:8000});
  assert.equal(run.status,70,run.stdout+run.stderr);
  assert.match(run.stderr,/host cleanup incomplete or unregistered/);
  const [decision]=ownerEvents(run.stderr,'decision');
  assert.equal(decision?.result,'refused');
  assert.equal(decision.observed,false);
  assert.deepEqual(decision.registeredPids,[]);
  assert.ok(decision.refusedBy.includes('host-never-observed'));
  assert.equal(JSON.parse(readFileSync(env.PICSEE_HEAVY_STATUS_PATH,'utf8')).cleanup,'incomplete');
  const guardians=readdirSync(dir).filter(name=>name.includes('.guardian-')&&name.endsWith('.owner'));
  assert.equal(guardians.length,1,'expected one guardian owner record');
  for(const name of guardians){
    const pid=Number(/^pid=(\d+)$/m.exec(readFileSync(path.join(dir,name),'utf8'))?.[1]);
    for(let attempt=0;attempt<150&&alive(pid);attempt++)await new Promise(resolve=>setTimeout(resolve,20));
    assert.equal(alive(pid),false,`missing registration leaked guardian ${pid}`);
  }
});

test('hostedAppLaneRegistersDetachedResistantHostUnderOuterTimeout',t=>{
  if(!['darwin','linux'].includes(process.platform)){t.skip('host inspector supports macOS and Linux');return;}
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-lane-positive-'));
  const hostPath=path.join(dir,'host.pid'),runner=path.join(dir,'runner.mjs');
  t.after(()=>{if(existsSync(hostPath)){const pid=Number(readFileSync(hostPath,'utf8'));
    try{process.kill(pid,'SIGKILL');}catch{}}rmSync(dir,{recursive:true,force:true});});
  writeFileSync(path.join(dir,'xcodebuild'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');const {spawn}=require('node:child_process');`+
    `const h=spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `fs.writeFileSync(${JSON.stringify(hostPath)},String(h.pid));h.unref();`+
    `setTimeout(()=>console.log('** TEST EXECUTE SUCCEEDED **'),150);\n`,{mode:0o755});
  const summary=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/summary.json',import.meta.url));
  const tests=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/tests.json',import.meta.url));
  writeFileSync(path.join(dir,'xcrun'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');process.stdout.write(fs.readFileSync(process.argv.includes('summary')?`+
    `${JSON.stringify(summary)}:${JSON.stringify(tests)},'utf8'));\n`,{mode:0o755});
  const lane=new URL('../../tdd/hosted-app-lane.mjs',import.meta.url).href;
  writeFileSync(runner,`import {runHostedAppLane} from ${JSON.stringify(lane)};`+
    `process.exitCode=runHostedAppLane({env:process.env,evidencePath:${JSON.stringify(path.join(dir,'evidence.log'))}}).status;\n`);
  const env={...process.env,PATH:dir+path.delimiter+process.env.PATH,
    PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_HEAVY_CI_TEST:'1',
    PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'4',
    PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1',PICSEE_HEAVY_STATUS_PATH:path.join(dir,'status.json'),
    PICSEE_HEAVY_LOCK:path.join(dir,'heavy.lock'),
    MADO_HOST_OWNERSHIP_REQUIRED:'1',MADO_HOST_EXECUTABLE:process.execPath};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(lock,[process.execPath,runner],{env,encoding:'utf8',timeout:9000});
  assert.equal(existsSync(hostPath),true,run.stdout+run.stderr);
  const pid=Number(readFileSync(hostPath,'utf8'));
  assert.equal(alive(pid),false,`registered host ${pid} survived outer timeout`);
  assert.equal(run.status===70||run.status===124,true,run.stdout+run.stderr);
  assert.equal(JSON.parse(readFileSync(env.PICSEE_HEAVY_STATUS_PATH,'utf8')).timedOut,true);
});
