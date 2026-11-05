import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync, spawn } from 'node:child_process';

const script = fileURLToPath(new URL('./archive-receipts.mjs', import.meta.url));
const receipt = (id = '408-WI-1', head_sha = 'a') => ({ id, lane: 'release-node', head_sha,
  red: { red: true, kind: 'assertion-failure' }, test_files: { 'test.mjs': { state: 'ok', lines: ['abc'], sha: '123' } },
  verified_at: '2026-11-05T00:00:00Z', verdict: 'SEPARATION-HELD' });
function fixture(root) {
  const cwd = mkdtempSync(join(tmpdir(), 'receipt-archive-'));
  mkdirSync(join(cwd, '.claude/tdd-guardian'), { recursive: true });
  const source = join(cwd, '.claude/tdd-guardian/receipts.json');
  root ??= join(cwd, 'archive');
  const options = { cwd, encoding: 'utf8', env: { ...process.env, PICSEE_RECEIPT_ARCHIVE_ROOT: root } };
  return { cwd, source, root, options,
    put: (receipts) => writeFileSync(source, JSON.stringify({ schemaVersion: 2, receipts })),
    run: (...args) => spawnSync(process.execPath, [script, ...args], options) };
}
function snapshot(root) {
  return Object.fromEntries(readdirSync(root).sort().map(name => [name,
    { content: readFileSync(join(root, name), 'utf8'), mtime: statSync(join(root, name)).mtimeMs }]));
}
function age(root) { for (const name of readdirSync(root)) utimesSync(join(root, name), 1000, 1000); }
const envelope = (worktree, receipt) => ({ schemaVersion: 1, worktree, receipt });

