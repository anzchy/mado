import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { decide, UI_CONTEXT } from './ui-design-pointer.mjs';

const script = fileURLToPath(new URL('./ui-design-pointer.mjs', import.meta.url));
const repoRoot = fileURLToPath(new URL('../..', import.meta.url)).replace(/\/$/, '');
const root = () => '/wt';
const edit = (file_path, tool_name = 'Edit') => ({ hook_event_name: 'PreToolUse', tool_name, tool_input: { file_path }, cwd: '/wt' });

test('UI paths get context and no decision', () => {
  for (const f of ['/wt/App/MadoApp.swift', '/wt/Packages/MadoKit/Sources/MadoMacUI/Viewer/Canvas.swift', 'App/Info.plist']) {
    for (const tool of ['Edit', 'Write', 'MultiEdit']) {
      const r = decide(edit(f, tool), root);
      assert.equal(r?.hookSpecificOutput?.additionalContext, UI_CONTEXT, `${tool} ${f}`);
      assert.equal(r.hookSpecificOutput.hookEventName, 'PreToolUse');
      assert.equal(r.hookSpecificOutput.permissionDecision, undefined);
    }
  }
  assert.match(UI_CONTEXT, /design\/DESIGN\.md/);
  assert.match(UI_CONTEXT, /docs\/agents\/ui-parity-contract\.md/);
});

test('other paths and tools get nothing', () => {
  for (const f of ['/wt/Packages/MadoKit/Sources/MadoCore/Item.swift', '/wt/AppTests/x.swift', '/wt/docs/App/x.md', '/wt/AGENTS.md']) {
    assert.equal(decide(edit(f), root), null, f);
  }
  assert.equal(decide({ tool_name: 'Read', tool_input: { file_path: '/wt/App/x.swift' } }, root), null);
  assert.equal(decide(edit('/elsewhere/App/x.swift'), () => null), null);
});

test('end to end with the real repository root', () => {
  const input = edit(`${repoRoot}/App/Sources/Example.swift`, 'Write');
  const r = spawnSync(process.execPath, [script], { input: JSON.stringify(input), encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.additionalContext, UI_CONTEXT);
  const other = spawnSync(process.execPath, [script], { input: JSON.stringify(edit(`${repoRoot}/AGENTS.md`)), encoding: 'utf8' });
  assert.equal(other.stdout, '');
});
