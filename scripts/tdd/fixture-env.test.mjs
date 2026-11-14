// #705: fixtures that launch their own heavy-lock supervisors must not inherit
// the enclosing supervisor's handoff (HELD, control/flock FDs, mdpro marker) or
// the node:test worker context.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { fixtureEnv } from './fixture-env.mjs';

const here = path => fileURLToPath(new URL(path, import.meta.url));
const stripped = name => name.startsWith('PICSEE_HEAVY_') || name === 'MDPRO_HEAVY_LOCK_HELD' || name === 'NODE_TEST_CONTEXT';

// Replace process.env's contents for the duration of fn, then restore them exactly.
function withEnv(map, fn) {
  const saved = { ...process.env };
  const reset = next => { for (const key of Object.keys(process.env)) delete process.env[key]; Object.assign(process.env, next); };
  reset(map);
  try { return fn(); } finally { reset(saved); }
}
function mulberry32(seed) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}

test('fixtureEnv strips the handoff by prefix and keeps look-alikes', () => {
  const env = { PATH: '/bin', PICSEE_HEAVY_LOCK_HELD: '1', PICSEE_HEAVY_CONTROL_FD: '3', PICSEE_HEAVY_FLOCK_FD: '5',
    PICSEE_HEAVY_ZZZ: 'x', MDPRO_HEAVY_LOCK_HELD: '1', NODE_TEST_CONTEXT: 'child-v8',
    PICSEE_HEAVYX: '1', XPICSEE_HEAVY_A: '1', MDPRO_HEAVY_LOCK: '1', PICSEE_APP_FILTER: 'a' };
  const out = withEnv(env, () => fixtureEnv());
  assert.deepEqual(Object.keys(out).sort(), ['MDPRO_HEAVY_LOCK', 'PATH', 'PICSEE_APP_FILTER', 'PICSEE_HEAVYX', 'XPICSEE_HEAVY_A']);
});

test('fixtureEnv keeps other values, returns a copy and never mutates process.env', () => {
  const env = { PATH: '/usr/bin:/bin', HOME: '/home/x', PICSEE_APP_FILTER: 'x', PICSEE_HEAVY_LOCK_HELD: '1' };
  withEnv(env, () => {
    const before = JSON.stringify(process.env);
    const out = fixtureEnv();
    assert.notEqual(out, process.env);
    assert.deepEqual(out, { PATH: '/usr/bin:/bin', HOME: '/home/x', PICSEE_APP_FILTER: 'x' });
    out.PATH = 'changed';
    assert.equal(JSON.stringify(process.env), before);
  });
});

test('fixtureEnv overrides win, including stripped names', () => {
  const out = withEnv({ PICSEE_HEAVY_LOCK: 'a', PICSEE_APP_FILTER: 'z', KEEP: 'k' },
    () => fixtureEnv({ PICSEE_HEAVY_LOCK: '/tmp/l', PICSEE_APP_FILTER: 'y', KEEP: undefined }));
  assert.deepEqual(out, { PICSEE_HEAVY_LOCK: '/tmp/l', PICSEE_APP_FILTER: 'y' });
});

