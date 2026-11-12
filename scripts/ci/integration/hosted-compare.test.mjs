import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const lock=fileURLToPath(new URL('../../heavy-lock.sh',import.meta.url));
const comparison=new URL('../app-compare.mjs',import.meta.url).href;
const worker=new URL('../app-repeat-worker.mjs',import.meta.url).href;
test('hostedCompareRealProcessesRequireHostDrainBeforeSecondIteration',t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-compare-native-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const out=path.join(dir,'out'),wrapper=path.join(dir,'compare.mjs');
  const summary=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/summary.json',import.meta.url));
  const tests=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/tests.json',import.meta.url));
  writeFileSync(path.join(dir,'xcodebuild'),`#!${process.execPath}\n`+
    `const {spawn}=require('node:child_process');const h=spawn(process.execPath,['-e','setTimeout(()=>{},450)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `h.unref();setTimeout(()=>console.log('** TEST EXECUTE SUCCEEDED **'),150);\n`,{mode:0o755});
  writeFileSync(path.join(dir,'xcrun'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');process.stdout.write(fs.readFileSync(process.argv.includes('summary')?`+
    `${JSON.stringify(summary)}:${JSON.stringify(tests)},'utf8'));\n`,{mode:0o755});
  writeFileSync(wrapper,`import {runAppCompare} from ${JSON.stringify(comparison)};`+
    `process.exitCode=runAppCompare({out:${JSON.stringify(out)},hostExecutable:${JSON.stringify(process.execPath)}});\n`);
  const env={...process.env,PATH:dir+path.delimiter+process.env.PATH,
    APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'2',
    APP_REPEAT_DEADLINE_MS:String(Date.now()+12000),PICSEE_HEAVY_LOCK_HELD:'1',
    PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',
    PICSEE_HEAVY_LOCK_EXEC_SECS:'15'};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(lock,[process.execPath,wrapper],{env,encoding:'utf8',timeout:20000});
  assert.equal(run.status,0,run.stdout+run.stderr);
  const report=JSON.parse(readFileSync(path.join(out,'summary.json'),'utf8'));
  assert.equal(report.iterations.length,2);
  assert.deepEqual(report.iterations.map(row=>row.status),[0,0]);
  assert.ok(report.iterations.every(row=>row.drained===true&&row.hostOwnership?.drained===true));
  assert.ok(report.iterations[1].startedAt>=report.iterations[0].endedAt);
});

test('hostedCompareRejectsContradictoryRealWorkerBeforeSecondIteration',t=>{
  if(!['darwin','linux'].includes(process.platform)){t.skip('native host probe supports macOS and Linux');return;}
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-compare-contradiction-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const out=path.join(dir,'out'),wrapper=path.join(dir,'compare.mjs');
  const workerScript=path.join(dir,'worker.mjs'),launches=path.join(dir,'launches');
  const summary=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/summary.json',import.meta.url));
  const tests=fileURLToPath(new URL('../../tdd/fixtures/i393-hosted/tests.json',import.meta.url));
  writeFileSync(path.join(dir,'xcodebuild'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');const {spawn}=require('node:child_process');`+
    `fs.appendFileSync(${JSON.stringify(launches)},'launch\\n');`+
    `const h=spawn(process.execPath,['-e','setTimeout(()=>{},450)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `h.unref();setTimeout(()=>console.log('** TEST EXECUTE SUCCEEDED **'),150);\n`,{mode:0o755});
  writeFileSync(path.join(dir,'xcrun'),`#!${process.execPath}\n`+
    `const fs=require('node:fs');process.stdout.write(fs.readFileSync(process.argv.includes('summary')?`+
    `${JSON.stringify(summary)}:${JSON.stringify(tests)},'utf8'));\n`,{mode:0o755});
  writeFileSync(workerScript,`import {runAppWorker} from ${JSON.stringify(worker)};`+
    `import {readFileSync,writeFileSync} from 'node:fs';`+
    `const [quarantinePath,evidencePath,expectedMode]=process.argv.slice(2);`+
    `const status=runAppWorker({quarantinePath,evidencePath,expectedMode});`+
    `if(status===0){const p=process.env.MADO_APP_COMPARE_RESULT_PATH;`+
    `const record=JSON.parse(readFileSync(p,'utf8'));record.groups.hosted=1;`+
    `writeFileSync(p,JSON.stringify(record));}process.exitCode=status;\n`);
  writeFileSync(wrapper,`import {runAppCompare} from ${JSON.stringify(comparison)};`+
    `process.exitCode=runAppCompare({out:${JSON.stringify(out)},workerScript:${JSON.stringify(workerScript)},`+
    `hostExecutable:${JSON.stringify(process.execPath)}});\n`);
  const env={...process.env,PATH:dir+path.delimiter+process.env.PATH,
    APP_COMPARE_MODE:'hosted',APP_COMPARE_SCOPE:'focus',APP_REPEAT:'2',
    APP_REPEAT_DEADLINE_MS:String(Date.now()+12000),PICSEE_HEAVY_LOCK_HELD:'1',
    PICSEE_HEAVY_CI_TOP_LEVEL:'1',PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',
    PICSEE_HEAVY_LOCK_EXEC_SECS:'15'};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(lock,[process.execPath,wrapper],{env,encoding:'utf8',timeout:20000});
  assert.equal(run.status,70,run.stdout+run.stderr);
  assert.doesNotMatch(run.stdout,/TOTAL \d+ PASS/);
  assert.equal(readFileSync(launches,'utf8').trim().split('\n').length,1,'only iteration 1 launched native tools');
  const report=JSON.parse(readFileSync(path.join(out,'summary.json'),'utf8'));
  assert.equal(report.iterations[0].status,70);
  assert.equal(report.iterations[1].started,false);
  assert.equal(report.iterations[1].status,70);
  assert.equal(existsSync(path.join(out,'iter-02.comparison.json')),false);
});
