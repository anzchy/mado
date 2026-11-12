#!/usr/bin/env node
/** Run node --test files for a RED receipt and print a count line the receipt parser understands. */
import { spawnSync } from "node:child_process";
import {fstatSync} from 'node:fs';

const files = process.argv.slice(2);
const requireBoundary=process.env.PICSEE_HEAVY_CI_BOUNDARY_REQUIRED==='1';
if (!files.length) {
  process.stderr.write("usage: node-lane.mjs <test file>…\n");
  process.exit(70);
}
if(requireBoundary){
  const control=Number(process.env.PICSEE_HEAVY_CONTROL_FD);
  try{
    if(process.env.PICSEE_HEAVY_LOCK_HELD!=='1'||!Number.isInteger(control)||control<3||control>64)
      throw new Error('missing inherited supervision');
    if(!fstatSync(control).isSocket())throw new Error('inherited control is not a socket');
  }catch{
    process.stderr.write('node-lane: CI Host ownership boundary missing; refusing tests\n');
    process.exit(70);
  }
}
// The integration fixtures intentionally launch their own top-level supervisors.
// The checked runner remains in this supervisor's process group while fixture
// processes obtain their own admission and verify their own cleanup.
const testEnv={...process.env};
if(requireBoundary){
  delete testEnv.PICSEE_HEAVY_LOCK_HELD;
  delete testEnv.PICSEE_HEAVY_CONTROL_FD;
  delete testEnv.PICSEE_HEAVY_FLOCK_FD;
}
const run = spawnSync(process.execPath, ["--test", "--test-reporter=tap", ...files], {
  encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: 600000,
  env:testEnv,
});
const stdout = run.stdout ?? "", stderr = run.stderr ?? "";
process.stdout.write(stdout);
process.stderr.write(stderr);
const count = (name) => Number(new RegExp(`^# ${name} (\\d+)$`, "m").exec(stdout)?.[1] ?? NaN);
const [total, failed, skipped, cancelled] = ["tests", "fail", "skipped", "cancelled"].map(count);
if (run.error || run.signal || ![total, failed, skipped, cancelled].every(Number.isFinite) || !total ||
    cancelled || ![0, 1].includes(run.status) || (run.status === 0) !== (failed === 0)) {
  process.stderr.write("node-lane: no reliable completed test result; environment failure\n");
  process.exitCode = 70;
} else {
  process.stdout.write(`\nTests run: ${total}, Failures: ${failed}, Errors: 0, Skipped: ${skipped}\n`);
  process.exitCode = run.status;
}
