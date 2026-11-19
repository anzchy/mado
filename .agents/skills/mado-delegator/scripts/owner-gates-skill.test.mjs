import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MANDATORY_GATES } from '../../mado-verify/scripts/gate-policy.mjs';

// #758: mado-verify SKILL.md must describe the lanes owner-gates.sh really runs, in its order.
const root = fileURLToPath(new URL('../../../..', import.meta.url));
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
const owner = read('.agents/skills/mado-delegator/scripts/owner-gates.sh');
const skill = read('.agents/skills/mado-verify/SKILL.md');
const step1 = skill.slice(skill.indexOf('## 1. Gate ladder'), skill.indexOf('## 2.'));
// Short messages: the step text is long and would bury the failure in the lane output.
const has = (text, re, label) => assert.ok(re.test(text), `${label}: expected ${re}`);
const lacks = (text, re, label) => assert.ok(!re.test(text), `${label}: unexpected ${re}`);

export function ownerLanes(script) {
  const lanes = [];
  for (const [, lane] of script.matchAll(/^\s*(?:.*;\s*)?lane_result ([a-z][a-z-]*) /gm)) if (!lanes.includes(lane)) lanes.push(lane);
  return lanes;
}
export function skillLanes(text) {
  const line = /^Lanes, in order: (.+)$/m.exec(text)?.[1];
  return line ? [...line.matchAll(/`([a-z][a-z-]*)`/g)].map(m => m[1]) : [];
}

test('SKILL.md lists exactly the owner-gates.sh lanes, in order', () => {
  const lanes = ownerLanes(owner);
  assert.ok(lanes.length >= 10, lanes.join(','));
  assert.deepEqual(skillLanes(step1), lanes);
  for (const gate of MANDATORY_GATES) assert.ok(lanes.includes(gate), `mandatory gate ${gate} is not an owner-gates lane`);
});

test('the lane comparison fails on a lane or an order the script does not have', () => {
  const lanes = ownerLanes(owner);
  assert.notDeepEqual(skillLanes(`Lanes, in order: ${[...lanes, 'tsan'].map(l => `\`${l}\``).join(', ')}`), lanes);
  assert.notDeepEqual(skillLanes(`Lanes, in order: ${[...lanes].reverse().map(l => `\`${l}\``).join(', ')}`), lanes);
});

test('every owner-gates flag SKILL.md names is one owner-gates.sh reads', () => {
  const flags = [...new Set([...skill.matchAll(/\b((?:OWNER_GATES|MADO_GATES)_[A-Z_]+)\b/g)].map(m => m[1]))];
  assert.ok(flags.includes('OWNER_GATES_HOSTED'), 'SKILL.md names the hosted switch');
  for (const flag of flags) has(owner, new RegExp(`\\b${flag}\\b`), `owner-gates.sh reads ${flag}`);
});

test('SKILL.md says the hosted group is skipped locally and binding on CI, with the real diffcheck order', () => {
  has(owner, /apptests-hosted=skipped \(OWNER_GATES_HOSTED=0; hosted CI binding\)/, 'owner-gates.sh');
  has(step1, /hosted CI binding/, 'SKILL.md step 1');
  has(step1, /\^MadoAppTests\\\./, 'SKILL.md step 1');
  lacks(step1, /retained MadoAppTests group plus the MadoHostedFocusTests group/, 'SKILL.md step 1');
  lacks(step1, /stop on the first failure/i, 'SKILL.md step 1');
  has(step1, /never stops at a failure/i, 'SKILL.md step 1');
});

test('SKILL.md asks for no TSan lane that does not exist and states there is no flake exception', () => {
  lacks(skill, /TSan lane via heavy-lock/, 'SKILL.md');
  has(step1, /no flake exception/i, 'SKILL.md step 1');
  for (const rel of ['.agents/skills/mado-verify/scripts/gate-policy.mjs', '.agents/skills/mado-verify/scripts/evidence.mjs'])
    lacks(read(rel), /known-flakes/, `${rel} reads no flake list`);
});

test('evidence.mjs warning does not call the local run binding for the hosted group', () => {
  const evidence = read('.agents/skills/mado-verify/scripts/evidence.mjs');
  lacks(evidence, /owner-gates run is the binding result/, 'evidence.mjs');
  has(evidence, /hosted CI binding/, 'evidence.mjs');
});
