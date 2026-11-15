import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname, '../..');
const tool = join(root, '.agents/skills/ci-linux-preflight/scripts/preflight.mjs');
const checker = join(root, '.agents/skills/ci-linux-preflight/scripts/env-check.sh');
const run = (args, options = {}) => spawnSync(process.execPath, [tool, ...args], { encoding: 'utf8', ...options });

test('extracts named Agent tooling run steps, including a workflow edit', () => {
  const workflow = readFileSync(join(root, '.github/workflows/pr-body.yml'), 'utf8');
  const dir = mkdtempSync(join(tmpdir(), 'preflight-extract-'));
  const file = join(dir, 'workflow.yml');
  writeFileSync(file, workflow);
  const original = run(['extract', file]);
  assert.equal(original.status, 0, original.stderr);
  const steps = JSON.parse(original.stdout);
  assert.deepEqual(steps.map(s => s.name), ['Test portable device tools', 'Test agent tooling']);
  writeFileSync(file, workflow.replace('node --test scripts/agents/*.test.mjs', 'node --test scripts/agents/changed.test.mjs'));
  const changed = JSON.parse(run(['extract', file]).stdout);
  assert.match(changed.at(-1).run, /changed\.test\.mjs/);
  assert.notDeepEqual(changed, steps);
});

test('remote run reports failed step, TAP totals and failing name; checker rejects incomplete summary', () => {
  const dir = mkdtempSync(join(tmpdir(), 'preflight-remote-'));
  mkdirSync(join(dir, '.github/workflows'), { recursive: true });
  writeFileSync(join(dir, '.github/workflows/pr-body.yml'), `jobs:\n  agent-tests:\n    name: Agent tooling\n    steps:\n      - name: Install tools\n        run: exit 99\n      - name: Test altered command\n        working-directory: pr-head\n        run: node --test --test-reporter=tap sample.test.cjs\n`);
  writeFileSync(join(dir, 'sample.test.cjs'), `const test=require('node:test');test('broken example',()=>{throw Error('broken')});`);
  const result = run(['remote', dir, 'abcdef1']);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  const summary = result.stdout;
  assert.match(summary, /step:Test altered command=1/);
  assert.doesNotMatch(summary, /step:Install tools/);
  assert.match(summary, /tests=1\npass=0\nfail=1\nskip=0/);
  assert.match(summary, /failed:broken example/);
  assert.match(summary, /\nDONE\n$/);
  const file = join(dir, 'summary.txt');
  writeFileSync(file, summary.replace(/DONE\n$/, ''));
  assert.notEqual(run(['summary-check', file]).status, 0);
  writeFileSync(file, summary);
  assert.match(run(['summary-check', file]).stdout, /Linux-Preflight: abcdef1 agent-tooling FAIL 0\/1 \(0 skip\)/);
});

test('editing a workflow run command changes the command executed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'preflight-edited-run-'));
  mkdirSync(join(dir, '.github/workflows'), { recursive: true });
  const workflow = join(dir, '.github/workflows/pr-body.yml');
  const prefix = `jobs:\n  agent-tests:\n    name: Agent tooling\n    steps:\n      - name: Run fixture\n        working-directory: pr-head\n        run: `;
  writeFileSync(join(dir, 'sample.test.cjs'), `require('node:test')('works',()=>{});`);
  writeFileSync(workflow, `${prefix}node --test --test-reporter=tap sample.test.cjs\n`);
  const initial = run(['remote', dir, 'abcdef1']);
  assert.equal(initial.status, 0, initial.stderr);
  assert.match(initial.stdout, /step:Run fixture=0/);
  writeFileSync(workflow, `${prefix}node --test --test-reporter=tap sample.test.cjs && exit 7\n`);
  const edited = run(['remote', dir, 'abcdef1']);
  assert.equal(edited.status, 1);
  assert.match(edited.stdout, /step:Run fixture=7/);
});

test('env check rejects a mismatched git version', () => {
  const dir = mkdtempSync(join(tmpdir(), 'preflight-env-'));
  for (const [name, output] of [['node', 'v22.0.0'], ['git', 'git version 2.34.1'], ['python3', 'Python 3.12.0'], ['zsh', 'zsh 5.9']]) {
    const path = join(dir, name);
    writeFileSync(path, `#!/bin/sh\necho '${output}'\n`, { mode: 0o755 });
  }
  const result = spawnSync('/bin/zsh', [checker], { encoding: 'utf8', env: { ...process.env, PATH: dir } });
  assert.notEqual(result.status, 0);
  assert.match(result.stdout, /git.*2\.34\.1.*FAIL/);
});

test('local transfer uses fake ssh and rsync and writes a checked summary without network', () => {
  const dir = mkdtempSync(join(tmpdir(), 'preflight-transfer-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  const log = join(dir, 'calls');
  writeFileSync(join(bin, 'ssh'), `#!/bin/sh\nprintf 'ssh %s\\n' "$*" >> "$CALL_LOG"\ncase "$*" in\n  *'preflight.mjs remote'*) printf 'head=%s\\nstep:Test agent tooling=0\\nsecs=1.0\\npeak_rss_kb=42\\ntests=2\\npass=2\\nfail=0\\nskip=0\\nDONE\\n' "$FAKE_SHA7";;\nesac\n`, { mode: 0o755 });
  writeFileSync(join(bin, 'rsync'), `#!/bin/sh\nprintf 'rsync %s\\n' "$*" >> "$CALL_LOG"\n`, { mode: 0o755 });
  const head = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).stdout.trim();
  const result = run(['run', head], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, HOME: dir, CALL_LOG: log, FAKE_SHA7: head.slice(0, 7) } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(`Linux-Preflight: ${head.slice(0, 7)} agent-tooling PASS 2/2 \\(0 skip\\)`));
  const calls = readFileSync(log, 'utf8');
  assert.match(calls, /ssh -o BatchMode=yes/);
  assert.match(calls, /rsync .*head\.bundle/);
  assert.doesNotMatch(calls, /StrictHostKeyChecking=no/);
  assert.match(readFileSync(join(dir, '.picsee/ci-linux', `${head}-summary.txt`), 'utf8'), /DONE\n$/);
});
