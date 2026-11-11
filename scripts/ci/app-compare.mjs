#!/usr/bin/env node
/** Dispatch-only hosted diagnostic. Never formal App evidence. */
import {spawnSync} from 'node:child_process';
import {appendFileSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runCompleteAppLane} from '../tdd/app-lane.mjs';
import {runHostedAppLane} from '../tdd/hosted-app-lane.mjs';
import {runAppRepeat} from './app-repeat.mjs';

export function runComparisonIteration({env=process.env,expectedMode,spawn=spawnSync,cwd=process.cwd(),
  quarantinePath,evidencePath='.build/app-compare-attempt1.log',stdout=s=>process.stdout.write(s),
  stderr=s=>process.stderr.write(s)}={}) {
  const started=Date.now();
  const destination=env.MADO_APP_COMPARE_RESULT_PATH;
  const mode=env.APP_COMPARE_MODE,scope=env.APP_COMPARE_SCOPE;
  const record={version:1,runId:env.MADO_APP_COMPARE_RESULT_ID??'',complete:false,status:null,mode:mode??null,scope:scope??null,
    diagnostic:true,formal:false,sha:env.GITHUB_SHA??'unknown',
    runner:env.RUNNER_OS==='macOS'?'macos-26':'local',groups:{}};
  const save=()=>{if(destination){mkdirSync(path.dirname(destination),{recursive:true});writeFileSync(destination,JSON.stringify(record,null,2)+'\n');}};
  let status=70;
  try {
    save();
    if(mode!=='hosted'||mode!==expectedMode)throw new Error('missing, invalid or contradictory comparison mode forwarding');
    if(!['focus','full'].includes(scope))throw new Error('comparison scope must be focus or full');
    if(env.PICSEE_APP_LANE_NO_RETRY!=='1')throw new Error('comparison requires retry disabled');
    if(!quarantinePath||JSON.stringify(JSON.parse(readFileSync(quarantinePath,'utf8')))!=='[]')throw new Error('comparison requires empty explicit quarantine');
    if(env.PICSEE_APP_FILTER!==undefined)throw new Error('comparison scope owns selection; inherited App filter is not allowed');
    const nativeEnv={...env};delete nativeEnv.PICSEE_APP_RESULT_PATH;delete nativeEnv.PICSEE_APP_RESULT_ID;
    if(scope==='focus') {
      const hosted=runHostedAppLane({env:nativeEnv,spawn,stdout,stderr,evidencePath});
      status=hosted.status;record.groups.hosted=status;
    } else {
      status=runCompleteAppLane({env:nativeEnv,spawn,quarantinePath,evidencePath,stdout,stderr});
      record.groups.combined=status;
    }
  } catch(error) {stderr('app-compare: '+error.message+'\n');status=70;}
  record.complete=true;record.status=status;record.wallMilliseconds=Date.now()-started;
  try{save();}catch(error){stderr('app-compare: cannot preserve comparison evidence: '+error.message+'\n');return 70;}
  stdout(`app-compare: mode=${mode??'unknown'} scope=${scope??'unknown'} diagnostic=true formal=false status=${status}\n`);
  return status;
}

export function runAppCompare({env=process.env,stdout=s=>process.stdout.write(s),...options}={}) {
  if(env.APP_COMPARE_MODE!=='hosted'||!['focus','full'].includes(env.APP_COMPARE_SCOPE)) {
    stdout('app-compare: explicit hosted mode and scope focus/full required\n');return 64;
  }
  if(env.APP_FILTER?.trim()||env.PICSEE_APP_FILTER!==undefined) {
    stdout('app-compare: comparison scope owns selection; remove App filters\n');return 64;
  }
  const start=Number(env.APP_JOB_STARTED_MS||Date.now());
  if(!Number.isFinite(start)) {stdout('app-compare: invalid job start time\n');return 64;}
  const compareEnv={...env,PICSEE_APP_LANE_NO_RETRY:'1'};
  const status=runAppRepeat({...options,env:compareEnv,repeat:env.APP_REPEAT??1,filter:'',stdout,requireComparisonEvidence:true,
    deadline:options.deadline??Number(env.APP_REPEAT_DEADLINE_MS||start+6900000)});
  try {
    const summary=JSON.parse(readFileSync(path.join(options.out??'.build/app-repeat','summary.json'),'utf8'));
    const usage=`Comparison timing: mode=${summary.mode}, scope=${summary.scope}, supervised iterations ${summary.wallMilliseconds} ms; `+
      `observed job elapsed runner minutes=${summary.observedRunnerMinutes??'unknown'}; billing minutes unavailable.\n`;
    stdout(usage);if(env.GITHUB_STEP_SUMMARY)appendFileSync(env.GITHUB_STEP_SUMMARY,usage);
  }catch(error){stdout('app-compare: timing summary unavailable: '+error.message+'\n');return 70;}
  return status;
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=runAppCompare();
