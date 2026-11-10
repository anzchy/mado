/** CI-only import of an original RED; execution remains the official verifier's job. */
import {spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync,readFileSync,realpathSync,lstatSync,existsSync,mkdtempSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const ID='i393-WI-1-native-prebuilt',FILTER='issue393RunsInsideRealAppWithLiveDispatchAndActivation';
const COMMIT='188ee8c9df5682a0dad37d35444e40fcbe0bb8f8';
const proof='AppTests/HostedAppProofTests.swift';
const requireFact=(condition,message)=>{if(!condition)throw new Error(message);};
const object=x=>x!==null&&typeof x==='object'&&!Array.isArray(x);
const storePath=cwd=>path.join(cwd,'.claude/tdd-guardian/receipts.json');
const readJSON=p=>JSON.parse(readFileSync(p,'utf8'));
const save=(p,value)=>writeFileSync(p,JSON.stringify(value,null,2)+'\n');
function safeStore(cwd){
  for(const suffix of ['.claude','.claude/tdd-guardian','.claude/tdd-guardian/receipts.json']){
    const p=path.join(cwd,suffix);
    if(existsSync(p)||(()=>{try{return lstatSync(p).isSymbolicLink();}catch{return false;}})())
      requireFact(!lstatSync(p).isSymbolicLink(),'unsafe receipt store symlink');
  }
}
export function admitNativePacket({env=process.env,packet=env.NATIVE_RED_RECEIPT_JSON,cwd=process.cwd()}={}){
  if(packet===undefined||packet==='')return null;
  requireFact(env.GITHUB_ACTIONS==='true'&&env.GITHUB_EVENT_NAME==='workflow_dispatch'&&
    env.PICSEE_HEAVY_LOCK_HELD==='1','native RED import requires explicit locked diagnostic CI');
  requireFact(/^\d+$/.test(env.GITHUB_RUN_ID??'')&&/^[1-9]\d*$/.test(env.GITHUB_RUN_ATTEMPT??''),'invalid CI run identity');
  requireFact(env.GITHUB_WORKSPACE&&realpathSync(env.GITHUB_WORKSPACE)===realpathSync(cwd),'CI workspace mismatch');
  safeStore(cwd);
  const p=JSON.parse(packet);
  requireFact(object(p)&&p.schemaVersion===2&&Array.isArray(p.receipts)&&p.receipts.length===1,'invalid original receipt store');
  const r=p.receipts[0];
  requireFact(object(r)&&r.id===ID&&r.lane==='app-prebuilt-red'&&r.verdict===null&&r.verified_at===null,'receipt must be original pending native RED');
  requireFact(object(r.red)&&r.red.red===true&&r.red.kind==='assertion-failure','receipt must contain genuine assertion RED');
  requireFact(object(r.test_files)&&isDeepStrictEqual(Object.keys(r.test_files),[proof]),'unexpected recorded test selection');
  const f=r.test_files[proof];
  requireFact(object(f)&&f.state==='ok'&&/^[a-fA-F0-9]{64}$/.test(f.sha??'')&&Array.isArray(f.lines)&&
    f.lines.length>0&&f.lines.every(x=>typeof x==='string'&&x.length>0),'invalid original test fingerprint');
  return p;
}
function immutable(packet){
  const p=structuredClone(packet);
  for(const r of p.receipts){delete r.verdict;delete r.verified_at;delete r.findings;}
  return p;
}
function successful(run){return run&&!run.error&&!run.signal&&run.status===0;}
function nativeEvidence(p,runId,filter){
  const n=readJSON(p),keys=filter===null?['hosted','unhosted']:['hosted'];
  requireFact(n.version===1&&n.runId===runId&&n.complete===true&&n.status===0&&n.attempts===1&&
    n.retryEnabled===false&&n.filter===filter&&object(n.groups)&&
    isDeepStrictEqual(Object.keys(n.groups).sort(),keys)&&Object.values(n.groups).every(x=>x===0),
    'fresh complete native execution evidence required');
  return n;
}
export function runNativeRedValidation({spawn=spawnSync,env=process.env,cwd=process.cwd(),
  out=path.join(cwd,'.build/hosted-native-red'),pluginRoot=path.join(cwd,'.build/ci-tdd-guardian'),
  stdout=s=>process.stdout.write(s),stderr=s=>process.stderr.write(s)}={}){
  let result,attemptPath,staged=false;
  const persist=()=>save(path.join(out,'result.json'),result);
  try{
    const packet=admitNativePacket({env,cwd});
    if(packet===null)return 0;
    mkdirSync(out,{recursive:true});
    result={version:1,diagnostic:true,formal:false,complete:false,status:70,
      runId:env.GITHUB_RUN_ID,runAttempt:env.GITHUB_RUN_ATTEMPT,sha:env.GITHUB_SHA??'unknown'};persist();
    attemptPath=mkdtempSync(path.join(out,'attempt-'));result.attemptPath=attemptPath;persist();
    save(path.join(attemptPath,'original.json'),packet);
    const call=(cmd,args,childEnv,label,timeout=2100000)=>{
      let run;try{run=spawn(cmd,args,{cwd,env:childEnv,encoding:'utf8',timeout,maxBuffer:64*1024*1024});}
      catch(error){run={error};}
      const output=run?.stdout??'',errors=run?.stderr??'';
      writeFileSync(path.join(attemptPath,label+'.stdout.log'),output);writeFileSync(path.join(attemptPath,label+'.stderr.log'),errors);
      stdout(output);stderr(errors);requireFact(successful(run),label+' process did not complete successfully');return output;
    };
    const childEnv={...env,PICSEE_APP_LANE_NO_RETRY:'1'};delete childEnv.NATIVE_RED_RECEIPT_JSON;
    const cli=path.join(pluginRoot,'scripts/tdd-guardian/receipt.js');
    requireFact(lstatSync(cli).isFile()&&!lstatSync(cli).isSymbolicLink(),'official receipt CLI must be a regular file');
    requireFact(readJSON(path.join(pluginRoot,'.claude-plugin/plugin.json')).version==='0.10.2','wrong official tool version');
    const commit=call('git',['-C',pluginRoot,'rev-parse','HEAD'],childEnv,'tool-head',60000).trim();
    requireFact(commit===COMMIT,'wrong official tool commit');
    call('git',['-C',pluginRoot,'diff','--quiet','HEAD','--'],childEnv,'tool-clean',60000);
    result.tool={commit,version:'0.10.2',pluginRoot};persist();
    safeStore(cwd);mkdirSync(path.dirname(storePath(cwd)),{recursive:true});save(storePath(cwd),packet);staged=true;
    const nonce=`${env.GITHUB_RUN_ID}:${env.GITHUB_RUN_ATTEMPT}:${randomUUID()}`;
    const verifyId=nonce+':verify',verifyPath=path.join(attemptPath,'verify-native-lane.json');
    const started=Date.now();
    call(process.execPath,[cli,'verify','--id',ID],{...childEnv,PICSEE_APP_FILTER:FILTER,
      PICSEE_APP_RESULT_ID:verifyId,PICSEE_APP_RESULT_PATH:verifyPath},'verify');
    const verified=readJSON(storePath(cwd));save(path.join(attemptPath,'verified.json'),verified);
    requireFact(isDeepStrictEqual(immutable(verified),immutable(packet)),'official verification changed original RED fields');
    const r=verified.receipts[0],date=Date.parse(r.verified_at);
    requireFact(r.verdict==='SEPARATION-HELD'&&Number.isFinite(date)&&date>=started&&date<=Date.now(),'fresh official SEPARATION-HELD required');
    result.verification=nativeEvidence(verifyPath,verifyId,FILTER);persist();
    const fullId=nonce+':full',fullPath=path.join(attemptPath,'full-native-lane.json');
    const fullEnv={...childEnv,PICSEE_APP_RESULT_ID:fullId,PICSEE_APP_RESULT_PATH:fullPath};delete fullEnv.PICSEE_APP_FILTER;
    call(process.execPath,[path.join(cwd,'scripts/tdd/app-lane.mjs')],fullEnv,'full');
    result.full=nativeEvidence(fullPath,fullId,null);result.status=0;result.complete=true;persist();return 0;
  }catch(error){
    stderr('native-red-ci: '+error.message+'\n');
    if(staged&&attemptPath){try{save(path.join(attemptPath,'verified.json'),readJSON(storePath(cwd)));}catch{}}
    if(result){result.status=70;result.complete=true;result.error=error.message;try{persist();}catch{}}
    return 70;
  }
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=runNativeRedValidation();