test('fixtureEnv law over seeded random environments', () => {
  const names = ['PICSEE_HEAVY_LOCK_HELD', 'PICSEE_HEAVY_CONTROL_FD', 'PICSEE_HEAVY_Q', 'MDPRO_HEAVY_LOCK_HELD', 'NODE_TEST_CONTEXT',
    'PICSEE_HEAVYX', 'XPICSEE_HEAVY_', 'MDPRO_HEAVY_LOCK_HELDX', 'NODE_TEST', 'PATH', 'HOME', 'PICSEE_APP_FILTER', 'A', 'B'];
  for (const seed of [1, 7, 705, 2026]) {
    const random = mulberry32(seed);
    for (let i = 0; i < 200; i++) {
      const pick = () => names[Math.floor(random() * names.length)];
      const env = {}, overrides = {};
      for (let k = 0; k < 8; k++) env[pick()] = String(Math.floor(random() * 100));
      for (let k = 0; k < 3; k++) if (random() < 0.5) overrides[pick()] = 'o' + k;
      const snapshot = JSON.stringify(env);
      const out = withEnv(env, () => {
        const result = fixtureEnv(overrides);
        assert.equal(JSON.stringify(process.env), snapshot, `seed ${seed}/${i}: process.env mutated`);
        return result;
      });
      const expected = {};
      for (const [key, value] of Object.entries(env)) if (!stripped(key)) expected[key] = value;
      Object.assign(expected, overrides);
      assert.deepEqual(out, expected, `seed ${seed}/${i}`);
      assert.deepEqual(withEnv(out, () => fixtureEnv(overrides)), out, `seed ${seed}/${i}: not idempotent`);
    }
  }
});

// Every process.env copy at test level must go through fixtureEnv. Generated
// child sources run inside an already sanitized fixture and carry the marker.
const scanned = ['app-lane.test.mjs', 'unit-lane.test.mjs', 'swift-lane.test.mjs', 'trash-lane.test.mjs',
  'host-unknown-fix1.test.mjs', 'heavy-lock.test.mjs', 'unit-startup.test.mjs'];
test('no in-scope fixture copies process.env without fixtureEnv', () => {
  const offenders = [];
  for (const file of scanned) readFileSync(here(`./${file}`), 'utf8').split('\n').forEach((line, index) => {
    if (/\.\.\.\s*process\.env\b|Object\.assign\(\s*\{\s*\}\s*,\s*process\.env/.test(line) && !line.includes('fixture-env: sanitized'))
      offenders.push(`${file}:${index + 1}`);
  });
  assert.deepEqual(offenders, []);
  for (const production of ['node-lane.mjs', 'trash-lane.mjs'])
    assert.doesNotMatch(readFileSync(here(`./${production}`), 'utf8'), /fixture-env/, `${production} must keep passing its handoff`);
});

// One supervisor-launching test per file, run as an independent node --test under
// the handoff a heavy-lock job gives its children (FD numbers not open here).
const contaminated = { PICSEE_HEAVY_LOCK_HELD: '1', PICSEE_HEAVY_CONTROL_FD: '3', PICSEE_HEAVY_FLOCK_FD: '5', MDPRO_HEAVY_LOCK_HELD: '1' };
for (const [file, name] of [
  ['app-lane.test.mjs', 'heldAndUnheldLanesPreservePassAndAssertionFailure App'],
  ['host-unknown-fix1.test.mjs', 'hostUnknownStillDrainsKnownWorkAndReleasesGuardian'],
  ['swift-lane.test.mjs', 'native Swift nested HELD retains pass and assertion counts'],
  ['unit-lane.test.mjs', 'full unit success and ordinary failure preserve output, status and single execution'],
  ['trash-lane.test.mjs', 'trashLaneCountsOnlyCompletedScenarios'],
  ['heavy-lock.test.mjs', 'lockAgeAlertStaysSilentWithinBudget'],
]) test(`contaminated handoff: ${file} fixture still runs`, { timeout: 120000 }, () => {
  // An independent runner, not a node:test worker of this file.
  const env = { ...process.env, ...contaminated };
  delete env.NODE_TEST_CONTEXT;
  const exact = '^' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$';
  const r = spawnSync(process.execPath, ['--test', '--test-reporter=tap', '--test-name-pattern', exact, here(`./${file}`)],
    { env, encoding: 'utf8', timeout: 110000, maxBuffer: 16 * 1024 * 1024 });
  assert.ifError(r.error);
  const output = r.stdout + r.stderr;
  assert.doesNotMatch(output, /HELD needs one parent control FD|reverse mdpro nesting refused/);
  assert.match(r.stdout, /^# pass 1$/m, output);
  assert.match(r.stdout, /^# fail 0$/m, output);
  assert.equal(r.status, 0, output);
});
