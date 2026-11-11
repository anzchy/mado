// Coverage-only Swift instrumentation. Keep CI, local unit, cache and exporter on one identity.
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

export const coverageAtomicSwiftArgs = ['-Xswiftc', '-Xllvm', '-Xswiftc', '-instrprof-atomic-counter-update-all'];
export const coverageAtomicScratchPath = 'Packages/MadoKit/.build-coverage-atomic';
export const ATOMIC_COVERAGE_FLAG_ID = createHash('sha256').update(coverageAtomicSwiftArgs.join('\0')).digest('hex').slice(0, 16);
const expectedXcode = 'Xcode 26.6\nBuild version 17F113';
const expectedSwift = 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)';

export function assertAtomicIR(ir) {
  if (!/atomicrmw add ptr @"__profc_[^\n]+?", i64 1 monotonic/.test(ir)) {
    throw new Error('coverage atomic flag ineffective: no atomicrmw add on __profc counter');
  }
}

export function verifyAtomicCompiler() {
  const xcode = execFileSync('xcodebuild', ['-version'], { encoding: 'utf8' }).trim();
  const swift = execFileSync('xcrun', ['swift', '--version'], { encoding: 'utf8' }).trim();
  if (xcode !== expectedXcode || !swift.startsWith(expectedSwift)) {
    throw new Error(`coverage atomic instrumentation is pinned to ${expectedXcode.replace('\n', ' ')} / ${expectedSwift}; got ${xcode.replace('\n', ' ')} / ${swift.split('\n')[0]}`);
  }
  const directory = mkdtempSync(path.join(tmpdir(), 'i631-atomic-'));
  try {
    const source = path.join(directory, 'Probe.swift');
    writeFileSync(source, 'public func issue631AtomicProbe(_ values: [Int]) -> Int { var sum = 0; for value in values { if value > 0 { sum += value } }; return sum }\n');
    const result = spawnSync('xcrun', ['swiftc', '-emit-ir', '-profile-generate', '-profile-coverage-mapping',
      '-module-name', 'Issue631AtomicProbe', source, '-o', '-', '-Xllvm', '-instrprof-atomic-counter-update-all'],
    { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    if (result.error || result.status !== 0 || result.signal) throw new Error(`coverage atomic flag unsupported: ${result.error?.message ?? result.stderr ?? result.signal}`);
    assertAtomicIR(result.stdout);
  } finally { rmSync(directory, { recursive: true, force: true }); }
  return { swiftArgs: coverageAtomicSwiftArgs, scratchPath: coverageAtomicScratchPath, flagId: ATOMIC_COVERAGE_FLAG_ID, proof: 'atomicrmw add __profc i64 monotonic' };
}
