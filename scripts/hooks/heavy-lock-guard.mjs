#!/usr/bin/env node
// PreToolUse(Bash): heavy jobs go under scripts/heavy-lock.sh (AGENTS.md 命令;
// docs/agents/heavy-lock.md). Denies `swift test`, `xcodebuild` and `xcodegen`
// unless scripts/heavy-lock.sh wraps them in the same simple command. The
// scripts/tdd/*-lane.mjs lanes and tdd-guardian receipt.js record/verify take
// the lock themselves and pass untouched; wrapping trash-lane.mjs in
// heavy-lock.sh is denied (docs/agents/test-lanes.md: 不要用外层包它).
// PICSEE_HEAVY_LOCK_HELD=1 written in the command is not an exemption: it is
// only a nesting hint and a Bash tool call has no parent lock FD.
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { segments, commandStart, shellScript, readHookInput, deny, emit } from './shell-words.mjs';

const XCODEBUILD_LIGHT = new Set(['-version', '-showsdks', '-help', '-usage', '-checkFirstLaunchStatus']);
const XCODEGEN_LIGHT = new Set(['--version', 'version', '--help', '-h', 'help']);

function heavyKind(words, index) {
  const cmd = basename(words[index] ?? '');
  const args = words.slice(index + 1);
  if (cmd === 'swift') {
    // `swift test …` or `swift --package-path P test …`; flag values precede the subcommand.
    return args.includes('test') ? 'swift test' : null;
  }
  if (cmd === 'xcodebuild') {
    return args.length > 0 && args.every((a) => XCODEBUILD_LIGHT.has(a)) ? null : 'xcodebuild';
  }
  if (cmd === 'xcodegen') {
    return args.length > 0 && args.every((a) => XCODEGEN_LIGHT.has(a)) ? null : 'xcodegen';
  }
  return null;
}

export function findViolation(command, depth = 0) {
  if (depth > 4) return null;
  for (const words of segments(command)) {
    const { index, wrappers } = commandStart(words);
    const locked = wrappers.includes('heavy-lock.sh');
    const cmdWord = words[index] ?? '';
    if (locked && basename(cmdWord) === 'node' && words.slice(index + 1).some((w) => basename(w) === 'trash-lane.mjs')) {
      return { kind: 'trash-lane', message: '`scripts/tdd/trash-lane.mjs` takes the heavy lock itself; run `node scripts/tdd/trash-lane.mjs` without the outer `scripts/heavy-lock.sh` (docs/agents/test-lanes.md).' };
    }
    if (locked) continue;
    const kind = heavyKind(words, index);
    if (kind) {
      return {
        kind,
        message: `\`${kind}\` is a heavy job: run it as \`scripts/heavy-lock.sh ${words.slice(index).join(' ')}\`, in the foreground, one heavy command per call. scripts/tdd/*-lane.mjs and receipt.js lanes take the lock themselves and need no wrapper. Stuck lock or timeout: read docs/agents/heavy-lock.md first; never delete heavy.lock.`,
      };
    }
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
  const violation = findViolation(input?.tool_input?.command ?? '');
  return violation ? deny(violation.message) : null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) emit(decide(readHookInput()));
