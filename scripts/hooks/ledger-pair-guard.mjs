#!/usr/bin/env node
// PreToolUse(Bash) on `git commit`: the ledger md and its generated html are
// committed together (AGENTS.md 功能账簿). When docs/feature-ledger.md is part
// of the commit, require the html to be part of it too (or unchanged) and run
// `npm run ledger:html-check` in the repository root; deny on failure. CI keeps
// the authoritative check; this only fails earlier.
import { execFileSync, spawnSync } from 'node:child_process';
import { isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { segments, gitInvocation, readHookInput, deny, emit } from './shell-words.mjs';

const MD = 'docs/feature-ledger.md';
const HTML = 'docs/feature-ledger.html';

const realDeps = {
  git(dir, args) {
    return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  },
  check(root) {
    const r = spawnSync('npm', ['run', '--silent', 'ledger:html-check'], { cwd: root, encoding: 'utf8', timeout: 120000 });
    if (r.error) return { ok: null, output: String(r.error.message) };
    return { ok: r.status === 0, output: `${r.stdout ?? ''}${r.stderr ?? ''}`.trim() };
  },
};

function lines(text) {
  return String(text ?? '').split('\n').map((l) => l.trim()).filter(Boolean);
}

function commitAll(args) {
  return args.some((a) => a === '--all' || /^-[a-zA-Z]*a[a-zA-Z]*$/.test(a) && !a.startsWith('--'));
}

export function decide(input, deps = realDeps) {
  if (input?.tool_name !== 'Bash') return null;
  const cwd = input?.cwd || process.cwd();
  const added = new Map();
  for (const words of segments(input?.tool_input?.command ?? '')) {
    const git = gitInvocation(words);
    if (!git) continue;
    const dir = git.dir ? (isAbsolute(git.dir) ? git.dir : resolve(cwd, git.dir)) : cwd;
    if (git.sub === 'add') {
      const set = added.get(dir) ?? new Set();
      for (const a of git.args) if (!a.startsWith('-')) set.add(a.replace(/^\.\//, ''));
      added.set(dir, set);
      continue;
    }
    if (git.sub !== 'commit') continue;
    let root;
    let staged;
    let unstaged;
    try {
      root = deps.git(dir, ['rev-parse', '--show-toplevel']).trim();
      staged = new Set(lines(deps.git(dir, ['diff', '--cached', '--name-only'])));
      unstaged = new Set(lines(deps.git(dir, ['diff', '--name-only'])));
    } catch {
      continue;
    }
    for (const p of added.get(dir) ?? []) staged.add(p);
    for (const a of git.args) if (a === MD || a === HTML) staged.add(a);
    if (commitAll(git.args)) for (const p of unstaged) staged.add(p);
    if (!staged.has(MD)) continue;
    if (!staged.has(HTML) && unstaged.has(HTML)) {
      return deny(`${MD} is in this commit but the regenerated ${HTML} is not staged. Stage it by name and commit both together (npm run ledger:build).`);
    }
    const result = deps.check(root);
    if (result.ok === false) {
      return deny(`${MD} is in this commit and \`npm run ledger:html-check\` fails. Run \`npm run ledger:build\`, stage ${HTML} by name and commit both together.\n${result.output.slice(-1500)}`);
    }
  }
  return null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) emit(decide(readHookInput()));
