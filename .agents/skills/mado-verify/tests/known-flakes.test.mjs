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

test('known-flake list names existing node tests with exact rerun patterns', () => {
  const list = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  assert.ok(Array.isArray(list.flakes) && list.flakes.length >= 4);
  assert.match(list.$comment, /twice/);
  const names = new Set();
  for (const flake of list.flakes) {
    assert.deepEqual(Object.keys(flake).sort(), ['file', 'name', 'pattern', 'why']);
    assert.ok(!names.has(flake.name), `duplicate ${flake.name}`); names.add(flake.name);
    const source = fs.readFileSync(path.join(root, flake.file), 'utf8');
    const mode = flake.name.match(/^(.*) \(([a-z-]+)\)$/);
    assert.ok(source.includes(flake.name) || (mode && source.includes(`${mode[1]} (\${mode})`) && source.includes(`'${mode[2]}'`)), flake.name);
    assert.equal(flake.pattern, `^${escape(flake.name)}$`);
    assert.ok(new RegExp(flake.pattern).test(flake.name));
    assert.ok(flake.why.length > 10);
  }
  for (const expected of ['discoveryOuterCancelAndTimeoutDrainRegisteredGroup',
    'discovery does not accept successful root exit while a pipe-less descendant remains alive',
    'i632M1 fallback validates a known orphan when the full interrupt process query fails']) assert.ok(names.has(expected), expected);
});

test('SKILL.md step 1 points to the list and the exact two-rerun procedure, with no gate retry', () => {
  const skill = fs.readFileSync(path.join(skillDir, 'SKILL.md'), 'utf8');
  const step1 = skill.slice(skill.indexOf('## 1. Gate ladder'), skill.indexOf('## 2.'));
  assert.match(step1, /known-flakes\.json/);
  assert.match(step1, /node --test --test-name-pattern=/);
  assert.match(step1, /exactly one known-flaky test/i);
  assert.match(step1, /twice/);
  const owner = fs.readFileSync(path.join(root, '.agents/skills/picsee-delegator/scripts/owner-gates.sh'), 'utf8');
  assert.doesNotMatch(owner, /known-flakes|retry/i);
  assert.match(fs.readFileSync(path.join(root, 'docs/agents/ci-flake-repro.md'), 'utf8'), /known-flakes\.json/);
});
