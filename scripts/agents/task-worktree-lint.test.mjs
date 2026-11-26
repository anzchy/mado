import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { lintTaskWorktree, repoFiles } from './task-worktree-lint.mjs';

// #901 (owner 2026-11-25): 「…看看能否增加lint」. CI runs this in the Agent tooling job: the brief template and the
// delegator SKILL dispatch step keep the one-task-one-worktree rule and the picsee-wt/<issue>-<slug> placeholder, and no
// template or implementer definition names a pane-home worktree as the place to work.
const root = fileURLToPath(new URL('../../', import.meta.url));
const lint = path.join(root, 'scripts/agents/task-worktree-lint.mjs');

const good = () => ({
  brief: 'You are **<implementer>**.\nWorktree: `~/Documents/mac-app/picsee-wt/<issue>-<slug>`. One task, one worktree: never a pane home.\n',
  skill: '1. **Issue** — x\n2. **Brief** — copy. One task, one worktree: `~/Documents/mac-app/picsee-wt/<issue>-<slug>` from origin/main.\n3. **Watch** — y\n',
  templates: { 'audit-request-template.md': 'worktree ~/Documents/mac-app/picsee-wt/<issue>-<slug>\n', 'audit-brief.md': '--cwd <auditor-worktree>\n' },
  agents: { 'opus-implementor.md': '- One item per session. Work only in the task worktree `~/Documents/mac-app/picsee-wt/<issue>-<slug>` the brief names.\n' },
});

test('#901 the checked-in delegator texts pass the lint', () => {
  assert.deepEqual(lintTaskWorktree(repoFiles(root)), []);
  const r = spawnSync(process.execPath, [lint], { cwd: root, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr + r.stdout);
});

test('#901 a clean fixture passes', () => {
  assert.deepEqual(lintTaskWorktree(good()), []);
});

test('#901 a template that still names a pane home as the place to work fails', () => {
  for (const text of ['worktree ~/Documents/mac-app/picsee-wt/<implementer>.', 'Worktree `~/Documents/mac-app/picsee-wt/<pane>`',
    'cd ~/Documents/mac-app/picsee-wt/gpt-imple-1 first', 'picsee-wt/opus-imple-<n>']) {
    const files = good();
    files.templates['brief-template.md'] = text;
    const problems = lintTaskWorktree(files);
    assert.equal(problems.length, 1, text);
    assert.match(problems[0], /brief-template\.md.*pane-home worktree/, text);
  }
});

test('#901 the brief template needs the Worktree placeholder and the rule', () => {
  const noPlaceholder = good();
  noPlaceholder.brief = 'One task, one worktree.\nWorktree `~/Documents/mac-app/picsee-wt/<implementer>`.\n';
  const problems = lintTaskWorktree(noPlaceholder);
  assert.ok(problems.some(p => /brief template: no `Worktree: .*picsee-wt\/<issue>-<slug>/.test(p)), problems.join('\n'));
  assert.ok(problems.some(p => /brief template: .*pane-home worktree/.test(p)), problems.join('\n'));
  const noRule = good();
  noRule.brief = 'Worktree: `~/Documents/mac-app/picsee-wt/<issue>-<slug>`.\n';
  assert.match(lintTaskWorktree(noRule).join('\n'), /brief template: missing the rule "One task, one worktree"/);
});

test('#901 the SKILL dispatch step (step 2) needs the rule and the placeholder', () => {
  const files = good();
  files.skill = '2. **Brief** — copy the template.\n3. **Watch** — One task, one worktree: picsee-wt/<issue>-<slug>.\n';
  const problems = lintTaskWorktree(files).join('\n');
  assert.match(problems, /SKILL\.md step 2: missing the rule/);
  assert.match(problems, /SKILL\.md step 2: no picsee-wt\/<issue>-<slug>/);
  const missing = good();
  missing.skill = 'no numbered steps';
  assert.match(lintTaskWorktree(missing).join('\n'), /SKILL\.md: no step 2/);
});

test('#901 an implementer definition that works in its pane worktree fails', () => {
  const files = good();
  files.agents['codex-implementor.md'] = '- One item per session. Work only in your worktree `~/Documents/mac-app/picsee-wt/<pane>` on the branch.\n';
  assert.match(lintTaskWorktree(files).join('\n'), /codex-implementor\.md.*pane-home worktree/);
});

test('#901 fix1 (gpt M2, opus L4) the rule and the placeholder count only as live text, not inside comments', () => {
  const briefInHtml = good();
  briefInHtml.brief = '<!-- One task, one worktree\nWorktree: `~/Documents/mac-app/picsee-wt/<issue>-<slug>` -->\nWork only in the pane home.\n';
  const brief = lintTaskWorktree(briefInHtml).join('\n');
  assert.match(brief, /brief template: missing the rule/);
  assert.match(brief, /brief template: no `Worktree:/);
  const skillInHtml = good();
  skillInHtml.skill = '1. **Issue** — x\n2. **Brief** — copy. <!-- One task, one worktree: picsee-wt/<issue>-<slug> --> Work in the pane home.\n3. **Watch** — y\n';
  const skill = lintTaskWorktree(skillInHtml).join('\n');
  assert.match(skill, /SKILL\.md step 2: missing the rule/);
  assert.match(skill, /SKILL\.md step 2: no picsee-wt\/<issue>-<slug>/);
  const shell = good();
  shell.brief = 'Worktree: `~/Documents/mac-app/picsee-wt/<issue>-<slug>`.\n```sh\n# One task, one worktree\ncd "$pane_home"\n```\n';
  assert.match(lintTaskWorktree(shell).join('\n'), /brief template: missing the rule/);
  // Live text next to a comment still counts.
  const live = good();
  live.brief = `<!-- note -->\n${live.brief}`;
  assert.deepEqual(lintTaskWorktree(live), []);
});
