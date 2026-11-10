/** One isolated OS inspector: logical query expiry never destroys the physical slot. */
import {spawn as nativeSpawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';

const LIMIT=4*1024*1024;
const identityKeys=['pid','birth','uid','executable','marker','ppid','pgid'];
function normalizedSnapshot(snapshot){
  const processes=snapshot.processes.map(record=>{
    if(!record||!Number.isInteger(record.pid)||record.pid<=0||typeof record.birth!=='string'||!/^\d+:\d+$/.test(record.birth)||
      !Number.isInteger(record.uid)||record.uid<0||typeof record.executable!=='string'||
      !(record.marker===null||typeof record.marker==='string')||!Number.isInteger(record.ppid)||record.ppid<0||
      !Number.isInteger(record.pgid)||record.pgid<=0)throw new Error('invalid OS identity schema');
    return Object.fromEntries(identityKeys.map(key=>[key,record[key]]));
  });
  const unknown=snapshot.unknown.map(record=>({
    ...(Number.isInteger(record?.pid)&&record.pid>0?{pid:record.pid}:{}),
    ...(Number.isInteger(record?.uid)&&record.uid>=0?{uid:record.uid}:{}),
    reason:snapshot.complete?'OS identity unavailable':'OS observation unavailable',
    ...(Number.isInteger(record?.errorCode)?{errorCode:record.errorCode}:{})
  }));
  return {complete:snapshot.complete,processes,unknown};
}
const server=String.raw`
import sys,time
generation=sys.argv[1]; boot=time.monotonic()
def bootmark(stage):
    sys.stdout.write('{"protocol":1,"type":"stage","generation":"'+generation+'","stage":"'+stage+'","elapsedMilliseconds":'+str((time.monotonic()-boot)*1000)+'}\n');sys.stdout.flush()
bootmark('interpreter-boot')
import json,os,ctypes,errno,subprocess
bootmark('imports-ready')
if sys.platform=='darwin':
    lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    class Bsd(ctypes.Structure):
        _fields_=[(n,ctypes.c_uint32) for n in ['flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','rfu1']]+[('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]+[(n,ctypes.c_uint32) for n in ['nfiles','pgid','pjobc','e_tdev','e_tpgid']]+[('nice',ctypes.c_int32),('startsec',ctypes.c_uint64),('startusec',ctypes.c_uint64)]
    def candidates(uid,until):
        remaining=until-time.monotonic()
        if remaining<=0: raise TimeoutError()
        result=subprocess.run(['/bin/ps','-axo','pid=,uid='],capture_output=True,text=True,timeout=remaining)
        if result.returncode!=0: raise OSError()
        rows=[line.split() for line in result.stdout.splitlines() if line.strip()]
        if any(len(row)!=2 for row in rows): raise ValueError()
        return [int(pid) for pid,owner in rows if int(owner)==uid and int(pid)>0]
    def inspect(pid,request,targeted):
        info=Bsd()
        if lib.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))!=ctypes.sizeof(info):
            if ctypes.get_errno()==errno.ESRCH: return None
            raise OSError(ctypes.get_errno())
        if not targeted and info.uid!=request['uid']: return None
        buf=ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(pid,buf,len(buf))<=0:
            if ctypes.get_errno() in [errno.ESRCH,errno.ENOENT]: return None
            raise OSError(ctypes.get_errno())
        exe=os.path.realpath(os.fsdecode(buf.value))
        if not targeted and exe!=request['executable']: return None
        marker=None
        if info.uid==request['uid']:
            mib=(ctypes.c_int*3)(1,49,pid);size=ctypes.c_size_t()
            if libc.sysctl(mib,3,None,ctypes.byref(size),None,0)!=0: raise OSError(ctypes.get_errno())
            args=ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib,3,args,ctypes.byref(size),None,0)!=0: raise OSError(ctypes.get_errno())
            data=args.raw[:size.value];argc=int.from_bytes(data[:4],sys.byteorder,signed=True)
            offset=data.index(b'\0',4)+1
            while offset<len(data) and data[offset]==0: offset+=1
            for i in range(argc): offset=data.index(b'\0',offset)+1
            for field in data[offset:].split(b'\0'):
                if field.startswith(b'MADO_TEST_RUN_TOKEN='): marker=os.fsdecode(field.split(b'=',1)[1])
        return dict(pid=pid,ppid=int(info.ppid),pgid=int(info.pgid),uid=int(info.uid),executable=exe,marker=marker,birth=str(info.startsec)+':'+str(info.startusec))
elif sys.platform.startswith('linux'):
    def candidates(uid,until): return [int(pid) for pid in os.listdir('/proc') if pid.isdecimal()]
    def inspect(pid,request,targeted):
        root='/proc/'+str(pid)
        try:
            uid=os.stat(root).st_uid
            if not targeted and uid!=request['uid']: return None
            exe=os.path.realpath(os.readlink(root+'/exe'))
            if not targeted and exe!=request['executable']: return None
            stat=open(root+'/stat').read().rsplit(')',1)[1].split()
            if stat[0]=='Z': return None
            marker=None
            if uid==request['uid']:
                for field in open(root+'/environ','rb').read().split(b'\0'):
                    if field.startswith(b'MADO_TEST_RUN_TOKEN='): marker=os.fsdecode(field.split(b'=',1)[1])
            return dict(pid=pid,ppid=int(stat[1]),pgid=int(stat[2]),uid=uid,executable=exe,marker=marker,birth=stat[19]+':0')
        except FileNotFoundError: return None
else: raise RuntimeError('unsupported OS inspector')
bootmark('os-bindings-ready')
def emit(value): print(json.dumps(value),flush=True)
emit(dict(protocol=1,type='ready',generation=generation))
for line in sys.stdin:
    started=time.monotonic()
    try:
        message=json.loads(line);request=message['request'];until=started+message['budgetMilliseconds']/1000
        records=[];unknown=[];targeted=request.get('pids') is not None
        for pid in (request['pids'] if targeted else candidates(request['uid'],until)):
            if time.monotonic()>=until: raise TimeoutError()
            try:
                record=inspect(pid,request,targeted)
                if record is not None: records.append(record)
            except Exception as error: unknown.append(dict(pid=pid,reason='OS identity unavailable',errorCode=getattr(error,'errno',None)))
        snapshot=dict(complete=True,processes=records,unknown=unknown)
    except Exception:
        snapshot=dict(complete=False,processes=[],unknown=[dict(reason='OS observation unavailable')])
    emit(dict(protocol=1,type='result',generation=generation,requestId=message.get('requestId'),snapshot=snapshot,processingMilliseconds=(time.monotonic()-started)*1000))
`;

export function prepareHostInspector({deadline,env=process.env,spawn=nativeSpawn,now=Date.now,
  signal,timers=globalThis,onStage=()=>{}}={}){
  if(!Number.isFinite(deadline)||deadline<=now())return Promise.reject(Object.assign(new Error('inspector startup deadline expired'),{inspector:{closed:true,reaped:true}}));
  if(signal?.aborted)return Promise.reject(Object.assign(new Error('inspector startup cancelled'),{inspector:{closed:true,reaped:true}}));
  const generation=randomUUID(),started=now(),events=[],stages=[];
  const diagnostics={startup:{isolated:true,noSite:true,elapsedMilliseconds:null,stages},events};
  let child,ready=false,live=true,reaped=false,killed=false,pending,requestId=0,buffer=Buffer.alloc(0),stdoutBytes=0,stderrBytes=0;
  let startupResolve,startupReject,startupTimer,invalidStage,readySettled=false;
  const closeWaiters=new Set();
  const startup=new Promise((resolve,reject)=>{startupResolve=resolve;startupReject=reject;});startup.catch(()=>{});
  const note=(stage,extra={})=>{events.push({stage,elapsedMilliseconds:Math.max(0,now()-started),...extra});if(events.length>16)events.shift();};
  const facts=(stage,request=pending)=>({stage,generation,requestId:request?.id??null,cleanupSignal:request?.cleanupSignal??null,
    elapsedMilliseconds:request?Math.max(0,now()-request.started):0,timeoutMilliseconds:request?.budget??0,
    status:Number.isInteger(child?.exitCode)?child.exitCode:null,signal:child?.signalCode??null,
    errorCode:null,stdoutBytes,stderrBytes});
  const failure=(stage,request=pending)=>({complete:false,processes:[],unknown:[{reason:'inspector '+stage}],transport:facts(stage,request)});
  function finishQuery(value){if(!pending)return;const old=pending;pending=null;timers.clearTimeout(old.timer);old.resolve?.(value);}
  function expireQuery(){
    if(!live||!pending||pending.expired)return;
    const value=failure('timeout');pending.expired=true;timers.clearTimeout(pending.timer);
    const resolve=pending.resolve;pending.resolve=null;note('timeout',{requestId:pending.id,budgetMilliseconds:pending.budget});
    // Keep one occupied physical slot. Its late correlated frame is discarded;
    // only a new phase-current query may authorize ownership. The supervisor
    // closes/kills this process by its unchanged cleanup drain deadline.
    resolve?.(value);
  }
  function detachStreams(){child?.stdout?.removeListener('data',stdout);child?.stderr?.removeListener('data',stderr);buffer=Buffer.alloc(0);}
  function close({notAfter=deadline}={}){
    if(live){live=false;invalidStage='closed';timers.clearTimeout(startupTimer);finishQuery(failure('closed'));}
    detachStreams();signal?.removeEventListener('abort',aborted);
    if(!child)return Promise.resolve({closed:true,reaped:true});
    if(reaped)return Promise.resolve({closed:true,reaped:true});
    if(!killed){killed=true;try{child.kill('SIGKILL');}catch{}}
    child.stdout?.destroy();child.stderr?.destroy();child.stdin?.destroy();
    if(notAfter<=now())return Promise.resolve({closed:false,reaped:false});
    return new Promise(resolve=>{
      let timer;const done=value=>{timers.clearTimeout(timer);closeWaiters.delete(done);resolve(value);};
      closeWaiters.add(done);timer=timers.setTimeout(()=>done({closed:false,reaped:false}),Math.max(0,notAfter-now()));
      if(reaped)done({closed:true,reaped:true});
    });
  }
  function invalidate(stage){
    if(!live)return;
    const value=failure(stage);invalidStage=stage;live=false;timers.clearTimeout(startupTimer);note(stage);
    finishQuery(value);
    const disposal=close();
    if(!readySettled){readySettled=true;disposal.then(state=>startupReject(Object.assign(new Error('inspector startup '+stage),{inspector:{...state,diagnostics}})));}
  }
  function aborted(){invalidate('cancelled');}
  function frame(line){
    let message;try{message=JSON.parse(line.toString('utf8'));}catch{invalidate('protocol');return;}
    if(!message||message.protocol!==1||message.generation!==generation){invalidate('protocol');return;}
    if(!ready&&message.type==='stage'){
      if(!['interpreter-boot','imports-ready','os-bindings-ready'].includes(message.stage)||!Number.isFinite(message.elapsedMilliseconds)||message.elapsedMilliseconds<0){invalidate('protocol');return;}
      const item={stage:message.stage,elapsedMilliseconds:message.elapsedMilliseconds};stages.push(item);if(stages.length>16)stages.shift();note(message.stage);
      try{onStage({...item});}catch{invalidate('protocol');}return;
    }
    if(!ready&&message.type==='ready'){
      if(now()>=deadline){invalidate('deadline');return;}
      ready=true;readySettled=true;timers.clearTimeout(startupTimer);diagnostics.startup.elapsedMilliseconds=Math.max(0,now()-started);
      note('ready');startupResolve(session);return;
    }
    const snapshot=message.snapshot;
    if(!ready||!pending||message.type!=='result'||message.requestId!==pending.id||
      !snapshot||typeof snapshot.complete!=='boolean'||!Array.isArray(snapshot.processes)||!Array.isArray(snapshot.unknown)){invalidate('protocol');return;}
    if(pending.expired||now()>=pending.notAfter){
      expireQuery();
      note('expired-reply',{requestId:pending.id,processingMilliseconds:Number.isFinite(message.processingMilliseconds)?message.processingMilliseconds:null});
      finishQuery(undefined);return;
    }
    const transport={...facts('complete'),processingMilliseconds:Number.isFinite(message.processingMilliseconds)?message.processingMilliseconds:null};
    let normalized;try{normalized=normalizedSnapshot(snapshot);}catch{invalidate('protocol');return;}
    note('reply',{requestId:pending.id});finishQuery({...normalized,transport});
  }
  function stdout(chunk){
    if(!live)return;const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);
    stdoutBytes+=bytes.length;
    if(buffer.length+stderrBytes+bytes.length>LIMIT){invalidate('overflow');return;}
    buffer=Buffer.concat([buffer,bytes]);
    let newline;while(live&&(newline=buffer.indexOf(10))!==-1){const line=buffer.subarray(0,newline);buffer=buffer.subarray(newline+1);frame(line);}
  }
  function stderr(chunk){if(!live)return;const length=Buffer.byteLength(chunk);stderrBytes+=length;if(buffer.length+stderrBytes>LIMIT)invalidate('overflow');}
  const session={generation,get pid(){return child?.pid??null;},get ready(){return ready&&live;},get busy(){return live&&Boolean(pending);},diagnostics,close,
    query(options={}){
      if(!live||!ready)return Promise.resolve(failure('closed'));
      if(pending){note('busy');return Promise.resolve(failure('busy'));}
      const requestStart=now(),notAfter=options.notAfter??deadline,budget=Math.min(1000,Math.max(0,Math.floor(notAfter-requestStart)));
      if(budget<=0)return Promise.resolve(failure('expired'));
      const id=++requestId;
      const message={protocol:1,type:'query',generation,requestId:id,budgetMilliseconds:budget,
        request:{...options,uid:options.uid===undefined?process.getuid():options.uid}};
      const encoded=JSON.stringify(message)+'\n';
      if(Buffer.byteLength(encoded)>LIMIT){invalidate('overflow');return Promise.resolve(failure('overflow'));}
      if(now()>=Math.min(notAfter,requestStart+budget))return Promise.resolve(failure('expired'));
      stdoutBytes=0;stderrBytes=0;
      return new Promise(resolve=>{
        pending={id,resolve,started:requestStart,budget,notAfter:Math.min(notAfter,requestStart+budget),cleanupSignal:options.cleanupSignal,expired:false};
        pending.timer=timers.setTimeout(expireQuery,Math.max(0,pending.notAfter-now()));
        note('request',{requestId:id,budgetMilliseconds:budget,cleanupSignal:options.cleanupSignal??null});
        try{child.stdin.write(encoded,error=>{if(error)invalidate('process');});}catch{invalidate('process');}
      });
    }};
  startupTimer=timers.setTimeout(()=>invalidate('deadline'),Math.max(0,deadline-now()));
  signal?.addEventListener('abort',aborted,{once:true});
  try{
    child=spawn('/usr/bin/python3',['-I','-S','-u','-c',server,generation],{env,stdio:['pipe','pipe','pipe']});
    child.stdout.on('data',stdout);child.stderr.on('data',stderr);
    child.once('error',()=>invalidate('process'));
    child.once('close',()=>{reaped=true;for(const done of [...closeWaiters])done({closed:true,reaped:true});if(live)invalidate('closed');});
  }catch{invalidate('process');}
  return startup;
}
