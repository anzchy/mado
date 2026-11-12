#!/usr/bin/env node
/** Observe the LaunchServices App host while xcodebuild runs, and register it with the owner. */
import {spawn,spawnSync} from 'node:child_process';
import {realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {queryHostProcesses} from '../ci/app-host-ownership.mjs';
import {createHostedOwnerCertainty} from './hosted-owner-certainty.mjs';

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
const certainty=createHostedOwnerCertainty();
let observed=false,childExited=false,childCode=null,childSignal=null,stopping=false,hostPresent=false;
let lastSnapshot=null;
const blockingReasons=new Set();
const emit=(event,details)=>process.stderr.write(`hosted-owner: ${event} ${JSON.stringify({at:Date.now(),...details})}\n`);
const block=reason=>{certainty.block();blockingReasons.add(reason);};
const child=spawn(command,args,{env:process.env,stdio:['ignore','pipe','pipe']});
child.stdout.pipe(process.stdout);child.stderr.pipe(process.stderr);
child.on('error',error=>{block('native-launch-failed');childExited=true;
  emit('child-error',{message:error.message});});
child.on('close',(code,signal)=>{childExited=true;childCode=code;childSignal=signal;});
for(const name of ['SIGINT','SIGTERM'])process.on(name,()=>{
  stopping=true;try{child.kill(name);}catch{};
});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const settledAt=()=>Date.now()+30000;
let drainDeadline=null;
while(true){
  const snapshot=queryHostProcesses({token,executable:canonical});
  const matching=snapshot.processes.filter(row=>row.marker===token);
  lastSnapshot={complete:snapshot.complete,unknown:snapshot.unknown,
    transport:{stage:snapshot.transport?.stage,status:snapshot.transport?.status,
      signal:snapshot.transport?.signal,errorCode:snapshot.transport?.errorCode,
      elapsedMilliseconds:snapshot.transport?.elapsedMilliseconds,
      timeoutMilliseconds:snapshot.transport?.timeoutMilliseconds}};
  emit('query',{child:{pid:child.pid,exited:childExited,code:childCode,signal:childSignal},
    drainDeadline,stopping,snapshot:lastSnapshot,candidateCount:snapshot.processes.length,
    matching:matching.map(row=>({pid:row.pid,ppid:row.ppid,pgid:row.pgid,birth:row.birth,
      executableMatches:row.executable===canonical}))});
  if(certainty.observe(snapshot)){
    const current=snapshot.processes.filter(p=>p.marker===token&&p.executable===canonical&&
      p.pid!==process.pid&&p.pid!==child.pid);
    hostPresent=current.length>0;
    for(const identity of current){
      observed=true;
      const prior=identities.get(identity.pid);
      if(prior&&prior.birth!==identity.birth){block('host-identity-changed');
        emit('registration',{pid:identity.pid,result:'identity-changed',birth:identity.birth,registeredBirth:prior.birth});
        continue;}
      if(!prior){
        const run=spawnSync(lock,['--register-host',String(identity.pid)],
          {env:process.env,stdio,timeout:2000});
        if(run.status!==0||run.error){
          block('host-registration-failed');
          emit('registration',{pid:identity.pid,result:'failed',status:run.status,
            signal:run.signal,error:run.error?.message??null});
        }else{
          identities.set(identity.pid,identity);
          emit('registration',{pid:identity.pid,result:'registered',birth:identity.birth});
        }
      }
    }
    if(childExited&&current.length===0)break;
  }
  if(childExited&&drainDeadline===null)drainDeadline=settledAt();
  if(drainDeadline!==null&&Date.now()>=drainDeadline){block('drain-deadline-expired');break;}
  await sleep(100);
}
const complete=certainty.canComplete({observed,hostPresent,childExited,childSignal,stopping});
const lastClean=lastSnapshot?.complete===true&&Array.isArray(lastSnapshot.unknown)&&lastSnapshot.unknown.length===0;
const refusedBy=[...blockingReasons];
if(!lastSnapshot?.complete)refusedBy.push('query-incomplete');
if(!Array.isArray(lastSnapshot?.unknown)||lastSnapshot.unknown.length)refusedBy.push('unknown-pid');
if(!observed)refusedBy.push('host-never-observed');
if(identities.size===0)refusedBy.push('host-never-registered');
if(lastClean&&hostPresent)refusedBy.push('host-alive');
if(!childExited)refusedBy.push('child-still-running');
if(childSignal)refusedBy.push('child-signaled');
if(stopping)refusedBy.push('owner-stopping');
if(!complete&&refusedBy.length===0)refusedBy.push('certainty-blocked');
emit('decision',{result:complete?'complete':'refused',observed,registeredPids:[...identities.keys()],
  lastSnapshot,hostAlive:lastClean?hostPresent:null,child:{pid:child.pid,exited:childExited,code:childCode,
    signal:childSignal},stopping,refusedBy});
if(!complete){
  const mark=spawnSync(lock,['--mark-host-unknown'],{env:process.env,stdio,timeout:2000});
  emit('unknown-cleanup-mark',{status:mark.status,signal:mark.signal,error:mark.error?.message??null});
  if(mark.status!==0||mark.error)
    process.stderr.write('hosted-owner: supervisor could not record unknown host cleanup\n');
}
if(!complete){
  process.stderr.write('hosted-owner: host cleanup incomplete or unregistered; refusing result\n');
  process.exitCode=70;
}else process.exitCode=childCode??70;
