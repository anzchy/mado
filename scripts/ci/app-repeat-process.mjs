#!/usr/bin/env node
/** Run one iteration in a private process group, and never leave live descendants behind silently. */
import { spawn, spawnSync } from 'node:child_process';
import { openSync, closeSync, appendFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {createHostOwnership} from './app-host-ownership.mjs';

function liveGroupMembers(group) {
  const ps = spawnSync('ps', ['-axo', 'pid=,pgid=,stat='], {encoding:'utf8',timeout:1000});
  if (ps.error || ps.status !== 0) return null;
  return ps.stdout.trim().split('\n').map(line => line.trim().split(/\s+/))
    .filter(([pid,pgid,state]) => Number(pgid) === group && Number(pid) > 0 && state && !state.startsWith('Z'));
}

export async function runProcessGroup({ command, args = [], env = process.env, logPath,
  deadline, graceMs = 250, drainMs = 1500,cancelOnHostObserved=false,hostQuery,hostSignal } = {}) {
  if (!Number.isFinite(deadline) || deadline <= Date.now()) {
    appendFileSync(logPath, 'app-repeat: job time budget exhausted\n');
    return {status:70,drained:true};
  }
  let host,child;
  try {
    if(env.MADO_HOST_OWNERSHIP_REQUIRED!==undefined&&env.MADO_HOST_OWNERSHIP_REQUIRED!=='1')
      throw new Error('invalid hosted ownership requirement');
    if(env.MADO_HOST_OWNERSHIP_REQUIRED==='1')host=createHostOwnership({token:env.MADO_TEST_RUN_TOKEN,executable:env.MADO_HOST_EXECUTABLE,excludeGroup:()=>child?.pid,query:hostQuery,signal:hostSignal});
    else if(env.MADO_HOST_EXECUTABLE)throw new Error('host executable requires explicit ownership policy');
  }catch(error){appendFileSync(logPath,`app-repeat: ${error.message}\n`);return {status:70,drained:false,hostOwnership:{observed:false,drained:false,unknown:[error.message]}};}
  const childEnv={...env};
  if(env.MADO_TEST_RUN_TOKEN)childEnv.TEST_RUNNER_MADO_TEST_RUN_TOKEN=env.MADO_TEST_RUN_TOKEN;
  const fd = openSync(logPath, 'a');
  try { child = spawn(command,args,{env:childEnv,detached:true,stdio:['ignore',fd,fd]}); }
  finally { closeSync(fd); }
  if (!child.pid) {
    // Consume the asynchronous spawn error so a missing executable cannot crash the supervisor.
    await new Promise(resolve => child.once('error',resolve));
    appendFileSync(logPath, 'app-repeat: iteration could not start\n');
    return {status:70,drained:true};
  }
  const group = child.pid;
  return await new Promise(resolve => {
    let done = false, stopping = false, poll, kill, drain,hostPoll,cleanup,cancelledOnHostObserved=false;
    const log = text => appendFileSync(logPath,`app-repeat: ${text}\n`);
    const finish = (status, drained) => {
      if (done) return;
      done = true;
      clearTimeout(timer); clearInterval(poll); clearTimeout(kill); clearTimeout(drain);clearInterval(hostPoll);
      process.removeListener('SIGTERM',interrupted); process.removeListener('SIGINT',interrupted);
      child.unref();
      const hostOwnership=host?.snapshot();
      if(hostOwnership)log(`host ownership ${JSON.stringify(hostOwnership)}`);
      resolve({status,drained,group,cancelledOnHostObserved,...(cleanup?{cleanup}:{}),...(hostOwnership?{hostOwnership}:{})});
    };
    const signal = name => {
      try { process.kill(-group,name); }
      catch (error) { if (error.code !== 'ESRCH') log(`cannot signal process group: ${error.message}`); }
    };
    const observeHost=()=>{
      const before=host?.snapshot().identities.length??0;host?.observe();
      const after=host?.snapshot();
      if(after&&after.identities.length>before)log(`owned host registered ${JSON.stringify(after.identities.slice(before))}`);
      if(cancelOnHostObserved&&after?.observed&&!stopping&&!done){
        cancelledOnHostObserved=true;stop('owned host observed; cancelling requested probe');
      }
    };
    const check = () => {
      const members = liveGroupMembers(group);
      observeHost();
      if (members !== null && members.length === 0&&(!host||host.snapshot().drained)){finish(70,true);return;}
      if(done||!host||!stopping||!cleanup||Date.now()>=cleanup.drainDeadline)return;
      const phase=Date.now()>=cleanup.graceDeadline?'SIGKILL':'SIGTERM',ownership=host.snapshot();
      const pending=ownership.identities.some(identity=>ownership.live.includes(identity.pid)&&
        !ownership.signals.some(sent=>sent.pid===identity.pid&&sent.birth===identity.birth&&sent.signal===phase));
      if(pending)host.signalOwned(phase,{notAfter:phase==='SIGTERM'?cleanup.graceDeadline:cleanup.drainDeadline});
    };
    const stop = reason => {
      if (done || stopping) return;
      stopping = true;
      log(reason);
      observeHost();
      signal('SIGTERM');
      host?.signalOwned('SIGTERM');
      const graceStartedAt=Date.now();
      cleanup=Object.freeze({graceStartedAt,graceDeadline:graceStartedAt+graceMs,drainDeadline:graceStartedAt+graceMs+drainMs});
      poll = setInterval(check,25);
      kill = setTimeout(() => { signal('SIGKILL');check(); },graceMs);
      drain = setTimeout(() => {
        const members = liveGroupMembers(group);
        observeHost();
        if (members !== null && members.length === 0&&(!host||host.snapshot().drained)) finish(70,true);
        else { log('process group still live or unverifiable after KILL; no further iterations allowed'); finish(70,false); }
      },graceMs+drainMs);
      check();
    };
    const interrupted = () => stop('supervisor interrupted; terminating iteration process group');
    process.on('SIGTERM',interrupted); process.on('SIGINT',interrupted);
    const timer = setTimeout(() => stop('job time budget exhausted; terminating iteration process group'),Math.max(1,deadline-Date.now()));
    if(host){hostPoll=setInterval(observeHost,50);observeHost();}
    child.once('error',error => stop(`iteration startup failed: ${error.message}`));
    child.once('exit',(code,signalName) => {
      if (done || stopping) return;
      const members = liveGroupMembers(group);
      observeHost();
      if (members !== null && members.length === 0&&(!host||host.snapshot().drained)) finish(signalName || code === null ? 70 : code,true);
      else stop('iteration leader exited with live descendants; terminating process group');
    });
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [deadline, logPath, command, ...args] = process.argv.slice(2);
  try { process.stdout.write(JSON.stringify(await runProcessGroup({deadline:Number(deadline),logPath,command,args}))); }
  catch (error) { process.stderr.write(`app-repeat supervisor: ${error.message}\n`); process.exitCode = 70; }
}
