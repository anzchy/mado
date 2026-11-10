#!/usr/bin/env node
/** Run one iteration in a private process group, and never leave live descendants behind silently. */
import { spawn, spawnSync } from 'node:child_process';
import { openSync, closeSync, appendFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startGroupObservation } from './app-repeat-observer.mjs';

function liveGroupMembers(group) {
  const ps = spawnSync('ps', ['-axo', 'pid=,pgid=,stat='], {encoding:'utf8',timeout:1000});
  if (ps.error || ps.status !== 0) return null;
  return ps.stdout.trim().split('\n').map(line => line.trim().split(/\s+/))
    .filter(([pid,pgid,state]) => Number(pgid) === group && Number(pid) > 0 && state && !state.startsWith('Z'));
}

export async function runProcessGroup({ command, args = [], env = process.env, logPath,
  deadline, graceMs = 250, drainMs = 1500, observation = {} } = {}) {
  if (!Number.isFinite(deadline) || deadline <= Date.now()) {
    appendFileSync(logPath, 'app-repeat: job time budget exhausted\n');
    return {status:70,drained:true};
  }
  const fd = openSync(logPath, 'a');
  let child;
  try { child = spawn(command,args,{env,detached:true,stdio:['ignore',fd,fd]}); }
  finally { closeSync(fd); }
  if (!child.pid) {
    // Consume the asynchronous spawn error so a missing executable cannot crash the supervisor.
    await new Promise(resolve => child.once('error',resolve));
    appendFileSync(logPath, 'app-repeat: iteration could not start\n');
    return {status:70,drained:true};
  }
  const group = child.pid;
  const observer = env.APP_REPEAT_OBSERVE === '1' ? startGroupObservation({ ...observation, group,
    write: row => appendFileSync(logPath, `[i600.supervisor] ${JSON.stringify(row)}\n`) }) : null;
  return await new Promise(resolve => {
    let done = false, stopping = false, poll, kill, drain;
    const log = text => appendFileSync(logPath,`app-repeat: ${text}\n`);
    const finish = async (status, drained) => {
      if (done) return;
      done = true;
      clearTimeout(timer); clearInterval(poll); clearTimeout(kill); clearTimeout(drain);
      process.removeListener('SIGTERM',interrupted); process.removeListener('SIGINT',interrupted);
      child.unref();
      const observationResult = await observer?.stop();
      const observerUndrained = observationResult?.drained === false;
      resolve({status,drained:drained && !observerUndrained,group,
        ...(observerUndrained ? {observerUndrained:true} : {})});
    };
    const signal = name => {
      try { process.kill(-group,name); }
      catch (error) { if (error.code !== 'ESRCH') log(`cannot signal process group: ${error.message}`); }
    };
    const check = () => {
      const members = liveGroupMembers(group);
      if (members !== null && members.length === 0) finish(70,true);
    };
    const stop = reason => {
      if (done || stopping) return;
      stopping = true;
      log(reason);
      signal('SIGTERM');
      poll = setInterval(check,25);
      kill = setTimeout(() => { signal('SIGKILL'); check(); },graceMs);
      drain = setTimeout(() => {
        const members = liveGroupMembers(group);
        if (members !== null && members.length === 0) finish(70,true);
        else { log('process group still live or unverifiable after KILL; no further iterations allowed'); finish(70,false); }
      },graceMs+drainMs);
      check();
    };
    const interrupted = () => stop('supervisor interrupted; terminating iteration process group');
    process.on('SIGTERM',interrupted); process.on('SIGINT',interrupted);
    const timer = setTimeout(() => stop('job time budget exhausted; terminating iteration process group'),Math.max(1,deadline-Date.now()));
    child.once('error',error => stop(`iteration startup failed: ${error.message}`));
    child.once('exit',(code,signalName) => {
      if (done || stopping) return;
      const members = liveGroupMembers(group);
      if (members !== null && members.length === 0) finish(signalName || code === null ? 70 : code,true);
      else stop('iteration leader exited with live descendants; terminating process group');
    });
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [deadline, logPath, command, ...args] = process.argv.slice(2);
  try { process.stdout.write(JSON.stringify(await runProcessGroup({deadline:Number(deadline),logPath,command,args}))); }
  catch (error) { process.stderr.write(`app-repeat supervisor: ${error.message}\n`); process.exitCode = 70; }
}
