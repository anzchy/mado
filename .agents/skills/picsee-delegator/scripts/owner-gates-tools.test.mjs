import test from 'node:test';
import assert from 'node:assert/strict';
import { selectSuites, failureFact, preflight } from './owner-gates-tools.mjs';

test('WI-1 selects subject suites and preserves always-on suites', () => {
  assert.deepEqual(selectSuites(['App/MadoApp.swift']), {native:true, agents:false, tdd:false});
  assert.deepEqual(selectSuites(['scripts/agents/gates-rows.mjs']), {native:false, agents:true, tdd:false});
  assert.deepEqual(selectSuites(['scripts/tdd/app-lane.mjs']), {native:true, agents:false, tdd:true});
  assert.deepEqual(selectSuites(['docs/guide.md']), {native:false, agents:false, tdd:false});
});

test('WI-2 emits one bounded fact for nonzero lanes', () => {
  assert.equal(failureFact('node', 1, '# tests 3\nnot ok 1 - a\nnot ok 2 - b', ['a']), 'node: failed=2 tests=a,b in-diff=yes');
  assert.equal(failureFact('apptests-hosted', 70, 'test runner hung before establishing connection', []), 'apptests-hosted: hung');
  assert.equal(failureFact('design', 1, 'missing node_modules', []), 'design: prereq=node_modules');
  assert.equal(failureFact('swift', 1, 'Executed 50 tests, with 2 failures\nTime limit reached', []), 'swift: failed=2 timelimit=1 other=1');
  assert.equal(failureFact('swift', 75, 'lock timeout owner 999999', []), 'swift: lock-timeout holder=999999 alive=no');
});

test('WI-3 preflight fails closed on missing prerequisites', () => {
  assert.match(preflight({scriptsOwn:true, nodeModules:false, playwright:true, holder:null}), /node_modules/);
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:false, holder:null}), /Playwright/);
  assert.match(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:{pid:123, alive:false, withinBudget:true}}), /holder=123 alive=no/);
  assert.match(preflight({scriptsOwn:false, nodeModules:true, playwright:true, holder:null}), /worktree copy/);
  assert.equal(preflight({scriptsOwn:true, nodeModules:true, playwright:true, holder:null}), null);
});
