import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, writeFileSync, rmSync, mkdirSync, statSync, readdirSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const root = process.cwd();
const scratch = mkdtempSync(path.join(os.tmpdir(), 'picsee-lock-tests-'));
after(() => rmSync(scratch, { recursive: true, force: true }));
const lock = path.join(root, 'scripts/heavy-lock.sh');
function environment() {
  const home = mkdtempSync(path.join(scratch, 'lock-'));
  const env = { ...process.env, HOME: home, PICSEE_HEAVY_LOCK: path.join(home, '.picsee/locks/heavy.lock'), PICSEE_MDPRO_LOCK: path.join(home, 'mdpro.lock'), MDPRO_HEAVY_LOCK_HELD: '', PICSEE_HEAVY_LOCK_WAIT_SECS: '15', PICSEE_HEAVY_LOCK_HELD: '' };
  delete env.PICSEE_HEAVY_CONTROL_FD;
  delete env.PICSEE_HEAVY_FLOCK_FD;
  return env;
}
function run(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(lock, args, { env, cwd: root });
    let output = '';
    child.stdout.on('data', b => output += b);
    child.stderr.on('data', b => output += b);
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({ code, signal, output }));
  });
}
const redOnly = process.env.PICSEE_HEAVY_TEST_FILTER;
function redTest(name, fn, options = {}) {
  test(name, {...options, skip: redOnly ? redOnly !== name : name.includes('BLOCKED-upstream')}, fn);
}

redTest('hugeFiniteDeadlineRejectedBeforeLockOrLaunch', () => {
  const env = {...environment(), PICSEE_HEAVY_LOCK_EXEC_SECS: '1e308'};
  const marker = path.join(env.HOME, 'launched');
  const result = spawnSync(lock, ['touch', marker], {env, encoding:'utf8', timeout:5000});
  assert.ifError(result.error);
  assert.equal(result.status, 70, result.stderr);
  assert.equal(existsSync(marker), false);
  assert.equal(existsSync(env.PICSEE_HEAVY_LOCK), false, 'preflight precedes lock acquisition');
});

redTest('heldWithoutCredentialRefusesBeforeLaunch', () => {
  const env = {...environment(), PICSEE_HEAVY_LOCK_HELD:'1'};
  const marker = path.join(env.HOME, 'launched');
  const result = spawnSync(lock, ['touch', marker], {env, encoding:'utf8', timeout:5000});
  assert.ifError(result.error);
  assert.equal(result.status, 70, result.stderr);
  assert.equal(existsSync(marker), false);
});

redTest('reverseMdproMissingHandoffRefusesBeforeLaunch', () => {
  const env = {...environment(), MDPRO_HEAVY_LOCK_HELD:'1'};
  const marker = path.join(env.HOME, 'launched');
  const result = spawnSync(lock, ['touch', marker], {env, encoding:'utf8', timeout:5000});
  assert.ifError(result.error);
  assert.equal(result.status, 70, result.stderr);
  assert.equal(existsSync(marker), false);
});

redTest('reverseMdproDeadlineAndCancelReachWorkload — BLOCKED-upstream RED', async () => {
  const env = {...environment(), MDPRO_HEAVY_LOCK_HELD:'1', PICSEE_HEAVY_LOCK_EXEC_SECS:'10'};
  const pidFile = path.join(env.HOME, 'worker-pid');
  const supervisorPidFile = path.join(env.HOME, 'supervisor-pid');
  const parent = spawn('bash', ['-c',
    '"$1" python3 -c "import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(3)" "$2" & echo $! > "$3"; wait',
    '_', lock, pidFile, supervisorPidFile], {env, cwd:root, stdio:'ignore'});
  try {
    await until(()=>existsSync(pidFile),'reverse nested workload launched');
    parent.kill('SIGKILL');
    await new Promise(resolve=>parent.once('close',resolve));
    await new Promise(resolve=>setTimeout(resolve,200));
    assert.throws(()=>process.kill(Number(readFileSync(pidFile,'utf8')),0),{code:'ESRCH'},
      'mdpro parent cancellation must reach its picsee workload');
  } finally {
    const supervisorPid=Number(readFileSync(supervisorPidFile,'utf8'));
    try {process.kill(supervisorPid,'SIGTERM');} catch(error) {if(error.code!=='ESRCH')throw error;}
    await new Promise(resolve=>setTimeout(resolve,300));
  }
}, {timeout:7000});

