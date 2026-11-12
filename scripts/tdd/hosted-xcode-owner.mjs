#!/usr/bin/env node
/** Observe the LaunchServices App host while xcodebuild runs, and register it with the owner. */
import {spawn,spawnSync} from 'node:child_process';
import {realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {queryHostProcesses} from '../ci/app-host-ownership.mjs';

const lock=fileURLToPath(new URL('../heavy-lock.sh',import.meta.url));
const [command,...args]=process.argv.slice(2);
const token=process.env.MADO_TEST_RUN_TOKEN;
const executable=process.env.MADO_HOST_EXECUTABLE;
const control=Number(process.env.PICSEE_HEAVY_CONTROL_FD);
if(!command||!token||!executable||!Number.isInteger(control)||control<3||control>64){
  process.stderr.write('hosted-owner: missing host identity or parent registration channel; cleanup incomplete\n');
  process.exit(70);
}
let canonical;
try{canonical=realpathSync(executable);}catch{
  process.stderr.write('hosted-owner: App executable unavailable; cleanup incomplete\n');
  process.exit(70);
}
const stdio=['ignore','ignore','ignore'];
while(stdio.length<=control)stdio.push('ignore');
stdio[control]=control;
const flock=Number(process.env.PICSEE_HEAVY_FLOCK_FD);
if(Number.isInteger(flock)&&flock>=3&&flock<=64){while(stdio.length<=flock)stdio.push('ignore');stdio[flock]=flock;}
const identities=new Map();
let uncertain=false,observed=false,childExited=false,childCode=null,childSignal=null,stopping=false;
const child=spawn(command,args,{env:process.env,stdio:['ignore','pipe','pipe']});
child.stdout.pipe(process.stdout);child.stderr.pipe(process.stderr);
child.on('error',error=>{uncertain=true;childExited=true;process.stderr.write(`hosted-owner: native launch failed: ${error.message}\n`);});
child.on('close',(code,signal)=>{childExited=true;childCode=code;childSignal=signal;});
for(const name of ['SIGINT','SIGTERM'])process.on(name,()=>{
  stopping=true;try{child.kill(name);}catch{};
});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const settledAt=()=>Date.now()+30000;
let drainDeadline=null;
while(true){
  const snapshot=queryHostProcesses({token,executable:canonical});
  if(process.env.MADO_HOST_QUERY_DIAGNOSTICS==='1')
    process.stderr.write('hosted-owner: query '+JSON.stringify({at:Date.now(),childPid:child.pid,
      childExited,childCode,childSignal,drainDeadline,stopping,
      snapshot:{complete:snapshot.complete,transport:snapshot.transport,unknown:snapshot.unknown,
        candidateCount:snapshot.processes.length,processes:snapshot.processes.filter(row=>row.marker===token)}})+'\n');
  if(!snapshot.complete||snapshot.unknown.length)uncertain=true;
  else{
    const current=snapshot.processes.filter(p=>p.marker===token&&p.executable===canonical&&
      p.pid!==process.pid&&p.pid!==child.pid);
    for(const identity of current){
      observed=true;
      const prior=identities.get(identity.pid);
      if(prior&&prior.birth!==identity.birth){uncertain=true;continue;}
      if(!prior){
        const run=spawnSync(lock,['--register-host',String(identity.pid)],
          {env:process.env,stdio,timeout:2000});
        if(run.status!==0||run.error){
          uncertain=true;
          process.stderr.write(`hosted-owner: host registration failed pid=${identity.pid}; cleanup incomplete\n`);
        }else{
          identities.set(identity.pid,identity);
          process.stderr.write(`hosted-owner: registered host pid=${identity.pid} at=${Date.now()}\n`);
        }
      }
    }
    if(childExited&&current.length===0)break;
  }
  if(childExited&&drainDeadline===null)drainDeadline=settledAt();
  if(drainDeadline!==null&&Date.now()>=drainDeadline){uncertain=true;break;}
  await sleep(100);
}
if(!observed||uncertain){
  const mark=spawnSync(lock,['--mark-host-unknown'],{env:process.env,stdio,timeout:2000});
  if(process.env.MADO_HOST_QUERY_DIAGNOSTICS==='1')
    process.stderr.write('hosted-owner: unknown cleanup mark '+JSON.stringify({at:Date.now(),status:mark.status,
      signal:mark.signal,error:mark.error?.message??null,observed,uncertain,childExited,childCode,childSignal})+'\n');
  if(mark.status!==0||mark.error)
    process.stderr.write('hosted-owner: supervisor could not record unknown host cleanup\n');
}
if(!observed||uncertain||stopping||childSignal){
  process.stderr.write('hosted-owner: host cleanup incomplete or unregistered; refusing result\n');
  process.exitCode=70;
}else process.exitCode=childCode??70;
