import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runHostedFocusBuild} from './hosted-focus-ci.mjs';
import {reportAppEvidence} from './app-evidence.mjs';

function fixture(t, run, before) {
  const out = mkdtempSync(path.join(tmpdir(), 'i393-ci-build-'));
  t.after(() => rmSync(out, {recursive:true, force:true}));
  if (before) writeFileSync(path.join(out, 'build.json'), JSON.stringify(before));
  let stdout = '', stderr = '';
  const calls = [];
  const status = runHostedFocusBuild({out, env:{GITHUB_SHA:'a'.repeat(40), RUNNER_OS:'macOS', RUNNER_ARCH:'ARM64'},
    spawn:(command,args,options) => {calls.push({command,args,options}); if (run instanceof Error) throw run; return run;},
    stdout:s => stdout += s, stderr:s => stderr += s});
  return {out,status,stdout,stderr,calls};
}

test('focused build preserves both streams and diagnostic provenance', t => {
  const h = fixture(t, {status:0, stdout:'focused build stdout\n', stderr:'focused build stderr\n'});
  assert.equal(h.status, 0);
  assert.equal(readFileSync(path.join(h.out,'build.stdout.log'),'utf8'), 'focused build stdout\n');
  assert.equal(readFileSync(path.join(h.out,'build.stderr.log'),'utf8'), 'focused build stderr\n');
  const record = JSON.parse(readFileSync(path.join(h.out,'build.json'),'utf8'));
  assert.equal(record.stage, 'build'); assert.equal(record.complete, true); assert.equal(record.status, 0);
  assert.equal(record.diagnostic, true); assert.equal(record.formal, false);
  assert.equal(record.sha, 'a'.repeat(40)); assert.equal(record.runner, 'macos-26');
  assert.equal(record.derivedDataPath, '.build/dd-ci');
  assert.match(h.calls[0].command, /heavy-lock\.sh$/);
  assert.deepEqual(h.calls[0].args, ['xcodebuild','build-for-testing','-scheme','Mado','-destination','platform=macOS',
    'CODE_SIGNING_ALLOWED=NO','-derivedDataPath','.build/dd-ci','-only-testing:MadoHostedFocusTests',
    'OTHER_SWIFT_FLAGS=$(inherited) -enable-incremental-file-hashing']);
});

for (const [name,run,status] of [
  ['compile failure',{status:65,stdout:'partial stdout',stderr:'compiler stderr'},65],
  ['signal',{status:null,signal:'SIGTERM',stdout:'partial stdout',stderr:'interrupted'},70],
  ['spawn error',Object.assign(new Error('launch unavailable'),{stdout:'partial stdout',stderr:'launch stderr'}),70],
  ['missing status',{status:null,stdout:'partial stdout',stderr:'no completion'},70],
]) test('focused build fails closed for ' + name + ' and replaces stale success', t => {
  const h = fixture(t,run,{version:1,complete:true,status:0,formal:true});
  assert.equal(h.status,status); assert.equal(h.calls.length,1);
  const record = JSON.parse(readFileSync(path.join(h.out,'build.json'),'utf8'));
  assert.equal(record.status,status); assert.equal(record.complete,true);
  assert.equal(record.formal,false); assert.equal(record.diagnostic,true);
  assert.equal(readFileSync(path.join(h.out,'build.stdout.log'),'utf8'),'partial stdout');
  assert.equal(readFileSync(path.join(h.out,'build.stderr.log'),'utf8'),run.stderr);
});

