import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,existsSync,symlinkSync,rmSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {admitNativePacket,runNativeRedValidation} from './native-red-ci.mjs';

const ID='i393-WI-1-native-prebuilt', FILTER='issue393RunsInsideRealAppWithLiveDispatchAndActivation';
const COMMIT='188ee8c9df5682a0dad37d35444e40fcbe0bb8f8';
const packet=()=>({schemaVersion:2,receipts:[{id:ID,lane:'app-prebuilt-red',recorded_at:'2026-11-10T00:47:22.113Z',
  head_sha:'a'.repeat(40),dirty_source:['scripts/tdd/app-lane.mjs'],red:{red:true,kind:'assertion-failure',reason:'one assertion failed'},
  test_files:{'AppTests/HostedAppProofTests.swift':{state:'ok',sha:'a'.repeat(64),lines:['abc'],reason:''}},
  verified_at:null,verdict:null,findings:[]}]});
function fixture(t){
  const root=mkdtempSync(path.join(os.tmpdir(),'native-red-ci-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
  const cwd=path.join(root,'repo'),pluginRoot=path.join(root,'external-tool'),out=path.join(cwd,'.build/hosted-native-red');
  mkdirSync(path.join(cwd,'.claude/tdd-guardian'),{recursive:true});
  mkdirSync(path.join(pluginRoot,'scripts/tdd-guardian'),{recursive:true});mkdirSync(path.join(pluginRoot,'.claude-plugin'));
  writeFileSync(path.join(pluginRoot,'.claude-plugin/plugin.json'),JSON.stringify({version:'0.10.2'}));
  writeFileSync(path.join(pluginRoot,'scripts/tdd-guardian/receipt.js'),'// external verifier fixture\n');
  const store=path.join(cwd,'.claude/tdd-guardian/receipts.json');writeFileSync(store,'sentinel');
  const env={GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',GITHUB_WORKSPACE:cwd,
    GITHUB_RUN_ID:'123',GITHUB_RUN_ATTEMPT:'2',PICSEE_HEAVY_LOCK_HELD:'1',NATIVE_RED_RECEIPT_JSON:JSON.stringify(packet())};
  return {cwd,pluginRoot,out,store,env,stdout:()=>{},stderr:()=>{}};
}
const json=p=>{assert.equal(existsSync(p),true,'expected current-run evidence file');return JSON.parse(readFileSync(p,'utf8'));};
function driver(f,alter={}) {
  const calls=[];
  const spawn=(cmd,args,options)=>{
    calls.push({cmd,args,options});
    if(cmd==='git')return {status:0,stdout:alter.commit??COMMIT};
    const verify=args.includes('verify'), e=options.env;
    assert.equal(e.NATIVE_RED_RECEIPT_JSON,undefined);
    assert.equal(e.PICSEE_APP_LANE_NO_RETRY,'1');
    if(verify){
      assert.equal(e.PICSEE_APP_FILTER,FILTER);assert.deepEqual(args.slice(-3),['verify','--id',ID]);
      const p=json(f.store);p.receipts[0].verdict='SEPARATION-HELD';p.receipts[0].verified_at=new Date().toISOString();
      alter.receipt?.(p);writeFileSync(f.store,JSON.stringify(p));
    }else assert.equal(e.PICSEE_APP_FILTER,undefined);
    const native={version:1,runId:e.PICSEE_APP_RESULT_ID,complete:true,status:0,attempts:1,retryEnabled:false,
      filter:verify?FILTER:null,groups:verify?{hosted:0}:{unhosted:0,hosted:0}};
    (verify?alter.native:alter.full)?.(native);
    if(!(verify?alter.missingNative:alter.missingFull))writeFileSync(e.PICSEE_APP_RESULT_PATH,JSON.stringify(native));
    return (verify?alter.verifyProcess:alter.fullProcess)??{status:0,stdout:'actual child output\n',stderr:''};
  };return {spawn,calls};
}

test('admission is CI-only, schema-exact and preserves existing state on all invalid partitions',t=>{
  const f=fixture(t);assert.equal(admitNativePacket({...f,packet:''}),null);
  assert.deepEqual(admitNativePacket(f),packet());assert.equal(readFileSync(f.store,'utf8'),'sentinel');
  const mutations=[p=>p.schemaVersion=1,p=>p.receipts.push(p.receipts[0]),p=>p.receipts[0].id='other',
    p=>p.receipts[0].lane='unit',p=>p.receipts[0].verdict='SEPARATION-HELD',p=>p.receipts[0].verified_at='yesterday',
    p=>p.receipts[0].red.kind='environment-failure',p=>p.receipts[0].red.red=false,
    p=>p.receipts[0].test_files={'../Proof.swift':{state:'ok'}},p=>p.receipts[0].test_files['AppTests/HostedAppProofTests.swift'].sha='bad',
    p=>p.receipts[0].test_files['AppTests/HostedAppProofTests.swift'].lines=[]];
  for(const mutate of mutations){const p=packet();mutate(p);assert.throws(()=>admitNativePacket({...f,packet:JSON.stringify(p)}));}
  assert.throws(()=>admitNativePacket({...f,packet:'{'}));
  for(const key of ['GITHUB_ACTIONS','GITHUB_EVENT_NAME','GITHUB_WORKSPACE','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','PICSEE_HEAVY_LOCK_HELD']){
    assert.throws(()=>admitNativePacket({...f,env:{...f.env,[key]:'invalid'}}));
  }
  assert.equal(readFileSync(f.store,'utf8'),'sentinel');
});
test('symlink state stores cannot overwrite external or local state',t=>{
  const f=fixture(t);rmSync(f.store);const external=path.join(f.pluginRoot,'sentinel');writeFileSync(external,'safe');symlinkSync(external,f.store);
  assert.throws(()=>admitNativePacket(f));assert.equal(readFileSync(external,'utf8'),'safe');
});
test('fresh official HELD preserves immutable original and runs an independent full combined phase',t=>{
  const f=fixture(t),d=driver(f);assert.equal(runNativeRedValidation({...f,...d}),0);
  const result=json(path.join(f.out,'result.json'));assert.equal(result.status,0);assert.equal(result.diagnostic,true);assert.equal(result.formal,false);
  assert.equal(result.complete,true);assert.notEqual(result.verification.runId,result.full.runId);
  assert.deepEqual(json(path.join(result.attemptPath,'original.json')),packet());
  assert.equal(json(path.join(result.attemptPath,'verified.json')).receipts[0].verdict,'SEPARATION-HELD');
  assert.equal(d.calls.filter(c=>c.cmd===process.execPath).length,2);
  assert.equal(d.calls.some(c=>c.args.includes('record')),false);
});
test('missing or floating official tool and failed child processes cannot pass',t=>{
  for(const alter of [{commit:'bad'},{verifyProcess:{status:1}},{verifyProcess:{status:null,signal:'SIGTERM'}},{verifyProcess:{error:new Error('spawn failed')}}]){
    const f=fixture(t),d=driver(f,alter);assert.equal(runNativeRedValidation({...f,...d}),70);
    assert.equal(json(path.join(f.out,'result.json')).status,70);
  }
  const f=fixture(t);rmSync(path.join(f.pluginRoot,'scripts/tdd-guardian/receipt.js'));
  assert.equal(runNativeRedValidation({...f,...driver(f)}),70);
});
test('exit zero cannot hide stale, forged or mutated receipt and focused native evidence',t=>{
  const alterations=[{receipt:p=>p.receipts[0].verdict='PENDING'},{receipt:p=>p.receipts[0].verdict='SEPARATION-BROKEN'},
    {receipt:p=>p.receipts[0].verified_at='2000-01-01T00:00:00Z'},
    ...['recorded_at','head_sha','dirty_source','red','test_files','lane'].map(key=>({receipt:p=>p.receipts[0][key]='forged'})),
    {missingNative:true},{native:n=>n.runId='old'},{native:n=>n.complete=false},{native:n=>n.status=1},
    {native:n=>n.attempts=2},{native:n=>n.retryEnabled=true},{native:n=>n.filter='other'},
    {native:n=>n.groups={hosted:0,unhosted:0}},{native:n=>n.groups.hosted=1}];
  for(const alter of alterations){const f=fixture(t);mkdirSync(f.out,{recursive:true});writeFileSync(path.join(f.out,'result.json'),JSON.stringify({status:0}));
    assert.equal(runNativeRedValidation({...f,...driver(f,alter)}),70);assert.equal(json(path.join(f.out,'result.json')).status,70);}
});
test('full combined completion is required separately from focused HELD',t=>{
  for(const alter of [{missingFull:true},{full:n=>n.complete=false},{full:n=>n.groups={hosted:0}},
    {full:n=>n.status=1},{full:n=>n.filter=FILTER},{full:n=>n.runId='old'},
    {fullProcess:{status:1}},{fullProcess:{status:null,signal:'SIGTERM'}}]){
    const f=fixture(t);assert.equal(runNativeRedValidation({...f,...driver(f,alter)}),70);
    assert.equal(json(path.join(f.out,'result.json')).status,70);
  }
});

test('tool clean/version guard, missing verdict and inherited filter fail closed or clear correctly',t=>{
  const dirty=fixture(t),normal=driver(dirty);
  const spawn=(cmd,args,opts)=>cmd==='git'&&args.includes('diff')?{status:1}:normal.spawn(cmd,args,opts);
  assert.equal(runNativeRedValidation({...dirty,spawn}),70);
  assert.equal(readFileSync(dirty.store,'utf8'),'sentinel');
  const wrongVersion=fixture(t);writeFileSync(path.join(wrongVersion.pluginRoot,'.claude-plugin/plugin.json'),'{"version":"0.10.3"}');
  assert.equal(runNativeRedValidation({...wrongVersion,...driver(wrongVersion)}),70);
  for(const receipt of [p=>delete p.receipts[0].verdict,p=>delete p.receipts[0].verified_at]){
    const f=fixture(t);assert.equal(runNativeRedValidation({...f,...driver(f,{receipt})}),70);
  }
  const inherited=fixture(t);inherited.env.PICSEE_APP_FILTER='untrusted inherited filter';
  assert.equal(runNativeRedValidation({...inherited,...driver(inherited)}),0);
});

test('absent packet is a no-op and unsafe parent symlinks never stage tool state',t=>{
  const empty=fixture(t);empty.env.NATIVE_RED_RECEIPT_JSON='';let invoked=false;
  assert.equal(runNativeRedValidation({...empty,spawn:()=>{invoked=true;}}),0);
  assert.equal(invoked,false);assert.equal(readFileSync(empty.store,'utf8'),'sentinel');assert.equal(existsSync(empty.out),false);
  const unsafe=fixture(t),external=path.join(unsafe.pluginRoot,'store');mkdirSync(external);
  writeFileSync(path.join(external,'receipts.json'),'external sentinel');
  rmSync(path.dirname(unsafe.store),{recursive:true});symlinkSync(external,path.dirname(unsafe.store));
  assert.equal(runNativeRedValidation({...unsafe,...driver(unsafe)}),70);
  assert.equal(readFileSync(path.join(external,'receipts.json'),'utf8'),'external sentinel');
});

test('stale phase files and current-run native retries/cancellation never establish combined success',t=>{
  for(const alter of [{full:n=>n.attempts=0},{full:n=>n.attempts=2},{full:n=>n.retryEnabled=true},
    {full:n=>n.groups.hosted=1},{full:n=>n.groups.extra=0},{fullProcess:{error:new Error('launch error')}}]){
    const f=fixture(t);mkdirSync(f.out,{recursive:true});
    writeFileSync(path.join(f.out,'native-lane.json'),JSON.stringify({complete:true,status:0,runId:'stale'}));
    assert.equal(runNativeRedValidation({...f,...driver(f,alter)}),70);
    const current=json(path.join(f.out,'result.json'));assert.equal(current.status,70);assert.equal(current.formal,false);
    assert.deepEqual(json(path.join(current.attemptPath,'original.json')),packet());
  }
});

test('nonzero verifier still preserves its actual resulting packet alongside original evidence',t=>{
  const f=fixture(t);
  assert.equal(runNativeRedValidation({...f,...driver(f,{verifyProcess:{status:1},receipt:p=>p.receipts[0].verdict='SEPARATION-BROKEN'})}),70);
  const result=json(path.join(f.out,'result.json'));
  assert.equal(json(path.join(result.attemptPath,'verified.json')).receipts[0].verdict,'SEPARATION-BROKEN');
  assert.deepEqual(json(path.join(result.attemptPath,'original.json')),packet());
});
