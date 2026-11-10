#!/usr/bin/env node
/** Serialized async ownership control; timers only notify immutable phase transitions. */
import {spawn} from 'node:child_process';
import {openSync,closeSync,appendFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {prepareHostInspector} from './app-host-inspector.mjs';
import {createAsyncHostOwnership} from './app-host-ownership.mjs';

export async function runProcessGroup({command,args=[],env=process.env,logPath,deadline,graceMs=250,drainMs=1500,
  cancelOnHostObserved=false,hostQuery,hostSignal,groupSignal,groupQuery,preparedInspector,inspectorSpawn,
  signal,now=Date.now}={}){
  const required=env.MADO_HOST_OWNERSHIP_REQUIRED==='1';
  const log=text=>appendFileSync(logPath,'app-repeat: '+text+'\n');
  let inspector=preparedInspector,host,child,group,childExit,cleanup,stopping=false,done=false,epoch=0,
    startupStopped=false,graceExpired=false,drainExpired=false,cancelledOnHostObserved=false,wakeResolve,
    deadlineTimer,graceTimer,drainTimer,lastGroupPhase,workerStarted=false;
  const startupAbort=new AbortController(),psChildren=new Set();
  const wake=()=>{const resolve=wakeResolve;wakeResolve=null;resolve?.();};
  const phase=()=>!stopping?'running':drainExpired||now()>=cleanup.drainDeadline?'expired':
    graceExpired||now()>=cleanup.graceDeadline?'SIGKILL':'SIGTERM';
  const phaseDeadline=()=>!stopping?deadline:phase()==='SIGTERM'?cleanup.graceDeadline:cleanup.drainDeadline;
  function stop(reason){
    if(done||stopping||startupStopped)return;
    epoch++;
    if(!workerStarted){startupStopped=true;startupAbort.abort();log('startup stopped: '+reason);wake();return;}
    stopping=true;const at=now();cleanup=Object.freeze({graceStartedAt:at,graceDeadline:at+graceMs,drainDeadline:at+graceMs+drainMs});
    log(reason);log('cleanup '+JSON.stringify(cleanup));
    graceTimer=setTimeout(()=>{graceExpired=true;wake();},Math.max(0,cleanup.graceDeadline-now()));
    drainTimer=setTimeout(()=>{drainExpired=true;wake();},Math.max(0,cleanup.drainDeadline-now()));wake();
  }
  const interrupted=()=>stop('supervisor interrupted; terminating iteration process group');
  const aborted=()=>stop('supervisor cancelled; terminating iteration process group');
  function scope(){const version=epoch,current=phase(),notAfter=phaseDeadline();return {notAfter,
    isCurrent:()=>!done&&version===epoch&&current===phase()&&now()<notAfter};}
  function signalGroup(name){
    if(!group||lastGroupPhase===name)return;
    try{(groupSignal??((id,s)=>process.kill(-id,s)))(group,name);lastGroupPhase=name;}
    catch(error){if(error.code==='ESRCH')lastGroupPhase=name;else log('cannot signal owned worker group');}
  }
  const idle=()=>new Promise(resolve=>{
    const timer=setTimeout(()=>{if(wakeResolve===notify)wakeResolve=null;resolve();},Math.max(0,Math.min(25,phaseDeadline()-now())));
    function notify(){clearTimeout(timer);resolve();}wakeResolve=notify;
  });
  function nativeGroupQuery(id,{notAfter}){
    const budget=Math.min(1000,Math.max(0,Math.floor(notAfter-now())));
    if(budget<=0||psChildren.size)return Promise.resolve(null);
    return new Promise(resolve=>{
      let query,output='',bytes=0,settled=false,timer;
      const finish=value=>{if(settled)return;settled=true;clearTimeout(timer);resolve(value);};
      try{query=spawn('/bin/ps',['-axo','pid=,pgid=,stat='],{stdio:['ignore','pipe','pipe']});}
      catch{finish(null);return;}
      psChildren.add(query);
      query.stdout.on('data',chunk=>{bytes+=chunk.length;if(bytes>4*1024*1024){query.kill('SIGKILL');finish(null);}else output+=chunk;});
      query.stderr.on('data',chunk=>{bytes+=chunk.length;if(bytes>4*1024*1024){query.kill('SIGKILL');finish(null);}});
      query.once('error',()=>finish(null));
      query.once('close',(code,termination)=>{psChildren.delete(query);wake();
        if(code!==0||termination){finish(null);return;}
        const rows=output.trim()?output.trim().split('\n').map(line=>line.trim().split(/\s+/)):[];
        if(rows.some(row=>row.length!==3||!/^\d+$/.test(row[0])||!/^\d+$/.test(row[1]))){finish(null);return;}
        finish(rows.filter(([pid,pgid,state])=>Number(pgid)===id&&Number(pid)>0&&!state.startsWith('Z')));
      });
      timer=setTimeout(()=>{query.kill('SIGKILL');query.stdout.destroy();query.stderr.destroy();query.unref();finish(null);},budget);
    });
  }
  async function members(){
    if(!group)return [];
    const current=scope();
    try{const result=await (groupQuery??nativeGroupQuery)(group,{notAfter:current.notAfter,now});return current.isCurrent()?result:null;}
    catch{return null;}
  }
  async function observe(){
    if(!host||inspector?.busy)return;
    const count=host.snapshot().identities.length;await host.observe(scope());
    const state=host.snapshot();if(state.identities.length>count)log('owned host registered '+JSON.stringify(state.identities.slice(count)));
    if(cancelOnHostObserved&&state.observed&&!stopping&&!startupStopped){cancelledOnHostObserved=true;stop('owned host observed; cancelling requested probe');}
  }
  async function authorize(){
    if(!host||inspector?.busy||phase()==='expired')return;
    const current=phase(),state=host.snapshot();
    const pending=state.identities.some(identity=>!state.signals.some(sent=>sent.pid===identity.pid&&sent.birth===identity.birth&&sent.signal===current));
    if(pending)await host.signalOwned(current,scope());
  }
  async function finish(status,proven){
    done=true;wake();clearTimeout(deadlineTimer);clearTimeout(graceTimer);clearTimeout(drainTimer);
    process.removeListener('SIGTERM',interrupted);process.removeListener('SIGINT',interrupted);signal?.removeEventListener('abort',aborted);
    const notAfter=cleanup?.drainDeadline??Math.min(deadline,now()+drainMs);
    for(const query of psChildren){try{query.kill('SIGKILL');query.stdout?.destroy();query.stderr?.destroy();query.unref();}catch{}}
    let closed={closed:true,reaped:true};
    if(inspector){try{closed=await inspector.close({notAfter});}catch{closed={closed:false,reaped:false};}}
    const inspectorState=inspector?{...closed,pid:inspector.pid,diagnostics:inspector.diagnostics}:undefined;
    const hostOwnership=host?.snapshot();if(hostOwnership)log('host ownership '+JSON.stringify(hostOwnership));
    child?.unref();
    return {status:closed.closed&&closed.reaped?status:70,drained:proven&&closed.closed&&closed.reaped&&psChildren.size===0,
      ...(group?{group}:{}),cancelledOnHostObserved,...(cleanup?{cleanup}:{}),...(hostOwnership?{hostOwnership}:{}),
      ...(inspectorState?{inspector:inspectorState}:{})};
  }
  process.on('SIGTERM',interrupted);process.on('SIGINT',interrupted);signal?.addEventListener('abort',aborted,{once:true});
  try{
    if(!Number.isFinite(deadline)||deadline<=now()){
      log('job time budget exhausted');return await finish(70,!required);
    }
    if(signal?.aborted){startupStopped=true;return await finish(70,false);}
    if(env.MADO_HOST_OWNERSHIP_REQUIRED!==undefined&&env.MADO_HOST_OWNERSHIP_REQUIRED!=='1')throw new Error('invalid ownership requirement');
    if(!required&&env.MADO_HOST_EXECUTABLE)throw new Error('host executable requires explicit ownership policy');
    deadlineTimer=setTimeout(()=>stop('job time budget exhausted; terminating iteration process group'),Math.max(0,deadline-now()));
    if(required){
      log('inspector startup '+JSON.stringify({deadline,remainingMilliseconds:Math.max(0,deadline-now())}));
      if(!inspector)inspector=await prepareHostInspector({deadline,env,spawn:inspectorSpawn,now,signal:startupAbort.signal});
      if(startupStopped||now()>=deadline||!inspector.ready)return await finish(70,false);
      host=createAsyncHostOwnership({token:env.MADO_TEST_RUN_TOKEN,executable:env.MADO_HOST_EXECUTABLE,now,
        excludeGroup:()=>group,query:hostQuery??(request=>inspector.query(request)),signal:hostSignal});
    }
    if(startupStopped||now()>=deadline)return await finish(70,false);
    const childEnv={...env};if(env.MADO_TEST_RUN_TOKEN)childEnv.TEST_RUNNER_MADO_TEST_RUN_TOKEN=env.MADO_TEST_RUN_TOKEN;
    const fd=openSync(logPath,'a');try{child=spawn(command,args,{env:childEnv,detached:true,stdio:['ignore',fd,fd]});}finally{closeSync(fd);}
    child.once('error',()=>{childExit={code:70,signal:null};if(workerStarted)stop('iteration startup failed');wake();});
    child.once('exit',(code,termination)=>{childExit={code,signal:termination};wake();});
    if(!child.pid){await new Promise(resolve=>child.once('error',resolve));return await finish(70,true);}
    group=child.pid;workerStarted=true;
    while(!done){
      if(stopping){
        if(phase()==='expired'){signalGroup('SIGKILL');return await finish(70,false);}
        // Target known hosts before scanning or tearing down the control session.
        await authorize();
        if(phase()==='expired'){signalGroup('SIGKILL');return await finish(70,false);}
        if(host&&!host.snapshot().signals.length&&inspector?.ready){
          await observe();await authorize();
        }
        const available=!host||host.snapshot().signals.length>0||!inspector?.ready||!host.snapshot().observed;
        if(available)signalGroup(phase()==='SIGTERM'?'SIGTERM':'SIGKILL');
        await observe();
        const groupState=await members();
        if(groupState!==null&&groupState.length===0&&(!host||host.snapshot().drained))return await finish(70,true);
        if(groupState!==null&&groupState.length===0&&host&&!host.snapshot().observed&&
          host.snapshot().live.length===0&&host.snapshot().unknown.length===0){
          log('host registration missing after worker/group exit');return await finish(70,false);
        }
      }else{
        await observe();if(stopping)continue;
        if(required&&!inspector.ready){stop('ownership inspector unavailable');continue;}
        if(childExit){
          const groupState=await members();if(stopping)continue;
          if(groupState!==null&&groupState.length===0&&(!host||host.snapshot().drained))
            return await finish(childExit.signal||childExit.code===null?70:childExit.code,true);
          if(groupState!==null&&groupState.length===0&&host&&!host.snapshot().observed&&
            host.snapshot().live.length===0&&host.snapshot().unknown.length===0){
            log('host registration missing after worker/group exit');return await finish(70,false);
          }
          stop('iteration leader exited with live descendants or unknown host');continue;
        }
      }
      await idle();
    }
  }catch(error){
    log('supervision failed');
    if(error.inspector&&!inspector){
      const result=await finish(70,false);return {...result,inspector:error.inspector};
    }
    if(group)signalGroup('SIGKILL');
    return await finish(70,false);
  }
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const [deadline,logPath,command,...args]=process.argv.slice(2);
  try{process.stdout.write(JSON.stringify(await runProcessGroup({deadline:Number(deadline),logPath,command,args})));}
  catch{process.stderr.write('app-repeat supervisor failed\n');process.exitCode=70;}
}
