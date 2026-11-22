import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
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

// Every `lane_result` call outside comments and the function definition, in any position (`then lane_result …`,
// `&& lane_result …`); a name that is not a literal lane (quoted, a variable) throws instead of being skipped.
export function ownerLanes(script) {
  const lanes = [];
  for (const line of script.split('\n')) {
    if (/^\s*#/.test(line)) continue;
    for (const [, arg] of line.matchAll(/(?:^|[\s;&|])lane_result(?![\w(-])\s*(\S*)/g)) {
      if (!/^[a-z][a-z-]*$/.test(arg)) throw new Error(`lane_result with a name the lane test cannot read: ${line.trim()}`);
      if (!lanes.includes(arg)) lanes.push(arg);
    }
  }
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

test('fix1 the lane extractor reads then/else lane_result calls and rejects names it cannot read', () => {
  assert.deepEqual(ownerLanes('x=1\nif true; then lane_result alpha 0; else lane_result alpha 1; fi\n  lane_result beta $?\n'), ['alpha', 'beta']);
  assert.deepEqual(ownerLanes('lane_result() {\n  local lane=$1\n}\n# lane_result gamma 0\nfoo && lane_result delta 0\n'), ['delta']);
  assert.throws(() => ownerLanes('lane_result "$name" 0\n'), /lane_result/);
  assert.throws(() => ownerLanes('if x; then lane_result $lane 0; fi\n'), /lane_result/);
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

// #804: the fake CLI returns saved pane screens and a live-shaped agent-list envelope.
const freshDir = path.join(root, '.agents/skills/mado-delegator/scripts/fixtures/fresh-codex');
const freshHelper = path.join(root, '.agents/skills/mado-delegator/scripts/start-fresh-codex.sh');
function freshScenario(scenario) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mado-fresh-codex-'));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  fs.copyFileSync(path.join(freshDir, 'fake-herdr.cjs'), path.join(bin, 'herdr'));
  fs.chmodSync(path.join(bin, 'herdr'), 0o755);
  const stateFile = path.join(dir, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({ phase: 'old', name: 'gpt-auditor', status: scenario.nonIdle ? 'working' : 'idle',
    cwd: scenario.wrongCwd ? path.join(os.homedir(), 'wrong-worktree') : path.join(os.homedir(), 'fixture-worktree'),
    reads: 0, prompts: 0, events: [] }));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MADO_FIXTURE_SCENARIO: JSON.stringify(scenario),
    MADO_FIXTURE_STATE: stateFile, MADO_FIXTURE_DIR: freshDir, MADO_FRESH_START_SECS: '0.8',
    MADO_FRESH_CONFIRM_SECS: '0.25', MADO_FRESH_POLL_SECS: '0.02' };
  const run = (...args) => spawnSync('/bin/bash', [freshHelper, ...args], { env, encoding: 'utf8', timeout: 10000 });
  const state = () => JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  return { run, state, env };
}
const startWithPrompt = f => f.run('w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), '--prompt', 'Audit #804');

test('#804 dialog shown chooses option 1 and delivers one prompt in one invocation', () => {
  const f = freshScenario({ dialog: true });
  const result = startWithPrompt(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const { events, prompts, status } = f.state();
  assert.equal(prompts, 1);
  assert.equal(status, 'working');
  assert.ok(events.indexOf('key-1') >= 0);
  assert.ok(events.indexOf('key-1') < events.indexOf('agent-prompt'));
  assert.ok(events.indexOf('agent-rename') < events.indexOf('agent-prompt'));
});

test('#804 dialog absent reaches empty Codex prompt and starts once', () => {
  const f = freshScenario({ dialog: false });
  const result = startWithPrompt(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(f.state().prompts, 1);
  assert.ok(!f.state().events.includes('key-1'));
});

test('#804 dialog appearing late is selected before the one retry', () => {
  const f = freshScenario({ dialog: false, lateDialog: true });
  const result = startWithPrompt(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const { events, prompts, status } = f.state();
  assert.equal(prompts, 2);
  assert.equal(status, 'working');
  assert.ok(events.indexOf('agent-prompt') < events.indexOf('key-1'));
  assert.ok(events.indexOf('key-1') < events.lastIndexOf('agent-prompt'));
});

test('#804 lost herdr name is restored and checked before prompting', () => {
  const f = freshScenario({ dialog: true, lostName: true });
  const result = startWithPrompt(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const { events, name, prompts } = f.state();
  assert.equal(name, 'gpt-auditor');
  assert.equal(prompts, 1);
  const beforePrompt = events.slice(0, events.indexOf('agent-prompt'));
  assert.ok(beforePrompt.indexOf('agent-rename') < beforePrompt.lastIndexOf('agent-list'));
});

test('#804 swallowed first prompt is retried once and confirmed working', () => {
  const f = freshScenario({ dialog: true, swallowFirst: true });
  const result = startWithPrompt(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(f.state().prompts, 2);
  assert.equal(f.state().status, 'working');
});

test('#804 never working exits nonzero with one-line reason after one retry', () => {
  const f = freshScenario({ dialog: true, neverStarts: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.equal(f.state().prompts, 2);
  assert.match(result.stderr + result.stdout, /never reached working/);
  assert.equal((result.stderr + result.stdout).trim().split('\n').length, 1);
});

test('#804 fix1 delayed chooser never receives a blind Enter', () => {
  const f = freshScenario({ dialog: true, delayReads: 100 });
  f.env.MADO_FRESH_START_SECS = '0.35';
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.deepEqual(f.state().events.filter(e => e === 'key-enter'), ['key-enter']);
  assert.equal(f.state().prompts, 0);
});

test('#804 fix1 wrong pane cwd refuses before prompting', () => {
  const f = freshScenario({ dialog: false, wrongCwd: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /cwd|worktree/i);
  assert.equal(f.state().prompts, 0);
});

test('#804 fix1 chooser accepting option 2 refuses wrong fresh cwd', () => {
  const f = freshScenario({ dialog: true, ignoreOne: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /cwd|worktree/i);
  assert.ok(f.state().events.includes('key-1'));
  assert.equal(f.state().prompts, 0);
});

test('#804 fix1 non-Codex and non-idle agents refuse before mutation', () => {
  for (const scenario of [{ nonCodex: true }, { nonIdle: true }]) {
    const f = freshScenario(scenario);
    const result = startWithPrompt(f);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, scenario.nonCodex ? /Codex/ : /not idle/);
    assert.equal(f.state().prompts, 0);
    assert.ok(!f.state().events.includes('send-new'));
  }
});

test('#804 fix1 failed rename refuses before prompting', () => {
  const f = freshScenario({ dialog: true, lostName: true, renameFails: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /name was not restored/);
  assert.equal(f.state().prompts, 0);
});

test('#804 fix1 duplicate agent name refuses before prompting', () => {
  const f = freshScenario({ dialog: true, duplicateName: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /duplicate|ambiguous/i);
  assert.equal(f.state().prompts, 0);
});

test('#804 fix1 accepted slow prompt is not sent twice', () => {
  const f = freshScenario({ dialog: false, acceptedSlow: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.equal(f.state().prompts, 1);
});

test('#804 fix3 option-like prompt is refused before herdr prompt', () => {
  const f = freshScenario({ dialog: false });
  const result = f.run('w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), '--prompt', '-audit #804');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /prompt.*starts with -/i);
  assert.equal(f.state().prompts, 0);
  assert.ok(!f.state().events.includes('send-new'));
});

test('#804 fix1 invalid pane bytes fail on one line', () => {
  const f = freshScenario({ invalidUtf8: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /UnicodeDecodeError/);
  assert.equal((result.stderr + result.stdout).trim().split('\n').length, 1);
});


test('#804 fix2 real fresh idle screen accepts known Codex header', () => {
  const f = freshScenario({ realIdle: true });
  const result = f.run('prompt-and-confirm', 'w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), 'Audit #804');
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(f.state().prompts, 1);
});

test('#804 fix2 popup needs visible /new and a second Enter', () => {
  const f = freshScenario({ popup: true, swallowNewEnter: true });
  const result = startWithPrompt(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(f.state().events.filter(e => e === 'key-enter').length, 2);
  assert.equal(f.state().prompts, 1);
});

test('#804 fix2 stuck /new is cleared on refusal', () => {
  const f = freshScenario({ popup: true, stuckPopup: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.ok(f.state().events.includes('key-ctrl+u'));
  assert.equal(f.state().prompts, 0);
});

test('#804 fix2 cwd refusal names screen and expected paths', () => {
  const f = freshScenario({ dialog: true, ignoreOne: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /screen cwd .*wrong-worktree.* != expected .*fixture-worktree/);
});

test('#804 followup startup tip and warning suffix allow an empty prompt', () => {
  for (const scenario of [{ startupTip: true }, { warningHint: true }]) {
    const f = freshScenario(scenario);
    const result = startWithPrompt(f);
    assert.equal(result.status, 0, JSON.stringify(scenario) + ': ' + result.stderr + result.stdout);
    assert.equal(f.state().prompts, 1);
  }
});

test('#804 followup stale transcript /new never enters or clears unrelated composer', () => {
  const f = freshScenario({ popup: true, staleNew: true, stuckPopup: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.equal(f.state().prompts, 0);
  assert.ok(!f.state().events.includes('key-enter'));
  assert.ok(!f.state().events.includes('key-ctrl+u'));
});

test('#804 followup repeated /new Enter is capped at two', () => {
  const f = freshScenario({ popup: true, stuckPopup: true });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.ok(f.state().events.filter(e => e === 'key-enter').length <= 2);
});

test('#804 followup screen cwd is independent of agent cwd', () => {
  const f = freshScenario({ screenCwd: path.join(os.homedir(), 'other-screen') });
  const result = startWithPrompt(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /screen cwd/);
  assert.equal(f.state().cwd, path.join(os.homedir(), 'fixture-worktree'));
});

test('#804 followup explicit screen cwd validates both paths', () => {
  const screen = path.join(os.homedir(), 'other-screen');
  const f = freshScenario({ screenCwd: screen });
  const result = f.run('w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), '--screen-cwd', screen, '--prompt', 'Audit #804');
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(f.state().prompts, 1);
  const wrong = freshScenario({ screenCwd: screen, wrongCwd: true });
  const rejected = wrong.run('w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), '--screen-cwd', screen, '--prompt', 'Audit #804');
  assert.notEqual(rejected.status, 0);
  assert.equal(wrong.state().prompts, 0);
  const mismatchedScreen = freshScenario({ screenCwd: screen });
  const mismatch = mismatchedScreen.run('w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), '--screen-cwd', path.join(os.homedir(), 'somewhere-else'), '--prompt', 'Audit #804');
  assert.notEqual(mismatch.status, 0);
  assert.match(mismatch.stderr, /screen cwd/);
  assert.equal(mismatchedScreen.state().prompts, 0);
  const idle = freshScenario({ realIdle: true, screenCwd: screen });
  const prompted = idle.run('prompt-and-confirm', 'w1:p5', 'gpt-auditor', '--cwd', path.join(os.homedir(), 'fixture-worktree'), '--screen-cwd', screen, 'Audit #804');
  assert.equal(prompted.status, 0, prompted.stderr + prompted.stdout);
  assert.equal(idle.state().prompts, 1);
});
