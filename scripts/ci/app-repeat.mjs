#!/usr/bin/env node
/** Dispatch-only reproduction. Normal CI continues to use app-lane directly. */
import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {randomUUID} from 'node:crypto';
import {hostedTestIDs} from '../tdd/hosted-app-lane.mjs';
const supervisor = fileURLToPath(new URL('./app-repeat-process.mjs', import.meta.url));
const worker = fileURLToPath(new URL('./app-repeat-worker.mjs', import.meta.url));

export function runAppRepeat({ repeat = process.env.APP_REPEAT ?? 1, filter = process.env.APP_FILTER ?? '',
  out = '.build/app-repeat', summaryPath = process.env.GITHUB_STEP_SUMMARY,
  deadline = Number(process.env.APP_REPEAT_DEADLINE_MS || Date.now() + 6900000), now = Date.now,
  env = process.env, spawn = spawnSync, stdout = s => process.stdout.write(s), validateOnly = false,
  requireComparisonEvidence = false } = {}) {
  const count = Number(repeat);
  if (String(repeat).trim() === '' || !Number.isInteger(count) || count < 1 || count > 50) {
    stdout('app-repeat: app_repeat must be an integer from 1 to 50\n'); return 64;
  }
  if (validateOnly) return 0;
  const mode=!env.APP_COMPARE_MODE||env.APP_COMPARE_MODE==='none'?'normal':env.APP_COMPARE_MODE;
  const scope=mode==='normal'?null:env.APP_COMPARE_SCOPE;
  if(!['normal','hosted'].includes(mode)||(mode!=='normal'&&!['focus','full'].includes(scope))) {
    stdout('app-repeat: invalid comparison mode or scope\n');return 64;
  }
  if (env.PICSEE_HEAVY_LOCK_HELD !== '1') {
    stdout('app-repeat: repeat execution requires PICSEE_HEAVY_LOCK_HELD=1 (CI machine ownership)\n'); return 64;
  }
  if (!Number.isFinite(deadline)) { stdout('app-repeat: invalid deadline\n'); return 64; }
  mkdirSync(out, { recursive: true });
  const repeatStarted=now();
  const rows=[];
  const temporary = mkdtempSync(path.join(tmpdir(), 'app-repeat-'));
  const quarantinePath = path.join(temporary, 'empty-quarantine.json');
  writeFileSync(quarantinePath, '[]\n');
  const iterationEnv = { ...env, PICSEE_APP_LANE_NO_RETRY: '1' };
  let filterCanLaunch=true;
  try{new RegExp(filter);}catch{filterCanLaunch=false;}
  const needsHost=mode==='hosted'||(mode==='normal'&&filterCanLaunch&&
    (!filter.trim()||hostedTestIDs.some(id=>new RegExp(filter).test(id))));
  // The lane deliberately rejects a blank filter. Omit it to select the full bundle.
  if (filter.trim()) iterationEnv.PICSEE_APP_FILTER = filter;
  else delete iterationEnv.PICSEE_APP_FILTER;
  const summarize = line => {
    stdout(line + '\n');
    if (summaryPath) appendFileSync(summaryPath, line + '\n');
  };
  let failures = 0, previousGroupDrained = true;
  try {
    for (let iteration = 1; iteration <= count; iteration++) {
      const label = String(iteration).padStart(2, '0');
      const iterationStarted=now();
      const row={version:1,iteration,mode,scope,sha:env.GITHUB_SHA??'unknown',
        runner:env.RUNNER_OS==='macOS'?'macos-26':'local',diagnostic:true,formal:false,
        started:false,startedAt:iterationStarted,endedAt:null,wallMilliseconds:null,nativeWallMilliseconds:null,
        durationLabel:'supervised iteration elapsed milliseconds (includes discovery and cleanup)',
        status:70,drained:null,filter:filter.trim()||null};
      let log = '', status = 70;
      const logPath = path.join(out, `iter-${label}.log`);
      writeFileSync(logPath, '');
      try {
        if (!previousGroupDrained) throw new Error('previous iteration process group did not drain; refusing to overlap');
        if (now() >= deadline) throw new Error('job time budget exhausted');
        // The async supervisor remains outside the worker's private process group. It owns the
        // deadline, TERM/KILL escalation and drain confirmation, including after a leader exits.
        previousGroupDrained = false;
        const token=randomUUID();
        const workerEnv={...iterationEnv,MADO_TEST_RUN_TOKEN:token,TEST_RUNNER_MADO_TEST_RUN_TOKEN:token,
          MADO_APP_COMPARE_RESULT_PATH:path.resolve(out,`iter-${label}.comparison.json`),
          MADO_APP_COMPARE_RESULT_ID:`${env.GITHUB_RUN_ID??'local'}-${label}-${token}`};
        if(requireComparisonEvidence&&mode!=='normal')writeFileSync(workerEnv.MADO_APP_COMPARE_RESULT_PATH,
          JSON.stringify({version:1,runId:workerEnv.MADO_APP_COMPARE_RESULT_ID,complete:false,status:null}));
        if(needsHost&&filterCanLaunch) {
          workerEnv.MADO_HOST_OWNERSHIP_REQUIRED='1';
          workerEnv.MADO_HOST_EXECUTABLE=path.resolve(env.PICSEE_APP_DERIVED_DATA_PATH??'.build/dd-ci',
            'Build/Products/Debug/Mado.app/Contents/MacOS/Mado');
        } else {delete workerEnv.MADO_HOST_OWNERSHIP_REQUIRED;delete workerEnv.MADO_HOST_EXECUTABLE;}
        row.started=true;
        const run = spawn(process.execPath, [supervisor, String(deadline), logPath,
          process.execPath, worker, quarantinePath, path.join(temporary, `attempt-${label}.log`),mode], {
          env: workerEnv, encoding:'utf8', maxBuffer:1024*1024 });
        log = readFileSync(logPath,'utf8');
        if (run.error || run.signal || run.status !== 0) {
          previousGroupDrained = false;
          throw new Error(`iteration supervisor failed: ${run.error?.message ?? run.signal ?? run.stderr ?? run.status}`);
        }
        const result = JSON.parse(run.stdout);
        row.group=result.group??null;row.hostOwnership=result.hostOwnership??null;
        previousGroupDrained = result.drained === true;
        row.drained=previousGroupDrained;
        status = previousGroupDrained && Number.isInteger(result.status) ? result.status : 70;
        if(requireComparisonEvidence&&mode!=='normal') {
          const evidence=JSON.parse(readFileSync(workerEnv.MADO_APP_COMPARE_RESULT_PATH,'utf8'));
          if(evidence.version!==1||evidence.runId!==workerEnv.MADO_APP_COMPARE_RESULT_ID||evidence.complete!==true||
            evidence.mode!==mode||evidence.scope!==scope||evidence.sha!==(env.GITHUB_SHA??'unknown')||
            evidence.status!==result.status||evidence.diagnostic!==true||evidence.formal!==false)
            throw new Error('missing, stale or contradictory current comparison worker result');
          row.comparisonResult=evidence;
        }
      } catch (error) { status=70;log += `app-repeat: ${error.message}\n`; }
      row.endedAt=now();row.wallMilliseconds=Math.max(0,row.endedAt-iterationStarted);
      // Native process execution time is recorded by the actual lane, not inferred from supervision overhead.
      row.nativeWallMilliseconds=null;row.status=status;
      rows.push(row);
      writeFileSync(path.join(out,`${mode==='normal'?'timing':'iter'}-${label}.json`),JSON.stringify(row,null,2)+'\n');
      writeFileSync(path.join(out, `iter-${label}.log`), log);
      const failed = status !== 0;
      if (failed) failures++;
      // The lane names both XCTest and Swift Testing failures, including filtered runs.
      const names = [...log.matchAll(/^app-lane: first-attempt failures: (.+)$/gm)].map(m => m[1]);
      const detail = names.join(', ') || (log.includes('job time budget exhausted') ? 'job time budget exhausted' : 'environment/lane failure (see log)');
      summarize(`${label} ${failed ? `FAIL ${detail}` : 'PASS'}`);
    }
    summarize(`TOTAL ${count - failures} PASS, ${failures} FAIL`);
    const ended=now(),jobStarted=Number(env.APP_JOB_STARTED_MS);
    const jobWall=Number.isFinite(jobStarted)&&jobStarted>0?Math.max(0,ended-jobStarted):null;
    writeFileSync(path.join(out,'summary.json'),JSON.stringify({version:1,mode,scope,diagnostic:true,formal:false,
      sha:env.GITHUB_SHA??'unknown',runner:env.RUNNER_OS==='macOS'?'macos-26':'local',
      requested:count,passed:count-failures,failed:failures,wallMilliseconds:Math.max(0,ended-repeatStarted),
      jobWallMilliseconds:jobWall,observedRunnerMinutes:jobWall===null?null:jobWall/60000,billedRunnerMinutes:null,
      usageLabel:'observed job elapsed runner minutes; billing data unavailable',iterations:rows},null,2)+'\n');
  } finally { rmSync(temporary, { recursive: true, force: true }); }
  return failures ? 1 : 0;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = runAppRepeat({validateOnly:process.argv[2] === '--validate'});
