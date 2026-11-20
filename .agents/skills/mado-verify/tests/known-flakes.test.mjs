import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Owner 2026-11-14: verification gaps — known flaky tooling tests get one recorded procedure and one list.
const root = fileURLToPath(new URL('../../../../', import.meta.url));
const skillDir = path.join(root, '.agents/skills/mado-verify');
const listFile = path.join(skillDir, 'known-flakes.json');
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

import { knownFlakeProblems } from '../scripts/known-flakes.mjs';

// #759: every entry carries issue, owner and expires (the app-quarantine.json shape); an invalid or expired entry fails
// this test, so it fails the node lane. Nothing retries a failure because of the list, and evidence.mjs never reads it.
const today = '2026-11-20';
const valid = () => ({
  file: 'scripts/tdd/unit-lane.test.mjs',
  name: 'i632M1 fallback validates a known orphan when the full interrupt process query fails',
  pattern: '^i632M1 fallback validates a known orphan when the full interrupt process query fails$',
  why: 'process-query timing on a loaded machine (fixture entry)',
  issue: 759, owner: 'delegator', expires: '2026-12-01',
});
const problems = (entry, day = today) => knownFlakeProblems({ $comment: 'x', flakes: [entry] }, { root, today: day });

test('the real known-flake list passes the entry check today (the lane check)', () => {
  const list = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  assert.ok(Array.isArray(list.flakes));
  assert.deepEqual(knownFlakeProblems(list, { root, today: new Date().toISOString().slice(0, 10) }), []);
});

test('a valid entry naming an existing test with its exact pattern passes', () => {
  assert.deepEqual(problems(valid()), []);
});

test('an entry without issue, owner or expires is rejected', () => {
  for (const field of ['issue', 'owner', 'expires']) {
    const entry = valid(); delete entry[field];
    assert.match(problems(entry).join('\n'), new RegExp(field), `missing ${field}`);
  }
  assert.match(problems({ ...valid(), issue: 0 }).join('\n'), /issue/);
  assert.match(problems({ ...valid(), issue: '759' }).join('\n'), /issue/);
  assert.match(problems({ ...valid(), owner: '  ' }).join('\n'), /owner/);
  assert.match(problems({ ...valid(), extra: 1 }).join('\n'), /extra/);
});

test('an expired entry is rejected; it is still valid on its expiry day', () => {
  assert.deepEqual(problems({ ...valid(), expires: '2026-11-20' }), []);
  assert.match(problems({ ...valid(), expires: '2026-11-19' }).join('\n'), /expired 2026-11-19/);
});

test('expires must be a real ISO date at most 30 days out', () => {
  assert.deepEqual(problems({ ...valid(), expires: '2026-12-20' }), []);
  assert.match(problems({ ...valid(), expires: '2026-12-21' }).join('\n'), /30 days/);
  assert.match(problems({ ...valid(), expires: '2026-02-30' }).join('\n'), /expires/);
  assert.match(problems({ ...valid(), expires: '2026-12-1' }).join('\n'), /expires/);
});

test('an entry must name a test in its file and rerun it with the exact anchored pattern', () => {
  assert.match(problems({ ...valid(), pattern: 'i632M1' }).join('\n'), /pattern/);
  assert.match(problems({ ...valid(), name: 'no such test name' , pattern: '^no such test name$' }).join('\n'), /not found/);
  assert.match(problems({ ...valid(), file: 'scripts/tdd/missing.test.mjs' }).join('\n'), /not found/);
  assert.match(problems({ ...valid(), why: 'short' }).join('\n'), /why/);
  const twice = knownFlakeProblems({ $comment: 'x', flakes: [valid(), valid()] }, { root, today });
  assert.match(twice.join('\n'), /duplicate/);
});

test('the list comment points App quarantine at scripts/tdd/app-quarantine.json', () => {
  const list = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  assert.match(list.$comment, /scripts\/tdd\/app-quarantine\.json/);
  assert.doesNotMatch(list.$comment, /known-flaky\.mjs/);
  assert.match(list.$comment, /issue/);
  assert.match(list.$comment, /expires/);
});

test('SKILL.md step 1 points to the list and the exact two-rerun procedure, with no gate retry', () => {
  const skill = fs.readFileSync(path.join(skillDir, 'SKILL.md'), 'utf8');
  const step1 = skill.slice(skill.indexOf('## 1. Gate ladder'), skill.indexOf('## 2.'));
  assert.match(step1, /known-flakes\.json/);
  assert.match(step1, /node --test --test-name-pattern=/);
  assert.match(step1, /exactly one known-flaky test/i);
  assert.match(step1, /twice/);
  const owner = fs.readFileSync(path.join(root, '.agents/skills/mado-delegator/scripts/owner-gates.sh'), 'utf8');
  assert.doesNotMatch(owner, /known-flakes|retry/i);
  assert.match(fs.readFileSync(path.join(root, 'docs/agents/ci-flake-repro.md'), 'utf8'), /known-flakes\.json/);
});
