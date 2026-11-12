import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';

const lock=fileURLToPath(new URL('../../heavy-lock.sh',import.meta.url));
const owner=fileURLToPath(new URL('../../tdd/hosted-xcode-owner.mjs',import.meta.url));
test('hostedAppLaunchServicesHostIsRegisteredBeforeCleanupCompletes',t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host ownership inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-owner-native-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const runner=path.join(dir,'runner.mjs'),pidPath=path.join(dir,'host.pid');
  writeFileSync(runner,`import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';\n`+
    `const host=spawn(process.execPath,['-e','setTimeout(()=>{},600)'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.env.MADO_TEST_RUN_TOKEN},stdio:'ignore'});`+
    `writeFileSync(${JSON.stringify(pidPath)},String(host.pid));host.unref();setTimeout(()=>{},150);\n`);
  const env={...process.env,PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    PICSEE_HEAVY_STATUS_PATH:path.join(dir,'status.json'),
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(lock,[process.execPath,owner,process.execPath,runner],{env,encoding:'utf8',timeout:8000});
  assert.equal(run.status,0,run.stdout+run.stderr);
  const pid=Number(readFileSync(pidPath,'utf8'));
  assert.ok(Number.isInteger(pid)&&pid>0);
  assert.match(run.stderr,/hosted-owner: registered host pid=/);
  assert.equal(JSON.parse(readFileSync(env.PICSEE_HEAVY_STATUS_PATH,'utf8')).cleanup,'complete');
});

test('hostedAppLaunchServicesMissingRegistrationFailsClosed',t=>{
  if(!['darwin','linux'].includes(process.platform)){
    t.skip('host ownership inspector supports macOS and Linux process APIs');return;
  }
  const dir=mkdtempSync(path.join(tmpdir(),'hosted-owner-missing-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const runner=path.join(dir,'runner.mjs');writeFileSync(runner,'setTimeout(()=>{},100);\n');
  const env={...process.env,PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    MADO_TEST_RUN_TOKEN:randomUUID(),MADO_HOST_EXECUTABLE:process.execPath};
  delete env.PICSEE_HEAVY_CONTROL_FD;delete env.PICSEE_HEAVY_FLOCK_FD;delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(lock,[process.execPath,owner,process.execPath,runner],{env,encoding:'utf8',timeout:8000});
  assert.equal(run.status,70,run.stdout+run.stderr);
  assert.match(run.stderr,/host cleanup incomplete or unregistered/);
});
