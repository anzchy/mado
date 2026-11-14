// #705 WI-3: a fixture budget is both the timeout under test and a wait for
// process startup. runEscalating repeats an attempt with a longer budget only
// when it proved nothing (no PID evidence and the supervisor reported an
// execution timeout); stop bounds are measured from the event, not the spawn.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { STARTUP_FACTORS, provedNothing, runEscalating, withinBound, attemptFacts } from './escalation.mjs';

const nothing = { verdict: 'fail', evidence: false, executionTimeout: true };
const pass = { verdict: 'pass', evidence: true, executionTimeout: false };
const evidenceFail = { verdict: 'fail', evidence: true, executionTimeout: true };
const noTimeoutFail = { verdict: 'fail', evidence: false, executionTimeout: false };
function scripted(results) {
  const budgets = [], lasts = [];
  let i = 0;
  const attempt = async (budget, { last }) => { budgets.push(budget); lasts.push(last); const r = results[i++]; if (r instanceof Error) throw r; return r; };
  return { attempt, budgets, lasts, consumed: () => i };
}
function mulberry32(seed) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}

test('escalation: factors are 1, 4, 16, 64', () => { assert.deepEqual(STARTUP_FACTORS, [1, 4, 16, 64]); });

test('escalation: an attempt that proves something runs once', async () => {
  const s = scripted([pass, pass]);
  const r = await runEscalating(s.attempt, { baseMs: 350 });
  assert.equal(r.verdict, 'pass'); assert.deepEqual(r.budgets, [350]); assert.deepEqual(s.budgets, [350]); assert.deepEqual(s.lasts, [false]);
});

test('escalation: proved nothing twice, then proof at 16x', async () => {
  const s = scripted([nothing, nothing, pass, pass]);
  const r = await runEscalating(s.attempt, { baseMs: 350 });
  assert.equal(r.verdict, 'pass'); assert.deepEqual(s.budgets, [350, 1400, 5600]); assert.deepEqual(r.budgets, [350, 1400, 5600]);
  assert.deepEqual(s.lasts, [false, false, false]);
});

test('escalation: evidence with a failure, a non-timeout failure or a thrown assertion is never retried', async () => {
  for (const first of [evidenceFail, noTimeoutFail]) {
    const s = scripted([first, pass]);
    const r = await runEscalating(s.attempt, { baseMs: 500 });
    assert.equal(r.verdict, 'fail'); assert.equal(s.consumed(), 1); assert.deepEqual(r.budgets, [500]);
  }
  const s = scripted([new assert.AssertionError({ message: 'survivor' }), pass]);
  await assert.rejects(runEscalating(s.attempt, { baseMs: 500 }), /survivor/);
  assert.equal(s.consumed(), 1);
});

test('escalation: proving nothing at 64x fails and stops', async () => {
  const s = scripted([nothing, nothing, nothing, nothing, pass]);
  const r = await runEscalating(s.attempt, { baseMs: 350 });
  assert.equal(r.verdict, 'fail'); assert.match(r.reason, /64×/);
  assert.equal(s.consumed(), 4); assert.deepEqual(s.budgets, [350, 1400, 5600, 22400]); assert.deepEqual(s.lasts, [false, false, false, true]);
});

test('escalation law over seeded scripted sequences', async () => {
  const kinds = [nothing, pass, evidenceFail, noTimeoutFail];
  for (const seed of [1, 7, 705, 2026]) {
    const random = mulberry32(seed);
    for (let i = 0; i < 250; i++) {
      const sequence = Array.from({ length: 1 + Math.floor(random() * 6) }, () => kinds[Math.floor(random() * kinds.length)]);
      while (sequence.length < 5) sequence.push(pass);
      const base = 1 + Math.floor(random() * 1000);
      const s = scripted(sequence);
      const r = await runEscalating(s.attempt, { baseMs: base });
      // Oracle: the first of the first four entries that proved something decides; otherwise fail.
      const k = sequence.slice(0, 4).findIndex(x => x !== nothing);
      const calls = k === -1 ? 4 : k + 1;
      assert.equal(s.consumed(), calls, `seed ${seed}/${i}`);
      assert.deepEqual(s.budgets, [1, 4, 16, 64].slice(0, calls).map(f => f * base), `seed ${seed}/${i}`);
      assert.ok(s.budgets.every((b, j) => j === 0 || b > s.budgets[j - 1]) && s.budgets.at(-1) <= 64 * base);
      assert.equal(r.verdict, k === -1 ? 'fail' : sequence[k].verdict, `seed ${seed}/${i}`);
      assert.equal(provedNothing(sequence[0]), sequence[0] === nothing);
    }
  }
});

test('stop bound depends only on event-to-exit time, never on the spawn time', () => {
  for (const seed of [3, 705]) {
    const random = mulberry32(seed);
    for (let i = 0; i < 200; i++) {
      const bound = 1500 + Math.floor(random() * 3000), shift = Math.floor(random() * 30000), spawnedAt = 1_000_000;
      const eventAt = spawnedAt + shift;
      assert.equal(withinBound(eventAt, eventAt + bound - 1000, bound), true, `inside seed ${seed}/${i}`);
      assert.equal(withinBound(eventAt, eventAt + bound + 1000, bound), false, `outside seed ${seed}/${i}`);
    }
  }
  assert.equal(withinBound(100, 100 + 1450, 1450), false, 'the bound is exclusive');
  for (const [eventAt, exitedAt] of [[NaN, 5], [5, NaN], [10, 5], [undefined, 5], [0, 5]])
    assert.equal(withinBound(eventAt, exitedAt, 1000), false, `${eventAt}→${exitedAt}`);
});

test('attemptFacts: PID evidence comes only from a complete published PID', t => {
  const dir = mkdtempSync(path.join(tmpdir(), 'i705-esc-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = (name, content) => { const p = path.join(dir, name); if (content !== null) writeFileSync(p, content); return p; };
  const timeout = 'app-lane inventory command failed: execution timeout\n';
  assert.deepEqual(attemptFacts({ pidFiles: [file('a', String(process.pid))], stderr: timeout }), { evidence: true, executionTimeout: true });
  assert.deepEqual(attemptFacts({ pidFiles: [file('b', null)], stderr: timeout }), { evidence: false, executionTimeout: true });
  assert.deepEqual(attemptFacts({ pidFiles: [file('c', '')], stderr: '' }), { evidence: false, executionTimeout: false });
  assert.deepEqual(attemptFacts({ listFiles: [file('d', '[')], stderr: '[heavy-lock] execution timeout after 0.5 s' }), { evidence: false, executionTimeout: true });
  assert.deepEqual(attemptFacts({ listFiles: [file('e', '[]')], stderr: timeout }), { evidence: false, executionTimeout: true });
  assert.deepEqual(attemptFacts({ listFiles: [file('f', '[42]')], stderr: 'cancelled' }), { evidence: true, executionTimeout: false });
  assert.deepEqual(attemptFacts({ pidFiles: [file('g', null), file('h', '7')], stderr: 'timeout' }), { evidence: true, executionTimeout: false });
});
