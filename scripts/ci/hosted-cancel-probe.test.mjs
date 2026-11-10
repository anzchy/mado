// Deterministic R2 orchestration regressions follow; real OS assertions moved intact to integration/.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,existsSync,rmSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runHostedCancelProbe} from './hosted-cancel-probe.mjs';
test('cancel probe cannot launch worker after inspector startup error and retains current failure evidence',async t=>{
  const out=mkdtempSync(path.join(tmpdir(),'r2-probe-'));t.after(()=>rmSync(out,{recursive:true,force:true}));
  const marker=path.join(out,'worker');let preparations=0;
  const status=await runHostedCancelProbe({out,executable:realpathSync(process.execPath),command:process.execPath,
    args:['-e',`require('node:fs').writeFileSync(${JSON.stringify(marker)},'started')`],
    inspectorSpawn:()=>{preparations++;throw Object.assign(new Error('PRIVATE_ENV_CONTENT'),{code:'ENOENT'});},deadline:Date.now()+1000,graceMs:80,drainMs:1000});
  assert.equal(status,70);assert.equal(preparations,1);assert.equal(existsSync(marker),false);
  assert.equal(existsSync(path.join(out,'result.json')),true);const result=JSON.parse(readFileSync(path.join(out,'result.json'),'utf8'));
  assert.equal(result.formal,false);assert.equal(result.status,70);assert.equal(JSON.stringify(result).includes('PRIVATE_ENV_CONTENT'),false);
});
