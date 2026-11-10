import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {readFileSync,mkdirSync,writeFileSync,readdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
export const BASELINE='c5a087f5949e0f087b96f19d0f4c58a8310a8960';
export const legacyWrappers=[
 'issue521NativePanPassesInIsolatedProcess()',
 'issue527NonCanvasPressesPassInIsolatedProcess()',
 'issue527InactiveFirstClickPassesInIsolatedProcess()',
 'issue527InspectorCanvasPressPassesInIsolatedProcess()',
 'issue564KeyWindowFixturePassesInIsolatedProcess()',
 'retry442NativeKeyboardMatrixPassesInIsolatedProcess()',
];
export function validateLegacySources({cwd=process.cwd()}={}) {
 const manifest=JSON.parse(readFileSync(new URL('./legacy393-manifest.json',import.meta.url),'utf8'));
 if(manifest.baseline!==BASELINE||Object.keys(manifest.files).length!==8)throw new Error('invalid frozen legacy source manifest');
 const allowed=new Set([...Object.keys(manifest.files),'LegacyRuntimeProof.swift']);
 for(const entry of readdirSync(path.join(cwd,'Legacy393Tests'),{withFileTypes:true})){
  if(!entry.isFile()||!allowed.has(entry.name))throw new Error('unexpected legacy source: '+entry.name);
 }
 for(const [name,sha] of Object.entries(manifest.files)){
  if(path.basename(name)!==name||!name.endsWith('.swift'))throw new Error('invalid legacy source path');
  const actual=createHash('sha256').update(readFileSync(path.join(cwd,'Legacy393Tests',name))).digest('hex');
  if(actual!==sha)throw new Error('frozen legacy source mismatch: '+name);
 }
 return manifest;
}
export function runComparisonBuild({env=process.env,cwd=process.cwd(),out=env.APP_COMPARE_BUILD_OUT??'.build/app-compare-build',
 spawn=spawnSync,now=Date.now,stdout=s=>process.stdout.write(s),stderr=s=>process.stderr.write(s)}={}) {
 const mode=env.APP_COMPARE_MODE;
 if(!['legacy','hosted'].includes(mode)||env.GITHUB_ACTIONS!=='true'||env.GITHUB_EVENT_NAME!=='workflow_dispatch'||env.PICSEE_HEAVY_LOCK_HELD!=='1'){
  stderr('comparison build requires explicit locked dispatch mode\n');return 64;
 }
 try{if(mode==='legacy')validateLegacySources({cwd});}catch(error){stderr(error.message+'\n');return 70;}
 const started=now(),derivedDataPath=mode==='legacy'?'.build/dd-legacy393':'.build/dd-ci';
 const record={version:1,mode,baseline:BASELINE,sha:env.GITHUB_SHA??'unknown',runner:'macos-26',
  diagnostic:true,formal:false,complete:false,status:null,derivedDataPath};
 mkdirSync(out,{recursive:true});
 const save=()=>writeFileSync(path.join(out,'build.json'),JSON.stringify(record,null,2)+'\n');save();
 let run;
 try{run=spawn(new URL('../heavy-lock.sh',import.meta.url).pathname,['xcodebuild','build-for-testing',
  '-scheme',mode==='legacy'?'MadoLegacy393':'Mado','-destination','platform=macOS',
  'CODE_SIGNING_ALLOWED=NO','-derivedDataPath',derivedDataPath,'OTHER_SWIFT_FLAGS=$(inherited) -enable-incremental-file-hashing'],
  {cwd,env,encoding:'utf8',timeout:2100000,maxBuffer:64*1024*1024});}catch(error){run={error};}
 record.status=!run?.error&&!run?.signal&&Number.isInteger(run?.status)&&run.status>=0?run.status:70;
 record.signal=run?.signal??null;record.error=run?.error?.message??null;record.wallMilliseconds=now()-started;record.complete=true;
 writeFileSync(path.join(out,'build.stdout.log'),run?.stdout??'');writeFileSync(path.join(out,'build.stderr.log'),run?.stderr??'');save();
 stdout(run?.stdout??'');stderr(run?.stderr??'');return record.status;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=runComparisonBuild();
