import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {existsSync,mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const lock=fileURLToPath(new URL('../heavy-lock.sh',import.meta.url));
const alive=pid=>{
  const run=spawnSync('/bin/ps',['-p',String(pid),'-o','stat='],{encoding:'utf8',timeout:1000});
  return run.status===0&&run.stdout.trim()&&!run.stdout.trim().startsWith('Z');
};
const wait=async(predicate,label)=>{
  for(let i=0;i<150&&!predicate();i++)await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(predicate(),label);
};
const guardianPID=directory=>{
  const owner=readdirSync(directory).find(name=>name.startsWith('heavy.lock.guardian-')&&name.endsWith('.owner'));
  assert.ok(owner,'guardian owner record exists');
  return Number(/^pid=(\d+)$/m.exec(readFileSync(path.join(directory,owner),'utf8'))?.[1]);
};

test('hostUnknownStillDrainsKnownWorkAndReleasesGuardian',async t=>{
  const sentinel=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'});
  sentinel.unref();t.after(()=>{try{process.kill(sentinel.pid,'SIGKILL');}catch{}});
  for(const [mode,trigger,registered] of [
    ['local','timeout',false],['ci','timeout',false],['local','cancel',false],['ci','cancel',false],
    ['local','timeout',true]]){
    const directory=mkdtempSync(path.join(tmpdir(),'i657-unknown-'));
    const lockPath=path.join(directory,'heavy.lock'),pidPath=path.join(directory,'member.pid');
    const hostPath=path.join(directory,'host.pid'),ready=path.join(directory,'ready');
    const statusPath=path.join(directory,'status.json'),runner=path.join(directory,'runner.mjs');
    const owned=[];
    t.after(()=>{
      for(const pid of owned)try{process.kill(pid,'SIGKILL');}catch{}
      if(existsSync(directory))for(const name of readdirSync(directory).filter(name=>name.startsWith('heavy.lock.guardian-')&&name.endsWith('.owner'))){
        const pid=Number(/^pid=(\d+)$/m.exec(readFileSync(path.join(directory,name),'utf8'))?.[1]);
        if(pid>0)try{process.kill(pid,'SIGKILL');}catch{}
      }
      rmSync(directory,{recursive:true,force:true});
    });
    const childSource=`const fs=require('node:fs');process.on('SIGTERM',()=>{});`+
      `fs.writeFileSync(${JSON.stringify(path.join(directory,'member-ready'))},'ready');setInterval(()=>{},1000);`;
    writeFileSync(runner,`import {spawn,spawnSync} from 'node:child_process';import {writeFileSync,existsSync} from 'node:fs';\n`+
      `const member=spawn(process.execPath,['-e',${JSON.stringify(childSource)}],{stdio:'ignore'});`+
      `writeFileSync(${JSON.stringify(pidPath)},String(member.pid));\n`+
      `while(!existsSync(${JSON.stringify(path.join(directory,'member-ready'))}))await new Promise(r=>setTimeout(r,10));\n`+
      `const fd=Number(process.env.PICSEE_HEAVY_CONTROL_FD),stdio=['ignore','ignore','ignore'];`+
      `while(stdio.length<=fd)stdio.push('ignore');stdio[fd]=fd;\n`+
      (registered?`const host=spawn(process.execPath,['-e',${JSON.stringify(childSource)}],{detached:true,stdio:'ignore'});`+
        `writeFileSync(${JSON.stringify(hostPath)},String(host.pid));`+
        `const hostRegistration=spawnSync(${JSON.stringify(lock)},['--register-host',String(host.pid)],`+
        `{env:process.env,stdio,timeout:2000});if(hostRegistration.status!==0)process.exit(72);\n`:'')+
      `const mark=spawnSync(${JSON.stringify(lock)},['--mark-host-unknown'],`+
      `{env:process.env,stdio,timeout:2000});if(mark.status!==0)process.exit(73);`+
      `writeFileSync(${JSON.stringify(ready)},'ready');setInterval(()=>{},1000);\n`);
    const env={...process.env,PICSEE_HEAVY_LOCK:lockPath,PICSEE_MDPRO_LOCK:'off',
      PICSEE_HEAVY_LOCK_WAIT_SECS:'0.3',PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1',
      PICSEE_HEAVY_LOCK_EXEC_SECS:trigger==='timeout'?'0.9':'5',PICSEE_HEAVY_STATUS_PATH:statusPath,
      ...(mode==='ci'?{PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_HEAVY_CI_TEST:'1'}:
        {PICSEE_HEAVY_LOCK_HELD:'',PICSEE_HEAVY_CI_TOP_LEVEL:''})};
    delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
    let result;
    if(trigger==='timeout')result=spawnSync(lock,[process.execPath,runner],{env,encoding:'utf8',timeout:9000});
    else{
      const job=spawn(lock,[process.execPath,runner],{env,stdio:['ignore','pipe','pipe']});
      let output='';job.stdout.on('data',chunk=>output+=chunk);job.stderr.on('data',chunk=>output+=chunk);
      const done=new Promise(resolve=>job.on('close',(code,signal)=>resolve({status:code,signal,stderr:output})));
      await wait(()=>existsSync(ready),`${mode} cancel fixture ready`);
      job.kill('SIGINT');result=await done;
    }
    assert.equal(result.status,70,`${mode}/${trigger}: ${result.stderr}`);
    assert.equal(existsSync(pidPath),true,`${mode}/${trigger}: known member started`);
    owned.push(Number(readFileSync(pidPath,'utf8')));
    if(registered){assert.equal(existsSync(hostPath),true);owned.push(Number(readFileSync(hostPath,'utf8')));}
    const status=JSON.parse(readFileSync(statusPath,'utf8'));
    assert.equal(status.cleanup,'incomplete');
    assert.equal(status.timedOut,trigger==='timeout');
    for(const pid of owned)assert.equal(alive(pid),false,`${mode}/${trigger}: known PID ${pid} survived`);
    const guardian=guardianPID(directory);
    await wait(()=>!alive(guardian),`${mode}/${trigger}: guardian exits`);
    const nextEnv={...env,PICSEE_HEAVY_LOCK_HELD:'',PICSEE_HEAVY_CI_TOP_LEVEL:'',PICSEE_HEAVY_CI_TEST:'',
      PICSEE_HEAVY_LOCK_EXEC_SECS:'1'};delete nextEnv.PICSEE_HEAVY_STATUS_PATH;
    const next=spawnSync(lock,['true'],{env:nextEnv,encoding:'utf8',timeout:3000});
    assert.equal(next.status,0,`${mode}/${trigger}: flock not reusable: ${next.stderr}`);
    assert.equal(alive(sentinel.pid),true,'unrelated process survives');
  }
},{timeout:60000});
