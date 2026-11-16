#!/usr/bin/env node
// PreToolUse(Bash): stage named paths only (AGENTS.md 不入库的内容). Denies
// `git add -A`, `git add --all`, `git add .` and equivalents (`./`, `:/`,
// short-flag bundles containing A), which would sweep in ignored-adjacent
// dumps, local tool state and files nobody named.
import { fileURLToPath } from 'node:url';
import { segments, gitInvocation, shellScript, commandStart, readHookInput, deny, emit } from './shell-words.mjs';

const WHOLE_TREE = new Set(['.', './', ':/', ':/.', '*']);

function badAdd(args) {
  for (const a of args) {
    if (a === '--') continue;
    if (a === '--all' || a === '--no-ignore-removal') return a;
    if (/^-[a-zA-Z]*A[a-zA-Z]*$/.test(a)) return a;
    if (WHOLE_TREE.has(a)) return a;
  }
  return null;
}

export function findViolation(command, depth = 0) {
  if (depth > 4) return null;
  for (const words of segments(command)) {
    const git = gitInvocation(words);
    if (git && git.sub === 'add') {
      const bad = badAdd(git.args);
      if (bad) return bad;
    }
    const { index } = commandStart(words);
    const script = shellScript(words, index);
    if (script) {
      const nested = findViolation(script, depth + 1);
      if (nested) return nested;
    }
  }
  return null;
}

export function decide(input) {
  if (input?.tool_name !== 'Bash') return null;
  const bad = findViolation(input?.tool_input?.command ?? '');
  return bad
    ? deny(`\`git add ${bad}\` stages paths nobody named. Stage each path by name (AGENTS.md: 只暂存你能逐个说出名字的路径); the tree holds dumps with third-party keys and local tool state.`)
    : null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) emit(decide(readHookInput()));
