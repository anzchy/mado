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
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath,MADO_HOST_QUERY_DIAGNOSTICS:'1'};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const startedAt=Date.now();
  const run=spawnSync(lock,[process.execPath,owner,process.execPath,runner],{env,encoding:'utf8',timeout:8000});
  t.diagnostic(JSON.stringify({startedAt,endedAt:Date.now(),status:run.status,signal:run.signal,
    error:run.error?.message??null,stdout:run.stdout,stderr:run.stderr,
    files:readdirSync(dir).sort().filter(name=>name==='status.json'||name==='host.pid'||
      name.includes('.guardian-')).map(name=>({name,content:readFileSync(path.join(dir,name),'utf8')}))},null,2));
  assert.equal(run.status,0,run.stdout+run.stderr);
  const pid=Number(readFileSync(pidPath,'utf8'));
  assert.ok(Number.isInteger(pid)&&pid>0);
  assert.match(run.stderr,/hosted-owner: registered host pid=/);
  assert.equal(JSON.parse(readFileSync(env.PICSEE_HEAVY_STATUS_PATH,'utf8')).cleanup,'complete');
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
