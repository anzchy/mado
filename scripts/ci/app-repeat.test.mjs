import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { runAppRepeat } from './app-repeat.mjs';

const baseline = readFileSync(new URL('../tdd/fixtures/i411-baseline.txt', import.meta.url), 'utf8');
const flaky = readFileSync(new URL('./fixtures/app-a1.txt', import.meta.url), 'utf8');
const result = (stdout = baseline, status = 0) => ({ stdout, stderr: '', status, signal: null });
function harness(t, options = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'app-repeat-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const out = path.join(dir, 'logs'), summaryPath = path.join(dir, 'summary.md');
  const calls = []; let output = '';
  const status = runAppRepeat({ repeat: 3, filter: '', out, summaryPath, deadline: 10000, now: () => 0,
    env: { PICSEE_APP_FILTER: 'inherited-filter' }, stdout: s => output += s,
    spawn: (cmd, args, opts) => { calls.push({cmd, args, opts}); return options.native?.(calls.length, cmd, args, opts) ?? result(); },
    ...options });
  return { status, calls, output, out, summaryPath };
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
      assert.ok(opts.timeout > 0 && opts.timeout <= 10000);
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
  const h = harness(t, { repeat: 2, filter, native: (_n, _cmd, args, opts) => {
    assert.equal(opts.env.PICSEE_APP_FILTER, filter);
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

test('remaining budget hard-kills an uncooperative subprocess without running App tests', async t => {
  const {spawnSync} = await import('node:child_process');
  const started = Date.now();
  const h = harness(t, { repeat: 1, deadline: started + 250, now: Date.now, native: (_n, _cmd, _args, opts) => {
    assert.equal(opts.killSignal, 'SIGKILL');
    return spawnSync(process.execPath, ['-e', "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], opts);
  }});
  assert.equal(h.status, 1);
  assert.ok(Date.now() - started < 5000);
  assert.match(readFileSync(h.summaryPath, 'utf8'), /01 FAIL/);
});

test('CLI rejects an excessive count with a clear nonzero status before native work', async () => {
  const {spawnSync} = await import('node:child_process');
  const run = spawnSync(process.execPath, [new URL('./app-repeat.mjs', import.meta.url).pathname], {
    env: {...process.env, APP_REPEAT:'51'}, encoding:'utf8', timeout:5000});
  assert.equal(run.status, 64);
  assert.match(run.stdout, /app_repeat must be an integer from 1 to 50/);
});
