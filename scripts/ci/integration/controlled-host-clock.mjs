/** Test-only logical clock. Real kernel work and child process I/O never use fake data. */
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {PassThrough} from 'node:stream';
import {setTimeout as realTimeout,clearTimeout as realClearTimeout,setImmediate as realImmediate} from 'node:timers';
import {prepareHostInspector} from '../app-host-inspector.mjs';

export async function controlledHostClock(t){
  let time=Date.now(),serial=0,inspector,held,barrierActive=false,barrierError,buffer='',outstanding=0,maxOutstanding=0;
  const timers=new Map(),requests=[],controller=new AbortController();
  const clock={now:()=>time,signal:controller.signal,
    setTimeout(fn,ms,...args){const id=++serial;timers.set(id,{at:time+Math.max(0,ms),fn:()=>fn(...args)});return id;},
    clearTimeout(id){timers.delete(id);},
    advanceTo(target){assert.ok(target>=time);for(;;){const entry=[...timers].filter(([,v])=>v.at<=target).sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0];
      if(!entry)break;timers.delete(entry[0]);time=entry[1].at;entry[1].fn();}time=target;},
    holdNext:false,onHeld:undefined,
    release(){assert.ok(held,'a real correlated response must be held');const release=held;held=undefined;release();},
    get inspector(){return inspector;},get requests(){return requests;},get maxOutstanding(){return maxOutstanding;},
    // Wait for microtasks and real I/O before advancing an idle supervisor.
    // Never advance an in-flight OS query except at an explicit expiry barrier.
    async drive(pending){let done=false,result,error;pending.then(v=>{done=true;result=v;},e=>{done=true;error=e;});const started=Date.now();
      try{while(!done){if(barrierError)throw barrierError;assert.ok(Date.now()-started<20000,'controlled scenario real-time watchdog');
        await new Promise(resolve=>realTimeout(resolve,2));
        if(!done&&inspector.ready&&!inspector.busy&&!held&&!barrierActive){const next=[...timers.values()].sort((a,b)=>a.at-b.at)[0];if(next)clock.advanceTo(next.at);}}
      if(error)throw error;return result;
      }catch(failure){controller.abort();clock.advanceTo(time+20000);if(held)clock.release();
        await new Promise(resolve=>realImmediate(resolve));clock.advanceTo(time+20000);
        await Promise.race([pending.catch(()=>{}),new Promise(resolve=>realTimeout(resolve,2000))]);
        await inspector.close({notAfter:clock.now()});throw failure;}},
    // Real ps proof, synchronous only so logical time cannot advance during I/O.
    groupQuery(group){const q=spawnSync('/bin/ps',['-axo','pid=,pgid=,stat='],{encoding:'utf8',timeout:2000});
      assert.equal(q.status,0,q.stderr);return q.stdout.trim().split('\n').map(s=>s.trim().split(/\s+/))
        .filter(([pid,pgid,state])=>Number(pgid)===group&&Number(pid)>0&&!state.startsWith('Z'));}
  };
  const startupAbort=new AbortController(),startupWatchdog=realTimeout(()=>{startupAbort.abort();clock.advanceTo(time+20000);},10000);
  try{inspector=await prepareHostInspector({deadline:time+10000,now:clock.now,timers:clock,signal:startupAbort.signal,spawn:(command,args,options)=>{
    const child=spawn(command,args,options),source=child.stdout,output=new PassThrough();child.stdout=output;
    const write=child.stdin.write.bind(child.stdin);child.stdin.write=(data,...rest)=>{
      const message=JSON.parse(String(data));requests.push({...message,at:time});outstanding++;maxOutstanding=Math.max(maxOutstanding,outstanding);
      assert.equal(outstanding,1,'one physical correlated query outstanding');return write(data,...rest);};
    source.on('data',chunk=>{buffer+=chunk;for(;;){const end=buffer.indexOf('\n');if(end<0)break;const line=buffer.slice(0,end+1);buffer=buffer.slice(end+1);
      const message=JSON.parse(line);const deliver=()=>{if(message.type==='result')outstanding--;output.write(line);};
      if(message.type==='result'&&clock.holdNext){clock.holdNext=false;assert.equal(held,undefined);held=deliver;
        barrierActive=true;Promise.resolve().then(()=>clock.onHeld(message)).catch(error=>{barrierError=error;if(held)clock.release();}).finally(()=>{barrierActive=false;});}
      else deliver();}});
    source.on('end',()=>output.end());return child;
  }});}finally{realClearTimeout(startupWatchdog);}
  t.after(()=>inspector.close({notAfter:clock.now()+1000}));
  // Inspector and supervisor use one logical clock; process I/O stays real.
  t.mock.method(globalThis,'setTimeout',clock.setTimeout);t.mock.method(globalThis,'clearTimeout',clock.clearTimeout);
  clock.turn=()=>new Promise(resolve=>realImmediate(resolve));
  return clock;
}