test('archive writes one full envelope per ID in overridden root, source unchanged', () => {
  const f = fixture(); const receipts = [receipt(), receipt('409-WI-1')]; f.put(receipts);
  const before = readFileSync(f.source, 'utf8'); const r = f.run('gpt-imple-1'); assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(readdirSync(f.root).sort(), ['408-WI-1.json', '409-WI-1.json']);
  for (const item of receipts) assert.deepEqual(JSON.parse(readFileSync(join(f.root, `${item.id}.json`))), envelope('gpt-imple-1', item));
  assert.equal(readFileSync(f.source, 'utf8'), before);
});
test('identical and key-reordered reruns report no-op without rewriting bytes or mtime', () => {
  const f = fixture(); const item = receipt(); f.put([item]); assert.equal(f.run('wt').status, 0); age(f.root);
  const before = snapshot(f.root);
  for (const next of [item, Object.fromEntries(Object.entries(item).reverse())]) {
    f.put([next]); const r = f.run('wt'); assert.equal(r.status, 0, r.stderr); assert.match(r.stdout, /no-op/i);
    assert.deepEqual(snapshot(f.root), before);
  }
});
test('same ID in two worktrees conserves both payloads, including identical payloads', () => {
  for (const sha of ['a', 'b']) {
    const f = fixture(); const a = receipt(), b = receipt('408-WI-1', sha);
    f.put([a]); assert.equal(f.run('first').status, 0); age(f.root); const original = snapshot(f.root);
    f.put([b]); const r = f.run('second'); assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(snapshot(f.root)['408-WI-1.json'], original['408-WI-1.json']);
    assert.deepEqual(JSON.parse(readFileSync(join(f.root, '408-WI-1.second.json'))), envelope('second', b));
    age(f.root); const both = snapshot(f.root);
    for (const [wt, item] of [['first', a], ['second', b]]) {
      f.put([item]); const retry = f.run(wt); assert.equal(retry.status, 0, retry.stderr); assert.match(retry.stdout, /no-op/i);
      assert.deepEqual(snapshot(f.root), both);
    }
  }
});
test('changed evidence and occupied suffix refuse while preserving every existing file', () => {
  const f = fixture(); f.put([receipt()]); assert.equal(f.run('first').status, 0);
  assert.equal(f.run('second').status, 0); age(f.root); const before = snapshot(f.root);
  f.put([receipt('408-WI-1', 'changed')]);
  for (const wt of ['first', 'second']) {
    const r = f.run(wt); assert.notEqual(r.status, 0); assert.match(r.stderr, /conflict/i);
    assert.deepEqual(snapshot(f.root), before);
  }
});
test('simultaneous worktree creates retain complete distinct envelopes and no-op on retry', async () => {
  const a = fixture(), b = fixture(a.root); a.put([receipt()]); b.put([receipt('408-WI-1', 'b')]);
  const run = (f, wt) => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script, wt], f.options); let stderr = '';
    child.stderr.on('data', data => stderr += data); child.on('error', reject);
    child.on('close', status => resolve({ status, stderr }));
  });
  const results = await Promise.all([run(a, 'first'), run(b, 'second')]);
  for (const r of results) assert.equal(r.status, 0, r.stderr);
  const stored = Object.values(snapshot(a.root)).map(f => JSON.parse(f.content)).sort((a, b) => a.worktree.localeCompare(b.worktree));
  assert.deepEqual(stored, [envelope('first', receipt()), envelope('second', receipt('408-WI-1', 'b'))]);
  age(a.root); const before = snapshot(a.root);
  assert.equal(a.run('first').status, 0); assert.equal(b.run('second').status, 0); assert.deepEqual(snapshot(a.root), before);
});
test('invalid batch, unsafe names, missing source/arguments and unusable destination fail clearly', () => {
  const f = fixture(); assert.notEqual(f.run('wt').status, 0);
  for (const invalid of ['../escape', '/tmp/escape', 'a/b', 'a\ninjected', '']) {
    f.put([receipt()]); assert.notEqual(f.run(invalid).status, 0);
    const invalidEntry = fixture(); invalidEntry.put([receipt(), receipt(invalid)]);
    const skipped = invalidEntry.run('wt'); assert.equal(skipped.status, 0, skipped.stderr);
    assert.match(skipped.stdout, /Skipped: entry 2/);
    assert.deepEqual(readdirSync(invalidEntry.root), ['408-WI-1.json']);
  }
  for (const value of ['{', '{}', JSON.stringify({ schemaVersion: 2, receipts: [receipt(), receipt()] })]) {
    writeFileSync(f.source, value); const r = f.run('wt'); assert.notEqual(r.status, 0); assert.ok(r.stderr.trim());
  }
  assert.equal(readdirSync(f.cwd).includes('archive'), false);
  f.put([receipt()]); assert.notEqual(f.run().status, 0); assert.notEqual(f.run('wt', 'extra').status, 0);
  writeFileSync(f.root, 'keep'); const r = f.run('wt'); assert.notEqual(r.status, 0); assert.equal(readFileSync(f.root, 'utf8'), 'keep');
});
test('empty store archives nothing successfully', () => {
  const f = fixture(); f.put([]); const r = f.run('wt'); assert.equal(r.status, 0); assert.match(r.stdout, /no receipts/i);
});
test('invalid existing archive entries refuse promptly without modification', () => {
  for (const contents of ['null', '{', '{}']) {
    const f = fixture(); f.put([receipt()]); mkdirSync(f.root);
    const file = join(f.root, '408-WI-1.json'); writeFileSync(file, contents); age(f.root); const before = snapshot(f.root);
    const r = spawnSync(process.execPath, [script, 'wt'], { ...f.options, timeout: 3000 });
    assert.equal(r.error, undefined, 'archive must not loop on an occupied invalid entry');
    assert.notEqual(r.status, 0); assert.match(r.stderr, /conflict/i); assert.deepEqual(snapshot(f.root), before);
  }
});
test('dangling symlink is occupied evidence and refuses promptly', async () => {
  const { symlinkSync, lstatSync, readlinkSync } = await import('node:fs');
  const f = fixture(); f.put([receipt()]); mkdirSync(f.root);
  const file = join(f.root, '408-WI-1.json'); symlinkSync('missing-target', file);
  const r = spawnSync(process.execPath, [script, 'wt'], { ...f.options, timeout: 3000 });
  assert.equal(r.error, undefined, 'occupied symlink must not cause an endless create retry');
  assert.notEqual(r.status, 0); assert.match(r.stderr, /conflict/i);
  assert.equal(lstatSync(file).isSymbolicLink(), true); assert.equal(readlinkSync(file), 'missing-target');
});
test('default archive root is the current home receipts directory', () => {
  const f = fixture(); f.put([receipt()]);
  const env = { ...process.env, HOME: f.cwd }; delete env.PICSEE_RECEIPT_ARCHIVE_ROOT;
  const r = spawnSync(process.execPath, [script, 'wt'], { ...f.options, env });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(JSON.parse(readFileSync(join(f.cwd, '.picsee/archive/tdd-guardian/receipts/408-WI-1.json'))), envelope('wt', receipt()));
});
test('relative roots and roots in git worktrees, including symlinked ancestors, are refused', async () => {
  const { symlinkSync, existsSync } = await import('node:fs');
  const f = fixture(); f.put([receipt()]);
  const repository = join(f.cwd, 'repository'); mkdirSync(repository);
  const init = spawnSync('git', ['init', '--quiet', repository], { encoding: 'utf8' });
  assert.equal(init.status, 0, init.stderr);
  const alias = join(f.cwd, 'alias'); symlinkSync(repository, alias);
  for (const root of ['relative', repository, join(repository, 'new/deep'), alias, join(alias, 'new/deep')]) {
    const r = spawnSync(process.execPath, [script, 'wt'], {
      ...f.options, env: { ...f.options.env, PICSEE_RECEIPT_ARCHIVE_ROOT: root },
    });
    assert.notEqual(r.status, 0, `must reject root ${root}`);
    assert.match(r.stderr, /absolute|worktree/i); assert.equal(r.stdout, '');
    assert.doesNotMatch(r.stderr, /receipt-archive-/);
  }
  assert.equal(existsSync(join(repository, '408-WI-1.json')), false);
  assert.equal(existsSync(join(repository, 'new')), false);
  assert.equal(existsSync(join(f.cwd, 'relative')), false);
  // A symlink into an external directory remains a usable override.
  mkdirSync(f.root); const external = join(f.cwd, 'external'); symlinkSync(f.root, external);
  const r = spawnSync(process.execPath, [script, 'wt'], {
    ...f.options, env: { ...f.options.env, PICSEE_RECEIPT_ARCHIVE_ROOT: join(external, 'new') },
  });
  assert.equal(r.status, 0, r.stderr); assert.equal(existsSync(join(f.root, 'new/408-WI-1.json')), true);
});
test('archive skips malformed and unverified entries and reports them without paths', () => {
  const f = fixture();
  const invalid = [
    { ...receipt('empty-spec'), test_files: {} },
    { ...receipt('bad-fingerprint'), test_files: { '/private/secret': { state: 'ok', lines: 'bad' } } },
    { ...receipt('bad-state'), test_files: { '/private/secret': { lines: [] } } },
    { ...receipt('unverified'), verified_at: null, verdict: null },
    { ...receipt('pending'), verdict: 'PENDING' },
    { ...receipt('bad-time'), verified_at: 'invalid' },
    { ...receipt('bad-red'), red: {} },
    { ...receipt('bad-lane'), lane: '' },
    { ...receipt('null-fingerprint'), test_files: { '/private/secret': null } },
    null,
  ];
  f.put([receipt(), ...invalid]); const before = readFileSync(f.source, 'utf8');
  const r = f.run('wt'); assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(readdirSync(f.root), ['408-WI-1.json']);
  for (const item of invalid.filter(Boolean)) assert.match(r.stdout, new RegExp(`Skipped: ${item.id}`));
  assert.match(r.stdout, /Skipped: entry 11/);
  assert.doesNotMatch(r.stdout + r.stderr, /\/private|secret|receipt-archive-/);
  assert.equal(readFileSync(f.source, 'utf8'), before);
  f.put([invalid[0], invalid[3]]); const retry = f.run('wt'); assert.equal(retry.status, 0);
  assert.match(retry.stdout, /Skipped: empty-spec/); assert.match(retry.stdout, /Skipped: unverified/);
});
test('a partial temporary write failure leaves no temporary archive file', () => {
  const f = fixture(); f.put([receipt()]);
  const preload = join(f.cwd, 'fail-write.mjs');
  writeFileSync(preload, `import fs from 'node:fs';\nimport { syncBuiltinESMExports } from 'node:module';\nconst original = fs.writeFileSync;\nfs.writeFileSync = function(target, data, options) {\n  if (typeof target === 'number' || String(target).endsWith('.tmp')) {\n    original(target, 'partial', options);\n    throw Object.assign(new Error('injected partial write failure'), {code:'ENOSPC'});\n  }\n  return original(target, data, options);\n};\nsyncBuiltinESMExports();\n`);
  const r = spawnSync(process.execPath, ['--import', preload, script, 'wt'], f.options);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /Cannot write/);
  assert.deepEqual(readdirSync(f.root), []);
});
test('verified terminal historical verdicts and pinned non-ok fingerprints remain intact', () => {
  const f = fixture();
  const broken = { ...receipt('broken'), verdict: 'SEPARATION-BROKEN' };
  const nonOK = { ...receipt('non-ok'), test_files: { 'test.mjs': { state: 'missing' } } };
  const unverified = [
    { ...receipt('missing-time'), verified_at: null },
    { ...receipt('missing-verdict'), verdict: null },
    { ...receipt('unknown-verdict'), verdict: 'unknown' },
  ];
  f.put([broken, nonOK, ...unverified]); const r = f.run('wt'); assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(readdirSync(f.root).sort(), ['broken.json', 'non-ok.json']);
  assert.deepEqual(JSON.parse(readFileSync(join(f.root, 'broken.json'))), envelope('wt', broken));
  assert.deepEqual(JSON.parse(readFileSync(join(f.root, 'non-ok.json'))), envelope('wt', nonOK));
});
test('worktree source cwd can archive externally and Git environment cannot conceal destination', () => {
  const f = fixture(); f.put([receipt()]);
  assert.equal(spawnSync('git', ['init', '--quiet', f.cwd]).status, 0);
  const external = mkdtempSync(join(tmpdir(), 'receipt-external-'));
  const allowed = spawnSync(process.execPath, [script, 'wt'], {
    ...f.options, env: { ...f.options.env, PICSEE_RECEIPT_ARCHIVE_ROOT: external },
  });
  assert.equal(allowed.status, 0, allowed.stderr);
  assert.deepEqual(JSON.parse(readFileSync(join(external, '408-WI-1.json'))), envelope('wt', receipt()));
  const hidden = spawnSync(process.execPath, [script, 'wt'], {
    ...f.options, env: { ...f.options.env, GIT_DIR: '/nonexistent', GIT_CEILING_DIRECTORIES: f.cwd },
  });
  assert.notEqual(hidden.status, 0); assert.match(hidden.stderr, /worktree/i);
});
test('archive refuses when Git cannot establish destination safety', () => {
  const f = fixture(); f.put([receipt()]);
  const r = spawnSync(process.execPath, [script, 'wt'], {
    ...f.options, env: { ...f.options.env, PATH: '' },
  });
  assert.notEqual(r.status, 0); assert.match(r.stderr, /Cannot establish.*outside Git worktrees/);
  assert.equal(readdirSync(f.cwd).includes('archive'), false);
});
