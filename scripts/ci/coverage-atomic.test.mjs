import test from 'node:test';
import assert from 'node:assert/strict';
import { assertAtomicIR, coverageAtomicSwiftArgs, coverageAtomicScratchPath, ATOMIC_COVERAGE_FLAG_ID } from './coverage-atomic.mjs';

test('coverage instrumentation identity is stable and rejects non-atomic IR', () => {
  assert.deepEqual(coverageAtomicSwiftArgs, ['-Xswiftc', '-Xllvm', '-Xswiftc', '-instrprof-atomic-counter-update-all']);
  assert.equal(coverageAtomicScratchPath, 'Packages/MadoKit/.build-coverage-atomic');
  assert.match(ATOMIC_COVERAGE_FLAG_ID, /^[0-9a-f]{16}$/);
  assert.throws(() => assertAtomicIR('store i64 1, ptr @"__profc_test"'), /ineffective/);
  assert.throws(() => assertAtomicIR('atomicrmw add ptr @"other", i64 1 monotonic'), /ineffective/);
  assert.doesNotThrow(() => assertAtomicIR('  %5 = atomicrmw add ptr @"__profc_test", i64 1 monotonic, align 8'));
});
