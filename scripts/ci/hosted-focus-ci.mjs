/** Diagnostic-only focused build; the existing hosted lane owns test execution. */
import {spawnSync} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {admitNativePacket} from './native-red-ci.mjs';

const lock=fileURLToPath(new URL('../heavy-lock.sh',import.meta.url));

export function runHostedFocusBuild({spawn=spawnSync,env=process.env,cwd=process.cwd(),out='.build/hosted-focus-build',
  stdout=s=>process.stdout.write(s),stderr=s=>process.stderr.write(s),now=Date.now}={}) {
  const started=now();
  let retainedInventory;
  try {retainedInventory=admitNativePacket({env,cwd})!==null;}
  catch(error) {stderr('hosted-focus-ci: invalid native receipt request: '+error.message+'\n');return 64;}
  const childEnv={...env};delete childEnv.NATIVE_RED_RECEIPT_JSON;
  const derivedDataPath=env.PICSEE_APP_DERIVED_DATA_PATH || '.build/dd-ci';
  const record={version:1,stage:'build',complete:false,status:null,diagnostic:true,formal:false,
    sha:env.GITHUB_SHA || 'unknown',runner:env.RUNNER_OS==='macOS'?'macos-26':'local',
    runnerOS:env.RUNNER_OS || process.platform,runnerArch:env.RUNNER_ARCH || process.arch,derivedDataPath,retainedInventory};
  const save=()=>writeFileSync(path.join(out,'build.json'),JSON.stringify(record,null,2)+'\n');
  try {mkdirSync(out,{recursive:true});save();}
  catch(error) {stderr('hosted-focus-ci: cannot initialize build evidence: '+error.message+'\n');return 70;}
  let run;
  try {
    run=spawn(lock,['xcodebuild','build-for-testing','-scheme','Mado','-destination','platform=macOS',
      'CODE_SIGNING_ALLOWED=NO','-derivedDataPath',derivedDataPath,...(retainedInventory?[]:['-only-testing:MadoHostedFocusTests']),
      'OTHER_SWIFT_FLAGS=$(inherited) -enable-incremental-file-hashing'],
    {cwd,env:childEnv,encoding:'utf8',timeout:2100000,maxBuffer:64*1024*1024});
  } catch(error) {run={error,stdout:error.stdout,stderr:error.stderr};}
  const status=run && !run.error && !run.signal && Number.isInteger(run.status) && run.status>=0?run.status:70;
  const output=run?.stdout ?? '', errors=run?.stderr ?? '';
  stdout(output);stderr(errors);
  Object.assign(record,{complete:true,status,nativeStatus:run?.status ?? null,signal:run?.signal ?? null,
    error:run?.error?.message ?? null,wallMilliseconds:Math.max(0,now()-started)});
  try {
    writeFileSync(path.join(out,'build.stdout.log'),output);
    writeFileSync(path.join(out,'build.stderr.log'),errors);
    save();
  } catch(error) {stderr('hosted-focus-ci: cannot preserve build evidence: '+error.message+'\n');return 70;}
  return status;
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
  process.exitCode=runHostedFocusBuild();
