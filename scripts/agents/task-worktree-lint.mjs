#!/usr/bin/env node
// #901 (owner 2026-11-25): 「每个任务单独的worktree(对于implementor来说）… 必要的话，看看能否增加lint」.
// The written instructions keep the one-task-one-worktree rule so they cannot drift back to pane-home worktrees:
// - the brief template has the rule and a `Worktree: …picsee-wt/<issue>-<slug>` line;
// - the delegator SKILL dispatch step (step 2) has the rule and the picsee-wt/<issue>-<slug> placeholder;
// - no template names a pane-home worktree (picsee-wt/<implementer>, picsee-wt/gpt-imple-1, …) and no implementer
//   definition's "Work only in" line points at one.
// Runtime enforcement is separate: mark-target.mjs and evidence.mjs check (.agents/skills/mado-verify/scripts).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const RULE = 'One task, one worktree';
export const PLACEHOLDER = 'picsee-wt/<issue>-<slug>';
const TEMPLATES = '.agents/skills/mado-delegator/references/templates';
const AGENTS = ['.claude/agents/opus-implementor.md', '.claude/agents/codex-implementor.md'];
// picsee-wt/<anything but issue-slug> or picsee-wt/<pane-name>, with an optional -<n> or -N suffix.
const PANE_REF = /picsee-wt\/(?:<(?!issue>-<slug>)[^>\s]+>|[a-z][a-z0-9]*-(?:imple|implementor|implementer|auditor|planner|researcher)(?:-(?:[0-9]+|<n>))?(?![\w<-]))/g;

const paneRefs = text => [...new Set(text.match(PANE_REF) ?? [])];
const hasRule = text => text.toLowerCase().includes(RULE.toLowerCase());

function step(skill, n) {
  const start = skill.indexOf(`\n${n}. **`);
  if (start === -1 && !skill.startsWith(`${n}. **`)) return null;
  const from = start === -1 ? 0 : start + 1;
  const next = skill.indexOf(`\n${n + 1}. **`, from);
  return skill.slice(from, next === -1 ? undefined : next);
}

// files: { brief, skill, templates: {name: text}, agents: {name: text} } → problem strings (empty when clean).
export function lintTaskWorktree({ brief, skill, templates = {}, agents = {} }) {
  const problems = [];
  if (!hasRule(brief)) problems.push(`brief template: missing the rule "${RULE}"`);
  if (!/^Worktree: `?~\/Documents\/mac-app\/picsee-wt\/<issue>-<slug>`?/m.test(brief))
    problems.push(`brief template: no \`Worktree: ~/Documents/mac-app/${PLACEHOLDER}\` line`);
  for (const ref of paneRefs(brief)) problems.push(`brief template: names the pane-home worktree ${ref} as the place to work; use ${PLACEHOLDER}`);
  const dispatch = step(skill, 2);
  if (dispatch === null) problems.push('SKILL.md: no step 2 (the dispatch step)');
  else {
    if (!hasRule(dispatch)) problems.push(`SKILL.md step 2: missing the rule "${RULE}"`);
    if (!dispatch.includes(PLACEHOLDER)) problems.push(`SKILL.md step 2: no ${PLACEHOLDER} placeholder`);
  }
  for (const [name, text] of Object.entries(templates))
    for (const ref of paneRefs(text)) problems.push(`${name}: names the pane-home worktree ${ref}; tasks run in ${PLACEHOLDER}`);
  for (const [name, text] of Object.entries(agents))
    for (const line of text.split('\n').filter(l => /Work only in/.test(l)))
      for (const ref of paneRefs(line)) problems.push(`${name}: "Work only in" names the pane-home worktree ${ref}; tasks run in ${PLACEHOLDER}`);
  return problems;
}

export function repoFiles(root) {
  const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
  const dir = path.join(root, TEMPLATES);
  const templates = Object.fromEntries(fs.readdirSync(dir).filter(n => n.endsWith('.md') && n !== 'brief-template.md').sort()
    .map(n => [n, fs.readFileSync(path.join(dir, n), 'utf8')]));
  const agents = Object.fromEntries(AGENTS.filter(rel => fs.existsSync(path.join(root, rel))).map(rel => [path.basename(rel), read(rel)]));
  return { brief: read(`${TEMPLATES}/brief-template.md`), skill: read('.agents/skills/mado-delegator/SKILL.md'), templates, agents };
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const problems = lintTaskWorktree(repoFiles(root));
  for (const problem of problems) console.error(`task-worktree-lint: ${problem}`);
  if (problems.length) process.exitCode = 1;
  else console.log('task-worktree-lint: OK');
}
