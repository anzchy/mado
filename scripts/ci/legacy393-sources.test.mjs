import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,cpSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {BASELINE,legacyWrappers,validateLegacySources,runComparisonBuild} from './legacy393-sources.mjs';
const root=path.resolve(import.meta.dirname,'../..');
const names=['Issue521NativePanRunner.swift','Issue521CanvasToolFocusTests.swift','Issue527CanvasFocusTests.swift','Issue527InactiveWindowTests.swift','Issue527InspectorFocusTests.swift','KeyWindowFixture.swift','KeyWindowFixtureTests.swift','Retry442Tests.swift'];
const temporary=t=>{const p=mkdtempSync(path.join(tmpdir(),'legacy393-'));t.after(()=>rmSync(p,{recursive:true,force:true}));return p;};
test('frozen eight match the pinned Git source bytes and isolate exactly six original wrappers',()=>{
 const manifest=validateLegacySources({cwd:root});
 assert.equal(manifest?.baseline,BASELINE);
 assert.deepEqual(Object.keys(manifest.files).sort(),names.toSorted());
 for(const name of names){
  const original=spawnSync('git',['show',`${BASELINE}:AppTests/${name}`],{cwd:root});
  assert.equal(original.status,0);assert.deepEqual(readFileSync(path.join(root,'Legacy393Tests',name)),original.stdout);
 }
 assert.deepEqual(legacyWrappers,['issue521NativePanPassesInIsolatedProcess()','issue527NonCanvasPressesPassInIsolatedProcess()','issue527InactiveFirstClickPassesInIsolatedProcess()','issue527InspectorCanvasPressPassesInIsolatedProcess()','issue564KeyWindowFixturePassesInIsolatedProcess()','retry442NativeKeyboardMatrixPassesInIsolatedProcess()']);
});
test('each missing or changed frozen source refuses native work; supplemental proof allowed',t=>{
 for(const name of names){
  const cwd=temporary(t);mkdirSync(path.join(cwd,'Legacy393Tests'));cpSync(path.join(root,'Legacy393Tests'),path.join(cwd,'Legacy393Tests'),{recursive:true});
  writeFileSync(path.join(cwd,'Legacy393Tests',name),'altered');assert.throws(()=>validateLegacySources({cwd}),/legacy|frozen|source/i);
  rmSync(path.join(cwd,'Legacy393Tests',name));assert.throws(()=>validateLegacySources({cwd}),/legacy|frozen|source|ENOENT/i);
 }
});
test('explicit CI builds disjoint mechanisms and persists timing/provenance',t=>{
 for(const mode of ['legacy','hosted']){
  const out=temporary(t),calls=[];
  const env={GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',GITHUB_SHA:'final-sha',APP_COMPARE_MODE:mode,PICSEE_HEAVY_LOCK_HELD:'1',RUNNER_OS:'macOS',RUNNER_ARCH:'ARM64'};
  const status=runComparisonBuild({cwd:root,env,out,now:(()=>{let n=1000;return()=>n+=50;})(),spawn:(cmd,args,opts)=>{calls.push({cmd,args,opts});return {status:0,stdout:'built\n',stderr:''};}});
  assert.equal(status,0);assert.equal(calls.length,1);
  assert.ok(calls[0].args.includes(mode==='legacy'?'MadoLegacy393':'Mado'));
  assert.ok(calls[0].args.includes(mode==='legacy'?'.build/dd-legacy393':'.build/dd-ci'));
  const record=JSON.parse(readFileSync(path.join(out,'build.json')));
  assert.equal(record.formal,false);assert.equal(record.mode,mode);assert.equal(record.sha,'final-sha');assert.equal(record.complete,true);assert.equal(record.status,0);assert.equal(record.wallMilliseconds,50);
 }
});
test('unknown mode, formal/local context and damaged legacy payload fail before spawn',t=>{
 for(const override of [{APP_COMPARE_MODE:'unknown'},{GITHUB_ACTIONS:'false'},{GITHUB_EVENT_NAME:'push'},{PICSEE_HEAVY_LOCK_HELD:'0'}]){
  let calls=0;
  const status=runComparisonBuild({cwd:root,out:temporary(t),env:{GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'hosted',...override},spawn:()=>{calls++;return {status:0};}});
  assert.notEqual(status,0);assert.equal(calls,0);
 }
});
test('build failure, signal and error retain failed current diagnostic evidence',t=>{
 for(const run of [{status:65,stdout:'assertion build'},{status:0,signal:'SIGTERM'},{status:null,error:new Error('spawn failed')}]){
  const out=temporary(t);
  const status=runComparisonBuild({cwd:root,out,env:{GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'hosted'},spawn:()=>run});
  assert.notEqual(status,0);const record=JSON.parse(readFileSync(path.join(out,'build.json')));assert.equal(record.complete,true);assert.notEqual(record.status,0);assert.ok(existsSync(path.join(out,'build.stdout.log')));
 }
});
test('comparison target is diagnostic-only, same module with separate artifacts; CI preserves existing repeat step',()=>{
 const y=readFileSync(path.join(root,'project.yml'),'utf8'),ci=readFileSync(path.join(root,'.github/workflows/ci.yml'),'utf8');
 assert.match(y,/MadoLegacy393Tests:/);assert.match(y,/PRODUCT_MODULE_NAME: MadoAppTests/);assert.match(y,/path: Legacy393Tests/);
 assert.match(ci,/app_compare_mode:/);assert.match(ci,/app_compare_scope:/);assert.match(ci,/name: App host comparison/);
 assert.match(ci,/run: node scripts\/ci\/app-compare.mjs/);
 const original=spawnSync('git',['show',`${BASELINE}:.github/workflows/ci.yml`],{cwd:root,encoding:'utf8'}).stdout;
 const step=s=>s.slice(s.indexOf('      - name: Run App tests\n'),s.indexOf('      - name: Report App test evidence\n'));
 assert.equal(step(ci),step(original));
});
test('DerivedData cache fingerprint includes frozen sources and their manifest',()=>{
 const ci=readFileSync(path.join(root,'.github/workflows/ci.yml'),'utf8');
 const input=ci.split('\n').find(line=>line.includes('INPUTS:')&&line.includes("'AppTests/**'"));
 assert.ok(input.includes("'Legacy393Tests/**'"));
 assert.ok(input.includes("'scripts/ci/legacy393-manifest.json'"));
});
test('unexpected or nested baseline sources refuse validation and build before native spawn',t=>{
 for(const relative of ['Unexpected.swift','Nested/Extra.swift']){
  const cwd=temporary(t);cpSync(path.join(root,'Legacy393Tests'),path.join(cwd,'Legacy393Tests'),{recursive:true});
  const extra=path.join(cwd,'Legacy393Tests',relative);mkdirSync(path.dirname(extra),{recursive:true});writeFileSync(extra,'import Testing');
  assert.throws(()=>validateLegacySources({cwd}),/unexpected|extra|source/i);
  let calls=0;const status=runComparisonBuild({cwd,out:temporary(t),env:{GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'legacy'},spawn:()=>{calls++;return {status:0};}});
  assert.notEqual(status,0);assert.equal(calls,0);
 }
});
test('shallow CI fetches the exact baseline object before running source-audit contracts',()=>{
 const ci=readFileSync(path.join(root,'.github/workflows/ci.yml'),'utf8');
 const fetch=`git fetch --no-tags --depth=1 origin ${BASELINE}`;
 assert.ok(ci.includes(fetch));
 assert.ok(ci.indexOf(fetch)<ci.indexOf('run: node --test scripts/ci/*.test.mjs'));
});

test('legacy full builds the authentic Debug App dependency before baseline tests and preserves both stages',t=>{
 const cwd=temporary(t),out=temporary(t),calls=[];
 cpSync(path.join(root,'Legacy393Tests'),path.join(cwd,'Legacy393Tests'),{recursive:true});
 const info=path.join(cwd,'.build/dd-ci/Build/Products/Debug/Mado.app/Contents/Info.plist');
 const fixture='<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>native-build-fixture</string></dict></plist>';
 let clock=100;
 const status=runComparisonBuild({cwd,out,now:()=>clock,
  env:{GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',GITHUB_SHA:'current-sha',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'full'},
  spawn:(cmd,args,opts)=>{
   calls.push({cmd,args,opts});
   if(calls.length===1){
    assert.equal(existsSync(info),false);
    assert.ok(cmd.endsWith('heavy-lock.sh'));assert.deepEqual(args.slice(0,2),['xcodebuild','build']);
    assert.equal(args[args.indexOf('-scheme')+1],'Mado');
    assert.equal(args[args.indexOf('-configuration')+1],'Debug');
    assert.equal(args[args.indexOf('-derivedDataPath')+1],'.build/dd-ci');
    assert.equal(args.includes('build-for-testing'),false);
    // Only the external build boundary creates this temp native-product fixture.
    mkdirSync(path.dirname(info),{recursive:true});writeFileSync(info,fixture);clock+=30;
    return {status:0,stdout:'Debug App build stdout\n',stderr:'Debug App build stderr\n'};
   }
   assert.equal(readFileSync(info,'utf8'),fixture,'baseline build starts with its fixed-path real-build product present');
   assert.deepEqual(args.slice(0,2),['xcodebuild','build-for-testing']);
   assert.equal(args[args.indexOf('-scheme')+1],'MadoLegacy393');
   assert.equal(args[args.indexOf('-derivedDataPath')+1],'.build/dd-legacy393');
   clock+=70;return {status:0,stdout:'legacy test build stdout\n',stderr:'legacy test build stderr\n'};
  },stdout:()=>{},stderr:()=>{}});
 assert.equal(status,0);assert.equal(calls.length,2);
 const record=JSON.parse(readFileSync(path.join(out,'build.json'),'utf8'));
 assert.deepEqual(record.stages.map(stage=>stage.name),['debug-app-prerequisite','legacy-tests']);
 assert.deepEqual(record.stages.map(stage=>stage.status),[0,0]);
 assert.equal(record.complete,true);assert.equal(record.status,0);assert.equal(record.formal,false);
 assert.equal(record.wallMilliseconds,100);assert.equal(record.sha,'current-sha');
 assert.equal(readFileSync(path.join(out,'prerequisite.stdout.log'),'utf8'),'Debug App build stdout\n');
 assert.equal(readFileSync(path.join(out,'prerequisite.stderr.log'),'utf8'),'Debug App build stderr\n');
 assert.equal(readFileSync(path.join(out,'build.stdout.log'),'utf8'),'legacy test build stdout\n');
 assert.equal(readFileSync(path.join(out,'build.stderr.log'),'utf8'),'legacy test build stderr\n');
 assert.equal(readFileSync(info,'utf8'),fixture);
});

test('failed or abnormal Debug App prerequisite stops before legacy build and overwrites stale success evidence',t=>{
 for(const run of [
  {status:65,stdout:'prerequisite compilation failed\n',stderr:'compiler error\n'},
  {status:0,signal:'SIGTERM',stdout:'partial App build\n'},
  {status:null,error:new Error('native build unavailable'),stdout:'partial before error\n'},
  {status:null,stdout:'missing completion\n'},
 ]){
  const out=temporary(t);let calls=0;
  writeFileSync(path.join(out,'build.json'),JSON.stringify({complete:true,status:0,stages:[{status:0}]}));
  const status=runComparisonBuild({cwd:root,out,
   env:{GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'full'},
   spawn:()=>{calls++;return run;},stdout:()=>{},stderr:()=>{}});
  assert.equal(status,run.status===65?65:70);assert.equal(calls,1);
  const record=JSON.parse(readFileSync(path.join(out,'build.json'),'utf8'));
  assert.equal(record.status,status);assert.equal(record.complete,true);assert.equal(record.formal,false);
  assert.deepEqual(record.stages.map(stage=>stage.name),['debug-app-prerequisite']);
  assert.equal(record.stages[0].status,status);
  assert.equal(readFileSync(path.join(out,'prerequisite.stdout.log'),'utf8'),run.stdout);
  assert.equal(readFileSync(path.join(out,'prerequisite.stderr.log'),'utf8'),run.stderr??'');
 }
});

test('legacy test build failure keeps successful App prerequisite evidence while other scopes stay single-stage',t=>{
 const env={GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'full'};
 const out=temporary(t);let calls=0;
 const status=runComparisonBuild({cwd:root,out,env,spawn:()=>++calls===1?{status:0,stdout:'App ready\n'}:{status:65,stdout:'legacy compile failed\n'},stdout:()=>{},stderr:()=>{}});
 assert.equal(status,65);assert.equal(calls,2);
 const record=JSON.parse(readFileSync(path.join(out,'build.json'),'utf8'));
 assert.deepEqual(record.stages.map(stage=>stage.status),[0,65]);
 assert.equal(readFileSync(path.join(out,'prerequisite.stdout.log'),'utf8'),'App ready\n');
 for(const [mode,scope] of [['legacy','focus'],['legacy',undefined],['hosted','focus'],['hosted','full']]){
  let count=0;
  const status=runComparisonBuild({cwd:root,out:temporary(t),env:{...env,APP_COMPARE_MODE:mode,APP_COMPARE_SCOPE:scope},
   spawn:()=>{count++;return {status:0};},stdout:()=>{},stderr:()=>{}});
  assert.equal(status,0);assert.equal(count,1);
 }
 const damaged=temporary(t);cpSync(path.join(root,'Legacy393Tests'),path.join(damaged,'Legacy393Tests'),{recursive:true});
 writeFileSync(path.join(damaged,'Legacy393Tests',names[0]),'broken frozen source');let count=0;
 assert.notEqual(runComparisonBuild({cwd:damaged,out:temporary(t),env,spawn:()=>{count++;return {status:0};},stdout:()=>{},stderr:()=>{}}),0);
 assert.equal(count,0,'frozen-source validation precedes the new App prerequisite');
});
