import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { runProcessGroup } from './app-repeat-process.mjs';

const livePids = () => new Set(spawnSync('ps', ['-axo','pid=,stat='], {encoding:'utf8'}).stdout.trim().split('\n')
  .map(line => line.trim().split(/\s+/)).filter(([,state]) => !state.startsWith('Z')).map(([pid]) => Number(pid)));
function directory(t) {
  const dir = mkdtempSync(path.join(tmpdir(), 'app-repeat-group-'));
  t.after(() => rmSync(dir, {recursive:true,force:true}));
  return dir;
}
function fixture(dir, exitLeader) {
  const pids = path.join(dir,'pids');
  const grandchild = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(pids)},process.pid+'\\n');process.on('SIGTERM',()=>{});process.send('ready');setInterval(()=>{},1000);`;
  const middle = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(pids)},process.pid+'\\n');process.on('SIGTERM',()=>{});const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(grandchild)}],{stdio:['ignore','ignore','ignore','ipc']});c.on('message',()=>process.send('ready'));setInterval(()=>{},1000);`;
  const root = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(pids)},process.pid+'\\n');process.on('SIGTERM',()=>{});const c=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(middle)}],{stdio:['ignore','ignore','ignore','ipc']});c.on('message',()=>{console.log('grandchild ready');${exitLeader ? 'process.exit(0)' : ''}});setInterval(()=>{},1000);`;
  return {pids, command:process.execPath,args:['-e',root]};
}
for (const exitLeader of [false,true]) test(`process group drains TERM-resistant descendants when ${exitLeader ? 'leader exits early' : 'deadline expires'}`, async t => {
  const dir = directory(t), logPath = path.join(dir,'iteration.log');
  const f = fixture(dir,exitLeader);
  const started = Date.now();
  const result = await runProcessGroup({...f,logPath,deadline:Date.now()+1200,graceMs:80,drainMs:1000});
  assert.equal(result.drained,true);
  assert.equal(result.status,70);
  assert.ok(existsSync(f.pids),'fixture must start before the cleanup claim can pass');
  const pids = readFileSync(f.pids,'utf8').trim().split('\n').map(Number);
  assert.equal(pids.length,3,'the fixture includes a grandchild');
  const live = livePids();
  for (const pid of pids) assert.ok(!live.has(pid),`descendant ${pid} survived cleanup`);
  assert.match(readFileSync(logPath,'utf8'), /grandchild ready/);
  assert.ok(Date.now()-started < 5000);
  // A following iteration can observe that every process from the prior iteration is gone.
  const next = await runProcessGroup({command:process.execPath,args:['-e','console.log("next iteration")'],logPath:path.join(dir,'next.log'),deadline:Date.now()+2000});
  assert.equal(next.status,0);
  assert.equal(next.drained,true);
  assert.equal(readFileSync(path.join(dir,'next.log'),'utf8'),'next iteration\n');
});

test('interrupting the supervisor drains its worker process group', async t => {
  const {spawn} = await import('node:child_process');
  const dir=directory(t), f=fixture(dir,false), logPath=path.join(dir,'interrupt.log');
  const supervisor = spawn(process.execPath,[new URL('./app-repeat-process.mjs',import.meta.url).pathname,
    String(Date.now()+10000),logPath,f.command,...f.args],{stdio:['ignore','pipe','pipe']});
  let output='',error='';
  supervisor.stdout.on('data',chunk=>output+=chunk); supervisor.stderr.on('data',chunk=>error+=chunk);
  const ended = new Promise(resolve=>supervisor.on('close',(code,signal)=>resolve({code,signal})));
  const readyUntil=Date.now()+5000;
  while ((!existsSync(f.pids) || readFileSync(f.pids,'utf8').trim().split('\n').length<3) && Date.now()<readyUntil)
    await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(existsSync(f.pids));
  const pids=readFileSync(f.pids,'utf8').trim().split('\n').map(Number);
  assert.equal(pids.length,3);
  supervisor.kill('SIGTERM');
  const end=await ended;
  assert.equal(end.code,0,error);
  assert.equal(end.signal,null);
  assert.equal(JSON.parse(output).drained,true);
  assert.equal(JSON.parse(output).status,70);
  const live=livePids();
  for (const pid of pids) assert.ok(!live.has(pid),`interrupted descendant ${pid} survived`);
  assert.match(readFileSync(logPath,'utf8'),/supervisor interrupted/);
});
