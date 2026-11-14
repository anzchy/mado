#!/usr/bin/env node
// Dispatch writes the target identity; implementers must not rewrite it.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// Optional <branch>: the task branch the implementer will work on; preferred over the worktree's current branch.
const [paneHome, worktree, issueRaw, task, handoff, explicitBranch] = process.argv.slice(2);
function git(at, ...args) {
  const result = spawnSync('git', args, { cwd: at, encoding: 'utf8', timeout: 1000 });
  if (result.status !== 0) throw new Error(result.stderr.trim() || `git ${args[0]} failed`);
  return result.stdout.trim();
}
try {
  const issue = Number(issueRaw);
  if (!paneHome || !worktree || !handoff || !path.isAbsolute(paneHome) || !path.isAbsolute(worktree) || !path.isAbsolute(handoff) || !Number.isSafeInteger(issue) || issue < 1 || !task || !/^[A-Za-z0-9._-]+$/.test(task)) throw new Error('usage: mark-target.mjs <pane-home> <worktree> <issue> <task> <handoff> [branch]');
  const home = fs.realpathSync(paneHome), target = fs.realpathSync(worktree);
  if (fs.realpathSync(git(home, 'rev-parse', '--show-toplevel')) !== home || fs.realpathSync(git(target, 'rev-parse', '--show-toplevel')) !== target) throw new Error('both paths must be worktree roots');
  if (fs.realpathSync(git(home, 'rev-parse', '--path-format=absolute', '--git-common-dir')) !== fs.realpathSync(git(target, 'rev-parse', '--path-format=absolute', '--git-common-dir'))) throw new Error('target must be a worktree of the pane-home repository');
  if (explicitBranch !== undefined && spawnSync('git', ['check-ref-format', '--branch', explicitBranch], { encoding: 'utf8' }).status !== 0) throw new Error(`invalid branch name: ${explicitBranch}`);
  const branch = explicitBranch ?? git(target, 'symbolic-ref', '-q', '--short', 'HEAD');
  const marker = path.join(home, '.build/mado-verify/target-worktree');
  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.writeFileSync(marker, JSON.stringify({ worktree: target, branch, issue, task, handoff }) + '\n');
  console.log(marker);
} catch (error) { console.error(error.message); process.exitCode = 1; }
