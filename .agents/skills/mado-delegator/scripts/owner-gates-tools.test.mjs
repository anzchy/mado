import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { selectSuites, failureFact, preflight, inspectLock, workflowNodeTests, expandPattern, readExceptions, nodeLaneFiles, uncoveredWorkflowTests, NODE_LANE_EXCEPTIONS } from './owner-gates-tools.mjs';

const fixture = name => fs.readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
test('WI-1 skips both optional suites only for reviewed native-only paths', () => {
  assert.deepEqual(selectSuites(['App/MadoApp.swift']), {native:true, agents:false, tdd:false});
  assert.deepEqual(selectSuites(['Packages/MadoKit/Tests/Foo.swift','TestAssets/foo.png']), {native:true, agents:false, tdd:false});
  for (const file of ['.github/workflows/pr-body.yml','.github/workflows/ci.yml','.agents/skills/pr/SKILL.md',
    'docs/agents/ui-parity-contract.md','.agents/skills/ci-linux-preflight/scripts/preflight.mjs',
    '.claude/agents/auditor.md','docs/agents/interaction-lifecycle-checklist.md',
    'scripts/agents/lifecycle-checklist-refs.test.mjs','scripts/git-hooks/pre-push','scripts/design/design-check.mjs',
    '.claude/tdd-guardian/config.json','.agents/skills/mado-delegator/scripts/listen-notify.py',
    'scripts/tdd/app-lane.mjs','docs/guide.md']) {
    const selected = selectSuites([file]);
    assert.equal(selected.agents, true, file);
    assert.equal(selected.tdd, true, file);
  }
  assert.deepEqual(selectSuites(['App/MadoApp.swift','docs/guide.md']), {native:true, agents:true, tdd:true});
});

test('WI-2 facts parse captured spec and heavy-lock output', () => {
  assert.equal(failureFact('node', 1, fixture('spec-failure.log'), ['scripts/agents/pre-push.test.mjs']),
    'node: failed=1 tests=documented_bootstrap_propagates_false-success in-diff=yes');
  assert.equal(failureFact('node', 1, fixture('spec-failure.log'), ['docs/guide.md']),
    'node: failed=1 tests=documented_bootstrap_propagates_false-success in-diff=no');
  assert.equal(failureFact('node', 1, 'failure with no test name', []), 'node: failed=unknown tests=unknown in-diff=unknown');
  assert.equal(failureFact('node', 1, '✔ lock wait timeout keeps exit 75\n✖ failing tests:\n✖ unrelated failure (1ms)', []),
    'node: failed=1 tests=unrelated_failure in-diff=no');
  assert.match(failureFact('swift', 75, fixture('heavy-timeout.log') + fixture('held-by.log'), []),
    /^swift: lock-timeout holder=69638 alive=(?:yes|no)$/);
  assert.equal(failureFact('apptests-hosted', 70, 'test runner hung before establishing connection', []), 'apptests-hosted: hung');
  assert.equal(failureFact('design', 1, fixture('design-prereq.log'), []), 'design: prereq=node_modules');
  assert.equal(failureFact('design', 1, 'Error at node_modules/playwright-core/lib/server.js', []), 'design: exit=1');
  assert.equal(failureFact('swift', 1, 'Executed 50 tests, with 2 failures\nTime limit reached', []), 'swift: failed=2 timelimit=unknown other=unknown');
});

test('WI-3 preflight fails only on missing prerequisites or an orphaned held lock', () => {
  assert.match(preflight({scriptsOwn:true, nodeModules:false, playwright:true, holder:null}), /node_modules/);
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:false, holder:null}), /Playwright/);
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:{pid:123, orphaned:true}}), /holder=123/);
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:{pid:123, orphaned:false}}), null);
  assert.match(preflight({scriptsOwn:false, nodeModules:true, playwright:true, holder:null}), /worktree copy/);
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:null}), null);
});

test('WI-3 free lock ignores captured stale owner record', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-lock-'));
  t.after(() => fs.rmSync(dir, {recursive:true, force:true}));
  const lock = path.join(dir, 'heavy.lock');
  fs.writeFileSync(lock, '');
  fs.writeFileSync(`${lock}.guardian-stale.owner`, fixture('guardian.owner'));
  assert.deepEqual(inspectLock(lock), {holder:null, staleRecords:1});
});

test('WI-3 live supervised holder waits instead of refusing', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-held-'));
  t.after(() => fs.rmSync(dir, {recursive:true, force:true}));
  const lock = path.join(dir, 'heavy.lock');
  const child = spawn('/usr/bin/python3', ['-c', 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("READY",flush=True); time.sleep(10)', lock], {stdio:['ignore','pipe','pipe']});
  t.after(() => child.kill());
  await once(child.stdout, 'data');
  const owner = fixture('guardian.owner').replace(/^pid=\d+$/m, `pid=${child.pid}`).replace(/^supervisor=\d+$/m, `supervisor=${process.pid}`);
  fs.writeFileSync(`${lock}.guardian-live.owner`, owner);
  assert.deepEqual(inspectLock(lock), {holder:{pid:child.pid, orphaned:false}, staleRecords:0});
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:inspectLock(lock).holder}), null);
  fs.writeFileSync(`${lock}.guardian-live.owner`, owner.replace(`supervisor=${process.pid}`, 'supervisor=999999'));
  assert.deepEqual(inspectLock(lock), {holder:{pid:child.pid, orphaned:true}, staleRecords:0});
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:inspectLock(lock).holder}), /supervisor=dead/);
});

