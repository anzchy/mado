import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { runAppRepeat } from './app-repeat.mjs';
import { runAppIteration } from './app-repeat-worker.mjs';

const baseline = readFileSync(new URL('../tdd/fixtures/i411-baseline.txt', import.meta.url), 'utf8');
const flaky = readFileSync(new URL('./fixtures/app-a1.txt', import.meta.url), 'utf8');
const result = (stdout = baseline, status = 0) => ({ stdout, stderr: '', status, signal: null });
function harness(t, options = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'app-repeat-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const out = path.join(dir, 'logs'), summaryPath = path.join(dir, 'summary.md');
  const calls = [], supervisors = []; let output = '';
  const status = runAppRepeat({ repeat: 3, filter: '', out, summaryPath, deadline: 10000, now: () => 0,
    env: { PICSEE_APP_FILTER: 'inherited-filter', PICSEE_HEAVY_LOCK_HELD:'1' }, stdout: s => output += s,
    spawn: (command, arguments_, options_) => {
      supervisors.push({command,arguments_,options_});
      const [, deadline, logPath, , , quarantinePath, evidencePath] = arguments_;
      assert.equal(Number(deadline), options.deadline ?? 10000);
      assert.equal(readFileSync(quarantinePath,'utf8'), '[]\n');
      let log = '', status;
      try {
        status = runAppIteration({env:options_.env,quarantinePath,evidencePath,stdout:s=>log+=s,stderr:s=>log+=s,
          spawn:(cmd,args,opts)=>{calls.push({cmd,args,opts});return options.native?.(calls.length,cmd,args,opts)??result();}});
      } catch (error) { log += error.message; status=70; }
      writeFileSync(logPath,log);
      return {status:0,stdout:JSON.stringify({status,drained:true}),stderr:'',signal:null};
    },
    ...options });
  return { status, calls, output, out, summaryPath, supervisors };
}

