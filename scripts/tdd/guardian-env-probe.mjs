// #705: lists heavy-lock guardian processes with their environments, for tests
// that prove a variable never reaches the guardian.
//   macOS: BSD `ps -wwEax` appends each process's environment to its command.
//   Linux: procps has no -E, so list `pid args` and read /proc/<pid>/environ.
// `owner` keeps only guardians whose PICSEE_HEAVY_GUARDIAN_OWNER starts with it,
// so a test sees its own run's guardian, not leftovers from other runs.
// Run as a script: node guardian-env-probe.mjs <owner-prefix> waits up to 5 s
// for a matching guardian and prints {job, guardians, leak} as JSON.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const guardianArgs = /heavy-lock\.py --guardian [0-9]+ [0-9]+/;
const plan = 'PICSEE_HEAVY_FAULT_EXIT_QUERY_PLAN';

function listed(ps, args) {
  const r = spawnSync(ps, args, { encoding: 'utf8', timeout: 5000 });
  return r.status === 0 ? r.stdout.split('\n') : [];
}

export function guardianEnvironments({ platform = process.platform, ps = '/bin/ps', procRoot = '/proc', owner } = {}) {
  let guardians;
  if (platform === 'linux') {
    guardians = [];
    for (const line of listed(ps, ['-eo', 'pid=,args='])) {
      const m = /^\s*(\d+)\s+(.*)$/.exec(line);
      if (!m || !guardianArgs.test(m[2])) continue;
      let env;
      try { env = readFileSync(path.join(procRoot, m[1], 'environ'), 'utf8').split('\0').filter(Boolean).join('\n'); }
      catch { continue; } // exited after the listing, or unreadable
      guardians.push({ pid: Number(m[1]), env });
    }
  } else {
    guardians = listed(ps, ['-wwEax', '-o', 'pid=,command=']).map(line => /^\s*(\d+)\s+(.*)$/.exec(line))
      .filter(m => m && guardianArgs.test(m[2])).map(m => ({ pid: Number(m[1]), env: m[2] }));
  }
  return owner === undefined ? guardians : guardians.filter(g => g.env.includes(`PICSEE_HEAVY_GUARDIAN_OWNER=${owner}`));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const owner = process.argv[2];
  const until = Date.now() + 5000;
  let guardians = guardianEnvironments({ owner });
  while (guardians.length === 0 && Date.now() < until) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    guardians = guardianEnvironments({ owner });
  }
  console.log(JSON.stringify({ job: plan in process.env, guardians: guardians.length,
    leak: guardians.some(g => g.env.includes(`${plan}=`)) }));
}
