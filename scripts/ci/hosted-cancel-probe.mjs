/** Real diagnostic cancellation through the same supervisor/worker as comparison runs. */
import {mkdirSync,mkdtempSync,writeFileSync,realpathSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runProcessGroup} from './app-repeat-process.mjs';

export async function runHostedCancelProbe({env=process.env,cwd=process.cwd(),out=path.join(cwd,'.build/app-compare-cancel'),
  command,args,token=randomUUID(),executable,deadline,graceMs,drainMs,preparedInspector,inspectorSpawn,
  hostQuery,hostSignal,groupSignal,signal,now=Date.now}={}){
  const result={version:1,diagnostic:true,formal:false,complete:false,status:70,sha:env.GITHUB_SHA??'unknown',
    runId:env.GITHUB_RUN_ID??null,runAttempt:env.GITHUB_RUN_ATTEMPT??null,token,startedAt:new Date().toISOString()};
  const save=()=>writeFileSync(path.join(out,'result.json'),JSON.stringify(result,null,2)+'\n');
  try{
    mkdirSync(out,{recursive:true});save();
    const attemptPath=mkdtempSync(path.join(out,'attempt-'));result.attemptPath=attemptPath;save();
    if(command===undefined&&env.PICSEE_HEAVY_LOCK_HELD!=='1')throw new Error('actual hosted cancellation requires the heavy-lock authorization');
    const derived=env.PICSEE_APP_DERIVED_DATA_PATH??'.build/dd-ci';
    const expected=realpathSync(executable??path.resolve(cwd,derived,'Build/Products/Debug/Mado.app/Contents/MacOS/Mado'));
    const quarantine=path.join(attemptPath,'quarantine.json');writeFileSync(quarantine,'[]\n');
    const worker=fileURLToPath(new URL('./app-repeat-worker.mjs',import.meta.url));
    const workerArgs=args??[worker,quarantine,path.join(attemptPath,'worker-evidence.json'),'hosted'];
    const childEnv={...env,APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',PICSEE_APP_LANE_NO_RETRY:'1',
      MADO_TEST_RUN_TOKEN:token,TEST_RUNNER_MADO_TEST_RUN_TOKEN:token,MADO_HOST_OWNERSHIP_REQUIRED:'1',
      MADO_HOST_EXECUTABLE:expected,MADO_APP_COMPARE_RESULT_PATH:path.join(attemptPath,'comparison.json')};
    delete childEnv.PICSEE_APP_FILTER;
    result.supervisor=await runProcessGroup({command:command??process.execPath,args:workerArgs,env:childEnv,
      logPath:path.join(attemptPath,'native.log'),deadline:Math.min(deadline??Infinity,Date.now()+120000),
      graceMs,drainMs,cancelOnHostObserved:true,preparedInspector,inspectorSpawn,hostQuery,hostSignal,groupSignal,signal,now});
    const s=result.supervisor,h=s.hostOwnership;
    if(s.status!==70||s.drained!==true||s.cancelledOnHostObserved!==true||!h?.observed||h.drained!==true||
      h.identities.length===0||h.signals.length===0||h.live.length!==0||h.unknown.length!==0||
      s.inspector?.closed!==true||s.inspector?.reaped!==true)
      throw new Error('exact observed hosted invocation was not cancelled and proven drained');
    result.status=0;
  }catch(error){result.error=error.message;}
  result.complete=true;result.endedAt=new Date().toISOString();
  try{save();}catch(error){process.stderr.write(`hosted-cancel-probe: ${error.message}\n`);return 70;}
  return result.status;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=await runHostedCancelProbe();
