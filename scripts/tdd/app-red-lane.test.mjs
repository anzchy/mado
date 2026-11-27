// #916 WI-3 (item 5, #909 / #871 fix 5): the app-red receipt lane builds inside its command, not in a plugin
// setupCommand. tdd-guardian 0.10.2 runs setupCommand under a fixed 300 s timeout (lib/lanes.js:404,
// `opts.setupTimeoutMs || 300000`, not configurable from config.json), and that clock includes the heavy-lock queue;
// #871 fix 5 timed out there seven times. Inside the command, the build waits on heavy-lock's own budget under the
// lane's timeoutMs. A failed or lock-timed-out build exits 70 (runner error), never 1, so it can never be a RED.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
// Imported dynamically so a missing module is an assertion failure, not a load error.
const appRed = await import('./app-red-lane.mjs').catch(() => ({}));

const root = fileURLToPath(new URL('../../', import.meta.url));
const config = JSON.parse(fs.readFileSync(path.join(root, '.claude/tdd-guardian/config.json'), 'utf8'));
const lane = config.lanes.find(l => l.name === 'app-red');

function harness(t, statuses) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'i916-app-red-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const calls = [];
  let stdout = '', stderr = '';
  const spawn = (command, args, options) => {
    calls.push({ command, args, options });
    const step = statuses[calls.length - 1] ?? { status: 0 };
    if (step.write && typeof options?.stdio?.[1] === 'number') fs.writeSync(options.stdio[1], step.write);
    return { status: step.status, signal: null };
  };
  const run = (extra = {}) => {
    assert.equal(typeof appRed.runAppRed, 'function', 'app-red-lane.mjs exports runAppRed');
    return appRed.runAppRed({ spawn, env: {}, argv: [], logDir: dir,
    stdout: s => { stdout += s; }, stderr: s => { stderr += s; }, ...extra });
  };
  return { dir, calls, run, out: () => stdout, err: () => stderr };
}

test('916 WI-3 the app-red lane has no setupCommand; its command builds, and timeoutMs covers the build lock wait', () => {
  assert.equal(typeof appRed.runAppRed, 'function', 'app-red-lane.mjs exports runAppRed');
  assert.equal(lane.setupCommand, undefined, 'no plugin setup phase (fixed 300 s timeout)');
  assert.equal(lane.command, 'node scripts/tdd/app-red-lane.mjs');
  // The old 2400 s for the tests plus heavy-lock's default 1800 s acquisition budget for the build step.
  assert.ok(lane.timeoutMs >= 2400000 + 1800000, `timeoutMs ${lane.timeoutMs}`);
});

test('916 WI-3 the build runs first through heavy-lock.sh, for both bundles, then app-lane with the same arguments', t => {
  const h = harness(t, [{ status: 0, write: 'No such file or directory (build noise)\n' }, { status: 1 }]);
  const status = h.run({ argv: ['issue512Name'], env: { MADO_APP_DERIVED_DATA_PATH: '/tmp/dd-x' } });
  assert.equal(status, 1, 'an App test failure stays exit 1 (a RED)');
  assert.equal(h.calls.length, 2);
  const [build, tests] = h.calls;
  assert.equal(build.command, path.join(root, 'scripts/heavy-lock.sh'));
  assert.deepEqual(build.args, ['xcodebuild', 'build-for-testing', '-scheme', 'Mado', '-destination', 'platform=macOS',
    'CODE_SIGNING_ALLOWED=NO', '-derivedDataPath', '/tmp/dd-x']);
  assert.ok(!build.args.some(a => a.startsWith('-only-testing')), 'both retained and hosted bundles are built');
  assert.equal(tests.command, process.execPath);
  assert.deepEqual(tests.args, [path.join(root, 'scripts/tdd/app-lane.mjs'), 'issue512Name']);
  // Build output goes to a log, so its text can never reach the receipt's output classifier.
  assert.doesNotMatch(h.out() + h.err(), /build noise/);
  assert.match(fs.readFileSync(path.join(h.dir, 'build.log'), 'utf8'), /build noise/);
  assert.match(h.err(), /app-red: build-for-testing ok \(log .*build\.log\)/);
});

test('916 WI-3 the default derived data is the one app-lane reads (.build/dd-ci), and a pass stays 0', t => {
  const h = harness(t, [{ status: 0 }, { status: 0 }]);
  assert.equal(h.run(), 0);
  assert.equal(h.calls[0].args.at(-1), '.build/dd-ci');
  assert.deepEqual(h.calls[1].args, [path.join(root, 'scripts/tdd/app-lane.mjs')]);
});

test('916 WI-3 a failed build or a heavy-lock wait timeout exits 70 and never runs the tests', t => {
  for (const [code, why] of [[65, 'build failed'], [75, 'heavy-lock wait timed out'], [null, 'build killed']]) {
    const h = harness(t, [{ status: code, write: 'error: compile failed\n' }]);
    assert.equal(h.run(), 70, `${why}: a runner error, not a RED`);
    assert.equal(h.calls.length, 1, `${why}: app-lane not started`);
    assert.match(h.err(), /app-red: build-for-testing failed .*not a RED/);
    assert.match(h.err(), /error: compile failed/, `${why}: the log tail is shown`);
  }
});
