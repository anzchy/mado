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
