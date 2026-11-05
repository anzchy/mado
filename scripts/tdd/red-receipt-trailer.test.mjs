import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('./red-receipt-trailer.mjs', import.meta.url));
const receipt = (id = '408-WI-1', extra = {}) => ({ id, lane: 'release-node',
  red: { red: true, kind: 'assertion-failure', reason: '/private/secret' },
  test_files: { '/private/test-a': {}, '/private/test-b': {} }, dirty_source: ['/secret/tool'],
  verified_at: '2026-11-05T00:00:00Z', verdict: 'SEPARATION-HELD', ...extra });
function fixture() {
  const cwd = mkdtempSync(join(tmpdir(), 'receipt-trailer-'));
  mkdirSync(join(cwd, '.claude/tdd-guardian'), { recursive: true });
  const source = join(cwd, '.claude/tdd-guardian/receipts.json');
  return { source, put: (receipts) => writeFileSync(source, JSON.stringify({ schemaVersion: 2, receipts })),
    run: (...args) => spawnSync(process.execPath, [script, ...args], { cwd, encoding: 'utf8' }) };
}
const line = (id, verdict = 'SEPARATION-HELD') => `Red-Receipt: ${id} release-node assertion-failure spec-files=2 ${verdict}\n`;

test('exact receipt-derived trailer omits private metadata and leaves source intact', () => {
  const f = fixture(); f.put([receipt()]); const before = readFileSync(f.source, 'utf8');
  const r = f.run(); assert.equal(r.status, 0); assert.equal(r.stdout, line('408-WI-1'));
  assert.equal(r.stderr, ''); assert.equal(readFileSync(f.source, 'utf8'), before);
});
test('multiple trailers are invariant under receipt order and private metadata changes', () => {
  const f = fixture(); f.put(['z', 'a', 'm'].map(id => receipt(id)));
  const first = f.run(); assert.equal(first.status, 0);
  assert.equal(first.stdout, ['a', 'm', 'z'].map(id => line(id)).join(''));
  f.put(['m', 'a', 'z'].map(id => receipt(id, { dirty_source: ['/different'], head_sha: 'other' })));
  assert.equal(f.run().stdout, first.stdout);
});
test('unverified receipts refuse the entire output without paths', () => {
  for (const extra of [{ verified_at: null }, { verdict: null }, { verdict: 'PENDING' },
    { verdict: 'unknown' }, { verified_at: '' }, { verified_at: 'invalid' }]) {
    const f = fixture(); f.put([receipt('a'), receipt('z', extra)]); const r = f.run();
    assert.notEqual(r.status, 0); assert.equal(r.stdout, ''); assert.match(r.stderr, /verif/i);
    assert.doesNotMatch(r.stderr, /\/private|\/secret|receipt-trailer-/);
  }
});
test('selector scopes historical evidence and broken verdict stays broken', () => {
  const f = fixture(); f.put([receipt('old', { verdict: null }), receipt('408-WI-1', { verdict: 'SEPARATION-BROKEN' })]);
  const r = f.run('--id', '408-WI-1'); assert.equal(r.status, 0);
  assert.equal(r.stdout, line('408-WI-1', 'SEPARATION-BROKEN'));
  const absent = f.run('--id', 'absent'); assert.notEqual(absent.status, 0); assert.equal(absent.stdout, '');
});
test('opaque evidence is labeled honestly and empty store prints no trailers', () => {
  const f = fixture(); f.put([receipt('opaque', { red: { red: true, kind: 'opaque-failure' } })]);
  const r = f.run(); assert.equal(r.status, 0); assert.match(r.stdout, / opaque-failure /);
  f.put([]); assert.equal(f.run().status, 0); assert.equal(f.run().stdout, '');
});
test('missing, malformed, duplicate and unsafe input refuses without leaking paths', () => {
  const f = fixture();
  const bad = [null, '{', JSON.stringify({ schemaVersion: 99, receipts: [] }),
    JSON.stringify({ schemaVersion: 2, receipts: {} }),
    ...[[receipt('a'), receipt('a')], [receipt('../escape')], [receipt('a', { lane: '/private/lane' })],
      [receipt('a\ninjected')], [receipt('a', { red: {} })], [receipt('a', { test_files: null })],
      [receipt('a', { red: { red: false, kind: 'environment-failure' } })]]
      .map(receipts => JSON.stringify({ schemaVersion: 2, receipts }))];
  for (const value of bad) {
    if (value !== null) writeFileSync(f.source, value);
    const r = f.run(); assert.notEqual(r.status, 0); assert.equal(r.stdout, '');
    assert.ok(r.stderr.trim()); assert.doesNotMatch(r.stderr, /\/private|receipt-trailer-/);
  }
  f.put([]);
  for (const args of [['--id'], ['--wat'], ['--id', 'a', '--id', 'b']]) assert.notEqual(f.run(...args).status, 0);
});