// #750: the local node lane covers every node test path the workflows run, or lists it as a reviewed exception.
const repo = new URL('../../../..', import.meta.url).pathname;
const workflowTexts = () => fs.readdirSync(path.join(repo, '.github/workflows')).filter(f => /\.ya?ml$/.test(f))
  .map(f => fs.readFileSync(path.join(repo, '.github/workflows', f), 'utf8'));

test('750 workflow parser reads node --test and node-lane commands only', () => {
  const text = [
    '      - run: node --test scripts/a/*.test.mjs scripts/b/x.test.cjs',
    '        run: |',
    '          python3 -m unittest discover -s scripts/device/tests',
    '          node --test --test-reporter=spec "scripts/c/y.test.mjs"',
    '        run: scripts/heavy-lock.sh node scripts/tdd/node-lane.mjs scripts/d/*.test.mjs > .build/out.tap 2>&1',
    '        run: node scripts/ci/cache-key.mjs spm "$MANIFEST"',
  ].join('\n');
  assert.deepEqual(workflowNodeTests(text), ['scripts/a/*.test.mjs', 'scripts/b/x.test.cjs', 'scripts/c/y.test.mjs', 'scripts/d/*.test.mjs']);
});

test('750 every node test the workflows run is in the local lane or a reviewed exception', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  const ci = [...new Set(workflowTexts().flatMap(workflowNodeTests).flatMap(p => expandPattern(repo, p)))];
  assert.ok(ci.length > 60, `expanded CI node tests: ${ci.length}`);
  assert.ok(ci.includes('scripts/ci/for-where-ban.test.mjs'));
  assert.deepEqual(uncoveredWorkflowTests(repo, workflowTexts(), exceptions), []);
});

test('750 a CI test directory the lane does not know is reported', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lane-parity-'));
  try {
    for (const rel of ['scripts/ci/a.test.mjs', 'scripts/brand-new/b.test.mjs', 'scripts/ci/integration/c.test.mjs']) {
      fs.mkdirSync(path.dirname(path.join(dir, rel)), {recursive: true}); fs.writeFileSync(path.join(dir, rel), '');
    }
    const text = 'run: node --test scripts/ci/*.test.mjs scripts/brand-new/*.test.mjs\nrun: node scripts/tdd/node-lane.mjs scripts/ci/integration/*.test.mjs';
    assert.deepEqual(uncoveredWorkflowTests(dir, [text], []), ['scripts/brand-new/b.test.mjs', 'scripts/ci/integration/c.test.mjs']);
    assert.deepEqual(uncoveredWorkflowTests(dir, [text], [{file: 'scripts/ci/integration/*.test.mjs', reason: 'x'.repeat(30), ticket: '#1'}]), ['scripts/brand-new/b.test.mjs']);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

test('750 the lane runs scripts/ci (for-where ban included) and the mado-verify tests on every diff', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  for (const choice of [{agents: false, tdd: false}, {agents: true, tdd: true}]) {
    const {files} = nodeLaneFiles(repo, choice, exceptions);
    for (const file of ['scripts/ci/for-where-ban.test.mjs', 'scripts/ci/name-checks-ci.test.mjs', 'scripts/release/appcast.test.mjs',
      'scripts/hooks/git-add-guard.test.mjs', '.agents/skills/mado-verify/tests/verify.test.mjs',
      '.agents/skills/mado-delegator/scripts/owner-gates-tools.test.mjs']) assert.ok(files.includes(file), `${file} with ${JSON.stringify(choice)}`);
    assert.equal(files.includes('scripts/agents/pre-push.test.mjs'), choice.agents);
    assert.equal(files.some(f => f.startsWith('scripts/tdd/')), choice.tdd);
  }
});

test('750 every exception names a reason and a ticket, matches a CI test, and is not also run', () => {
  const exceptions = readExceptions(NODE_LANE_EXCEPTIONS);
  const ci = [...new Set(workflowTexts().flatMap(workflowNodeTests).flatMap(p => expandPattern(repo, p)))];
  const {files, excepted} = nodeLaneFiles(repo, {agents: true, tdd: true}, exceptions);
  for (const entry of exceptions) {
    assert.match(entry.ticket, /^#[1-9]\d*$/, entry.file);
    assert.ok(entry.reason.length >= 20, entry.file);
    const matched = expandPattern(repo, entry.file);
    assert.ok(matched.length && matched.every(f => ci.includes(f)), `${entry.file} matches no CI test`);
    for (const file of matched) { assert.ok(!files.includes(file), file); assert.ok(excepted.includes(file), file); }
  }
  for (const bad of [[{file: 'scripts/ci/a.test.mjs', reason: 'x'.repeat(30)}], [{file: 'scripts/ci/a.test.mjs', ticket: '#1'}], [{file: '', reason: 'x'.repeat(30), ticket: '#1'}]]) {
    const file = path.join(os.tmpdir(), `lane-exceptions-${process.pid}.json`);
    fs.writeFileSync(file, JSON.stringify({exceptions: bad}));
    try { assert.throws(() => readExceptions(file), /exception/); } finally { fs.rmSync(file, {force: true}); }
  }
});
