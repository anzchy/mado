import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runHostedBuild} from './hosted-build.mjs';

const env={GITHUB_ACTIONS:'true',GITHUB_EVENT_NAME:'workflow_dispatch',PICSEE_HEAVY_LOCK_HELD:'1',APP_COMPARE_MODE:'hosted',GITHUB_SHA:'current-sha'};
const temporary=t=>{const dir=mkdtempSync(path.join(tmpdir(),'hosted-build-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));return dir;};
test('hosted build uses current Mado scheme and records current SHA without baseline metadata',t=>{
  const out=temporary(t),calls=[];
  const status=runHostedBuild({env,out,spawn:(command,args)=>{calls.push({command,args});return {status:0,stdout:'built\n',stderr:''};},stdout:()=>{},stderr:()=>{}});
  assert.equal(status,0);assert.equal(calls.length,1);
  assert.ok(calls[0].command.endsWith('heavy-lock.sh'));
  assert.ok(calls[0].args.includes('Mado'));
  assert.ok(calls[0].args.includes('.build/dd-ci'));
  assert.ok(!calls[0].args.includes('MadoLegacy393'));
  const record=JSON.parse(readFileSync(path.join(out,'build.json'),'utf8'));
  assert.equal(record.sha,'current-sha');assert.equal(record.baseline,undefined);
  assert.equal(record.complete,true);assert.equal(record.status,0);
});
test('removed mode, non-dispatch context and missing ownership reject before native build',t=>{
  for(const patch of [{APP_COMPARE_MODE:'legacy'},{GITHUB_EVENT_NAME:'push'},{PICSEE_HEAVY_LOCK_HELD:'0'}]){
    let calls=0;assert.equal(runHostedBuild({env:{...env,...patch},out:temporary(t),spawn:()=>{calls++;return {status:0};},stderr:()=>{}}),64);assert.equal(calls,0);
  }
});
test('hosted build failure remains a complete nonzero diagnostic record',t=>{
  const out=temporary(t);assert.equal(runHostedBuild({env,out,spawn:()=>({status:65,stdout:'failed\n'}),stdout:()=>{},stderr:()=>{}}),65);
  const record=JSON.parse(readFileSync(path.join(out,'build.json'),'utf8'));
  assert.equal(record.complete,true);assert.equal(record.status,65);
  assert.equal(readFileSync(path.join(out,'build.stdout.log'),'utf8'),'failed\n');
});
