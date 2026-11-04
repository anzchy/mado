#!/usr/bin/env node
// Run CI's trusted PR-body validator locally, bound to the commit about to be pushed.
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

let temporary, validatorProcess, termination;
const timers = new Set();
const handlers = new Map(['SIGINT', 'SIGTERM'].map(signal => [signal, () => {
  termination = signal;
  if (validatorProcess) {
    validatorProcess.kill(signal);
    const timer = setTimeout(() => validatorProcess?.kill('SIGKILL'), 1000);
    timers.add(timer);
  }
}]));
for (const [signal, handler] of handlers) process.on(signal, handler);
try {
  const options = { base: 'origin/main' };
  const args = process.argv.slice(2);
  const seen = new Set();
  for (let index = 0; index < args.length; index++) {
    const flag = args[index];
    if (!['--body-file', '--base', '--expect'].includes(flag) || seen.has(flag) ||
        !args[index + 1] || args[index + 1].startsWith('--')) {
      throw Error('usage: local-pr-lint.mjs --body-file F [--base origin/main] [--expect SHA]');
    }
    seen.add(flag);
    options[flag.slice(2)] = args[++index];
  }
  if (!options['body-file']) throw Error('usage: local-pr-lint.mjs --body-file F [--base origin/main] [--expect SHA]');
  if (!/^[A-Za-z0-9._/-]+$/.test(options.base) || options.base.startsWith('-') || options.base.includes('..')) {
    throw Error('invalid base ref');
  }
  const git = (...args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const head = git('rev-parse', '--verify', 'HEAD^{commit}');
  let expected;
  if (options.expect) {
    if (!/^[0-9a-f]{7,40}$/i.test(options.expect)) throw Error('--expect must name a commit SHA');
    expected = git('rev-parse', '--verify', `${options.expect}^{commit}`);
  } else {
    try { expected = git('rev-parse', '--verify', '@{upstream}^{commit}'); }
    catch { throw Error('no resolvable local upstream tip; pass --expect <SHA about to be pushed>'); }
  }
  if (head !== expected) throw Error(`HEAD ${head} differs from expected pushed commit ${expected}; pass the actual pushed SHA with --expect`);
  const body = resolve(options['body-file']);
  readFileSync(body); // Fail before extraction on an unreadable body.
  const base = git('rev-parse', '--verify', `${options.base}^{commit}`);
  temporary = realpathSync(mkdtempSync(join(tmpdir(), 'picsee-pr-lint-')));
  // A base snapshot preserves every import (including package metadata), without ever
  // resolving validator dependencies from the topic worktree. No checkout mutates HEAD.
  const archive = execFileSync('git', ['archive', '--format=tar', base], { maxBuffer: 128 * 1024 * 1024 });
  execFileSync('tar', ['-xf', '-', '-C', temporary], { input: archive, stdio: ['pipe', 'pipe', 'pipe'] });
  const validator = join(temporary, 'scripts/agents/ui-parity-pr-body-lint.mjs');
  if (!/^export function checkGates\b/m.test(readFileSync(validator, 'utf8'))) {
    throw Error('trusted PR-body lint lacks checkGates; update the base before local validation');
  }
  if (git('rev-parse', '--verify', 'HEAD^{commit}') !== expected) throw Error('HEAD changed while preparing expected pushed commit');
  // Keep cwd in the topic worktree so the trusted CLI checks its diff and HEAD.
  const result = await new Promise((resolve, reject) => {
    validatorProcess = spawn(process.execPath, [validator, '--base', base, '--body-file', body], {
      stdio: ['ignore', 'inherit', 'inherit'],
    });
    validatorProcess.once('error', reject);
    validatorProcess.once('close', (status, signal) => resolve({ status, signal }));
  });
  if (result.signal || result.status === null) throw Error(`trusted validator failed to run: ${result.signal ?? "missing exit status"}`);
  process.exitCode = result.status;
} catch (error) {
  console.error(`local-pr-lint: ${error.message}`);
  process.exitCode = 2;
} finally {
  for (const timer of timers) clearTimeout(timer);
  for (const [signal, handler] of handlers) process.off(signal, handler);
  if (termination) process.exitCode = termination === 'SIGINT' ? 130 : 143;
  if (temporary) rmSync(temporary, { recursive: true, force: true });
}
