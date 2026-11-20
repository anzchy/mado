// #788 item 3: bounded retries for package installs in the two required Linux jobs, never around a test or assertion.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseWorkflow } from '../../.agents/skills/ci-linux-preflight/scripts/workflow.mjs';

const retry = fileURLToPath(new URL('./retry.sh', import.meta.url));
const workflows = new URL('../../.github/workflows/', import.meta.url);
const read = name => readFileSync(new URL(name, workflows), 'utf8');

function flaky(t, failures, code = 7) {
  const dir = mkdtempSync(join(tmpdir(), 'retry-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const counter = join(dir, 'count'), cmd = join(dir, 'flaky.sh');
  writeFileSync(counter, '0');
  writeFileSync(cmd, `#!/bin/sh\nn=$(($(cat "${counter}") + 1)); echo $n > "${counter}"\necho "call $n $*"\n[ $n -gt ${failures} ] || exit ${code}\n`, { mode: 0o755 });
  return { cmd, calls: () => Number(readFileSync(counter, 'utf8')) };
}
const run = (...args) => spawnSync('/bin/sh', [retry, ...args], { encoding: 'utf8' });

test('788 retry runs once when the command succeeds and passes its arguments through', t => {
  const f = flaky(t, 0);
  const r = run('3', '0', f.cmd, 'a b', 'c');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.calls(), 1);
  assert.match(r.stdout, /^call 1 a b c$/m);
  assert.equal(r.stderr, '');
});

test('788 retry tries again with doubling waits and stops at the first success', t => {
  const f = flaky(t, 2);
  const started = Date.now();
  const r = run('3', '1', f.cmd);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.calls(), 3);
  assert.match(r.stderr, /^retry: try 1\/3 of .*flaky\.sh failed with exit 7; next try in 1 s$/m);
  assert.match(r.stderr, /^retry: try 2\/3 of .*flaky\.sh failed with exit 7; next try in 2 s$/m);
  assert.ok(Date.now() - started >= 3000, 'waited 1 s then 2 s');
});

test('788 retry gives up after the bounded number of tries with the last exit code', t => {
  const f = flaky(t, 99, 9);
  const r = run('3', '0', f.cmd);
  assert.equal(r.status, 9);
  assert.equal(f.calls(), 3);
  assert.match(r.stderr, /^retry: .*flaky\.sh failed 3 times; last exit 9$/m);
});

test('788 retry refuses unbounded or malformed use', () => {
  for (const args of [[], ['3'], ['3', '1'], ['0', '1', 'true'], ['6', '1', 'true'], ['x', '1', 'true'], ['3', '121', 'true'], ['3', '-1', 'true'], ['3', '1.5', 'true']]) {
    const r = run(...args);
    assert.equal(r.status, 64, JSON.stringify(args));
    assert.match(r.stderr, /usage: retry\.sh <tries 1-5> <first-wait-seconds 0-120> <command>/);
  }
});

const steps = text => text.split(/^      - name: /m).slice(1).map(part => ({ name: part.split('\n')[0], body: part }));
const jobOf = (text, id) => text.match(new RegExp(String.raw`^  ${id}:\n([\s\S]*?)(?=^  [a-z][a-z0-9-]*:\n|$(?![\s\S]))`, 'm'))?.[1] ?? '';

test('788 Agent tooling installs only missing tools, with apt retries and a bounded retry loop', () => {
  const install = steps(jobOf(read('pr-body.yml'), 'agent-tests')).find(s => s.name === 'Install portable device test tools');
  assert.ok(install);
  const lines = install.body.split('\n').slice(1).map(l => l.trim()).filter(Boolean);
  assert.deepEqual(lines, ['run: |',
    "if command -v python3 >/dev/null && command -v git >/dev/null && command -v zsh >/dev/null; then echo 'install: python3, git and zsh already present'; exit 0; fi",
    'pr-head/scripts/ci/retry.sh 3 15 sudo apt-get -o Acquire::Retries=3 update',
    'pr-head/scripts/ci/retry.sh 3 15 sudo apt-get -o Acquire::Retries=3 install --no-install-recommends -y python3 git zsh']);
  // The Linux preflight maps exactly this step to provision-checked and refuses a changed package list.
  const parsed = parseWorkflow(read('pr-body.yml'));
  assert.equal(parsed.steps.find(s => s.name === 'Install portable device test tools').kind, 'provision');
  assert.throws(() => parseWorkflow(read('pr-body.yml').replace('-y python3 git zsh', '-y python3 git zsh curl')), /unsupported provision mapping/);
});

test('788 Design check retries apt downloads and the Playwright install, and keeps the pinned browser cache', () => {
  const job = jobOf(read('ci.yml'), 'design-check');
  const install = steps(job).find(s => s.name === 'Install Playwright Chromium');
  assert.ok(install);
  assert.match(install.body, /^          echo 'Acquire::Retries "3";' \| sudo tee \/etc\/apt\/apt\.conf\.d\/80-mado-retries$/m);
  assert.match(install.body, /^          scripts\/ci\/retry\.sh 3 20 npx playwright install --with-deps chromium$/m);
  assert.match(job, /path: ~\/\.cache\/ms-playwright\n {10}key: playwright-v1-\$\{\{ runner\.os \}\}-\$\{\{ runner\.arch \}\}-\$\{\{ steps\.playwright\.outputs\.version \}\}/);
  assert.match(job, /- name: Check design catalog and journeys\n        run: npm run design:check\n/);
});

test('788 no workflow retries a test or assertion step: retry.sh appears only in Install steps', () => {
  const files = readdirSync(workflows).filter(name => /\.ya?ml$/.test(name));
  let installs = 0;
  for (const file of files) for (const { name, body } of steps(read(file))) {
    if (!/retry\.sh|Acquire::Retries/.test(body)) continue;
    assert.match(name, /^Install /, `${file}: ${name} retries`);
    installs++;
  }
  assert.equal(installs, 2, 'the two install steps');
});