redTest('postLaunchSupervisorExceptionCancelsBeforeRelease', async () => {
  const env = {...environment(), PICSEE_HEAVY_FAULT_AFTER_LAUNCH:'1', PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1'};
  const pidFile = path.join(env.HOME, 'pid');env.PICSEE_HEAVY_FAULT_READY_PATH=pidFile;
  const result = await run(['python3','-c',
    'import os,pathlib,time,sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(1)',pidFile],env);
  assert.equal(result.code, 70, result.output);
  assert.ok(existsSync(pidFile));
  assert.throws(() => process.kill(Number(readFileSync(pidFile,'utf8')),0), {code:'ESRCH'});
  const competitorEnv={...env};delete competitorEnv.PICSEE_HEAVY_FAULT_AFTER_LAUNCH;
  delete competitorEnv.PICSEE_HEAVY_FAULT_READY_PATH;
  assert.equal((await run(['true'],competitorEnv)).code,0);
});

redTest('outerTimeoutKillsNestedTermResistantDescendants', async () => {
  const env = {...environment(), PICSEE_HEAVY_LOCK_EXEC_SECS:'0.4', PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1',
    PICSEE_MDPRO_LOCK:'off'};
  const pidFile = path.join(env.HOME,'nested-pid');
  const script = `PICSEE_HEAVY_LOCK_KILL_GRACE_SECS=5 "$1" python3 -c 'import os,pathlib,signal,time,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(2)' "$2"; :`;
  const result = await run(['bash','-c',script,'_',lock,pidFile],env);
  assert.equal(result.code,124,result.output);
  assert.ok(existsSync(pidFile),'nested descendant launched');
  assert.throws(()=>process.kill(Number(readFileSync(pidFile,'utf8')),0),{code:'ESRCH'});
  assert.equal((await run(['true'],env)).code,0);
});

redTest('outerCancelKillsNestedTermResistantDescendants', async () => {
  const env = {...environment(), PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1', PICSEE_MDPRO_LOCK:'off'};
  const pidFile = path.join(env.HOME,'nested-pid'), outerGroup=path.join(env.HOME,'outer-group');
  const script = `ps -o pgid= -p $$ > "$3"; PICSEE_HEAVY_LOCK_KILL_GRACE_SECS=5 "$1" python3 -c 'import os,pathlib,signal,time,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())+" "+str(os.getpgrp())); time.sleep(2)' "$2"`;
  const holder = start(['bash','-c',script,'_',lock,pidFile,outerGroup],env);
  await until(()=>existsSync(pidFile),'nested descendant launched');
  const [nestedPid,nestedGroup]=readFileSync(pidFile,'utf8').split(' ').map(Number);
  assert.notEqual(nestedGroup,Number(readFileSync(outerGroup,'utf8').trim()),'nested work registers a separate same-session subgroup');
  const began=Date.now();holder.child.kill('SIGTERM');
  await holder.done;
  assert.ok(Date.now()-began<1500,'outer grace governs nested cleanup');
  assert.throws(()=>process.kill(nestedPid,0),{code:'ESRCH'});
}, {timeout:7000});

redTest('outerTimeoutAfterIntermediateSupervisorDeathKillsGrandchild', async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_EXEC_SECS:'5',
    PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1'};
  const middle=path.join(env.HOME,'middle.sh'),inner=path.join(env.HOME,'inner.sh');
  const middlePid=path.join(env.HOME,'middle-supervisor-pid'),workerPid=path.join(env.HOME,'grandchild-pid');
  writeFileSync(middle,'"$1" bash "$2" "$1" "$4" &\necho $! > "$3"\nwait\nsleep 8\n');
  writeFileSync(inner,'"$1" python3 -c \'import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(10)\' "$2" </dev/null >/dev/null 2>&1\n:');
  const holder=start(['bash',middle,lock,inner,middlePid,workerPid],env);
  let pid;
  try {
    try {await until(()=>existsSync(workerPid)&&existsSync(middlePid),'grandchild launches under middle supervisor');}
    catch(error) {throw new Error(`${error.message}: ${holder.output()}`);}
    pid=Number(readFileSync(workerPid,'utf8'));
    process.kill(Number(readFileSync(middlePid,'utf8').trim()),'SIGKILL');
    const result=await holder.done;
    assert.equal(result.code,124,result.output);
    assert.throws(()=>process.kill(pid,0),{code:'ESRCH'},'outer owns grandchild after middle dies');
    assert.equal((await run(['true'],{...env,PICSEE_HEAVY_LOCK_WAIT_SECS:'0.2'})).code,0,
      'outer releases only after grandchild drain');
  } finally {
    if(pid)try{process.kill(pid,'SIGKILL');}catch(error){if(error.code!=='ESRCH')throw error;}
    await holder.done;
  }
}, {timeout:18000});

redTest('nestedFlockCredentialSurvivesThreeLevels', async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off'};
  const middle=path.join(env.HOME,'middle.sh'),inner=path.join(env.HOME,'inner.sh');
  const marker=path.join(env.HOME,'launched');
  writeFileSync(middle,'"$1" bash "$2" "$1" "$3"\nexit $?');
  writeFileSync(inner,'"$1" touch "$2"\nexit $?');
  const result=await run(['bash',middle,lock,inner,marker],env);
  assert.equal(result.code,0,result.output);
  assert.ok(existsSync(marker),'third level receives inherited flock authority');
}, {timeout:7000});

redTest('nestedCompletePublishesWhileAncestorAlive', async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off'};
  const status=path.join(env.HOME,'nested-status.json'), sibling=path.join(env.HOME,'sibling');
  const script='PICSEE_HEAVY_STATUS_PATH="$1" "$2" true; touch "$3"; sleep 1';
  const holder=start(['bash','-c',script,'_',status,lock,sibling],env);
  try {
    await until(()=>existsSync(sibling),'nested completed while ancestor is alive');
    process.kill(holder.child.pid,0);
    assert.ok(existsSync(status),'nested supervisor must publish local cleanup before ancestor exits');
    assert.equal(JSON.parse(readFileSync(status,'utf8')).cleanup,'complete');
  } finally {await holder.done;}
}, {timeout:7000});

