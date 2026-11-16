#!/usr/bin/env node
// PreToolUse(Edit|Write|MultiEdit): before a change under App/ or
// Packages/MadoKit/Sources/MadoMacUI/, remind Claude where the UI rules live
// (AGENTS.md 按需阅读: UI、颜色、间距、组件). Adds context only; never denies.
import { existsSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readHookInput, context, emit } from './shell-words.mjs';

const UI_PREFIXES = ['App/', 'Packages/MadoKit/Sources/MadoMacUI/'];
export const UI_CONTEXT = 'UI change: read design/DESIGN.md and docs/agents/ui-parity-contract.md first (AGENTS.md 按需阅读: UI、颜色、间距、组件).';

function repoRoot(file) {
  let dir = dirname(file);
  for (;;) {
    if (existsSync(resolve(dir, '.git'))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

export function isUiPath(file, cwd, findRoot = repoRoot) {
  if (!file) return false;
  const abs = isAbsolute(file) ? file : resolve(cwd || process.cwd(), file);
  const root = findRoot(abs);
  if (!root) return false;
  const rel = relative(root, abs).split(sep).join('/');
  return UI_PREFIXES.some((p) => rel.startsWith(p));
}

export function decide(input, findRoot = repoRoot) {
  if (!['Edit', 'Write', 'MultiEdit'].includes(input?.tool_name)) return null;
  return isUiPath(input?.tool_input?.file_path, input?.cwd, findRoot) ? context(UI_CONTEXT) : null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) emit(decide(readHookInput()));
