import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = relative => readFileSync(new URL(`../../${relative}`, import.meta.url), 'utf8');
const workflow = read('.github/workflows/ci.yml');
const locked = read('scripts/tdd/unit-locked.mjs');
const owner = read('.agents/skills/picsee-delegator/scripts/owner-gates.sh');
const cache = read('scripts/ci/cache-key.mjs');
const flags = '-Xswiftc -Xllvm -Xswiftc -instrprof-atomic-counter-update-all';

test('CI shards, owner gate, and local unit lane share atomic coverage instrumentation', () => {
  assert.equal((workflow.match(new RegExp(flags, 'g')) ?? []).length, 2, 'both CI coverage shards');
  assert.equal((workflow.match(/node scripts\/ci\/coverage-atomic-verify\.mjs/g) ?? []).length, 2, 'both CI compiler probes');
  assert.match(locked, /coverageAtomicSwiftArgs/);
  assert.match(locked, /atomicVerify/);
  assert.match(locked, /--scratch-path.*coverageAtomicScratchPath/);
  assert.match(owner, /node scripts\/tdd\/unit-lane\.mjs/);
  assert.match(cache, /ATOMIC_COVERAGE_FLAG_ID/);
});

test('non-coverage SwiftPM build uses its own cache family and the atomic scratch path is explicit', () => {
  assert.match(workflow, /cache-key\.mjs spm-coverage/g);
  assert.match(workflow, /Packages\/MadoKit\/\.build-coverage-atomic/g);
  assert.match(locked, /coverageAtomicSwiftArgs/);
  assert.match(locked, /atomicVerify/);
  assert.doesNotMatch(read('scripts/tdd/swift-lane.mjs'), /coverageAtomicSwiftArgs/);
});
