import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const checklistPath = 'docs/agents/interaction-lifecycle-checklist.md';
const templates = '.agents/skills/picsee-delegator/references/templates';
const briefTemplate = `${templates}/brief-template.md`;
const auditTemplate = `${templates}/audit-request-template.md`;
const implementerAgents = ['.claude/agents/opus-implementor.md', '.claude/agents/codex-implementor.md'];

const read = (path) => readFileSync(resolve(root, path), 'utf8');

// Every markdown link in `path` that names the checklist must resolve to it.
function checklistLinks(path) {
  const links = [...read(path).matchAll(/\]\(([^)\s]*interaction-lifecycle-checklist\.md)\)/g)].map((m) => m[1]);
  for (const link of links) {
    assert.equal(resolve(root, dirname(path), link), resolve(root, checklistPath), `${path}: ${link} does not resolve`);
  }
  return links;
}

// One behaviour-bearing requirement per case: a case body cannot be emptied or
// weakened without failing here. Not a copy of the prose.
const cases = [
  ['Esc', [/one Esc never closes two layers/]],
  ['Focus', [/first responder/]],
  ['Refresh', [/old content is not shown/]],
  ['Close', [/no orphaned/]],
  ['Relaunch', [/no longer exist/]],
  ['Cancel mid-load', [/cancelled or its result discarded/, /progress UI disappears/]],
  ['Tasks cancelled on close', [/\bis cancelled\b/, /released/, /cancellation flag or handle is cancelled/, /ends early/, /device run/]],
  ['Late or stale completion', [/never delivered/, /not with a sleep/]],
];

function caseBody(text, heading) {
  const start = text.search(new RegExp(`^### .*${heading}\\s*$`, 'm'));
  assert.ok(start >= 0, `case heading "${heading}" missing`);
  const rest = text.slice(start).split('\n').slice(1).join('\n');
  return rest.split(/^##/m)[0];
}

test('checklist names every lifecycle case and the four-part case shape', () => {
  assert.ok(existsSync(resolve(root, checklistPath)), `${checklistPath} missing`);
  const text = read(checklistPath);
  for (const [heading, requirements] of cases) {
    const body = caseBody(text, heading);
    for (const requirement of requirements) assert.match(body, requirement, `case "${heading}" lacks ${requirement}`);
  }
  assert.match(text, /start state → event sequence → expected result → proving test or device run/);
  assert.match(text, /`n\/a`/);
});

// Case 7 must not offer release or suppression (a missing side effect, a discarded
// result) as an alternative to cancellation, whatever the punctuation between them.
const notCancellation = String.raw`(?:releas\w*|suppress\w*|discard\w*|ignor\w*|(?:no\s+)?late\s+side\s+effects?|not\s+delivered)`;
const cancellationAlternative = new RegExp(
  String.raw`cancel\w*[\s,;:()\[\]\x60'"/—–-]*(?:\bor\b|\/)[^.]{0,60}?\b${notCancellation}` +
    String.raw`|\b${notCancellation}[\s,;:()\[\]\x60'"/—–-]*(?:\bor\b|\/)[^.]{0,20}?\bcancel`,
  'i',
);

test('the case 7 guard rejects release or suppression offered instead of cancellation', () => {
  for (const fixture of [
    'is cancelled, or released when its window closes', // gpt-auditor i410-confirm M1 counterexample
    'is cancelled or released when its window closes',
    'is cancelled (or released) when its window closes',
    'is cancelled / released when its window closes',
    'is cancelled; or\nreleased when its window closes',
    'is released or cancelled when its window closes',
    'observes the cancellation (`CancellationError`) or that no late side effect follows the close',
    'is cancelled, or its result is suppressed',
  ]) {
    assert.match(fixture, cancellationAlternative, `guard misses: ${fixture}`);
  }
});

test('tasks cancelled on close requires cancellation, not only release', () => {
  const body = caseBody(read(checklistPath), 'Tasks cancelled on close');
  assert.doesNotMatch(body, cancellationAlternative, 'release or suppression must not substitute for cancellation');
});

test('checklist points to the brief template visual rows instead of repeating them', () => {
  const text = read(checklistPath);
  assert.ok(linksTo(checklistPath, 'brief-template.md'), 'checklist must link an existing brief template');
  for (const dimension of ['zh/en', 'light/dark', '@1x/@2x']) assert.ok(text.includes(dimension), `${dimension} not named`);
  assert.doesNotMatch(text, /\| *State *\| *Selector/, 'checklist must not copy the design-derived assertion table');
});

// A relative link in `path` whose target ends in `target` and exists on disk.
function linksTo(path, target) {
  return [...read(path).matchAll(/\]\(([^)\s#]+)(?:#[^)\s]*)?\)/g)]
    .map((m) => resolve(root, dirname(path), m[1]))
    .some((abs) => abs.endsWith(`/${target}`) && existsSync(abs));
}

test('brief template has an interaction and lifecycle section linking the checklist', () => {
  const text = read(briefTemplate);
  assert.match(text, /^## Interaction & lifecycle/m, 'section heading missing');
  assert.ok(checklistLinks(briefTemplate).length >= 1, 'no link to the checklist');
  const testFirst = text.split(/^## Test-first/m)[1]?.split(/^## /m)[0] ?? '';
  assert.match(testFirst, /Interaction & lifecycle/, 'Test-first step must pull the lifecycle rows into the test matrix');
  const section = text.split(/^## Interaction & lifecycle/m)[1].split(/^## /m)[0];
  assert.match(section, /^\| *Case *\| *Start state *\| *Event sequence *\| *Expected result *\| *Proving test or device run *\|$/m,
    'brief table columns must match the checklist case shape');
});

test('audit request template asks auditors to check the lifecycle section', () => {
  const text = read(auditTemplate);
  assert.ok(checklistLinks(auditTemplate).length >= 1, 'no link to the checklist');
  assert.match(text, /Interaction & lifecycle/, 'auditors are not pointed at the brief section');
  assert.match(text, /on\s+every\s+brief/, 'auditors must check the section on every brief');
  assert.match(text, /missing (that )?section\s+is\s+(itself\s+)?a\s+finding/, 'a missing section must be a finding');
  assert.doesNotMatch(text, /when the brief has that section/, 'wording must not let auditors skip a brief without the section');
});

test('implementer agents put the lifecycle rows into the test matrix', () => {
  for (const agent of implementerAgents) {
    assert.ok(checklistLinks(agent).length >= 1 || read(agent).includes(checklistPath), `${agent} does not reference the checklist`);
  }
});
