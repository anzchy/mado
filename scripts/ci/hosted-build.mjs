import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
export function runHostedBuild({env=process.env,cwd=process.cwd(),out=env.APP_COMPARE_BUILD_OUT??'.build/app-compare-build',
 spawn=spawnSync,now=Date.now,stdout=s=>process.stdout.write(s),stderr=s=>process.stderr.write(s)}={}) {
 const mode=env.APP_COMPARE_MODE;
 if(mode!=='hosted'||env.GITHUB_ACTIONS!=='true'||env.GITHUB_EVENT_NAME!=='workflow_dispatch'||env.PICSEE_HEAVY_LOCK_HELD!=='1'){
  stderr('comparison build requires explicit locked dispatch mode\n');return 64;
 }
 const control=Number(env.PICSEE_HEAVY_CONTROL_FD);
 if(!Number.isInteger(control)||control<3||control>64){stderr('comparison build needs parent control FD\n');return 70;}
 const fds=[control];
 if(env.PICSEE_HEAVY_FLOCK_FD){
  const flock=Number(env.PICSEE_HEAVY_FLOCK_FD);
  if(!Number.isInteger(flock)||flock<3||flock>64){stderr('comparison build has invalid flock FD\n');return 70;}
  fds.push(flock);
 }
 const stdio=['ignore','pipe','pipe'];
 for(const fd of fds){while(stdio.length<=fd)stdio.push('ignore');stdio[fd]=fd;}
 const started=now(),derivedDataPath='.build/dd-ci';
 const record={version:1,mode,sha:env.GITHUB_SHA??'unknown',runner:'macos-26',
  diagnostic:true,formal:false,complete:false,status:null,derivedDataPath};
 record.stages=[];
 mkdirSync(out,{recursive:true});
 const save=()=>writeFileSync(path.join(out,'build.json'),JSON.stringify(record,null,2)+'\n');save();
 const perform=(name,args,prefix)=>{
  const stageStarted=now();
  let run;
  try{run=spawn(new URL('../heavy-lock.sh',import.meta.url).pathname,args,
   {cwd,env,stdio,encoding:'utf8',timeout:2100000,maxBuffer:64*1024*1024});}
  catch(error){run={error,stdout:error.stdout,stderr:error.stderr};}
  const status=!run?.error&&!run?.signal&&Number.isInteger(run?.status)&&run.status>=0?run.status:70;
  const stage={name,complete:true,status,nativeStatus:run?.status??null,signal:run?.signal??null,error:run?.error?.message??null,
   wallMilliseconds:now()-stageStarted};
  record.stages.push(stage);
  writeFileSync(path.join(out,prefix+'.stdout.log'),run?.stdout??'');
  writeFileSync(path.join(out,prefix+'.stderr.log'),run?.stderr??'');
  stdout(run?.stdout??'');stderr(run?.stderr??'');
  record.status=status;record.signal=stage.signal;record.error=stage.error;save();
  return status;
 };
 const finish=()=>{record.wallMilliseconds=now()-started;record.complete=true;save();return record.status;};
 // Clear stale logs before this build so failure evidence belongs to the current run.
 writeFileSync(path.join(out,'build.stdout.log'),'');writeFileSync(path.join(out,'build.stderr.log'),'');
 perform('hosted-tests',['xcodebuild','build-for-testing',
  '-scheme','Mado','-destination','platform=macOS',
  'CODE_SIGNING_ALLOWED=NO','-derivedDataPath',derivedDataPath,'OTHER_SWIFT_FLAGS=$(inherited) -enable-incremental-file-hashing'],'build');
 return finish();
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=runHostedBuild();
