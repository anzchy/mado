/** Exact invocation ownership for App hosts launched outside xcodebuild's process group. */
export function createAsyncHostOwnership({query,now=Date.now,...options}={}){
  if(typeof query!=='function')throw new Error('async ownership requires a prepared OS query');
  let busy=false,fresh;
  // The same policy consumes exactly one freshly awaited reply. It never queries
  // the compatibility cold inspector, queues work, or reuses a prior reply.
  const state=createHostOwnership({...options,now,query:request=>{
    if(!fresh||JSON.stringify(request.pids)!==JSON.stringify(fresh.pids))return {complete:false,processes:[],unknown:[{reason:'no current observation'}]};
    const result=fresh.result;fresh=null;return result;
  }});
  const request=async(pids,operation,cleanupSignal)=>{
    const notAfter=operation.notAfter??Infinity;
    if(now()>=notAfter)return {complete:false,processes:[],unknown:[{reason:'ownership phase expired'}]};
    try{return await query({token:options.token,executable:options.executable,uid:options.uid??process.getuid(),pids,
      cleanupSignal,notAfter});}
    catch{return {complete:false,processes:[],unknown:[{reason:'OS observation unavailable'}]};}
  };
  return {
    snapshot:()=>({...state.snapshot(),drained:!busy&&state.snapshot().drained}),
    async observe(operation={}){
      if(busy)return;busy=true;state.invalidateCurrent('pending');
      try{
        const result=await request(undefined,operation);
        if(operation.isCurrent&&!operation.isCurrent()){state.invalidateCurrent('superseded');return;}
        if(result.complete&&now()>=(operation.notAfter??Infinity)){state.invalidateCurrent('expired');return;}
        fresh={pids:undefined,result};state.observe();
      }finally{fresh=null;busy=false;}
    },
    async signalOwned(name,operation={}){
      if(busy)return;busy=true;
      try{
        for(const identity of state.snapshot().identities){
          if(state.snapshot().unknown.length)break;
          const result=await request([identity.pid],operation,name);
          if(operation.isCurrent&&!operation.isCurrent()){state.invalidateCurrent('superseded');return;}
          fresh={pids:[identity.pid],result};state.signalOwned(name,{notAfter:operation.notAfter??Infinity,onlyPid:identity.pid});
        }
      }finally{fresh=null;busy=false;}
    }
  };
}
import {spawnSync} from 'node:child_process';
import {realpathSync} from 'node:fs';
import path from 'node:path';

// Only OS APIs are used here. Never return arbitrary process environment contents.
const inspector=String.raw`
import os,sys,json,ctypes,errno,subprocess
request=json.loads(sys.argv[1]); expected=request['executable']; wanted=request.get('pids')
records=[]; unknown=[]
if sys.platform=='darwin':
    lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    class Bsd(ctypes.Structure):
        _fields_=[(n,ctypes.c_uint32) for n in ['flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','rfu1']]+[('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]+[(n,ctypes.c_uint32) for n in ['nfiles','pgid','pjobc','e_tdev','e_tpgid']]+[('nice',ctypes.c_int32),('startsec',ctypes.c_uint64),('startusec',ctypes.c_uint64)]
    def pids():
        # ps obtains each UID from the OS. Protected daemons owned by another UID
        # cannot be this invocation; never infer their UID from an unreadable path.
        snapshot=subprocess.run(['/bin/ps','-axo','pid=,uid='],capture_output=True,text=True,timeout=1)
        if snapshot.returncode!=0: raise OSError('cannot enumerate OS process UIDs')
        rows=[line.split() for line in snapshot.stdout.splitlines() if line.strip()]
        if any(len(row)!=2 for row in rows): raise OSError('incomplete OS UID snapshot')
        return [int(pid) for pid,uid in rows if int(uid)==request['uid'] and int(pid)>0]
    def inspect(pid):
        info=Bsd()
        if lib.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))!=ctypes.sizeof(info):
            if ctypes.get_errno()==errno.ESRCH: return None
            raise OSError('unreadable kernel birth identity')
        # Another user's process cannot be ours; do not probe its protected executable/environment.
        if wanted is None and info.uid!=request['uid']: return None
        buf=ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(pid,buf,len(buf))<=0:
            if ctypes.get_errno() in [errno.ESRCH,errno.ENOENT]: return None
            raise OSError('unreadable process executable')
        exe=os.path.realpath(os.fsdecode(buf.value))
        if wanted is None and exe!=expected: return None
        marker=None
        if info.uid==request['uid']:
            mib=(ctypes.c_int*3)(1,49,pid); size=ctypes.c_size_t()
            if libc.sysctl(mib,3,None,ctypes.byref(size),None,0)!=0: raise OSError('unreadable process marker size')
            args=ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib,3,args,ctypes.byref(size),None,0)!=0: raise OSError('unreadable process marker')
            data=args.raw[:size.value];argc=int.from_bytes(data[:4],sys.byteorder,signed=True)
            offset=data.index(b'\0',4)+1
            while offset<len(data) and data[offset]==0: offset+=1
            for i in range(argc): offset=data.index(b'\0',offset)+1
            for field in data[offset:].split(b'\0'):
                if field.startswith(b'MADO_TEST_RUN_TOKEN='): marker=os.fsdecode(field.split(b'=',1)[1])
        return dict(pid=pid,ppid=int(info.ppid),pgid=int(info.pgid),uid=int(info.uid),executable=exe,marker=marker,birth=str(info.startsec)+':'+str(info.startusec))
elif sys.platform.startswith('linux'):
    def pids(): return [int(p) for p in os.listdir('/proc') if p.isdecimal()]
    def inspect(pid):
        root='/proc/'+str(pid)
        try:
            uid=os.stat(root).st_uid
            if wanted is None and uid!=request['uid']: return None
            exe=os.path.realpath(os.readlink(root+'/exe'))
            if wanted is None and exe!=expected: return None
            stat=open(root+'/stat').read().rsplit(')',1)[1].split()
            if stat[0]=='Z': return None
            marker=None
            if uid==request['uid']:
                for field in open(root+'/environ','rb').read().split(b'\0'):
                    if field.startswith(b'MADO_TEST_RUN_TOKEN='): marker=os.fsdecode(field.split(b'=',1)[1])
            return dict(pid=pid,ppid=int(stat[1]),pgid=int(stat[2]),uid=uid,executable=exe,marker=marker,birth=stat[19]+':0')
        except FileNotFoundError: return None
else: raise RuntimeError('host ownership inspection unsupported on this OS')
for pid in (wanted if wanted is not None else pids()):
    try:
        record=inspect(pid)
        if record is not None: records.append(record)
    except Exception as error: unknown.append(dict(pid=pid,reason=str(error)))
print(json.dumps(dict(complete=True,processes=records,unknown=unknown)))
`;

