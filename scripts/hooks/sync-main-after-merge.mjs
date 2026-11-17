#!/usr/bin/env node
// PostToolUse(Bash): after a successful `gh pr merge`, bring the main checkout's local
// `main` up to origin/main before the next step (owner 2026-11-16: 「每次pr merge之后要将remote
// git sync 回本地，再继续」; scope: the main checkout's `main` only).
//
// It acts only in the session whose project directory IS the main worktree (the first entry of
// `git worktree list`). Implementer sessions run in their own worktrees and are skipped. It runs
// `git fetch origin` and `git merge --ff-only origin/main`, checks that local main equals
// origin/main, and tells Claude the result. A failure (network, a local edit that blocks the
// fast-forward, a main checkout on another branch) is returned as a `block` decision so the
// reason reaches Claude, who must not continue; nothing is stashed, reset, checked out or pushed.
import { spawnSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { segments, commandStart, shellScript, readHookInput, emit } from './shell-words.mjs';

const KEYWORDS = new Set(['do', 'then', 'else', 'elif', 'if', 'while', 'until', '!', '{']);
const GH_VALUE_FLAGS = new Set(['-R', '--repo']);

function ghPrMerge(words) {
  let i = 0;
  while (i < words.length && KEYWORDS.has(words[i])) i += 1;
  const rest = words.slice(i);
  const start = commandStart(rest);
  if (!start) return {};
  if (basename(rest[start.index] ?? '') !== 'gh') return { script: shellScript(rest, start.index) };
  const args = rest.slice(start.index + 1);
  let k = 0;
  while (k < args.length && args[k].startsWith('-')) k += GH_VALUE_FLAGS.has(args[k]) ? 2 : 1;
  if (args[k] !== 'pr' || args[k + 1] !== 'merge') return {};
  const tail = args.slice(k + 2);
  return { merge: !tail.some((a) => a === '-h' || a === '--help') };
}

export function isPrMerge(command, depth = 0) {
  if (depth > 4) return false;
  for (const words of segments(command)) {
    const found = ghPrMerge(words);
    if (found.merge) return true;
    if (found.script && isPrMerge(found.script, depth + 1)) return true;
  }
  return false;
}

function defaultGit(args, cwd) {
  const r = spawnSync('git', args, {
    cwd, encoding: 'utf8', timeout: args[0] === 'fetch' ? 60000 : 30000,
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
  });
  return { status: r.status ?? 1, stdout: r.stdout ?? '', stderr: r.stderr || (r.error ? String(r.error.message) : '') };
}

const same = (a, b) => {
  try { return realpathSync(a) === realpathSync(b); } catch { return a === b; }
};
const brief = (text, lines = 6) => String(text ?? '').trim().split('\n').slice(0, lines).join('\n');

function failure(what) {
  const message = `sync-main-after-merge FAILED: ${what}`;
  return {
    decision: 'block',
    reason: `${message}\nThe PR merge itself went through, but the local main checkout is not in sync. Do not continue with the ` +
      'next step until it is. Fix the cause, then run `git fetch origin && git merge --ff-only origin/main` in the main checkout. ' +
      'Nothing was stashed, reset, checked out or discarded.',
    hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: message },
  };
}

export function run(input, { env = process.env, git = defaultGit } = {}) {
  if (input?.tool_name !== 'Bash') return null;
  if (!isPrMerge(input?.tool_input?.command ?? '')) return null;
  const project = env.CLAUDE_PROJECT_DIR || input?.cwd;
  if (!project) return null;
  const list = git(['worktree', 'list', '--porcelain'], project);
  if (list.status !== 0) return null;
  const main = list.stdout.split('\n').find((l) => l.startsWith('worktree '))?.slice('worktree '.length).trim();
  if (!main || !same(project, main)) return null;

  const branch = git(['symbolic-ref', '--short', '-q', 'HEAD'], main);
  const current = branch.stdout.trim();
  if (branch.status !== 0 || current !== 'main') {
    return failure(`the main checkout is on ${current || 'a detached HEAD'}, not on main; it was not synced.`);
  }
  const fetch = git(['fetch', '--quiet', 'origin'], main);
  if (fetch.status !== 0) return failure(`git fetch origin failed (exit ${fetch.status}): ${brief(fetch.stderr, 3)}`);
  const merge = git(['merge', '--ff-only', 'origin/main'], main);
  if (merge.status !== 0) return failure(`git merge --ff-only origin/main failed: ${brief(`${merge.stderr}\n${merge.stdout}`)}`);

  const local = git(['rev-parse', 'main'], main).stdout.trim();
  const remote = git(['rev-parse', 'origin/main'], main).stdout.trim();
  if (!local || local !== remote) {
    return failure(`local main (${local.slice(0, 7) || '?'}) differs from origin/main (${remote.slice(0, 7) || '?'}) after the merge.`);
  }
  const last = git(['log', '-1', '--format=%h %s', 'main'], main).stdout.trim();
  return {
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext: `sync-main-after-merge: local main is now ${last} (= origin/main). The main checkout is in sync; continue.`,
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) emit(run(readHookInput()));
