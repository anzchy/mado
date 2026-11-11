import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { coverageAtomicSwiftArgs, coverageAtomicScratchPath, ATOMIC_COVERAGE_FLAG_ID } from './coverage-atomic.mjs';

const script = fileURLToPath(new URL('./package-coverage-export.mjs', import.meta.url));
const digest = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const sha = 'a'.repeat(40);
const fixtureLCOV = [
  'SF:Packages/MadoKit/Sources/MadoCore/A.swift', 'FN:1,main', 'FNDA:1,main', 'FNF:1', 'FNH:1',
  'DA:1,1', 'LF:1', 'LH:1', 'end_of_record', '',
].join('\n');

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'mado-coverage-export-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin');
  const source = join(root, 'Packages/MadoKit/Sources/MadoCore/A.swift');
  const profile = join(bin, 'codecov/default.profdata');
  const binary = join(bin, 'MadoKitPackageTests.xctest/Contents/MacOS/MadoKitPackageTests');
  const tools = join(root, 'tools');
  const out = join(root, 'out/non-ui');
  for (const path of [join(root, 'Packages/MadoKit/Sources/MadoCore'), join(bin, 'codecov'), join(bin, 'MadoKitPackageTests.xctest/Contents/MacOS'), tools]) mkdirSync(path, { recursive: true });
  writeFileSync(source, 'func main() {}\n');
  for (const module of ['MadoApplication', 'MadoInfrastructure', 'MadoMacUI']) {
    const directory = join(root, 'Packages/MadoKit/Sources', module);
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, 'Placeholder.swift'), 'struct Placeholder {}\n');
  }
  writeFileSync(profile, 'profile fixture');
  writeFileSync(binary, 'binary fixture');
  const fake = (name, body) => {
    const path = join(tools, name);
    writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755);
  };
  fake('swift', `echo '${bin}'`);
  fake('xcodebuild', "printf 'Xcode 26.6\\nBuild version 17F113\\n'");
  fake('xcrun', `case "$1" in swift) printf 'Apple Swift version 6.3.3\\n';; llvm-cov) if [ "$2" = --version ]; then printf 'Apple LLVM version 21.0.0\\n'; else cat '${join(root, 'fixture.lcov')}'; fi;; *) exit 9;; esac`);
  writeFileSync(join(root, 'fixture.lcov'), fixtureLCOV);
  const args = ['--root', root, '--shard', 'non-ui', '--out', out, '--commit', sha, '--run-id', '1234', '--attempt', '2', '--not-before', String(Math.floor(Date.now() / 1000) - 2)];
  const run = (extra = []) => spawnSync(process.execPath, [script, ...args, ...extra], { cwd: root, env: { ...process.env, PATH: `${tools}:${process.env.PATH}` }, encoding: 'utf8' });
  return { root, bin, source, profile, binary, out, tools, run, args };
}

test('successful shard export records matched binary, profile, source inventory and toolchain', t => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const metadata = JSON.parse(readFileSync(join(f.out, 'metadata.json'), 'utf8'));
  const lcov = join(f.out, 'coverage.lcov');
  assert.equal(readFileSync(lcov, 'utf8'), fixtureLCOV);
  assert.deepEqual({ version: metadata.version, shard: metadata.shard, commit: metadata.commit,
    runId: metadata.runId, runAttempt: metadata.runAttempt },
    { version: 1, shard: 'non-ui', commit: sha, runId: '1234', runAttempt: 2 });
  assert.equal(metadata.binary.sha256, digest(f.binary));
  assert.equal(metadata.profile.sha256, digest(f.profile));
  assert.equal(metadata.lcovSha256, digest(lcov));
  assert.equal(metadata.sourceInventory['Packages/MadoKit/Sources/MadoCore/A.swift'], digest(f.source));
  assert.match(metadata.toolchain.xcode, /17F113/);
  assert.match(metadata.toolchain.swift, /6\.3\.3/);
  assert.match(metadata.toolchain.llvmCov, /21\.0\.0/);
  assert.deepEqual(metadata.instrumentation, { swiftArgs: coverageAtomicSwiftArgs, scratchPath: coverageAtomicScratchPath, flagId: ATOMIC_COVERAGE_FLAG_ID });
});

test('stale or missing profile and missing binary cannot publish a complete artifact', t => {
  for (const scenario of ['stale', 'missing-profile', 'empty-profile', 'missing-binary']) {
    const f = fixture(t);
    if (scenario === 'stale') utimesSync(f.profile, 1, 1);
    if (scenario === 'missing-profile') rmSync(f.profile);
    if (scenario === 'empty-profile') writeFileSync(f.profile, '');
    if (scenario === 'missing-binary') rmSync(f.binary);
    const result = f.run();
    assert.notEqual(result.status, 0, scenario);
    assert.match(result.stderr, /profile|binary|fresh/i, scenario);
    assert.equal(existsSync(join(f.out, 'metadata.json')), false, scenario);
  }
});

test('LLVM export failure or empty LCOV cannot leave complete metadata', t => {
  for (const scenario of ['failure', 'empty']) {
    const f = fixture(t);
    const xcrun = join(f.tools, 'xcrun');
    if (scenario === 'failure') writeFileSync(xcrun, '#!/bin/sh\nif [ "$2" = --version ]; then echo LLVM; else exit 1; fi\n');
    else writeFileSync(join(f.root, 'fixture.lcov'), '');
    chmodSync(xcrun, 0o755);
    const result = f.run();
    assert.notEqual(result.status, 0, scenario);
    assert.equal(existsSync(join(f.out, 'metadata.json')), false, scenario);
  }
});

test('LLVM warnings do not become a publishable matched profile', t => {
  const f = fixture(t);
  const xcrun = join(f.tools, 'xcrun');
  writeFileSync(xcrun, `#!/bin/sh\nif [ "$1" = llvm-cov ] && [ "$2" != --version ]; then cat '${join(f.root, 'fixture.lcov')}'; echo 'profile mismatch warning' >&2; else echo version; fi\n`);
  chmodSync(xcrun, 0o755);
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /profile mismatch warning/);
  assert.equal(existsSync(join(f.out, 'metadata.json')), false);
});

test('invalid run identity and shard fail before export', t => {
  const f = fixture(t);
  for (const invalid of [['--commit', 'HEAD'], ['--run-id', ''], ['--attempt', '0'], ['--shard', 'anything']]) {
    const result = f.run(invalid);
    assert.notEqual(result.status, 0, invalid.join('='));
    assert.equal(existsSync(join(f.out, 'metadata.json')), false);
  }
});
