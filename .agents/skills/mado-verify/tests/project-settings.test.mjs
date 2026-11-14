import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Owner 2026-11-14: 「mado-verify skill顺着查下去，不需要hook」. The record check is a manual delegator command.
const root = fileURLToPath(new URL('../../../../', import.meta.url));

test('project Claude settings register no Stop hook and keep the plugin', () => {
  const settings = JSON.parse(fs.readFileSync(path.join(root, '.claude/settings.json'), 'utf8'));
  assert.equal(settings.enabledPlugins['tdd-guardian@xiaolai'], true);
  assert.equal(settings.hooks, undefined);
  assert.doesNotMatch(JSON.stringify(settings), /mado-verify|stop-hook/);
});

test('no Codex hooks file or implementer frontmatter hook runs mado-verify', () => {
  const codexHooks = path.join(root, '.codex/hooks.json');
  if (fs.existsSync(codexHooks)) assert.doesNotMatch(fs.readFileSync(codexHooks, 'utf8'), /mado-verify|stop-hook/);
  for (const name of ['opus-implementor', 'codex-implementor']) {
    const frontmatter = fs.readFileSync(path.join(root, '.claude/agents', `${name}.md`), 'utf8').split('---')[1];
    assert.doesNotMatch(frontmatter, /^hooks:/m, name);
    assert.doesNotMatch(frontmatter, /stop-hook|mado-verify/, name);
  }
  assert.equal(fs.existsSync(path.join(root, '.agents/skills/mado-verify/scripts/stop-hook.mjs')), false);
});

test('SKILL.md names the manual record check and no hook', () => {
  const skill = fs.readFileSync(path.join(root, '.agents/skills/mado-verify/SKILL.md'), 'utf8');
  assert.match(skill, /evidence\.mjs check --head <sha>/);
  assert.doesNotMatch(skill, /Stop hook|stop-hook|hooks\.json/);
});
