#!/usr/bin/env node
/** One isolated App-lane iteration. The supervisor owns this worker and all native descendants. */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runAppLane } from '../tdd/app-lane.mjs';
export function runAppIteration(options = {}) {
  const nativeSpawn = options.spawn ?? spawnSync;
  const env = options.env ?? process.env;
  return runAppLane({...options,env,spawn:(command,args,settings)=>{
    // Discovery normally creates another local-lock session. CI already owns the machine,
    // and this worker already has its own process group: retain that inherited authorization
    // so the discovery compiler/probe cannot escape the iteration's group.
    if (env.PICSEE_HEAVY_LOCK_HELD === '1' && command.endsWith('heavy-lock.sh'))
      settings = {...settings,env:{...settings.env,PICSEE_HEAVY_LOCK_HELD:'1'}};
    return nativeSpawn(command,args,settings);
  }});
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [quarantinePath,evidencePath] = process.argv.slice(2);
  process.exitCode = runAppIteration({quarantinePath,evidencePath});
}
