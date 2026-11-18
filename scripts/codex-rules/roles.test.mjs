import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, readFileSync, cpSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
const root = process.cwd();
const roleScript = join(root, 'scripts/codex-rules/install-role.py');
for (const role of ['delegator', 'implementor', 'auditor']) {
  test(`${role} push/PR policy with common safety rules`, () => {
    const dir=mkdtempSync(join(tmpdir(),'picsee-role-'));
    mkdirSync(join(dir,'.codex/rules'),{recursive:true});
    cpSync(join(root,'.codex/rules/picsee.rules'),join(dir,'.codex/rules/picsee.rules'));
    const install=spawnSync('python3',[roleScript,'--worktree',dir,'--role',role],{encoding:'utf8'});
    assert.equal(install.status,0,install.stderr);
    for(const argv of [['gh','pr','create'],['gh','pr','merge','12'],['gh','pr','close','12']]) {
      const result=spawnSync('codex',['execpolicy','check','--rules',join(dir,'.codex/rules/picsee.rules'),'--rules',join(dir,'.codex/rules/picsee-role.rules'),'--',...argv],{encoding:'utf8'});
      assert.equal(result.status,0,result.stderr);
      assert.equal(JSON.parse(result.stdout).decision==='forbidden',role!=='delegator',JSON.stringify(argv));
    }
    for(const argv of [
      ['git','push','origin','feature'],
      ['git','push','--force','origin','main'],
      ['git','push','origin','--force','main'],
      ['git','push','origin','--mirror'],
      ['git','push','--force-with-lease=refs/heads/topic:deadbeef','origin','topic'],
      ['git','push','origin','+HEAD:topic'],
      ['rm','-rf','src'],['git','reset','--hard'],['tccutil','reset','All'],
    ]) {
      const result=spawnSync('codex',['execpolicy','check','--rules',join(dir,'.codex/rules/picsee.rules'),'--rules',join(dir,'.codex/rules/picsee-role.rules'),'--',...argv],{encoding:'utf8'});
      assert.equal(JSON.parse(result.stdout).decision,'forbidden',JSON.stringify(argv));
    }
    const before=readFileSync(join(dir,'.codex/rules/picsee-role.rules'),'utf8');
    const bad=spawnSync('python3',[roleScript,'--worktree',dir,'--role','typo'],{encoding:'utf8'});
    assert.notEqual(bad.status,0);
    assert.equal(readFileSync(join(dir,'.codex/rules/picsee-role.rules'),'utf8'),before);
  });
}
