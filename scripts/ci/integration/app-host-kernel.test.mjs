import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {realpathSync} from 'node:fs';
import {prepareHostInspector} from '../app-host-inspector.mjs';
const executable=realpathSync(process.execPath),uid=process.getuid();
test('real kernel query observes escaped process birth uid executable and actual environment marker',async t=>{
  const inspector=await prepareHostInspector({deadline:Date.now()+10000});
  assert.equal(inspector.ready,true);t.after(()=>inspector.close());
  const token=randomUUID();
  const host=spawn(process.execPath,['-e','process.send("ready");setInterval(()=>{},1000)'],
    {detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:token},stdio:['ignore','ignore','ignore','ipc']});
  t.after(()=>{host.kill('SIGKILL');host.unref();});
  await new Promise(resolve=>host.once('message',resolve));
  const snapshot=await inspector.query({token,executable,uid,pids:[host.pid]});
  t.diagnostic(JSON.stringify({kernelQuery:snapshot}));
  assert.equal(snapshot.complete,true);assert.equal(snapshot.processes.length,1);
  const actual=snapshot.processes[0];assert.equal(actual.pid,host.pid);assert.equal(actual.uid,uid);
  t.diagnostic(JSON.stringify({kernelHost:actual}));
  assert.equal(actual.executable,executable);assert.equal(actual.marker,token);assert.match(actual.birth,/^\d+:\d+$/);
});
