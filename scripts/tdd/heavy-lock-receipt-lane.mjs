#!/usr/bin/env node
// Run one named process contract for a focused RED receipt.
import {spawnSync} from 'node:child_process';
const name=process.env.PICSEE_HEAVY_TEST_FILTER;
const file=process.env.PICSEE_HEAVY_TEST_FILE??'scripts/tdd/heavy-lock.test.mjs';
if(!['scripts/tdd/heavy-lock.test.mjs','scripts/tdd/swift-lane.test.mjs','scripts/tdd/app-lane.test.mjs',
  'scripts/ci/integration/hosted-owner.test.mjs',
  'scripts/ci/integration/hosted-compare.test.mjs',
  'scripts/ci/integration/app-repeat-process.test.mjs',
  'scripts/ci/app-repeat.test.mjs',
  'scripts/tdd/host-unknown-fix1.test.mjs'].includes(file)){
  process.stderr.write('unsupported process contract file\n');process.exit(70);
}
if(!name){process.stderr.write('PICSEE_HEAVY_TEST_FILTER is required\n');process.exit(70);}
const exact='^'+name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$';
const run=spawnSync(process.execPath,['--test','--test-reporter=tap','--test-name-pattern',exact,file],
  {encoding:'utf8',maxBuffer:16*1024*1024,timeout:30000});
const output=run.stdout??'';
process.stdout.write(output);process.stderr.write(run.stderr??'');
const count=label=>Number(new RegExp(`^# ${label} (\\d+)$`,'m').exec(output)?.[1]??NaN);
const [total,failed,skipped,cancelled]=['tests','fail','skipped','cancelled'].map(count);
if(run.error||run.signal||![total,failed,skipped,cancelled].every(Number.isFinite)||total-skipped!==1||cancelled||
  ![0,1].includes(run.status)||(run.status===0)!==(failed===0)){
  process.stderr.write('heavy-lock receipt lane: incomplete selected result\n');process.exit(70);
}
process.stdout.write(`\nTests run: ${total-skipped}, Failures: ${failed}, Errors: 0, Skipped: 0\n`);
process.exitCode=run.status;
