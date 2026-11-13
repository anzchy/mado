/** Private, invocation-bound cleanup evidence for native heavy-lock attempts. */
import { spawnSync, spawn } from 'node:child_process';

function setup(options) {
  const stdio=Array.isArray(options.stdio)?[...options.stdio]:['ignore','pipe','pipe'];
  const fd=Math.max(3,stdio.length);
  while(stdio.length<=fd)stdio.push('ignore');
  stdio[fd]='pipe';
  const env={...(options.env??process.env),PICSEE_HEAVY_ATTEST_FD:String(fd)};
  delete env.PICSEE_HEAVY_STATUS_PATH;
  delete env.PICSEE_HEAVY_STATUS_DIR;
  return {fd,stdio,env};
}

function inspect(run, privateOutput, channel, fault, rejectDrain=false) {
  let invocationID=null,statusPath=null,attested=false,reason='missing private cleanup status';
  try {
    if (run.error || run.signal || ![0,1,65,124,70].includes(run.status)) throw new Error('invalid supervisor exit');
    if (typeof privateOutput!=='string' || !/^(?:\{[^\n]+\}\n){2}$/.test(privateOutput)) throw new Error('missing or malformed private records');
    const [header,final]=privateOutput.trimEnd().split('\n');
    const notice=JSON.parse(header);
    invocationID=notice.id;statusPath=`pipe:${invocationID}`;
    if (notice.kind!=='begin' || !/^[a-f0-9]{32}$/.test(invocationID) ||
        notice.supervisor!==run.pid) throw new Error('stale or contradictory private notice');
    let body=final;
    if (fault==='missing') throw new Error('missing status');
    if (fault==='malformed') body='{';
    const record=JSON.parse(body);
    if (fault==='stale') record.id='0'.repeat(32);
    if (fault==='contradictory') record.commandExit=99;
    if (record.kind!=='status' || record.id!==invocationID || record.supervisor!==run.pid ||
        record.cleanup!=='complete' || record.timedOut!==false ||
        record.commandExit!==run.status || ![0,1,65].includes(run.status))
      throw new Error('incomplete, stale or contradictory cleanup status');
    // #672: a leader that exited while its group survived had to be drained by
    // force. Callers producing gates or RED receipts never accept that result.
    if (rejectDrain && record.drainExpired!==false)
      throw new Error('drain expired: leader exited with surviving descendants');
    attested=true;reason='';
  } catch(error) {reason=error.message;}
  return {...run,status:attested?run.status:70,attested,invocationID,statusPath,
    ...(attested?{}:{stderr:`${run.stderr??''}status-channel: ${reason}\n`})};
}

/** For synchronous App/hosted consumers. `fault` corrupts evidence in tests only. */
export function runAttestedSync(command,args,options={}, {fault,rejectDrain=false}={}) {
  const channel=setup(options);
  let run;
  try {run=spawnSync(command,args,{...options,env:channel.env,stdio:channel.stdio,encoding:'utf8'});}
  catch(error) {run={error,status:null,stdout:'',stderr:''};}
  return inspect(run,run.output?.[channel.fd],channel,fault,rejectDrain);
}

/** Swift streams diagnostics but withholds Maven counts until this resolves. */
export function spawnAttested(command,args,options={},{rejectDrain=false}={}) {
  const channel=setup(options);
  const child=spawn(command,args,{...options,env:channel.env,stdio:channel.stdio});
  const chunks=[];
  child.stdio[channel.fd].on('data',chunk=>chunks.push(chunk));
  const finished=new Promise(resolve=>child.on('close',(code,signal)=>resolve(inspect(
    {status:code,signal,pid:child.pid,stdout:'',stderr:''},Buffer.concat(chunks).toString('utf8'),channel,undefined,rejectDrain))));
  return {child,finished};
}