// The hosted runner may need more than one second for Python startup, ps and the
// per-PID kernel walk. Keep each query below the owner's 30-second drain budget.
const inspectorTimeoutMilliseconds=5000;

export function queryHostProcesses({token,executable,uid=process.getuid(),pids,spawn=spawnSync,now=Date.now}={}){
  const started=now();let run,stage='spawn',reason='OS ownership inspector could not start';
  const transport=()=>({stage,elapsedMilliseconds:Math.max(0,now()-started),timeoutMilliseconds:inspectorTimeoutMilliseconds,
    status:Number.isInteger(run?.status)?run.status:null,signal:run?.signal??null,
    errorCode:typeof run?.error?.code==='string'?run.error.code:null,
    stdoutBytes:Buffer.byteLength(run?.stdout??''),stderrBytes:Buffer.byteLength(run?.stderr??'')});
  try{
    run=spawn('/usr/bin/python3',['-c',inspector,JSON.stringify({token,executable,uid,pids})],
      {encoding:'utf8',timeout:inspectorTimeoutMilliseconds,maxBuffer:4*1024*1024});
    stage='process';reason='OS ownership inspection failed';
    if(run.error||run.signal||run.status!==0)throw new Error(reason);
    stage='json';reason='OS ownership response is not JSON';
    const result=JSON.parse(run.stdout);
    stage='schema';reason='incomplete OS ownership response';
    if(result.complete!==true||!Array.isArray(result.processes)||!Array.isArray(result.unknown))throw new Error(reason);
    stage='complete';return {...result,transport:transport()};
  }catch(error){
    if(stage==='spawn')run={error};
    return {complete:false,processes:[],unknown:[{reason}],transport:transport()};
  }
}
const same=(a,b)=>a.pid===b.pid&&a.birth===b.birth&&a.uid===b.uid&&a.executable===b.executable&&a.marker===b.marker;
const identityKeys=['pid','birth','uid','executable','marker','ppid','pgid'];
const copyIdentity=record=>Object.fromEntries(identityKeys.map(key=>[key,record[key]]));
const codes=new Set(['ETIMEDOUT','ENOENT','EACCES','EPERM','ENOBUFS','ESRCH','EPIPE','ECONNRESET','ECANCELED','ERR_CHILD_PROCESS_STDIO_MAXBUFFER','ABORT_ERR']);
const stages=new Set(['spawn','process','json','schema','complete','busy','protocol','timeout','expired','closed','overflow','deadline','cancelled','superseded']);
function transportFacts(value){
  if(!value||typeof value!=='object')return null;const result={};
  for(const key of ['status','elapsedMilliseconds','timeoutMilliseconds','physicalTimeoutMilliseconds','stdoutBytes','stderrBytes','processingMilliseconds','requestId'])
    if(Object.hasOwn(value,key)&&(value[key]===null||Number.isFinite(value[key])))result[key]=value[key];
  if(Object.hasOwn(value,'stage'))result.stage=stages.has(value.stage)?value.stage:'unknown';
  if(Object.hasOwn(value,'errorCode'))result.errorCode=value.errorCode===null?null:codes.has(value.errorCode)?value.errorCode:'UNKNOWN';
  for(const key of ['signal','cleanupSignal'])if(Object.hasOwn(value,key))
    result[key]=value[key]===null?null:['SIGTERM','SIGKILL','SIGINT','SIGHUP','SIGQUIT','SIGABRT','SIGSEGV','SIGBUS','SIGPIPE','SIGILL'].includes(value[key])?value[key]:'UNKNOWN';
  if(typeof value.generation==='string'&&/^[a-zA-Z0-9_.:-]{1,256}$/.test(value.generation))result.generation=value.generation;
  return result;
}
export function createHostOwnership({token,executable,uid=process.getuid(),query=queryHostProcesses,excludeGroup=()=>undefined,excludePids=[process.pid],now=Date.now,
  signal=(pid,name)=>process.kill(pid,name)}={}){
  if(typeof token!=='string'||!token.trim()||typeof executable!=='string'||!path.isAbsolute(executable)||
    realpathSync(executable)!==executable||!Number.isInteger(uid)||uid<0)throw new Error('invalid hosted ownership request');
  const identities=new Map(),signals=[],problems=[],queryFailures=[];let current=[],observed=false,registrationCurrent=false,uncertainty=null;
  const valid=r=>r&&Number.isInteger(r.pid)&&r.pid>0&&typeof r.birth==='string'&&/^\d+:\d+$/.test(r.birth)&&
    r.uid===uid&&r.executable===executable&&r.marker===token&&Number.isInteger(r.ppid)&&r.ppid>=0&&Number.isInteger(r.pgid)&&r.pgid>0;
  function inspect(pids,cleanupSignal){
    let result;try{result=query({token,executable,uid,pids,cleanupSignal});}catch(error){result={complete:false,processes:[],unknown:[error.message]};}
    const relevantUnknown=Array.isArray(result?.unknown)?result.unknown.filter(problem=>
      !Number.isInteger(problem?.uid)||problem.uid===uid||identities.has(problem.pid)):null;
    for(const problem of relevantUnknown??[]){
      const original=identities.get(problem?.pid);
      if(original&&Number.isInteger(problem.uid)&&problem.uid!==original.uid)problems.push(`identity changed for PID ${original.pid}: kernel UID mismatch`);
    }
    const complete=result?.complete===true&&Array.isArray(result.processes)&&relevantUnknown!==null&&relevantUnknown.length===0;
    if(!complete){
      registrationCurrent=false;uncertainty='OS ownership query incomplete or unreadable';
      if(queryFailures.length<16)queryFailures.push({transport:transportFacts(result?.transport),
        unknown:relevantUnknown?.map(problem=>({pid:Number.isInteger(problem?.pid)?problem.pid:null,reason:'OS identity unavailable'}))??[]});
      return null;
    }
    const outside=result.processes.filter(record=>record.pgid!==excludeGroup()&&!excludePids.includes(record.pid));
    for(const record of outside){
      const original=identities.get(record.pid);
      if(original&&!same(original,record))problems.push(`identity changed for PID ${record.pid}`);
      if(record.marker===token&&!valid(record))problems.push('malformed or mismatched current host identity');
    }
    return outside;
  }
  return {
    invalidateCurrent(kind){registrationCurrent=false;uncertainty=kind==='expired'?'ownership observation expired':kind==='superseded'?'ownership observation superseded':'ownership observation pending';},
    observe(){
      const records=inspect();if(records===null)return;
      registrationCurrent=true;uncertainty=null;
      current=records.filter(valid);
      for(const record of current){if(!identities.has(record.pid))identities.set(record.pid,copyIdentity(record));observed=true;}
    },
    signalOwned(name,{notAfter=Infinity,onlyPid}={}){
      for(const original of identities.values()){
        if(onlyPid!==undefined&&original.pid!==onlyPid)continue;
        if(!registrationCurrent||problems.length)break;
        // Re-query immediately before each signal; a prior observation never authorizes PID reuse.
        const records=inspect([original.pid],name);if(records===null)continue;
        const actual=records.find(r=>r.pid===original.pid);
        if(!actual)continue;
        if(!valid(actual)||!same(original,actual)||problems.length)continue;
        current=[...current.filter(record=>record.pid!==actual.pid),actual];
        if(now()>=notAfter)continue;
        try{signal(actual.pid,name);signals.push({pid:actual.pid,birth:actual.birth,signal:name});}
        catch(error){if(error.code!=='ESRCH')problems.push(`cannot signal owned PID ${actual.pid}: ${codes.has(error.code)?error.code:'UNKNOWN'}`);}
      }
    },
    snapshot(){return {token,executable,uid,observed,drained:observed&&registrationCurrent&&current.length===0&&problems.length===0,
      identities:[...identities.values()],signals:[...signals],unknown:[...problems,...(!registrationCurrent&&uncertainty?[uncertainty]:[])],queryFailures:[...queryFailures],live:current.map(r=>r.pid)};}
  };
}
