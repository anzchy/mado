import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../..',import.meta.url));
const installer=path.join(root,'scripts/locks/install_shared_locks.py');
const conformance=path.join(root,'scripts/locks/conformance.py');
const heavy=path.join(root,'scripts/heavy-lock.sh');
const gui=path.join(root,'.agents/skills/mado-delegator/scripts/gui-lock.sh');
const run=(cmd,args,options={})=>spawnSync(cmd,args,{encoding:'utf8',timeout:90000,...options});

function fixture(t){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'shared-locks-test-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const repo=path.join(dir,'repo'),home=path.join(dir,'home');
  fs.mkdirSync(repo);fs.mkdirSync(home);
  const git=(...args)=>{
    const r=run('git',args,{cwd:repo});assert.equal(r.status,0,r.stderr);return r.stdout.trim();
  };
  git('init','-q','-b','main');git('config','user.email','test@example.invalid');git('config','user.name','Test');
  for(const [rel,body] of [
    ['scripts/heavy-lock.sh','#!/bin/bash\necho heavy-snapshot\n'],
    ['scripts/tdd/heavy-lock.py','print("heavy helper")\n'],
    ['.agents/skills/mado-delegator/scripts/gui-lock.sh','#!/bin/bash\necho gui-snapshot\n']]){
    const dest=path.join(repo,rel);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,body,{mode:0o755});
  }
  git('add','.');git('commit','-qm','snapshot A');
  return {dir,repo,home,git,first:git('rev-parse','HEAD')};
}

test('i738w23 install snapshots a named commit and atomically switches one version pointer without touching lock state',t=>{
  const f=fixture(t);
  const guiSource=path.join(f.repo,'.agents/skills/mado-delegator/scripts/gui-lock.sh');
  fs.writeFileSync(guiSource,'#!/bin/bash\necho gui-newer\n',{mode:0o755});
  f.git('add','.');f.git('commit','-qm','snapshot B');
  const second=f.git('rev-parse','HEAD');
  const cache=path.join(f.home,'.cache'),lockdir=path.join(cache,'desktop-gui.lock');
  fs.mkdirSync(lockdir,{recursive:true});fs.writeFileSync(path.join(lockdir,'owner'),'held-by-test');
  const heavyState=path.join(f.home,'.mado/locks/heavy.lock');
  fs.mkdirSync(path.dirname(heavyState),{recursive:true});fs.writeFileSync(heavyState,'persistent');
  const install=commit=>run('python3',[installer,'--repo',f.repo,'--commit',commit],{env:{...process.env,HOME:f.home}});
  const first=install(f.first);assert.equal(first.status,0,first.stdout+first.stderr);
  const share=path.join(f.home,'.local/share/shared-locks'),bin=path.join(f.home,'.local/bin');
  const current=path.join(share,'current');
  assert.equal(fs.existsSync(current),true,'installer must publish the current version pointer');
  assert.equal(fs.readlinkSync(current),f.first);
  const heavyLink=fs.readlinkSync(path.join(bin,'heavy-lock'));
  const guiLink=fs.readlinkSync(path.join(bin,'gui-lock'));
  const oldVersion=run(path.join(bin,'heavy-lock'),['--version']);
  assert.match(oldVersion.stdout,new RegExp(`${f.first}.*sha256=[0-9a-f]{64}`));
  assert.equal(fs.readFileSync(path.join(share,f.first,'scripts/heavy-lock.sh'),'utf8'),'#!/bin/bash\necho heavy-snapshot\n');
  const newer=install(second);assert.equal(newer.status,0,newer.stdout+newer.stderr);
  assert.equal(fs.readlinkSync(current),second);
  assert.equal(fs.readlinkSync(path.join(bin,'heavy-lock')),heavyLink);
  assert.equal(fs.readlinkSync(path.join(bin,'gui-lock')),guiLink);
  const newVersion=run(path.join(bin,'gui-lock'),['--version']);
  assert.match(newVersion.stdout,new RegExp(`${second}.*sha256=[0-9a-f]{64}`));
  assert.equal(fs.readFileSync(path.join(share,f.first,'scripts/heavy-lock.sh'),'utf8'),'#!/bin/bash\necho heavy-snapshot\n');
  assert.equal(fs.readFileSync(path.join(lockdir,'owner'),'utf8'),'held-by-test');
  assert.equal(fs.readFileSync(heavyState,'utf8'),'persistent');
});

test('i738w23 conformance accepts both repo tools and rejects a broken GUI copy',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'lock-conformance-test-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const check=(kind,executable)=>run('python3',[conformance,'--kind',kind,'--executable',executable],
    {env:{...process.env,HOME:path.join(dir,`home-${kind}`)},timeout:90000});
  const goodGui=check('gui',gui);assert.equal(goodGui.status,0,goodGui.stdout+goodGui.stderr);
  const goodHeavy=check('heavy',heavy);assert.equal(goodHeavy.status,0,goodHeavy.stdout+goodHeavy.stderr);
  const broken=path.join(dir,'broken-gui.sh');
  fs.writeFileSync(broken,fs.readFileSync(gui,'utf8').replace('return 75\n','return 0\n'),{mode:0o755});
  const bad=check('gui',broken);
  assert.equal(bad.status,1,bad.stdout+bad.stderr);
  assert.match(bad.stderr,/busy|75|conformance/i);
});

test('i738w23 installed real snapshot runs outside the checkout with temporary HOME',t=>{
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'shared-locks-home-'));
  t.after(()=>fs.rmSync(home,{recursive:true,force:true}));
  const commit=run('git',['rev-parse','HEAD'],{cwd:root}).stdout.trim();
  const installed=run('python3',[installer,'--repo',root,'--commit',commit],
    {env:{...process.env,HOME:home}});
  assert.equal(installed.status,0,installed.stdout+installed.stderr);
  const bin=path.join(home,'.local/bin');
  const version=run(path.join(bin,'heavy-lock'),['--version'],{cwd:home,env:{...process.env,HOME:home}});
  assert.equal(version.status,0,version.stdout+version.stderr);
  assert.match(version.stdout,new RegExp(`${commit}.*sha256=[0-9a-f]{64}`));
  const status=run(path.join(bin,'gui-lock'),['status'],{cwd:home,env:{...process.env,HOME:home}});
  assert.equal(status.status,0,status.stdout+status.stderr);
  assert.equal(status.stdout.trim(),'FREE');
  for(const [kind,name] of [['heavy','heavy-lock'],['gui','gui-lock']]){
    const probe=run('python3',[conformance,'--kind',kind,'--executable',path.join(bin,name)],
      {cwd:home,env:{...process.env,HOME:home}});
    assert.equal(probe.status,0,`${kind}: ${probe.stdout}${probe.stderr}`);
  }
});
