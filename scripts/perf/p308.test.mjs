// node --test scripts/perf/p308.test.mjs — the orchestrator's pure parts; the native steps are device-only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { cacheDirectory, launch, moveCacheAside, parseArgs, planCacheAside, quit } from './p308.mjs';

const run = ['run', '--app', '/A/Mado.app', '--fixture', '/F', '--tier', 'S2', '--cache-state', 'cold-app',
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
  assert.equal(cacheDirectory('io.github.anzchy.mado', '/Users/u'),
    '/Users/u/Library/Containers/io.github.anzchy.mado/Data/Library/Caches/Mado/Thumbnails');
  assert.throws(() => cacheDirectory('../evil', '/Users/u'));
});

test('cache aside: moves only the exact plain directory into a new target, never deletes', () => {
  const cache = cacheDirectory('io.github.anzchy.mado', '/Users/u');
  const fs = (kind, targetExists = false) => ({
    existsSync: () => targetExists,
    lstatSync: (p) => {
      if (kind === 'missing') throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
      const last = p === cache;
      return { isSymbolicLink: () => last && kind === 'link', isDirectory: () => !last || kind === 'dir' };
    },
    realpathSync: (p) => p,
  });
  const options = (kind, exists) => ({ bundleID: 'io.github.anzchy.mado', home: '/Users/u', fs: fs(kind, exists) });
  assert.deepEqual(planCacheAside(cache, '/R', 7, options('dir')), { action: 'move', from: cache, to: '/R/cache-aside/007' });
  assert.equal(planCacheAside(cache, '/R', 7, options('missing')).action, 'none');
  assert.equal(planCacheAside(cache, '/R', 7, options('link')).action, 'refuse');
  assert.equal(planCacheAside(cache, '/R', 7, options('file')).action, 'refuse');
  assert.match(planCacheAside(cache, '/R', 7, options('dir', true)).reason, /already exists/);
  assert.match(planCacheAside('/Users/u/Library/Caches', '/R', 7, options('dir')).reason, /not picsee's cache/);
  assert.match(planCacheAside(cache + '/..', '/R', 7, options('dir')).reason, /not picsee's cache/);
});

// ---- fix round 1: real filesystem trees and real child processes (#146 H1–H3, M1) ----

const BUNDLE = 'io.github.anzchy.mado';
function tree() {
  const home = mkdtempSync(path.join(tmpdir(), 'p308-home-'));
  const cache = cacheDirectory(BUNDLE, home);
  mkdirSync(cache, { recursive: true });
  writeFileSync(path.join(cache, 'index.sqlite'), 'thumbnail index');
  return { home, cache, out: mkdtempSync(path.join(tmpdir(), 'p308-run-')), extra: [],
           cleanup() {
             try { chmodSync(path.dirname(cache), 0o755); } catch {}
             for (const d of [this.home, this.out, ...this.extra]) rmSync(d, { recursive: true, force: true });
           } };
}

test('cache aside (real tree): a symlinked ancestor anywhere below the container root is refused, nothing moves', () => {
  const t = tree();
  try {
    // Data/Library/Caches/Picsee → a directory outside the container, holding its own Thumbnails.
    const foreign = mkdtempSync(path.join(tmpdir(), 'p308-foreign-'));
    t.extra.push(foreign);
    mkdirSync(path.join(foreign, 'Thumbnails'));
    writeFileSync(path.join(foreign, 'Thumbnails', 'keep'), 'not picsee');
    const picsee = path.dirname(t.cache);
    rmSync(picsee, { recursive: true });
    symlinkSync(foreign, picsee);
    const plan = planCacheAside(t.cache, t.out, 1, { bundleID: BUNDLE, home: t.home });
    assert.equal(plan.action, 'refuse');
    assert.match(plan.reason, /symlink/);
    assert.match(plan.reason, /Caches\/Mado/);
    const run = { cache: t.cache, bundleID: BUNDLE, cacheMoves: [] };
    assert.throws(() => moveCacheAside(t.out, run, 1, { home: t.home }), /cold cache refused: .*symlink/);
    assert.equal(readFileSync(path.join(foreign, 'Thumbnails', 'keep'), 'utf8'), 'not picsee', 'the foreign directory stays put');
    assert.equal(existsSync(path.join(t.out, 'cache-aside')), false);
  } finally { t.cleanup(); }
});

test('cache aside (real tree): a symlinked container root is refused too', () => {
  const t = tree();
  try {
    const containers = path.join(t.home, 'Library/Containers');
    const real = mkdtempSync(path.join(tmpdir(), 'p308-elsewhere-'));
    t.extra.push(real);
    const bundleDir = path.join(containers, BUNDLE);
    mkdirSync(path.join(real, 'x'), { recursive: true });
    rmSync(bundleDir, { recursive: true });
    symlinkSync(path.join(real, 'x'), bundleDir);
    mkdirSync(t.cache, { recursive: true });
    const plan = planCacheAside(t.cache, t.out, 1, { bundleID: BUNDLE, home: t.home });
    assert.equal(plan.action, 'refuse');
    assert.match(plan.reason, /symlink/);
  } finally { t.cleanup(); }
});

test('cache aside (real tree): a plain cache moves whole into the run directory, never deleted', () => {
  const t = tree();
  try {
    const run = { cache: t.cache, bundleID: BUNDLE, cacheMoves: [] };
    moveCacheAside(t.out, run, 3, { home: t.home });
    assert.equal(existsSync(t.cache), false);
    assert.equal(readFileSync(path.join(t.out, 'cache-aside/003/index.sqlite'), 'utf8'), 'thumbnail index');
    assert.equal(run.cacheMoves[0].action, 'move');
    // Now absent: the next cold sample has nothing to move (ENOENT only).
    moveCacheAside(t.out, run, 4, { home: t.home });
    assert.equal(run.cacheMoves[1].action, 'none');
    assert.equal(existsSync(path.join(t.out, 'cache-aside/004')), false);
  } finally { t.cleanup(); }
});

test('cache aside: only ENOENT means absent; EACCES (real) and EPERM fail the run with the error code', (t2) => {
  const t = tree();
  try {
    const run = { cache: t.cache, bundleID: BUNDLE, cacheMoves: [] };
    if (process.getuid?.() === 0) {
      t2.diagnostic('running as root: permission bits do not deny root, real EACCES case skipped');
    } else {
      chmodSync(path.dirname(t.cache), 0o000); // Caches/Picsee unreadable: lstat of Thumbnails fails with EACCES
      const plan = planCacheAside(t.cache, t.out, 1, { bundleID: BUNDLE, home: t.home });
      assert.equal(plan.action, 'refuse');
      assert.match(plan.reason, /EACCES/);
      assert.throws(() => moveCacheAside(t.out, run, 1, { home: t.home }), /cold cache refused: .*EACCES/);
      chmodSync(path.dirname(t.cache), 0o755);
      assert.equal(existsSync(path.join(t.cache, 'index.sqlite')), true, 'the warm cache is untouched, and the run stops');
    }
    const eperm = { existsSync, realpathSync: (p) => p,
      lstatSync: (p) => { if (p === t.cache) throw Object.assign(new Error('operation not permitted'), { code: 'EPERM' }); return { isSymbolicLink: () => false, isDirectory: () => true }; } };
    const plan = planCacheAside(t.cache, t.out, 1, { bundleID: BUNDLE, home: t.home, fs: eperm });
    assert.equal(plan.action, 'refuse');
    assert.match(plan.reason, /EPERM/);
  } finally { t.cleanup(); }
});

test('cache aside: refuses when the resolved cache leaves the real container', () => {
  const t = tree();
  try {
    const escaping = { existsSync, lstatSync: () => ({ isSymbolicLink: () => false, isDirectory: () => true }),
      realpathSync: (p) => (p === t.cache ? '/private/elsewhere/Thumbnails' : p) };
    const plan = planCacheAside(t.cache, t.out, 1, { bundleID: BUNDLE, home: t.home, fs: escaping });
    assert.equal(plan.action, 'refuse');
    assert.match(plan.reason, /outside the App container/);
  } finally { t.cleanup(); }
});

/** A fake bundle whose executable is a shell loop that exits on SIGTERM (or at once, for `exits`). */
function fakeApp(kind = 'stays') {
  const root = mkdtempSync(path.join(tmpdir(), 'p308-app-'));
  const app = path.join(root, 'Mado.app');
  const bin = path.join(app, 'Contents/MacOS/Mado');
  mkdirSync(path.dirname(bin), { recursive: true });
  writeFileSync(bin, kind === 'exits' ? '#!/bin/sh\nexit 3\n' : "#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.05; done\n", { mode: 0o755 });
  return { app, root };
}
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('launch: owns exactly the child it spawned, even when another Mado appears meanwhile', async () => {
  const { app, root } = fakeApp();
  const run = { owned: [] };
  let calls = 0;
  const stranger = process.pid; // a live process the script must never claim or signal
  const deps = { sleep: async () => {}, readyMs: 0,
    picseePIDs: () => (calls++ === 0 ? [] : [stranger]) };
  const record = await launch(app, run, deps);
  try {
    assert.ok(record.child && record.pid !== stranger);
    assert.deepEqual(run.owned.map((r) => r.pid), [record.pid]);
    assert.equal(alive(record.pid), true);
    assert.equal(await quit(record, { sleep: (ms) => new Promise((r) => setTimeout(r, ms)) }), 'terminated');
    assert.equal(alive(record.pid), false);
    assert.equal(alive(stranger), true);
  } finally { if (alive(record.pid)) process.kill(record.pid, 'SIGKILL'); rmSync(root, { recursive: true, force: true }); }
});

test('launch: refuses while another Mado runs and spawns nothing', async () => {
  const { app, root } = fakeApp();
  let spawned = false;
  const run = { owned: [] };
  try {
    await assert.rejects(launch(app, run, { picseePIDs: () => [4242], spawn: () => { spawned = true; }, sleep: async () => {}, readyMs: 0 }), /another Mado is running \(pid 4242\)/);
    assert.equal(spawned, false);
    assert.deepEqual(run.owned, []);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// The first exec of a new script can take a while on macOS (the system checks the new executable), hence 5 s.
test('launch: a child that exits during start-up is reported and never owned', async () => {
  const { app, root } = fakeApp('exits');
  const run = { owned: [] };
  try {
    await assert.rejects(launch(app, run, { picseePIDs: () => [], sleep: (ms) => new Promise((r) => setTimeout(r, ms)), readyMs: 5000 }), /exited during start-up/);
    assert.deepEqual(run.owned, []);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('quit: never signals a record it did not spawn', async () => {
  const stranger = { pid: process.pid, birth: 'x', executable: 'node' };
  await assert.rejects(quit(stranger, { sleep: async () => {} }), /not a child this script spawned/);
});
