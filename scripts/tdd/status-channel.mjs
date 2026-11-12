/** Private, invocation-bound cleanup evidence for native heavy-lock attempts. */
import { spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function setup(options) {
  const directory=mkdtempSync(path.join(os.tmpdir(),'mado-status-'));
  const stdio=Array.isArray(options.stdio)?[...options.stdio]:['ignore','pipe','pipe'];
  const fd=Math.max(3,stdio.length);
  while(stdio.length<=fd)stdio.push('ignore');
  stdio[fd]='pipe';
  const env={...(options.env??process.env),PICSEE_HEAVY_STATUS_DIR:directory,
    PICSEE_HEAVY_ATTEST_FD:String(fd)};
  delete env.PICSEE_HEAVY_STATUS_PATH;
  return {directory,fd,stdio,env};
}

function inspect(run, privateOutput, channel, fault) {
  let invocationID=null,statusPath=null,attested=false,reason='missing private cleanup status';
  try {
    if (run.error || run.signal || ![0,1,65,124,70].includes(run.status)) throw new Error('invalid supervisor exit');
    if (typeof privateOutput!=='string' || !/^\{[^\n]+\}\n$/.test(privateOutput)) throw new Error('missing or malformed private notice');
    const notice=JSON.parse(privateOutput);
    invocationID=notice.id;statusPath=notice.path;
    if (!/^[a-f0-9]{32}$/.test(invocationID) || notice.supervisor!==run.pid ||
        statusPath!==path.join(channel.directory,`${invocationID}.json`)) throw new Error('stale or contradictory private notice');
    let body=readFileSync(statusPath,'utf8');
    if (fault==='missing') throw new Error('missing status');
    if (fault==='malformed') body='{';
    const record=JSON.parse(body);
    if (fault==='stale') record.id='0'.repeat(32);
    if (fault==='contradictory') record.commandExit=99;
    if (record.id!==invocationID || record.supervisor!==run.pid ||
        record.cleanup!=='complete' || record.timedOut!==false ||
        record.commandExit!==run.status || ![0,1,65].includes(run.status) ||
        statSync(statusPath).nlink!==1) throw new Error('incomplete, stale or contradictory cleanup status');
    attested=true;reason='';
  } catch(error) {reason=error.message;}
  finally {rmSync(channel.directory,{recursive:true,force:true});}
  return {...run,status:attested?run.status:70,attested,invocationID,statusPath,
    ...(attested?{}:{stderr:`${run.stderr??''}status-channel: ${reason}\n`})};
}

/** For synchronous App/hosted consumers. `fault` corrupts evidence in tests only. */
export function runAttestedSync(command,args,options={}, {fault}={}) {
  const channel=setup(options);
  let run;
  try {run=spawnSync(command,args,{...options,env:channel.env,stdio:channel.stdio,encoding:'utf8'});}
  catch(error) {run={error,status:null,stdout:'',stderr:''};}
  return inspect(run,run.output?.[channel.fd],channel,fault);
}

/** Swift streams diagnostics but withholds Maven counts until this resolves. */
export function spawnAttested(command,args,options={}) {
  const channel=setup(options);
  let child;
  try {child=spawn(command,args,{...options,env:channel.env,stdio:channel.stdio});}
  catch(error) {rmSync(channel.directory,{recursive:true,force:true});throw error;}
  const chunks=[];
  child.stdio[channel.fd].on('data',chunk=>chunks.push(chunk));
  const finished=new Promise(resolve=>child.on('close',(code,signal)=>resolve(inspect(
    {status:code,signal,pid:child.pid,stdout:'',stderr:''},Buffer.concat(chunks).toString('utf8'),channel))));
  return {child,finished};
}
