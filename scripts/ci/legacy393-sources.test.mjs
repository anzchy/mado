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
