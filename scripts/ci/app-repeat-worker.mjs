#!/usr/bin/env node
/** One isolated App-lane iteration. The supervisor owns this worker and all native descendants. */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runAppLane, runCompleteAppLane } from '../tdd/app-lane.mjs';
import { runComparisonIteration } from './app-compare.mjs';
import { runAttestedSync } from '../tdd/status-channel.mjs';
export function runAppIteration(options = {}) {
  const nativeSpawn = options.spawn ?? spawnSync;
  const env = options.env ?? process.env;
  return runAppLane({...options,env,spawn:(command,args,settings)=>{
    // Discovery normally creates another local-lock session. CI already owns the machine,
    // and this worker already has its own process group: retain that inherited authorization
    // so the discovery compiler/probe cannot escape the iteration's group.
    if (env.PICSEE_HEAVY_LOCK_HELD === '1' && command.endsWith('heavy-lock.sh'))
      settings = {...settings,env:{...settings.env,PICSEE_HEAVY_LOCK_HELD:'1'}};
    return nativeSpawn===spawnSync&&command.endsWith('heavy-lock.sh')?
      runAttestedSync(command,args,settings):nativeSpawn(command,args,settings);
  }});
}

/** CLI semantics include the hosted group; keep the exported helper above for existing consumers. */
export function runAppWorker(options={}) {
  const env=options.env??process.env;
  const expectedMode=options.expectedMode??'normal';
  const mode=!env.APP_COMPARE_MODE||env.APP_COMPARE_MODE==='none'?'normal':env.APP_COMPARE_MODE;
  if(!['normal','hosted'].includes(mode)||mode!==expectedMode) {
    (options.stderr??(s=>process.stderr.write(s)))('app-repeat worker: missing or contradictory expected comparison mode\n');
    return 70;
  }
  const nativeSpawn=options.spawn??spawnSync;
  const spawn=(command,args,settings)=>{
    const prepared=env.PICSEE_HEAVY_LOCK_HELD==='1'&&command.endsWith('heavy-lock.sh')?
      {...settings,env:{...settings.env,PICSEE_HEAVY_LOCK_HELD:'1'}}:settings;
    return nativeSpawn===spawnSync&&command.endsWith('heavy-lock.sh')?
      runAttestedSync(command,args,prepared):nativeSpawn(command,args,prepared);
  };
  return mode==='normal'?runCompleteAppLane({...options,env,spawn}):runComparisonIteration({...options,env,spawn,expectedMode});
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [quarantinePath,evidencePath,expectedMode='normal'] = process.argv.slice(2);
  process.exitCode = runAppWorker({quarantinePath,evidencePath,expectedMode});
}