redTest('realRunProcessGroupNeverReportsDrainedWithSurvivors', async () => {
  const env={...environment(),PICSEE_HEAVY_FAULT_QUERY:'1',PICSEE_HEAVY_LOCK_DRAIN_SECS:'0.1',PICSEE_MDPRO_LOCK:'off'};
  const pidFile=path.join(env.HOME,'survivor-pid');
  const status=path.join(env.HOME,'status.json');
  env.PICSEE_HEAVY_STATUS_PATH=status;
  const result=await run(['bash','-c',
    'python3 -c "import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(2)" "$1" </dev/null >/dev/null 2>&1 & while ! test -f "$1"; do sleep 0.01; done; exit 1',
    '_',pidFile],env);
  assert.equal(result.code,70,result.output);
  assert.ok(existsSync(pidFile),'real descendant was launched');
  assert.equal(JSON.parse(readFileSync(status,'utf8')).cleanup,'incomplete');
  assert.match(result.output,/unknown|incomplete/i);
  const contenderEnv={...env};delete contenderEnv.PICSEE_HEAVY_FAULT_QUERY;
  delete contenderEnv.PICSEE_HEAVY_STATUS_PATH;
  assert.equal((await run(['true'],contenderEnv)).code,0);
  assert.throws(()=>process.kill(Number(readFileSync(pidFile,'utf8')),0),{code:'ESRCH'});
});

redTest('nestedExecutionKeepsLockUntilLastProtectedDescendantExits', async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off'};
  const hostPid=path.join(env.HOME,'host-pid'),hostDone=path.join(env.HOME,'host-done'),commandDone=path.join(env.HOME,'command-done');
  const script=`python3 -c 'import os,pathlib,sys,time; p=os.fork();
if p==0:
 os.setsid(); os.closerange(3,256); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(1); pathlib.Path(sys.argv[2]).touch(); os._exit(0)
os.waitpid(p,0) if False else None' "$1" "$2"; while ! test -f "$1"; do sleep 0.02; done; "$3" --register-host "$(cat "$1")"; result=$?; touch "$4"; exit $result`;
  const holder=start(['bash','-c',script,'_',hostPid,hostDone,lock,commandDone],env);
  await until(()=>existsSync(hostPid),'out-of-group host launched');
  await until(()=>existsSync(commandDone),'worker command completed');
  const contender=await run(['true'],{...env,PICSEE_HEAVY_LOCK_WAIT_SECS:'0.2'});
  assert.equal(contender.code,75,contender.output);
  assert.equal((await holder.done).code,0,'host registration succeeded');
  assert.ok(existsSync(hostDone));
  assert.equal((await run(['true'],env)).code,0);
}, {timeout:7000});

redTest('guardianRetainsLockAfterSupervisorDeathWithOutOfGroupHost', async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_WAIT_SECS:'2'};
  const hostPid=path.join(env.HOME,'host-pid'), registered=path.join(env.HOME,'registered');
  const script=`python3 -c 'import os,pathlib,sys,time; p=os.fork();
if p==0:
 os.setsid(); null=os.open("/dev/null",os.O_RDWR); os.dup2(null,0); os.dup2(null,1); os.dup2(null,2); os.closerange(3,256); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(2); os._exit(0)
' "$1"; while ! test -f "$1"; do sleep 0.02; done; "$2" --register-host "$(cat "$1")"; touch "$3"`;
  const holder=start(['bash','-c',script,'_',hostPid,lock,registered],env);
  await until(()=>existsSync(registered),'host registered before parent death');
  const pid=Number(readFileSync(hostPid,'utf8'));
  holder.child.kill('SIGKILL');
  await holder.done;
  const probe=await run(['bash','-c','if kill -0 "$1" 2>/dev/null; then exit 23; fi','_',String(pid)],env);
  assert.equal(probe.code,0,'competitor may enter only after host is absent');
  assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
}, {timeout:7000});

