#!/usr/bin/env node
// Run one named process contract for a focused RED receipt.
import {spawnSync} from 'node:child_process';
const name=process.env.PICSEE_HEAVY_TEST_FILTER;
if(!name){process.stderr.write('PICSEE_HEAVY_TEST_FILTER is required\n');process.exit(70);}
const exact='^'+name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$';
const run=spawnSync(process.execPath,['--test','--test-reporter=tap','--test-name-pattern',exact,'scripts/tdd/heavy-lock.test.mjs'],
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
