import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { selectSuites, failureFact, preflight, inspectLock } from './owner-gates-tools.mjs';

const fixture = name => fs.readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
test('WI-1 skips both optional suites only for reviewed native-only paths', () => {
  assert.deepEqual(selectSuites(['App/MadoApp.swift']), {native:true, agents:false, tdd:false});
  assert.deepEqual(selectSuites(['Packages/MadoKit/Tests/Foo.swift','TestAssets/foo.png']), {native:true, agents:false, tdd:false});
  for (const file of ['.github/workflows/pr-body.yml','.github/workflows/ci.yml','.agents/skills/pr/SKILL.md',
    'docs/agents/ui-parity-contract.md','.agents/skills/ci-linux-preflight/scripts/preflight.mjs',
    '.claude/agents/auditor.md','docs/agents/interaction-lifecycle-checklist.md',
    'scripts/agents/lifecycle-checklist-refs.test.mjs','scripts/git-hooks/pre-push','scripts/design/design-check.mjs',
    '.claude/tdd-guardian/config.json','.agents/skills/picsee-delegator/scripts/listen-notify.py',
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