test('focused build cannot launch if current evidence cannot be initialized', t => {
  const dir=mkdtempSync(path.join(tmpdir(),'i393-ci-unwritable-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'file'); writeFileSync(file,'untouched'); let calls=0;
  const status=runHostedFocusBuild({out:path.join(file,'child'),spawn:()=>{calls++;return {status:0};},stdout:()=>{},stderr:()=>{}});
  assert.equal(status,70); assert.equal(calls,0); assert.equal(readFileSync(file,'utf8'),'untouched');
});

test('dispatch routing isolates hosted diagnosis and cannot supply formal App evidence', t => {
  const workflow=readFileSync(new URL('../../.github/workflows/ci.yml',import.meta.url),'utf8');
  assert.match(workflow,/hosted_focus_only:\n +description:[^\n]*\n +type: boolean\n +default: false/);
  const job=workflow.match(/^  hosted-focus-diagnostic:\n([\s\S]*?)(?=^  [a-z][a-z0-9-]*:|$(?![\s\S]))/m)?.[1];
  assert.ok(job,'diagnostic job exists');
  assert.match(job,/^    name: Hosted focus diagnostic$/m);
  const condition=job.match(/^    if: (.+)$/m)?.[1];
  assert.equal(condition,"github.event_name == 'workflow_dispatch' && inputs.hosted_focus_only && !inputs.app_tests");
  const evaluate=Function('github','inputs','return ('+condition+')');
  const out=mkdtempSync(path.join(tmpdir(),'i393-focus-routing-')); t.after(()=>rmSync(out,{recursive:true,force:true}));
  const record=path.join(out,'focused.json'); writeFileSync(record,JSON.stringify({version:1,status:0,complete:true,diagnostic:true,formal:false}));
  for(const event_name of ['workflow_dispatch','pull_request','push']) for(const hosted_focus_only of [false,true]) for(const app_tests of [false,true]) {
    const selected=evaluate({event_name},{hosted_focus_only,app_tests});
    assert.equal(selected,event_name==='workflow_dispatch'&&hosted_focus_only&&!app_tests);
    if(selected) {
      const evidence=reportAppEvidence({EVENT_NAME:event_name,APP_TESTS:String(app_tests),APP_TEST_STEP:'skipped',APP_RESULT_PATH:record});
      assert.equal(evidence.formal,false); assert.equal(evidence.diagnostic,true);
      assert.match(evidence.status,/tests not run/);
    }
  }
  assert.match(job,/uses: \.\/\.github\/actions\/xcode-setup/);
  assert.match(job,/run: node scripts\/ci\/hosted-focus-ci\.mjs/);
  assert.match(job,/run: node scripts\/tdd\/hosted-app-lane\.mjs/);
  assert.match(job,/PICSEE_APP_LANE_NO_RETRY: '1'/);
  const upload=job.split(/^      - name: /m).find(x=>x.startsWith('Upload hosted focus diagnostics\n'));
  assert.ok(upload); assert.match(upload,/^        if: always\(\)$/m);
  assert.match(upload,/path: \.build\/hosted-\*/);
  assert.match(upload,/include-hidden-files: true/);
});
function nativeBuildPacket() {
 return JSON.stringify({schemaVersion:2,receipts:[{id:'i393-WI-1-native-prebuilt',lane:'app-prebuilt-red',
  recorded_at:'2026-11-10T00:47:22.113Z',head_sha:'a'.repeat(40),dirty_source:[],
  red:{red:true,kind:'assertion-failure',reason:'fixture assertion'},
  test_files:{'AppTests/HostedAppProofTests.swift':{state:'ok',sha:'a'.repeat(64),lines:['fixture proof'],reason:''}},
  verdict:null,verified_at:null,findings:[]}]});
}
function nativeBuildContext(t) {
 const cwd=mkdtempSync(path.join(tmpdir(),'i393-ci-native-build-'));
 t.after(()=>rmSync(cwd,{recursive:true,force:true}));
 mkdirSync(path.join(cwd,'.claude/tdd-guardian'),{recursive:true});
 const store=path.join(cwd,'.claude/tdd-guardian/receipts.json');writeFileSync(store,'original sentinel');
 return {cwd,store,out:path.join(cwd,'evidence'),env:{GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',
  GITHUB_WORKSPACE:cwd,GITHUB_RUN_ID:'123',GITHUB_RUN_ATTEMPT:'1',PICSEE_HEAVY_LOCK_HELD:'1',
  NATIVE_RED_RECEIPT_JSON:nativeBuildPacket(),GITHUB_SHA:'a'.repeat(40),RUNNER_OS:'macOS',RUNNER_ARCH:'ARM64'}};
}
test('native receipt mode builds both bundles for recorded filtered inventory without changing original state',t=>{
 const f=nativeBuildContext(t),calls=[];
 const status=runHostedFocusBuild({...f,spawn:(cmd,args,options)=>{calls.push({cmd,args,options});return {status:0,stdout:'both bundles built',stderr:''};},stdout:()=>{},stderr:()=>{}});
 assert.equal(status,0);assert.equal(calls.length,1);
 assert.equal(calls[0].args.some(x=>x.startsWith('-only-testing:')),false);
 assert.equal(calls[0].options.env.NATIVE_RED_RECEIPT_JSON,undefined);
 const record=JSON.parse(readFileSync(path.join(f.out,'build.json'),'utf8'));
 assert.equal(record.retainedInventory,true);assert.equal(record.formal,false);
 assert.equal(readFileSync(f.store,'utf8'),'original sentinel');
});
for(const label of ['invalid packet','local context']) test('native receipt build rejects '+label+' before native work',t=>{
 const f=nativeBuildContext(t);let calls=0;
 const env={...f.env,...(label==='invalid packet'?{NATIVE_RED_RECEIPT_JSON:'{'}:{GITHUB_ACTIONS:'false'})};
 const status=runHostedFocusBuild({...f,env,spawn:()=>{calls++;return {status:0};},stdout:()=>{},stderr:()=>{}});
 assert.equal(status,64);assert.equal(calls,0);assert.equal(readFileSync(f.store,'utf8'),'original sentinel');
});
test('optional native receipt workflow pins the tool and keeps native verification and full validation explicit',()=>{
 const workflow=readFileSync(new URL('../../.github/workflows/ci.yml',import.meta.url),'utf8');
 assert.match(workflow,/native_red_receipt:\n +description:[^\n]*\n +type: string\n +default: ''/);
 const job=workflow.split('  hosted-focus-diagnostic:\n')[1];assert.ok(job);
 assert.match(job,/timeout-minutes: \$\{\{ inputs\.native_red_receipt != '' && 120 \|\| 45 \}\}/);
 const steps=job.split(/^      - name: /m);
 const tool=steps.find(x=>x.startsWith('Checkout pinned tdd-guardian\n'));
 assert.ok(tool);assert.match(tool,/repository: xiaolai\/tdd-guardian-for-claude/);
 assert.match(tool,/ref: 188ee8c9df5682a0dad37d35444e40fcbe0bb8f8/);
 assert.match(tool,/path: \.build\/ci-tdd-guardian/);assert.match(tool,/persist-credentials: false/);
 const focused=steps.find(x=>x.startsWith('Run hosted focus diagnostic\n'));
 assert.match(focused,/if: inputs\.native_red_receipt == ''/);
 const verification=steps.find(x=>x.startsWith('Verify native RED and full App lane\n'));
 assert.ok(verification);assert.match(verification,/if: inputs\.native_red_receipt != ''/);
 assert.match(verification,/NATIVE_RED_RECEIPT_JSON: \$\{\{ inputs\.native_red_receipt \}\}/);
 assert.match(verification,/run: node scripts\/ci\/native-red-ci\.mjs/);
});