redTest('ciAppInvocationPreservesHeldSupervision', async () => {
  const env={...environment(),PICSEE_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_CI_TOP_LEVEL:'1',
    PICSEE_HEAVY_CI_TEST:'1',PICSEE_MDPRO_LOCK:'off'};
  const statusPath=path.join(env.HOME,'ci-status.json');env.PICSEE_HEAVY_STATUS_PATH=statusPath;
  const result=await run(['bash','-c','test -n "$PICSEE_HEAVY_CONTROL_FD" && test "$PICSEE_HEAVY_LOCK_HELD" = 1'],env);
  assert.equal(result.code,0,result.output);
  assert.equal(JSON.parse(readFileSync(statusPath,'utf8')).cleanup,'complete');
  const workflow=readFileSync(path.join(root,'.github/workflows/ci.yml'),'utf8');
  const step=workflow.slice(workflow.indexOf('- name: Run App tests'),workflow.indexOf('- name: Report App test evidence'));
  assert.match(step,/PICSEE_HEAVY_CI_TOP_LEVEL/);
  assert.match(step,/PICSEE_HEAVY_LOCK_EXEC_SECS=2400 scripts\/heavy-lock\.sh node scripts\/tdd\/app-lane\.mjs/);
});
redTest('ciSupervisedAppStepsOutlastTheirOwnDeadlines', () => {
  const workflow=readFileSync(path.join(root,'.github/workflows/ci.yml'),'utf8');
  const app=workflow.slice(workflow.indexOf('- name: Run App tests'),workflow.indexOf('- name: Report App test evidence'));
  const compare=workflow.slice(workflow.indexOf('- name: Run App host comparison'),workflow.indexOf('- name: Upload App host comparison'));
  const repeat=app.match(/PICSEE_HEAVY_LOCK_EXEC_SECS=(\d+) scripts\/heavy-lock\.sh node scripts\/ci\/app-repeat\.mjs/);
  const ordinary=app.match(/PICSEE_HEAVY_LOCK_EXEC_SECS=(\d+) scripts\/heavy-lock\.sh node scripts\/tdd\/app-lane\.mjs/);
  const hosted=compare.match(/PICSEE_HEAVY_LOCK_EXEC_SECS:\s*['"]?(\d+)/);
  assert.ok(repeat,'repeat outer budget is explicit');
  assert.ok(ordinary,'App lane outer budget is explicit');
  assert.ok(hosted,'comparison outer budget is explicit');
  assert.ok(Number(repeat[1])>=6900 && Number(repeat[1])<=7200,'repeat fits 115-minute deadline and 120-minute job');
  assert.ok(Number(ordinary[1])>=2100 && Number(ordinary[1])<=2700,'App lane fits native deadline and 45-minute job');
  assert.ok(Number(hosted[1])>=6900 && Number(hosted[1])<=7200,'comparison fits 115-minute deadline and 120-minute job');
});
test('uses picsee machine-wide default and exports nesting flag', () => {
  const env = environment();
  const r = spawnSync(lock, ['bash', '-c', 'test "$PICSEE_HEAVY_LOCK_HELD" = 1 && test -f "$HOME/.picsee/locks/heavy.lock"'], { env });
  assert.equal(r.status, 0, r.stderr.toString());
});
test('two independent invocations serialize command lifetimes', async () => {
  const env = environment();
  const events = path.join(env.HOME, 'events');
  const cmd = ['bash', '-c', 'echo start >> "$1"; sleep 0.3; echo end >> "$1"', '_', events];
  const results = await Promise.all([run(cmd, env), run(cmd, env)]);
  assert.deepEqual(results.map(r => r.code), [0, 0]);
  assert.equal(readFileSync(events, 'utf8'), 'start\nend\nstart\nend\n');
});
test('nested use shares held flag without deadlock', () => {
  const env = environment();
  const r = spawnSync(lock, ['bash', '-c', 'test "$PICSEE_HEAVY_LOCK_HELD" = 1 && "$1" true', '_', lock], { env, timeout: 5000 });
  assert.equal(r.status, 0, r.stderr.toString());
});
test('preserves child exit code', () => {
  assert.equal(spawnSync(lock, ['bash', '-c', 'exit 23'], { env: environment() }).status, 23);
});
test('TERM reaches child group before releasing the lock', async () => {
  const env = environment();
  const ready = path.join(env.HOME, 'ready');
  const stopped = path.join(env.HOME, 'stopped');
  const child = spawn(lock, ['bash', '-c', 'trap \'echo stopped > "$2"; exit 0\' TERM; touch "$1"; while :; do sleep 0.1; done', '_', ready, stopped], { env });
  child.stdout.resume(); child.stderr.resume();
  const done = new Promise(resolve => child.on('close', (code, signal) => resolve({code, signal})));
  for (let i = 0; i < 100 && !existsSync(ready); i++) await new Promise(r => setTimeout(r, 20));
  assert.ok(existsSync(ready), 'child started');
  child.kill('SIGTERM');
  assert.equal((await done).signal, 'SIGTERM');
  assert.ok(existsSync(stopped), 'child received TERM');
  assert.equal((await run(['true'], env)).code, 0, 'lock available after termination');
});
test('HUP stops the command before releasing the lock', async () => {
  const env = environment();
  const ready = path.join(env.HOME, 'ready');
  const stopped = path.join(env.HOME, 'stopped');
  // Natural completion is bounded so a failing baseline leaves no orphan job.
  const child = spawn(lock, ['bash', '-c', 'trap \'echo stopped > "$2"; exit 0\' TERM; touch "$1"; sleep 0.8', '_', ready, stopped], { env });
  child.stdout.resume(); child.stderr.resume();
  const done = new Promise(resolve => child.on('close', (code, signal) => resolve({code, signal})));
  for (let i = 0; i < 100 && !existsSync(ready); i++) await new Promise(r => setTimeout(r, 20));
  assert.ok(existsSync(ready));
  child.kill('SIGHUP');
  assert.equal((await done).signal, 'SIGHUP');
  assert.ok(existsSync(stopped), 'child must receive termination before lock release');
  assert.equal((await run(['true'], env)).code, 0, 'lock available after hangup');
});

for (const sig of ['SIGINT', 'SIGHUP']) {
  redTest(`groupDirected${sig}StopsWorkerAndReleasesLock`, async () => {
    const env={...environment(), PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1'};
    const pidFile=path.join(env.HOME,'group-worker');
    const child=spawn(lock,['python3','-c',
      'import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(3)',pidFile],
      {env,cwd:root,detached:true,stdio:['ignore','pipe','pipe']});
    let output=''; child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
    const done=new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',(code,signal)=>resolve({code,signal}));});
    try {
      await until(()=>existsSync(pidFile),'worker launched');
      process.kill(-child.pid,sig);
      const result=await done;
      assert.equal(result.signal,sig,output);
      const pid=Number(readFileSync(pidFile,'utf8'));
      assert.throws(()=>process.kill(pid,0),{code:'ESRCH'},'group cancellation drains worker');
      assert.equal((await run(['true'],{...env,PICSEE_HEAVY_LOCK_WAIT_SECS:'0.5'})).code,0,
        'lock released after worker drain');
    } finally {
      try {process.kill(-child.pid,'SIGKILL');} catch(error) {if(error.code!=='ESRCH')throw error;}
      await done;
    }
  }, {timeout:10000});
}

redTest('guardianLossStillDrainsWorkerBeforeExit70', async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1'};
  const pidFile=path.join(env.HOME,'worker-pid');
  const holder=start(['python3','-c',
    'import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(3)',pidFile],env);
  try {
    await until(()=>existsSync(pidFile),'worker launched');
    const rows=spawnSync('ps',['-axo','pid=,ppid=,command='],{encoding:'utf8'});
    assert.equal(rows.status,0,rows.stderr);
    const guardianPid=rows.stdout.split('\n').map(line=>line.trim().match(/^(\d+)\s+(\d+)\s+.*heavy-lock\.py --guardian /))
      .filter(Boolean).find(match=>Number(match[2])===holder.child.pid)?.[1];
    assert.ok(guardianPid,'guardian process found');
    const began=Date.now();
    process.kill(Number(guardianPid),'SIGKILL');
    const result=await holder.done;
    assert.ok(Date.now()-began<1500,'guardian loss stops the worker promptly');
    assert.equal(result.code,70,result.output);
    assert.throws(()=>process.kill(Number(readFileSync(pidFile,'utf8')),0),{code:'ESRCH'});
    assert.equal((await run(['true'],{...env,PICSEE_HEAVY_LOCK_WAIT_SECS:'0.5'})).code,0,
      'guardian-loss cleanup released the flock');
  } finally {
    holder.child.kill('SIGTERM');
    await holder.done;
  }
}, {timeout:10000});

async function until(check, message) {
  for (let i = 0; i < 200 && !check(); i++) await new Promise(r => setTimeout(r, 20));
  assert.ok(check(), message);
}
function start(args, env) {
  const child = spawn(lock, args, { env, cwd: root });
  let output = '';
  child.stdout.on('data', b => output += b); child.stderr.on('data', b => output += b);
  const done = new Promise((resolve,reject) => {
    child.on('error',reject);child.on('close',(code,signal) => resolve({code,signal,output}));
  });
  return {child,done,output:()=>output};
}
test('SIGKILLed supervisor drains its child before admitting two waiters', {timeout:25000}, async () => {
  const env={...environment(),PICSEE_MDPRO_LOCK:'off'};
  const events=path.join(env.HOME,'events');
  const release=path.join(env.HOME,'release');
  const holder=start(['bash','-c','echo holder-start >> "$1"; for ((i=0;i<600;i++)); do test -f "$2" && break; sleep 0.02; done; echo holder-end >> "$1"','_',events,release],env);
  await until(()=>existsSync(events),'holder starts');
  const cmd=['bash','-c','echo start >> "$1"; sleep 0.1; echo end >> "$1"','_',events];
  const waiters=[start(cmd,env),start(cmd,env)];
  try {
    await until(()=>waiters.every(w=>w.output().includes('waiting')),'both waiters queue before kill');
    const exited=new Promise(resolve=>holder.child.on('exit',(code,signal)=>resolve({code,signal})));
    holder.child.kill('SIGKILL');
    assert.equal((await exited).signal,'SIGKILL');
    await until(()=>readFileSync(events,'utf8').includes('start\nend\nstart\nend\n'),
      'guardian drains the holder and admits both waiters');
    assert.equal(readFileSync(events,'utf8').includes('holder-end'),false,
      'the killed supervisor does not leave the holder running');
  } finally {
    writeFileSync(release,'release');
    await holder.done;
    const result=await Promise.all(waiters.map(w=>w.done));
    assert.deepEqual(result.map(r=>r.code),[0,0]);
  }
  assert.equal(readFileSync(events,'utf8'),'holder-start\nstart\nend\nstart\nend\n');
});
test('three-way contention never overlaps', {timeout:25000}, async () => {
  const env=environment();
  const events=path.join(env.HOME,'events');
  const active=path.join(env.HOME,'active');
  const cmd=['bash','-c','mkdir "$2" || exit 22; echo start >> "$1"; sleep 0.2; echo end >> "$1"; rmdir "$2"','_',events,active];
  const result=await Promise.all([run(cmd,env),run(cmd,env),run(cmd,env)]);
  assert.deepEqual(result.map(r=>r.code),[0,0,0]);
  assert.equal(readFileSync(events,'utf8'),'start\nend\nstart\nend\nstart\nend\n');
});
test('lock wait timeout keeps exit 75 without entering the command', async () => {
  const env=environment();
  const ready=path.join(env.HOME,'ready');
  const holder=start(['bash','-c','touch "$1"; sleep 4','_',ready],env);
  try {
    await until(()=>existsSync(ready),'holder owns kernel lock');
    const waiting=await run(['bash','-c','echo must-not-run'],{...env,PICSEE_HEAVY_LOCK_WAIT_SECS:'1'});
    assert.equal(waiting.code,75);
    assert.doesNotMatch(waiting.output,/must-not-run/);
  } finally {
    holder.child.kill('SIGTERM');
    await holder.done;
  }
});

// Shared-lock contract: every path is private to this test's temporary directory.
function fakeHolder(env, pid) {
  mkdirSync(env.PICSEE_MDPRO_LOCK);
  writeFileSync(path.join(env.PICSEE_MDPRO_LOCK, 'owner'), `pid=${pid}\nstarted=fixture\ncwd=/fixture\ncmd=sleep\n`);
}
function releaseFake(env) { rmSync(env.PICSEE_MDPRO_LOCK, { recursive: true, force: true }); }
const pause = ms => new Promise(r => setTimeout(r, ms));
test('AC-1 live mdpro holder blocks picsee until release', async () => {
  const env=environment(), ready=path.join(env.HOME,'ready');
  const sleeper=spawn('sleep',['20']);
  fakeHolder(env,sleeper.pid);
  const job=start(['touch',ready],env);
  try {
    await pause(250);
    assert.equal(existsSync(ready),false);
    assert.match(job.output(),/held by:.*pid=/);
  } finally { releaseFake(env); sleeper.kill(); await job.done; }
  assert.ok(existsSync(ready));
});
test('AC-2 shared owner is live and describes the job; exits and signal propagate', async () => {
  for (const ending of ['exit 0','exit 3','kill -TERM $$']) {
    const env=environment(), ready=path.join(env.HOME,'ready'), release=path.join(env.HOME,'release');
    const job=start(['bash','-c',`touch "$1"; while ! test -f "$2"; do sleep 0.02; done; ${ending}`,'_',ready,release],env);
    try {
      await until(()=>existsSync(ready),'job started');
      const owner=readFileSync(path.join(env.PICSEE_MDPRO_LOCK,'owner'),'utf8');
      const pid=Number(owner.match(/^pid=(\d+)$/m)[1]);
      process.kill(pid,0);
      assert.equal(pid,job.child.pid);
      assert.ok(owner.includes(`cwd=${root}\n`));
      assert.match(owner,/^cmd=bash /m);
      assert.match(owner,/^started=.+/m);
    } finally { writeFileSync(release,''); await job.done; }
    const result=await job.done;
    assert.equal(result.code,ending==='exit 0'?0:ending==='exit 3'?3:null);
    assert.equal(result.signal,ending.startsWith('kill')?'SIGTERM':null);
    assert.equal(existsSync(env.PICSEE_MDPRO_LOCK),false);
  }
});
test('AC-3 stale and ownerless mdpro locks time out without mutation or launch', async () => {
  for (const ownerless of [false,true]) {
    const env={...environment(),PICSEE_HEAVY_LOCK_WAIT_SECS:'0.15'};
    const dead=spawn('true'); await new Promise(r=>dead.on('close',r));
    fakeHolder(env,dead.pid);
    if(ownerless) rmSync(path.join(env.PICSEE_MDPRO_LOCK,'owner'));
    const before=statSync(env.PICSEE_MDPRO_LOCK);
    const contents=readdirSync(env.PICSEE_MDPRO_LOCK);
    const result=await run(['echo','must-not-launch'],env);
    assert.equal(result.code,75,result.output);
    assert.doesNotMatch(result.output,/must-not-launch|reclaiming stale/);
    assert.match(result.output,/waiting for an mdpro waiter to reclaim it/);
    assert.match(result.output,/pgrep -f/);
    assert.equal(statSync(env.PICSEE_MDPRO_LOCK).ino,before.ino);
    assert.equal(statSync(env.PICSEE_MDPRO_LOCK).mtimeMs,before.mtimeMs);
    assert.deepEqual(readdirSync(env.PICSEE_MDPRO_LOCK),contents);
    assert.ok(!readdirSync(env.HOME).some(n=>n.includes('.stale.')));
  }
});
test('AC-4 INT and TERM keep shared lock through group kill grace', async () => {
  for(const sig of ['SIGINT','SIGTERM']) {
    const env={...environment(),PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.5'};
    const ready=path.join(env.HOME,'ready');
    const job=start(['python3','-c','import signal,time,pathlib,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(__import__("os").getpid())); time.sleep(3)',ready],env);
    await until(()=>existsSync(ready),'ignoring child started');
    const pid=Number(readFileSync(ready,'utf8'));
    try {
      job.child.kill(sig); await pause(150);
      process.kill(pid,0);
      assert.ok(existsSync(env.PICSEE_MDPRO_LOCK),'held while child ignores TERM');
    } finally { await job.done; }
    assert.equal((await job.done).signal,sig);
    assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
    assert.equal(existsSync(env.PICSEE_MDPRO_LOCK),false);
  }
});
test('AC-5 shared timeout exits 75 and releases picsee flock', async () => {
  const env=environment(); fakeHolder(env,process.pid);
  try {
    const result=await run(['echo','must-not-run'],{...env,PICSEE_HEAVY_LOCK_WAIT_SECS:'0.2'});
    assert.equal(result.code,75,result.output);
    assert.doesNotMatch(result.output,/must-not-run/);
    assert.equal((await run(['true'],{...env,PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_WAIT_SECS:'0.2'})).code,0);
    assert.ok(existsSync(env.PICSEE_MDPRO_LOCK),'live peer never reclaimed');
  } finally { releaseFake(env); }
});
test('AC-6 opt-out does not invent mdpro ownership; direct HELD needs a credential', async () => {
  for(const direct of [false,true]) {
    const env={...environment(),PICSEE_MDPRO_LOCK:'off',PICSEE_HEAVY_LOCK_HELD:direct?'1':''};
    const result=await run(['bash','-c','test -z "$MDPRO_HEAVY_LOCK_HELD"'],env);
    assert.equal(result.code,direct?70:0,result.output);
    assert.equal(existsSync(env.PICSEE_HEAVY_LOCK),!direct);
  }
  assert.equal((await run(['bash','-c','test "$MDPRO_HEAVY_LOCK_HELD" = 1'],environment())).code,0);
  assert.equal((await run(['bash','-c','test "$MDPRO_HEAVY_LOCK_HELD" = 1'],{...environment(),PICSEE_HEAVY_LOCK_HELD:'1',MDPRO_HEAVY_LOCK_HELD:'1'})).code,70);
});
const mdproLock=process.env.PICSEE_MDPRO_SCRIPT;
test('AC-7 real mdpro script serializes in both directions', {timeout:30000}, async t => {
  if (!mdproLock) { t.skip('PICSEE_MDPRO_SCRIPT not set'); return; }
  for(const first of ['picsee','mdpro']) {
    const env=environment(), events=path.join(env.HOME,'events');
    env.MDPRO_HEAVY_LOCK=env.PICSEE_MDPRO_LOCK;
    function launch(which,args) {
      const child=spawn(which==='picsee'?lock:mdproLock,args,{env,cwd:root});
      let output=''; child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
      return new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',(code,signal)=>resolve({code,signal,output}));});
    }
    const holder=launch(first,['bash','-c','echo "$2-start $(date +%s)" >> "$1"; sleep 5; echo "$2-end $(date +%s)" >> "$1"','_',events,first]);
    await until(()=>existsSync(events),'first job started');
    const second=first==='picsee'?'mdpro':'picsee';
    const waiter=launch(second,['bash','-c','echo "$2-date $(date +%s)" >> "$1"','_',events,second]);
    const results=await Promise.all([holder,waiter]);
    console.log(`AC-7 ${first} first:\n${readFileSync(events,'utf8')}${results.map(r=>r.output).join('')}`);
    assert.deepEqual(results.map(r=>r.code),[0,0]);
    assert.deepEqual(readFileSync(events,'utf8').trim().split('\n').map(s=>s.split(' ')[0]),[`${first}-start`,`${first}-end`,`${second}-date`]);
  }
});

test('B2 leader exit retains directory until same-group worker finishes', async () => {
  for (const ending of ['exit 3', 'kill -TERM $$']) {
    const env=environment(), ready=path.join(env.HOME,'worker'), done=path.join(env.HOME,'done'), entered=path.join(env.HOME,'waiter');
    const job=start(['bash','-c',`(touch "$1"; sleep 1; touch "$2") & ${ending}`,'_',ready,done],env);
    await until(()=>existsSync(ready),'background worker started');
    const waiter=spawn('bash',['-c','while ! mkdir "$1" 2>/dev/null; do sleep 0.02; done; touch "$2"; rmdir "$1"','_',env.PICSEE_MDPRO_LOCK,entered]);
    const waiterDone=new Promise(r=>waiter.on('close',r));
    try {
      await pause(200);
      assert.ok(existsSync(env.PICSEE_MDPRO_LOCK),'directory held for worker');
      assert.equal(existsSync(entered),false,'mdpro waiter stays blocked');
    } finally { await job.done; await waiterDone; }
    assert.ok(existsSync(done));
    const result=await job.done;
    assert.equal(result.code,ending==='exit 3'?3:null,result.output);
    assert.equal(result.signal,ending==='exit 3'?null:'SIGTERM');
  }
});

test('N2 reverse nesting refuses before picsee flock and leaves the shared lock untouched', async () => {
  const env={...environment(),MDPRO_HEAVY_LOCK_HELD:'1',PICSEE_HEAVY_LOCK_WAIT_SECS:'0.2'};
  fakeHolder(env,process.pid);
  const before=statSync(env.PICSEE_MDPRO_LOCK);
  const result=await run(['bash','-c','test "$PICSEE_HEAVY_LOCK_HELD" = 1 && test "$MDPRO_HEAVY_LOCK_HELD" = 1 && test -f "$PICSEE_HEAVY_LOCK"'],env);
  assert.equal(result.code,70,result.output);
  assert.match(result.output,/no verified handoff/);
  assert.equal(existsSync(env.PICSEE_HEAVY_LOCK),false);
  assert.equal(statSync(env.PICSEE_MDPRO_LOCK).ino,before.ino);
  assert.ok(existsSync(path.join(env.PICSEE_MDPRO_LOCK,'owner')));
});
test('N4 file at shared lock path fails clearly without traceback', async () => {
  const env=environment(); writeFileSync(env.PICSEE_MDPRO_LOCK,'peer');
  const result=await run(['echo','must-not-launch'],env);
  assert.equal(result.code,75);
  assert.match(result.output,/not a directory/);
  assert.doesNotMatch(result.output,/Traceback|must-not-launch/);
  assert.equal(readFileSync(env.PICSEE_MDPRO_LOCK,'utf8'),'peer');
});

for (const mode of ['survivors','publication','heartbeat']) {
  test(`fault injection: ${mode}`, () => {
    const env={...environment(),PICSEE_HEAVY_LOCK_WAIT_SECS:mode==='heartbeat'?'200':'0.1',PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0'};
    if(mode==='heartbeat') fakeHolder(env,process.pid);
    const result=spawnSync('python3',['scripts/tdd/fixtures/heavy-lock-faults.py','scripts/tdd/heavy-lock.py',mode],{env,encoding:'utf8',timeout:5000});
    assert.ifError(result.error);
    assert.equal(result.status,0,result.stderr);
    assert.doesNotMatch(result.stderr,/Traceback/);
    if(mode==='survivors') assert.match(result.stderr,/WARNING.*incomplete cleanup.*123456789/);
    if(mode==='publication') assert.match(result.stderr,/owner publication failed/);
    if(mode==='heartbeat') assert.match(result.stderr,/still waiting \(\d+s\)/);
  });
}

test('R1 contended reverse nesting fails promptly without disturbing the flock holder', async () => {
  const env=environment(), entered=path.join(env.HOME,'entered');
  fakeHolder(env,process.pid); // M holds S; P will take F and wait on S.
  const peer=start(['touch',entered],env);
  try {
    await until(()=>peer.output().includes('held by:'),'P owns F and waits for S');
    const began=Date.now();
    const nested=spawnSync(lock,['echo','must-not-launch'],{env:{...env,MDPRO_HEAVY_LOCK_HELD:'1'},encoding:'utf8',timeout:1500});
    assert.ifError(nested.error);
    assert.equal(nested.status,70,nested.stderr);
    assert.ok(Date.now()-began<1500);
    assert.match(nested.stderr,/no verified handoff/);
    assert.doesNotMatch(nested.stdout,/must-not-launch/);
    process.kill(peer.child.pid,0);
    assert.equal(existsSync(entered),false);
  } finally { releaseFake(env); await peer.done; }
  assert.equal((await peer.done).code,0);
  assert.ok(existsSync(entered),'P completes after M releases S');
});

for (const mode of ['vanished']) {
  test(`R2/R3 fault injection: ${mode}`, () => {
    const env={...environment(),PICSEE_HEAVY_LOCK_DRAIN_SECS:mode==='drain-message'?'100':'0.2',PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0'};
    const result=spawnSync('python3',['scripts/tdd/fixtures/heavy-lock-faults.py','scripts/tdd/heavy-lock.py',mode],{env,encoding:'utf8',timeout:5000});
    assert.ifError(result.error);
    assert.equal(result.status,0,result.stderr);
    if(mode==='vanished') assert.doesNotMatch(result.stderr,/not a directory/);
  });
}


test('F4 drain bound stops worker before real mdpro waiter enters and preserves status 3', {timeout:15000}, async t => {
  if (!mdproLock) { t.skip('PICSEE_MDPRO_SCRIPT not set'); return; }
  const env={...environment(),PICSEE_HEAVY_LOCK_DRAIN_SECS:'1',PICSEE_HEAVY_LOCK_KILL_GRACE_SECS:'0.1'};
  env.MDPRO_HEAVY_LOCK=env.PICSEE_MDPRO_LOCK;
  const ready=path.join(env.HOME,'worker'), entered=path.join(env.HOME,'entered');
  const job=start(['bash','-c','(sleep 30) </dev/null >/dev/null 2>&1 & echo $! > "$1"; exit 3','_',ready],env);
  let pid, waiter, waiterDone;
  try {
    await until(()=>existsSync(ready),'background worker started');
    pid=Number(readFileSync(ready,'utf8'));
    process.kill(pid,0);
    waiter=spawn(mdproLock,['bash','-c','if kill -0 "$1" 2>/dev/null; then echo alive; else echo gone; fi > "$2"','_',String(pid),entered],{env,cwd:root});
    let output=''; waiter.stdout.on('data',b=>output+=b);waiter.stderr.on('data',b=>output+=b);
    waiterDone=new Promise((resolve,reject)=>{waiter.on('error',reject);waiter.on('close',code=>resolve({code,output}));});
    await until(()=>output.includes('waiting for'),'real mdpro waiter queues while owner is live');
    const result=await job.done;
    const peer=await waiterDone;
    assert.equal(result.code,3,result.output);
    assert.equal(peer.code,0,peer.output);
    assert.equal(readFileSync(entered,'utf8'),'gone\n','mdpro must never enter beside surviving worker');
    assert.throws(()=>process.kill(pid,0),{code:'ESRCH'},'worker gone after drain termination');
    assert.equal(existsSync(env.PICSEE_MDPRO_LOCK),false,'normal cleanup after group empties');
  } finally {
    if(pid) { try { process.kill(pid,'SIGKILL'); } catch(error) { if(error.code!=='ESRCH') throw error; } }
    await job.done;
    if(waiterDone) await waiterDone;
  }
});

// F5: exercise the real process listing with an unreaped zombie.
test('F5 real-kernel unreaped zombie group drains without exception', {skip: process.platform !== 'darwin'}, () => {
  const r = spawnSync('python3', ['scripts/tdd/fixtures/heavy-lock-faults.py', 'scripts/tdd/heavy-lock.py', 'zombie-group'], {env: environment(), timeout: 5000});
  assert.equal(r.status, 0, r.stderr.toString());
  assert.doesNotMatch(r.stderr.toString(), /Traceback/);
});
for (const mode of ['eperm-signal']) {
  test(`F5 supervisor ignores EPERM while signalling a verified PID`, () => {
    const env = {...environment(), PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: '0'};
    const r = spawnSync('python3', ['scripts/tdd/fixtures/heavy-lock-faults.py', 'scripts/tdd/heavy-lock.py', mode], {
      env, timeout: 5000,
    });
    assert.doesNotMatch(r.stderr.toString(), /Traceback/);
    assert.equal(r.status,0,r.stderr.toString());
  });
}
