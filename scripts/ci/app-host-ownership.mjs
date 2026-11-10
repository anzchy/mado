/** Exact invocation ownership for App hosts launched outside xcodebuild's process group. */
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
                if field.startswith(b'PICSEE_TEST_RUN_TOKEN='): marker=os.fsdecode(field.split(b'=',1)[1])
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
                    if field.startswith(b'PICSEE_TEST_RUN_TOKEN='): marker=os.fsdecode(field.split(b'=',1)[1])
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

export function queryHostProcesses({token,executable,uid=process.getuid(),pids,spawn=spawnSync}={}){
  try{
    const run=spawn('/usr/bin/python3',['-c',inspector,JSON.stringify({token,executable,uid,pids})],
      {encoding:'utf8',timeout:1000,maxBuffer:4*1024*1024});
    if(run.error||run.signal||run.status!==0)throw new Error('OS ownership inspection failed');
    const result=JSON.parse(run.stdout);
    if(result.complete!==true||!Array.isArray(result.processes)||!Array.isArray(result.unknown))throw new Error('incomplete OS ownership response');
    return result;
  }catch(error){return {complete:false,processes:[],unknown:[{reason:error.message}]};}
}
const same=(a,b)=>a.pid===b.pid&&a.birth===b.birth&&a.uid===b.uid&&a.executable===b.executable&&a.marker===b.marker;
export function createHostOwnership({token,executable,uid=process.getuid(),query=queryHostProcesses,excludeGroup=()=>undefined,excludePids=[process.pid],
  signal=(pid,name)=>process.kill(pid,name)}={}){
  if(typeof token!=='string'||!token.trim()||typeof executable!=='string'||!path.isAbsolute(executable)||
    realpathSync(executable)!==executable||!Number.isInteger(uid)||uid<0)throw new Error('invalid hosted ownership request');
  const identities=new Map(),signals=[],problems=[];let current=[],observed=false,complete=false;
  const valid=r=>r&&Number.isInteger(r.pid)&&r.pid>0&&/^\d+:\d+$/.test(r.birth??'')&&
    r.uid===uid&&r.executable===executable&&r.marker===token;
  function inspect(pids){
    let result;try{result=query({token,executable,uid,pids});}catch(error){result={complete:false,processes:[],unknown:[error.message]};}
    const relevantUnknown=Array.isArray(result?.unknown)?result.unknown.filter(problem=>
      !Number.isInteger(problem?.uid)||problem.uid===uid||identities.has(problem.pid)):null;
    complete=result?.complete===true&&Array.isArray(result.processes)&&relevantUnknown!==null&&relevantUnknown.length===0;
    if(!complete){problems.push('OS ownership query incomplete or unreadable');return null;}
    const outside=result.processes.filter(record=>record.pgid!==excludeGroup()&&!excludePids.includes(record.pid));
    for(const record of outside){
      const original=identities.get(record.pid);
      if(original&&!same(original,record))problems.push(`identity changed for PID ${record.pid}`);
      if(record.marker===token&&!valid(record))problems.push('malformed or mismatched current host identity');
    }
    return outside;
  }
  return {
    observe(){
      const records=inspect();if(records===null)return;
      current=records.filter(valid);
      for(const record of current){if(!identities.has(record.pid))identities.set(record.pid,{...record});observed=true;}
    },
    signalOwned(name){
      for(const original of identities.values()){
        // Re-query immediately before each signal; a prior observation never authorizes PID reuse.
        const records=inspect([original.pid]);if(records===null)continue;
        const actual=records.find(r=>r.pid===original.pid);
        if(!actual)continue;
        if(!valid(actual)||!same(original,actual)||problems.length)continue;
        try{signal(actual.pid,name);signals.push({pid:actual.pid,birth:actual.birth,signal:name});}
        catch(error){if(error.code!=='ESRCH')problems.push(`cannot signal owned PID ${actual.pid}: ${error.message}`);}
      }
    },
    snapshot(){return {token,executable,uid,observed,drained:observed&&complete&&current.length===0&&problems.length===0,
      identities:[...identities.values()],signals:[...signals],unknown:[...problems],live:current.map(r=>r.pid)};}
  };
}
