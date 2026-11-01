// node --test scripts/perf/p308.test.mjs — the orchestrator's pure parts; the native steps are device-only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { cacheDirectory, parseArgs, planCacheAside, sameProcess } from './p308.mjs';

const run = ['run', '--app', '/A/Picsee.app', '--fixture', '/F', '--tier', 'S2', '--cache-state', 'cold-app',
  '--samples', '30', '--driver', 'drive.sh', '--out', '/R'];

test('arguments: a complete run parses', () => {
  const o = parseArgs(run);
  assert.equal(o.samples, 30);
  assert.equal(o.cacheState, 'cold-app');
  assert.equal(o.allowUnder30, false);
  assert.deepEqual(parseArgs(['parse', '/R']).out, '/R');
});

test('arguments: refuses missing inputs, bad states and fewer than 30 samples', () => {
  const without = (flag) => { const i = run.indexOf(flag); return [...run.slice(0, i), ...run.slice(i + 2)]; };
  for (const flag of ['--app', '--fixture', '--driver', '--tier', '--out', '--samples']) {
    assert.throws(() => parseArgs(without(flag)), new RegExp(flag.slice(2)), flag);
  }
  assert.throws(() => parseArgs(run.map((a) => (a === 'cold-app' ? 'cold' : a))), /--cache-state/);
  assert.throws(() => parseArgs(run.map((a) => (a === 'S2' ? 'S9' : a))), /--tier/);
  assert.throws(() => parseArgs(run.map((a) => (a === '30' ? '29' : a))), /29 < 30/);
  assert.equal(parseArgs([...run.map((a) => (a === '30' ? '5' : a)), '--allow-under-30']).samples, 5);
  assert.throws(() => parseArgs(run.map((a) => (a === '30' ? '3.5' : a))), /positive integer/);
  assert.throws(() => parseArgs([...run, '--bogus', 'x']), /unknown/);
  assert.throws(() => parseArgs(['measure']), /usage/);
  const resources = ['resources', '--app', 'a', '--fixture', 'f', '--tier', 'S2', '--driver', 'd', '--out', 'o'];
  assert.equal(parseArgs(resources).rounds, 3);
  assert.throws(() => parseArgs([...resources, '--rounds', '2']), /at least 3/);
});

test('cache directory is the container thumbnail cache for the bundle', () => {
  assert.equal(cacheDirectory('io.github.anzchy.picsee', '/Users/u'),
    '/Users/u/Library/Containers/io.github.anzchy.picsee/Data/Library/Caches/Picsee/Thumbnails');
  assert.throws(() => cacheDirectory('../evil', '/Users/u'));
});

test('cache aside: moves only the exact plain directory into a new target, never deletes', () => {
  const cache = cacheDirectory('io.github.anzchy.picsee', '/Users/u');
  const fs = (kind, targetExists = false) => ({
    existsSync: () => targetExists,
    lstatSync: () => { if (kind === 'missing') throw new Error('ENOENT'); return { isSymbolicLink: () => kind === 'link', isDirectory: () => kind === 'dir' }; },
  });
  const options = (kind, exists) => ({ bundleID: 'io.github.anzchy.picsee', home: '/Users/u', fs: fs(kind, exists) });
  assert.deepEqual(planCacheAside(cache, '/R', 7, options('dir')), { action: 'move', from: cache, to: '/R/cache-aside/007' });
  assert.equal(planCacheAside(cache, '/R', 7, options('missing')).action, 'none');
  assert.equal(planCacheAside(cache, '/R', 7, options('link')).action, 'refuse');
  assert.equal(planCacheAside(cache, '/R', 7, options('file')).action, 'refuse');
  assert.match(planCacheAside(cache, '/R', 7, options('dir', true)).reason, /already exists/);
  assert.match(planCacheAside('/Users/u/Library/Caches', '/R', 7, options('dir')).reason, /not picsee's cache/);
  assert.match(planCacheAside(cache + '/..', '/R', 7, options('dir')).reason, /not picsee's cache/);
});

test('process identity: signal only the same pid, birth and executable', () => {
  const record = { pid: 10, birth: 'Sun Nov  1 12:00:00 2026', executable: '/A/Picsee.app/Contents/MacOS/Picsee' };
  assert.equal(sameProcess(record, { ...record }), true);
  assert.equal(sameProcess(record, { ...record, birth: 'Sun Nov  1 12:00:01 2026' }), false);
  assert.equal(sameProcess(record, { ...record, executable: '/B/Picsee' }), false);
  assert.equal(sameProcess(record, { ...record, pid: 11 }), false);
  assert.equal(sameProcess(record, null), false);
  assert.equal(sameProcess(null, record), false);
});