test('repeat count conserves logs, summary rows and native runs; full clears inherited filter', t => {
  for (const repeat of [1, 3, 50]) {
    const h = harness(t, { repeat });
    assert.equal(h.status, 0, h.output);
    assert.equal(h.calls.length, repeat);
    assert.equal(readdirSync(h.out).filter(n => /^iter-\d\d.log$/.test(n)).length, repeat);
    const summary = readFileSync(h.summaryPath, 'utf8');
    assert.equal(summary.match(/^\d\d PASS$/gm).length, repeat);
    assert.match(summary, new RegExp(`TOTAL ${repeat} PASS, 0 FAIL`));
    for (const { args, opts } of h.calls) {
      assert.deepEqual(args, ['xcrun', 'xctest', '.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);
      assert.equal(opts.env.PICSEE_APP_LANE_NO_RETRY, '1');
      assert.equal(opts.env.PICSEE_APP_FILTER, undefined);
      assert.ok(opts.timeout > 0);
    }
    assert.match(readFileSync(path.join(h.out, 'iter-01.log'), 'utf8'), /app-lane quarantine none/);
  }
});
test('known flaky fails without retry; continues, preserves bytes, names test and exits nonzero', t => {
  const h = harness(t, { native: n => n === 2 ? result(flaky, 1) : result() });
  assert.equal(h.status, 1);
  assert.equal(h.calls.length, 3);
  assert.match(readFileSync(path.join(h.out, 'iter-02.log'), 'utf8'), /t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves/);
  assert.ok(readFileSync(path.join(h.out, 'iter-02.log'), 'utf8').includes(flaky));
  assert.equal(readFileSync(h.summaryPath, 'utf8'), '01 PASS\n02 FAIL t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves\n03 PASS\nTOTAL 2 PASS, 1 FAIL\n');
});
test('filter is a literal environment value and selects real lane inventory', t => {
  const inventory = 'APP_LANE_INVENTORY_BEGIN\nProbe.swiftKeep()\nAPP_LANE_INVENTORY_END\n';
  const selected = "Test Suite 'Selected tests' started at now\nTest Suite 'Selected tests' passed at now\nExecuted 0 tests, with 0 failures (0 unexpected)\n◇ Test run started.\n◇ Test swiftKeep() started.\n✔ Test swiftKeep() passed after 0.001 seconds.\n✔ Test run with 1 test in 0 suites passed after 0.001 seconds.\n";
  const filter = '^Probe\\.swiftKeep\\(\\)$';
  const h = harness(t, { repeat: 2, filter, env:{PICSEE_HEAVY_LOCK_HELD:'1'}, native: (_n, _cmd, args, opts) => {
    assert.equal(opts.env.PICSEE_APP_FILTER, filter);
    assert.equal(opts.env.PICSEE_HEAVY_LOCK_HELD, '1', 'discovery stays in the already authorized iteration group');
    if (args.includes('xctest')) {
      assert.ok(args.includes('Probe.swiftKeep()'));
      return result(selected);
    }
    if (args.includes('--show-sdk-platform-path')) return result('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform\n');
    if (args.includes('swiftc')) return result('');
    return result(inventory);
  }});
  assert.equal(h.status, 0, h.output);
  assert.match(readFileSync(h.summaryPath, 'utf8'), /TOTAL 2 PASS, 0 FAIL/);
});
test('invalid counts fail clearly before launching anything', t => {
  for (const repeat of [0, -1, 1.5, 51, 'nope', Infinity, '']) {
    const h = harness(t, { repeat });
    assert.equal(h.status, 64);
    assert.equal(h.calls.length, 0);
    assert.match(h.output, /app_repeat must be an integer from 1 to 50/);
  }
});
test('native environment errors and elapsed budget cannot pass or erase later iteration logs', t => {
  let clock = 0;
  const h = harness(t, { now: () => clock, native: () => {
    clock = 10001;
    return { status: null, stdout: 'partial native log', stderr: '', signal: 'SIGTERM', error: new Error('timed out') };
  }});
  assert.equal(h.status, 1);
  assert.equal(h.calls.length, 1);
  assert.equal(readdirSync(h.out).filter(n => /^iter-/.test(n)).length, 3);
  assert.match(readFileSync(h.summaryPath, 'utf8'), /01 FAIL.*\n02 FAIL.*budget.*\n03 FAIL.*budget.*\nTOTAL 0 PASS, 3 FAIL/);
});

test('failures at either end and thrown spawn errors still produce every outcome', t => {
  for (const position of [1, 3]) {
    const h = harness(t, { native: n => {
      if (n === position) throw new Error('native boundary unavailable');
      return result();
    }});
    assert.equal(h.status, 1);
    assert.equal(h.calls.length, 3);
    assert.match(readFileSync(path.join(h.out, `iter-0${position}.log`), 'utf8'), /native boundary unavailable/);
    assert.match(readFileSync(h.summaryPath, 'utf8'), /TOTAL 2 PASS, 1 FAIL/);
  }
});
test('stdout and stderr both survive; invalid numeric inputs never spawn', t => {
  const h = harness(t, { repeat: 1, native: () => ({ ...result(), stderr: 'stderr evidence\n' }) });
  assert.equal(h.status, 0);
  assert.ok(readFileSync(path.join(h.out, 'iter-01.log'), 'utf8').includes(baseline));
  assert.match(readFileSync(path.join(h.out, 'iter-01.log'), 'utf8'), /stderr evidence/);
  for (const repeat of [NaN, '1.2', '-Infinity']) {
    const invalid = harness(t, {repeat});
    assert.equal(invalid.status, 64);
    assert.equal(invalid.calls.length, 0);
  }
});

// Native group cleanup uses real multi-generation processes in app-repeat-process.test.mjs.
test('supervisor group-drain failure refuses to launch another iteration', t => {
  let launched=0;
  const h=harness(t,{repeat:3,spawn:(_cmd,args)=>{
    launched++;
    writeFileSync(args[2],'group could not drain\n');
    return {status:0,stdout:JSON.stringify({status:70,drained:false}),stderr:''};
  }});
  assert.equal(h.status,1);
  assert.equal(launched,1);
  assert.match(readFileSync(path.join(h.out,'iter-02.log'),'utf8'),/refusing to overlap/);
  assert.match(readFileSync(h.summaryPath,'utf8'),/TOTAL 0 PASS, 3 FAIL/);
});

test('CLI rejects an excessive count with a clear nonzero status before native work', async () => {
  const {spawnSync} = await import('node:child_process');
  const run = spawnSync(process.execPath, [new URL('./app-repeat.mjs', import.meta.url).pathname], {
    env: {...process.env, APP_REPEAT:'51'}, encoding:'utf8', timeout:5000});
  assert.equal(run.status, 64);
  assert.match(run.stdout, /app_repeat must be an integer from 1 to 50/);
});

test('whitespace-only filter selects the full bundle and clears an inherited filter', t => {
  const h = harness(t, {repeat:1,filter:' \t\n '});
  assert.equal(h.status, 0, h.output);
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].opts.env.PICSEE_APP_FILTER, undefined);
});
test('validation-only CLI rejects invalid dispatch counts and never launches tests for valid counts', async () => {
  const {spawnSync} = await import('node:child_process');
  for (const repeat of ['0','-1','1.5','51','1','3','50']) {
    const run = spawnSync(process.execPath, [new URL('./app-repeat.mjs', import.meta.url).pathname,'--validate'], {
      env:{...process.env,APP_REPEAT:repeat,APP_FILTER:'',APP_REPEAT_DEADLINE_MS:'invalid-before-native'},encoding:'utf8',timeout:5000});
    assert.equal(run.status, ['1','3','50'].includes(repeat) ? 0 : 64, run.stdout+run.stderr);
    assert.doesNotMatch(run.stdout, /app-lane|TOTAL/);
  }
});

test('real repeat CLI supervises worker failures and writes every log without native App execution', async t => {
  const {spawnSync} = await import('node:child_process');
  const dir = mkdtempSync(path.join(tmpdir(),'app-repeat-cli-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const run = spawnSync(process.execPath,[new URL('./app-repeat.mjs',import.meta.url).pathname], {
    cwd:dir,env:{...process.env,APP_REPEAT:'2',APP_FILTER:'[',PICSEE_HEAVY_LOCK_HELD:'1',
      APP_REPEAT_DEADLINE_MS:String(Date.now()+5000),GITHUB_STEP_SUMMARY:path.join(dir,'summary')},
    encoding:'utf8',timeout:10000});
  assert.equal(run.status,1,run.stdout+run.stderr);
  for (const label of ['01','02']) {
    const log = readFileSync(path.join(dir,'.build/app-repeat',`iter-${label}.log`),'utf8');
    assert.match(log,/usage: node scripts\/tdd\/app-lane.mjs/);
    assert.doesNotMatch(log,/app-lane quarantine|Tests run:/);
  }
  assert.match(readFileSync(path.join(dir,'summary'),'utf8'),/01 FAIL.*\n02 FAIL.*\nTOTAL 0 PASS, 2 FAIL/);
});

test('repeat execution refuses an unowned machine before launching any worker', t => {
  const h=harness(t,{env:{}});
  assert.equal(h.status,64);
  assert.equal(h.calls.length,0);
  assert.equal(h.supervisors.length,0);
  assert.match(h.output,/requires PICSEE_HEAVY_LOCK_HELD=1/);
});
