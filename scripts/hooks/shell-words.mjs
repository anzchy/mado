// Minimal shell splitter for Claude Code PreToolUse hooks. No dependencies.
// Splits a Bash command into simple-command segments (word arrays), honouring
// quotes, backslashes, comments, operators (; & | && || newline, parentheses)
// and here-documents, whose bodies are skipped. It does not expand anything;
// it only has to find the command words a hook cares about.
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';

export function segments(command) {
  const out = [];
  let words = [];
  let word = '';
  let inWord = false;
  const pendingHeredocs = [];
  const flushWord = () => {
    if (inWord) words.push(word);
    word = '';
    inWord = false;
  };
  const flushSegment = () => {
    flushWord();
    if (words.length) out.push(words);
    words = [];
  };
  const s = String(command ?? '');
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === '\\') {
      if (s[i + 1] === '\n') { i += 2; continue; }
      word += s[i + 1] ?? '';
      inWord = true;
      i += 2;
      continue;
    }
    if (c === "'") {
      const end = s.indexOf("'", i + 1);
      const stop = end === -1 ? s.length : end;
      word += s.slice(i + 1, stop);
      inWord = true;
      i = stop + 1;
      continue;
    }
    if (c === '"') {
      i += 1;
      while (i < s.length && s[i] !== '"') {
        if (s[i] === '\\' && i + 1 < s.length && '"\\$`\n'.includes(s[i + 1])) {
          if (s[i + 1] !== '\n') word += s[i + 1];
          i += 2;
        } else {
          word += s[i];
          i += 1;
        }
      }
      inWord = true;
      i += 1;
      continue;
    }
    if (c === '#' && !inWord) {
      while (i < s.length && s[i] !== '\n') i += 1;
      continue;
    }
    if (c === '<' && s[i + 1] === '<' && s[i + 2] !== '<') {
      flushWord();
      i += 2;
      let strip = false;
      if (s[i] === '-') { strip = true; i += 1; }
      while (s[i] === ' ' || s[i] === '\t') i += 1;
      let delim = '';
      while (i < s.length && !/[\s;&|()<>]/.test(s[i])) {
        if (s[i] === "'" || s[i] === '"') {
          const q = s[i];
          const end = s.indexOf(q, i + 1);
          const stop = end === -1 ? s.length : end;
          delim += s.slice(i + 1, stop);
          i = stop + 1;
        } else if (s[i] === '\\') {
          delim += s[i + 1] ?? '';
          i += 2;
        } else {
          delim += s[i];
          i += 1;
        }
      }
      if (delim) pendingHeredocs.push({ delim, strip });
      continue;
    }
    if (c === '\n') {
      flushSegment();
      i += 1;
      while (pendingHeredocs.length) {
        const { delim, strip } = pendingHeredocs.shift();
        while (i < s.length) {
          let end = s.indexOf('\n', i);
          if (end === -1) end = s.length;
          const line = s.slice(i, end);
          i = end + 1;
          if ((strip ? line.replace(/^\t+/, '') : line) === delim) break;
        }
      }
      continue;
    }
    if (c === ';' || c === '&' || c === '|' || c === '(' || c === ')') {
      flushSegment();
      i += 1;
      continue;
    }
    if (c === ' ' || c === '\t') {
      flushWord();
      i += 1;
      continue;
    }
    word += c;
    inWord = true;
    i += 1;
  }
  flushSegment();
  return out;
}

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/**
 * Walk past env assignments and transparent wrappers. Returns the index of the
 * real command word and the wrappers seen (by basename).
 */
export function commandStart(words) {
  const wrappers = [];
  let i = 0;
  while (i < words.length) {
    const w = words[i];
    if (ASSIGNMENT.test(w)) { i += 1; continue; }
    const base = basename(w);
    if (base === 'heavy-lock.sh') { wrappers.push(base); i += 1; continue; }
    if (base === 'with-ram.sh') { wrappers.push(base); i += 2; continue; }
    if (base === 'env') {
      wrappers.push(base);
      i += 1;
      while (i < words.length && (words[i].startsWith('-') || ASSIGNMENT.test(words[i]))) {
        if (words[i] === '-u' || words[i] === '-C') i += 1;
        i += 1;
      }
      continue;
    }
    if (base === 'timeout' || base === 'gtimeout') {
      wrappers.push(base);
      i += 1;
      while (i < words.length && words[i].startsWith('-')) i += 1;
      i += 1;
      continue;
    }
    if (base === 'nice') {
      wrappers.push(base);
      i += 1;
      while (i < words.length && words[i].startsWith('-')) {
        if (words[i] === '-n') i += 1;
        i += 1;
      }
      continue;
    }
    if (['time', 'nohup', 'exec', 'command', 'caffeinate', 'xcrun'].includes(base)) {
      wrappers.push(base);
      i += 1;
      while (i < words.length && words[i].startsWith('-')) i += 1;
      continue;
    }
    break;
  }
  return { index: i, wrappers };
}

/** The `-c` string of `bash|sh|zsh -c '<script>'`, or null. */
export function shellScript(words, index) {
  const base = basename(words[index] ?? '');
  if (!['bash', 'sh', 'zsh', 'dash'].includes(base)) return null;
  for (let j = index + 1; j < words.length; j += 1) {
    const w = words[j];
    if (!w.startsWith('-')) return null;
    if (/^-[a-zA-Z]*c[a-zA-Z]*$/.test(w)) return words[j + 1] ?? null;
  }
  return null;
}

/** Parse `git [global opts] <sub> args…` from a segment, or null. */
export function gitInvocation(words) {
  const { index } = commandStart(words);
  if (basename(words[index] ?? '') !== 'git') return null;
  let i = index + 1;
  let dir = null;
  while (i < words.length && words[i].startsWith('-')) {
    const w = words[i];
    if (w === '-C') { dir = dir ? `${dir}/${words[i + 1]}` : words[i + 1]; i += 2; continue; }
    if (w === '-c' || w === '--git-dir' || w === '--work-tree' || w === '--namespace') { i += 2; continue; }
    i += 1;
  }
  if (i >= words.length) return null;
  return { dir, sub: words[i], args: words.slice(i + 1) };
}

export function readHookInput() {
  try {
    return JSON.parse(readFileSync(0, 'utf8') || '{}');
  } catch {
    return {};
  }
}

export function deny(reason) {
  return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } };
}

export function context(text) {
  return { hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: text } };
}

export function emit(result) {
  if (result) process.stdout.write(`${JSON.stringify(result)}\n`);
}
