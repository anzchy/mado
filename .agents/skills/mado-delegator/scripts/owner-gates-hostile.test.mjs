import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';

test('760 fix2 TERM-resistant probe test ignores hostile host facts', {timeout:60000}, () => {
  const file=new URL('./owner-gates-tools.test.mjs',import.meta.url).pathname;
  const env={...process.env,OWNER_GATES_MAX_LOAD:'0',OWNER_GATES_MIN_MEM_FREE:'99',OWNER_GATES_MAX_PRESSURE:'0'};
  delete env.NODE_TEST_CONTEXT;
  const run=spawnSync(process.execPath,['--test','--test-reporter=tap','--test-name-pattern','^760 fix1 TERM-resistant probes expire as unknown within the hard deadline$',file],
    {env,encoding:'utf8',timeout:50000,killSignal:'SIGKILL'});
  assert.ifError(run.error);
  assert.equal(run.status,0,run.stdout+run.stderr);
  assert.match(run.stdout,/pass 1/);
});
