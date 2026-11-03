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

test('checklist names every lifecycle case and the four-part case shape', () => {
  assert.ok(existsSync(resolve(root, checklistPath)), `${checklistPath} missing`);
  const text = read(checklistPath);
  for (const heading of ['Esc', 'Focus', 'Refresh', 'Close', 'Relaunch', 'Cancel mid-load', 'Tasks cancelled on close', 'Late or stale completion']) {
    assert.match(text, new RegExp(`^### .*${heading}`, 'm'), `case heading "${heading}" missing`);
  }
  assert.match(text, /start state → event sequence → expected result → proving test or device run/);
  assert.match(text, /`n\/a`/);
});

test('checklist points to the brief template visual rows instead of repeating them', () => {
  const text = read(checklistPath);
  assert.ok(checklistLinksTo(text, 'brief-template.md'), 'checklist must link the brief template');
  for (const dimension of ['zh/en', 'light/dark', '@1x/@2x']) assert.ok(text.includes(dimension), `${dimension} not named`);
  assert.doesNotMatch(text, /\| *State *\| *Selector/, 'checklist must not copy the design-derived assertion table');
});

function checklistLinksTo(text, target) {
  return [...text.matchAll(/\]\(([^)\s]+)\)/g)].some((m) => m[1].endsWith(target));
}

test('brief template has an interaction and lifecycle section linking the checklist', () => {
  const text = read(briefTemplate);
  assert.match(text, /^## Interaction & lifecycle/m, 'section heading missing');
  assert.ok(checklistLinks(briefTemplate).length >= 1, 'no link to the checklist');
  const testFirst = text.split(/^## Test-first/m)[1]?.split(/^## /m)[0] ?? '';
  assert.match(testFirst, /Interaction & lifecycle/, 'Test-first step must pull the lifecycle rows into the test matrix');
});

test('audit request template asks auditors to check the lifecycle section', () => {
  const text = read(auditTemplate);
  assert.ok(checklistLinks(auditTemplate).length >= 1, 'no link to the checklist');
  assert.match(text, /Interaction & lifecycle/, 'auditors are not pointed at the brief section');
});

test('implementer agents put the lifecycle rows into the test matrix', () => {
  for (const agent of implementerAgents) {
    assert.ok(checklistLinks(agent).length >= 1 || read(agent).includes(checklistPath), `${agent} does not reference the checklist`);
  }
});
