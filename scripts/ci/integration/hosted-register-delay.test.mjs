import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {writeHostedCompareXcodebuild} from './hosted-compare-fixture.mjs';
const lock=fileURLToPath(new URL('../../heavy-lock.sh',import.meta.url));
const comparison=new URL('../app-compare.mjs',import.meta.url).href;
test('hosted comparison registers a live host after a 2.5 second registration startup',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-register-slow-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const out=path.join(dir,'out'),wrapper=path.join(dir,'compare.mjs'),hostPids=path.join(dir,'host-pids');
  const summary=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/summary.json',import.meta.url));
  const tests=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/tests.json',import.meta.url));
  writeHostedCompareXcodebuild(dir,hostPids,6000);
  writeFileSync(path.join(dir,'python3'),'#!/bin/sh\nif [ "$1" = "'+fileURLToPath(new URL('../../tdd/heavy-lock.py',import.meta.url))+'" ] && [ "$2" = "--register-host" ]; then /bin/sleep 2.5; fi\nexec /usr/bin/python3 "$@"\n',{mode:0o755});
  writeFileSync(path.join(dir,'xcrun'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');process.stdout.write(fs.readFileSync(process.argv.includes('summary')?`+
    `${JSON.stringify(summary)}:${JSON.stringify(tests)},'utf8'));\n`,{mode:0o755});
  writeFileSync(wrapper,`import {runAppCompare} from ${JSON.stringify(comparison)};`+
    `process.exitCode=runAppCompare({out:${JSON.stringify(out)},hostExecutable:${JSON.stringify(process.execPath)}});\n`);
  const env={...process.env,PATH:dir+path.delimiter+process.env.PATH,
    APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'1',
    APP_REPEAT_DEADLINE_MS:String(Date.now()+15000),PICSEE_HEAVY_LOCK_HELD:'1',
    PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',
    PICSEE_HEAVY_LOCK_EXEC_SECS:'18',PICSEE_HEAVY_LOCK_DRAIN_SECS:'2'};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  delete env.MDPRO_HEAVY_LOCK_HELD;delete env.PICSEE_HEAVY_CI_BOUNDARY_REQUIRED;
  const run=spawnSync(lock,[process.execPath,wrapper],{env,encoding:'utf8',timeout:20000});
  const log=existsSync(path.join(out,'iter-01.log'))?readFileSync(path.join(out,'iter-01.log'),'utf8'):'';
  assert.equal(run.status,0,run.stderr+'\n'+log);
  const report=JSON.parse(readFileSync(path.join(out,'summary.json'),'utf8'));
  assert.equal(report.iterations[0].hostOwnership.identities[0].pid,Number(readFileSync(hostPids,'utf8').trim()));
  assert.equal(report.iterations[0].drained,true);
});
test('registration refusal reports transport and parent reason while retaining status 70',t=>{
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-register-refusal-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const out=path.join(dir,'out'),wrapper=path.join(dir,'compare.mjs'),hostPids=path.join(dir,'host-pids');
  const summary=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/summary.json',import.meta.url));
  const tests=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/tests.json',import.meta.url));
  writeHostedCompareXcodebuild(dir,hostPids,4000);
  writeFileSync(path.join(dir,'python3'),'#!/bin/sh\nif [ "$2" = "--register-host" ]; then echo "[heavy-lock] host registration refused: parent reply b\\x27NO\\x27" >&2; exit 70; fi\nexec /usr/bin/python3 "$@"\n',{mode:0o755});
  writeFileSync(path.join(dir,'xcrun'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');process.stdout.write(fs.readFileSync(process.argv.includes('summary')?`+
    `${JSON.stringify(summary)}:${JSON.stringify(tests)},'utf8'));\n`,{mode:0o755});
  writeFileSync(wrapper,`import {runAppCompare} from ${JSON.stringify(comparison)};`+
    `process.exitCode=runAppCompare({out:${JSON.stringify(out)},hostExecutable:${JSON.stringify(process.execPath)}});\n`);
  const env={...process.env,PATH:dir+path.delimiter+process.env.PATH,
    APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'1',
    APP_REPEAT_DEADLINE_MS:String(Date.now()+12000),PICSEE_HEAVY_LOCK_HELD:'1',
    PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',
    PICSEE_HEAVY_LOCK_EXEC_SECS:'15',PICSEE_HEAVY_LOCK_DRAIN_SECS:'2'};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  delete env.MDPRO_HEAVY_LOCK_HELD;delete env.PICSEE_HEAVY_CI_BOUNDARY_REQUIRED;
  const run=spawnSync(lock,[process.execPath,wrapper],{env,encoding:'utf8',timeout:17000});
  const log=readFileSync(path.join(out,'iter-01.log'),'utf8');
  assert.equal(run.status,70,run.stderr+'\n'+log);
  assert.match(log,/outer supervisor host registration failed \{.*"status":70.*"signal":null.*"errorCode":null.*"elapsedMilliseconds":\d+.*"timeoutMilliseconds":8000.*"refusal":"\[heavy-lock\] host registration refused: parent reply/);
  assert.match(log,/"drained":true/);
});
