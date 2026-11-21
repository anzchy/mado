import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { coverageAtomicSwiftArgs, coverageAtomicScratchPath, ATOMIC_COVERAGE_FLAG_ID } from './coverage-atomic.mjs';

const script = new URL('./package-coverage.mjs', import.meta.url).pathname;
const modules = ['MadoCore', 'MadoApplication', 'MadoInfrastructure', 'MadoMacUI'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const functionManifest = () => JSON.parse(readFileSync(new URL('./package-coverage-function-exceptions.json', import.meta.url), 'utf8'));

test('current function exception policy retains only InspectorPanel', () => {
  const entries = functionManifest();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].path, 'Packages/MadoKit/Sources/MadoMacUI/Inspector/InspectorPanel.swift');
  assert.equal(entries[0].start, 191);
});

test('retired ViewerChromeOverlay closure cannot be reintroduced for the current source', t => {
  const f = fixture(t);
  const path = 'Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift';
  const current = readFileSync(new URL('../../Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift', import.meta.url));
  writeFileSync(join(f.root, path), current);
  f.inventory[path] = hash(current);
  const retired = {
    path, symbol: '$s9MadoMacUI14ChromeToolViewC18accessibilityValueypSgyFyyYbScMYccACYbcfu_yyYbScMYccfu0_',
    start: 198, sourceSha256: f.inventory[path],
    toolchain: { xcode: 'Xcode 26.6\nBuild version 17F113', swift: 'Swift 6.3.3', llvmCov: 'LLVM 21' },
    reason: 'Retired temporary label callback.', decision: 'i631-pin-refresh.md M6',
  };
  writeFileSync(join(f.root, 'scripts/ci/package-coverage-function-exceptions.json'), JSON.stringify([retired]));
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({
    metadata: { ...metadata, sourceInventory: { ...metadata.sourceInventory, [path]: f.inventory[path] } },
    lcov: lcov.replace('FN:1,MadoMacUI.fn', `FN:1,MadoMacUI.fn\nFN:198,${retired.symbol}\nFNDA:0,${retired.symbol}`),
  }));
  assert.match(f.run().stderr, /unapproved function exception location/);
});
const pathOf = (module) => module === 'MadoInfrastructure'
  ? 'Packages/MadoKit/Sources/MadoInfrastructure/Images/ImageSourceHeader.swift'
  : module === 'MadoMacUI' ? 'Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift'
  : `Packages/MadoKit/Sources/${module}/A.swift`;
const source = module => module === 'MadoInfrastructure'
  ? 'func header() {\n  while false { break }\n  // end chunk\n  throw ImageDecodeError.unreadableImage\n}\n'
  : `func ${module}() {}\n`;
function record(file, lineHits, functionHits, sf = file) {
  const lines = lineHits.map(([line, hits]) => `DA:${line},${hits}`).join('\n');
  const fns = functionHits.map(([line, name, hits]) => `FN:${line},${name}\nFNDA:${hits},${name}`).join('\n');
  return `SF:${sf}\n${fns}\nFNF:${functionHits.length}\nFNH:${functionHits.filter(x => x[2] > 0).length}\n${lines}\nLF:${lineHits.length}\nLH:${lineHits.filter(x => x[1] > 0).length}\nend_of_record\n`;
}
function fixture(t, { left = {}, right = {}, macuiPath = pathOf('MadoMacUI') } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'package-coverage-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const input = join(root, 'artifacts');
  const inventory = {};
  const fileFor = module => module === 'MadoMacUI' ? macuiPath : pathOf(module);
  for (const module of modules) {
    const file = fileFor(module), contents = source(module);
    mkdirSync(dirname(join(root, file)), { recursive: true });
    writeFileSync(join(root, file), contents);
    inventory[file] = hash(contents);
  }
  mkdirSync(join(root, 'scripts/ci'), { recursive: true });
  writeFileSync(join(root, 'scripts/ci/package-coverage-exceptions.json'), '[]\n');
  writeFileSync(join(root, 'scripts/ci/package-coverage-function-exceptions.json'), '[]\n');
  for (const [shard, hits] of [['non-ui', left], ['macui', right]]) {
    const directory = join(input, shard);
    mkdirSync(directory, { recursive: true });
    const lcov = modules.map(module => {
      const file = fileFor(module);
      const count = hits[module] ?? 1;
      return record(file, [[1, count], ...(module === 'MadoInfrastructure' ? [[4, count]] : [])], [[1, `${module}.fn`, count]]);
    }).join('');
    writeFileSync(join(directory, 'coverage.lcov'), lcov);
    writeFileSync(join(directory, 'metadata.json'), JSON.stringify({
      version: 1, shard, commit: 'a'.repeat(40), runId: '1234', runAttempt: 1,
      toolchain: { xcode: 'Xcode 26.6\nBuild version 17F113', swift: 'Swift 6.3.3', llvmCov: 'LLVM 21' },
      instrumentation: { swiftArgs: coverageAtomicSwiftArgs, scratchPath: coverageAtomicScratchPath, flagId: ATOMIC_COVERAGE_FLAG_ID },
      binary: { path: `/tmp/${shard}/Tests.xctest`, sha256: hash(`binary-${shard}`) },
      profile: { path: `/tmp/${shard}/default.profdata`, sha256: hash(`profile-${shard}`) },
      lcovSha256: hash(lcov), sourceInventory: inventory,
    }));
  }
  const out = join(root, 'report.md');
  const run = (formal = true) => spawnSync(process.execPath, [script, '--root', root, '--input', input, '--out', out,
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', String(formal)], { encoding: 'utf8' });
  return { root, input, out, inventory, run, edit(shard, mutate) {
    const directory = join(input, shard);
    const metaFile = join(directory, 'metadata.json');
    const metadata = JSON.parse(readFileSync(metaFile, 'utf8'));
    const lcovFile = join(directory, 'coverage.lcov');
    const next = mutate({ metadata, lcov: readFileSync(lcovFile, 'utf8') });
    const finalMetadata = next.metadata ?? metadata;
    if (next.lcov !== undefined) { writeFileSync(lcovFile, next.lcov); finalMetadata.lcovSha256 = hash(next.lcov); }
    writeFileSync(metaFile, JSON.stringify(finalMetadata));
  } };
}

test('complementary hits merge once per mapping and expose exact report counts', t => {
  const f = fixture(t, { left: { MadoCore: 0, MadoApplication: 1, MadoInfrastructure: 1, MadoMacUI: 0 },
    right: { MadoCore: 1, MadoApplication: 0, MadoInfrastructure: 0, MadoMacUI: 1 } });
  const run = f.run();
  assert.equal(run.status, 0, run.stderr + run.stdout);
  assert.ok(existsSync(f.out), 'merger writes a report');
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /MadoCore.*lines 1\/1.*functions 1\/1/);
  assert.match(report, /MadoInfrastructure.*lines 2\/2.*functions 1\/1/);
  assert.match(report, /Package.*lines 5\/5.*functions 4\/4/);
  assert.match(report, /statement proxy.*LCOV executable lines/i);
  assert.match(report, /branches unmeasured/);
  assert.match(report, /App\/ excluded/);
  assert.match(report, /ImageSourceHeader\.swift:4.*hit count 1/);
  assert.match(report, /binary.*sha256/i);
  assert.match(report, /profile.*sha256/i);
});

test('a single uncovered executable line or function fails, reports locations, and never rounds up', t => {
  const f = fixture(t);
  f.edit('non-ui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:4,1', 'DA:4,0').replace('LH:2', 'LH:1') }));
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:4,1', 'DA:4,0').replace('LH:2', 'LH:1') }));
  const run = f.run();
  assert.equal(run.status, 1, run.stderr + run.stdout);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /ImageSourceHeader\.swift:4/);
  assert.match(report, /Package.*lines 4\/5/);
  assert.doesNotMatch(report, /PASS/);
});

test('missing shard, wrong provenance and divergent source content fail closed', t => {
  const f = fixture(t);
  f.edit('macui', ({ metadata }) => ({ metadata: { ...metadata, runAttempt: 2 } }));
  assert.match(f.run().stderr, /attempt|provenance/i);
  f.edit('macui', ({ metadata }) => ({ metadata: { ...metadata, runAttempt: 1, sourceInventory: { ...metadata.sourceInventory, [pathOf('MadoCore')]: hash('different') } } }));
  assert.match(f.run().stderr, /source|digest/i);
  rmSync(join(f.input, 'macui'), { recursive: true });
  assert.match(f.run().stderr, /macui|missing/i);
});

test('LCOV duplicate and incompatible mapping cannot yield a pass', t => {
  const f = fixture(t);
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:1,1', 'DA:2,1') }));
  assert.match(f.run().stderr, /mapping|line/i);
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:2,1', 'DA:1,1').replace('DA:1,1', 'DA:1,1\nDA:1,1') }));
  assert.match(f.run().stderr, /duplicate/i);
});

test('unexplained absent production source and zero denominator fail', t => {
  const f = fixture(t);
  const file = pathOf('MadoMacUI');
  f.edit('non-ui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace(new RegExp(`SF:${file}[\\s\\S]*?end_of_record\\n`), '') }));
  assert.match(f.run().stderr, /missing|mapping|source/i);
});

test('filtered dispatch is diagnostic and cannot claim formal full-package evidence', t => {
  const f = fixture(t);
  const run = f.run(false);
  assert.equal(run.status, 0, run.stderr + run.stdout);
  assert.ok(existsSync(f.out), 'merger writes a report');
  assert.match(readFileSync(f.out, 'utf8'), /diagnostic.*not formal/i);
});

test('absolute Mac checkout paths and relative dot paths normalize to one source identity', t => {
  const f = fixture(t);
  const file = pathOf('MadoCore');
  f.edit('non-ui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace(`SF:${file}`, `SF:/Users/runner/work/mado/mado/${file}`) }));
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace(`SF:${file}`, `SF:Packages/MadoKit/Sources/MadoCore/./A.swift`) }));
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(f.out, 'utf8'), /MadoCore: lines 1\/1; functions 1\/1/);
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('SF:Packages/MadoKit/Sources/MadoCore/./A.swift', 'SF:/other/A.swift') }));
  assert.match(f.run().stderr, /SF outside production source/);
});

test('missing and malformed profile metadata, LCOV digest and summary fail before report', t => {
  const f = fixture(t);
  f.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, profile: { path: metadata.profile.path, sha256: '' } } }));
  assert.match(f.run().stderr, /profile.*sha256/i);
  f.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, profile: { path: '/tmp/profile', sha256: hash('profile-non-ui') }, lcovSha256: hash('different') } }));
  assert.match(f.run().stderr, /LCOV sha256 mismatch/);
  f.edit('non-ui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('LF:1', 'LF:0') }));
  assert.match(f.run().stderr, /summary mismatch/);
  assert.equal(existsSync(f.out), false);
});

test('uncovered function alone fails and names its source and function', t => {
  const f = fixture(t);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({
    lcov: lcov.replace('FNDA:1,MadoCore.fn', 'FNDA:0,MadoCore.fn').replace('FNH:1', 'FNH:0') }));
  const run = f.run();
  assert.equal(run.status, 1, run.stderr);
  assert.match(readFileSync(f.out, 'utf8'), /MadoCore\/A.swift:1 function MadoCore.fn/);
});

test('a new zero-hit FNDA fails even when FNF and FNH summaries still claim 100 percent', t => {
  const f = fixture(t);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov.replace('FN:1,MadoCore.fn', 'FN:1,MadoCore.fn\nFN:1,MadoCore.newCallback\nFNDA:0,MadoCore.newCallback'),
  }));
  const run = f.run();
  assert.equal(run.status, 1, run.stderr);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /MadoCore:.*raw functions 1\/2.*eligible functions 1\/2/);
  assert.match(report, /MadoCore\.newCallback/);
  assert.match(report, /Coverage gate: FAIL/);
});

test('wrapped DA and FNDA in one shard invalidate evidence before merge', t => {
  const f = fixture(t);
  const wrapped = '9223372036854775808';
  f.edit('non-ui', ({ metadata, lcov }) => ({ metadata, lcov: lcov
    .replace('FNDA:1,MadoCore.fn', `FNDA:${wrapped},MadoCore.fn`)
    .replace(`DA:1,1`, `DA:1,${wrapped}`) }));
  const eligible = join(f.root, 'eligible.lcov');
  const run = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
    '--eligible-out', eligible, '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true'],
  { encoding: 'utf8' });
  assert.equal(run.status, 1, run.stderr + run.stdout);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /Invalid coverage evidence/);
  assert.match(report, /non-ui.*MadoCore\/A\.swift:1.*DA.*9223372036854775808/);
  assert.match(report, /non-ui.*MadoCore\/A\.swift.*MadoCore\.fn.*FNDA.*9223372036854775808/);
  assert.match(report, /commit.*aaaa|run.*1234/i);
  assert.match(report, /Coverage gate: FAIL/);
  assert.equal(existsSync(eligible), false);
});

test('a new exception cannot conceal an omitted executable source', t => {
  const f = fixture(t);
  const extra = 'Packages/MadoKit/Sources/MadoCore/Omitted.swift';
  const contents = 'func omitted() {}\n';
  writeFileSync(join(f.root, extra), contents);
  writeFileSync(join(f.root, 'scripts/ci/package-coverage-exceptions.json'),
    JSON.stringify([{ path: extra, reason: 'Declaration only.' }]));
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: {
    ...metadata, sourceInventory: { ...metadata.sourceInventory, [extra]: hash(contents) },
  } }));
  const run = f.run();
  assert.equal(run.status, 1, run.stderr + run.stdout);
  assert.match(run.stderr, /unapproved|exception/i);
});

test('new declaration-only exception also requires a reviewed pin', t => {
  const f = fixture(t);
  const extra = 'Packages/MadoKit/Sources/MadoCore/Declarations.swift';
  const contents = 'protocol EmptyPort { func read() }\n';
  writeFileSync(join(f.root, extra), contents);
  writeFileSync(join(f.root, 'scripts/ci/package-coverage-exceptions.json'),
    JSON.stringify([{ path: extra, reason: 'Protocol requirement only.' }]));
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: {
    ...metadata, sourceInventory: { ...metadata.sourceInventory, [extra]: hash(contents) },
  } }));
  const run = f.run();
  assert.equal(run.status, 1, run.stderr);
  assert.match(run.stderr, /unapproved|exception/i);
});

test('toolchain mismatch and missing source digest fail independently of coverage', t => {
  const f = fixture(t);
  f.edit('macui', ({ metadata }) => ({ metadata: { ...metadata, toolchain: { ...metadata.toolchain, swift: 'Swift 7' } } }));
  assert.match(f.run().stderr, /toolchain mismatch/);
  f.edit('macui', ({ metadata }) => ({ metadata: { ...metadata, toolchain: { ...metadata.toolchain, swift: 'Swift 6.3.3' },
    sourceInventory: { ...metadata.sourceInventory, [pathOf('MadoMacUI')]: undefined } } }));
  assert.match(f.run().stderr, /source inventory missing|source digest mismatch/);
});

test('CLI accepts checkout-relative paths used by the Linux CI job', t => {
  const f = fixture(t);
  const run = spawnSync(process.execPath, [script, '--root', '.', '--input', 'artifacts', '--out', 'report.md',
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true'],
  { cwd: f.root, encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.match(readFileSync(f.out, 'utf8'), /Coverage gate: PASS/);
});

test('an empty SF record fails even when another file keeps its module denominator positive', t => {
  const f = fixture(t);
  const extra = 'Packages/MadoKit/Sources/MadoCore/B.swift';
  const code = 'func B() {}\n';
  writeFileSync(join(f.root, extra), code);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({
    metadata: { ...metadata, sourceInventory: { ...metadata.sourceInventory, [extra]: hash(code) } },
    lcov: lcov.replace(`SF:${pathOf('MadoCore')}\nFN:1,MadoCore.fn\nFNDA:1,MadoCore.fn\nFNF:1\nFNH:1\nDA:1,1\nLF:1\nLH:1\nend_of_record\n`,
      `SF:${pathOf('MadoCore')}\nFNF:0\nFNH:0\nLF:0\nLH:0\nend_of_record\n`) + record(extra, [[1, 1]], [[1, 'B.fn', 1]]),
  }));
  const empty = f.run();
  assert.equal(empty.status, 1, empty.stderr);
  assert.match(empty.stderr, /MadoCore\/A.swift.*zero.*(line|function)|MadoCore\/A.swift.*empty/i);
  assert.equal(existsSync(f.out), false);
});

test('CLI appends complete passing and failing reports to GitHub step summary', t => {
  const f = fixture(t);
  const summary = join(f.root, 'summary.md');
  const invoke = () => spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input,
    '--out', f.out, '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true'],
  { encoding: 'utf8', env: { ...process.env, GITHUB_STEP_SUMMARY: summary } });
  const passing = invoke();
  assert.equal(passing.status, 0, passing.stderr);
  assert.ok(existsSync(summary), 'GitHub step summary exists');
  assert.match(readFileSync(summary, 'utf8'), /Coverage gate: PASS/);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov.replace('DA:4,1', 'DA:4,0').replace('LH:2', 'LH:1') }));
  const failing = invoke();
  assert.equal(failing.status, 1, failing.stderr);
  const text = readFileSync(summary, 'utf8');
  assert.match(text, /Coverage gate: PASS[\s\S]*Coverage gate: FAIL/);
  assert.match(text, /ImageSourceHeader.swift:4/);
});

test('raw FNDA denominator stays strict while a pinned uncovered function is disclosed separately', t => {
  const file = 'Packages/MadoKit/Sources/MadoMacUI/Inspector/InspectorPanel.swift';
  const f = fixture(t, { macuiPath: file });
  const reviewedSource = readFileSync(new URL('../../Packages/MadoKit/Sources/MadoMacUI/Inspector/InspectorPanel.swift', import.meta.url));
  writeFileSync(join(f.root, file), reviewedSource);
  f.inventory[file] = hash(reviewedSource);
  const symbol = functionManifest()[0].symbol;
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({
    metadata: { ...metadata, sourceInventory: { ...metadata.sourceInventory, [file]: f.inventory[file] } },
    lcov: lcov.replace(`FN:1,MadoMacUI.fn`, `FN:1,MadoMacUI.fn\nFN:191,${symbol}\nFNDA:0,${symbol}`),
  }));
  const exception = { path: file, symbol, start: 191, sourceSha256: f.inventory[file],
    toolchain: { xcode: 'Xcode 26.6\nBuild version 17F113', swift: 'Swift 6.3.3', llvmCov: 'LLVM 21' },
    reason: 'Empty initializer callback is replaced on view update.', decision: 'i631-fn-astra.md B' };
  const manifest = join(f.root, 'scripts/ci/package-coverage-function-exceptions.json');
  writeFileSync(manifest, JSON.stringify([exception]));
  const result = f.run();
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /MadoMacUI.*raw functions 1\/2.*exceptions 1.*eligible functions 1\/1/);
  assert.match(report, /Package.*raw functions 4\/5.*exceptions 1.*eligible functions 4\/4/);
  assert.ok(report.includes(symbol));
  const eligible = join(f.root, 'eligible.lcov');
  const guardian = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true', '--eligible-out', eligible],
  { encoding: 'utf8' });
  assert.equal(guardian.status, 0, guardian.stderr);
  const derived = readFileSync(eligible, 'utf8');
  assert.ok(!derived.includes(symbol), 'guardian eligible LCOV omits only the pinned exception');
  assert.match(derived, /SF:Packages\/MadoKit\/Sources\/MadoMacUI\/Inspector\/InspectorPanel.swift[\s\S]*FNF:1\nFNH:1/);
  const local = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'false', '--shards', 'non-ui'],
  { encoding: 'utf8' });
  assert.equal(local.status, 0, local.stderr);
  const localReport = readFileSync(f.out, 'utf8');
  for (const count of ['raw functions 4/5', 'exceptions 1', 'eligible functions 4/4']) {
    assert.ok(report.includes(count) && localReport.includes(count), `same LCOV yields ${count} in CI and local layouts`);
  }

  writeFileSync(manifest, JSON.stringify([exception, exception]));
  assert.match(f.run().stderr, /duplicate/i);
  writeFileSync(manifest, JSON.stringify([{ ...exception, symbol: '*' }]));
  assert.match(f.run().stderr, /wildcard|symbol|unmatched/i);
  writeFileSync(manifest, JSON.stringify([{ ...exception, start: 2 }]));
  assert.match(f.run().stderr, /unapproved|stale|location|unmatched/i);
  writeFileSync(manifest, JSON.stringify([{ ...exception, sourceSha256: hash('changed') }]));
  assert.match(f.run().stderr, /digest|source/i);
  writeFileSync(manifest, JSON.stringify([{ ...exception, toolchain: { ...exception.toolchain, swift: 'Swift 7' } }]));
  assert.match(f.run().stderr, /toolchain/i);
  writeFileSync(manifest, JSON.stringify([{ ...exception, symbol: 'missing' }]));
  assert.match(f.run().stderr, /unapproved|unmatched/i);
  writeFileSync(manifest, JSON.stringify([{ ...exception, path: pathOf('MadoCore'), sourceSha256: f.inventory[pathOf('MadoCore')] }]));
  assert.match(f.run().stderr, /unapproved/i);
  writeFileSync(manifest, JSON.stringify([exception]));
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov.replace(`FNDA:0,${symbol}`, `FNDA:1,${symbol}`),
  }));
  assert.match(f.run().stderr, /covered/i);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov.replace(`FN:191,${symbol}\nFNDA:1,${symbol}\n`, ''),
  }));
  assert.match(f.run().stderr, /unmatched/i);
});

test('missing function exception manifest fails closed', t => {
  const f = fixture(t);
  rmSync(join(f.root, 'scripts/ci/package-coverage-function-exceptions.json'));
  assert.match(f.run().stderr, /function exception.*missing/i);
});

test('local single full-suite artifact uses the CI evaluator and the same denominator', t => {
  const f = fixture(t);
  rmSync(join(f.input, 'macui'), { recursive: true });
  const run = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'false', '--shards', 'non-ui'],
  { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.match(readFileSync(f.out, 'utf8'), /Package: lines 5\/5; functions 4\/4; raw functions 4\/4; exceptions 0; eligible functions 4\/4/);
  const formal = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true', '--shards', 'non-ui'],
  { encoding: 'utf8' });
  assert.equal(formal.status, 1);
  assert.match(formal.stderr, /formal.*two shards/i);
});

test('guardian-facing LCOV is derived from strict eligible mappings rather than LLVM summaries', t => {
  const f = fixture(t);
  const eligible = join(f.root, 'eligible.lcov');
  const run = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
    '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true', '--eligible-out', eligible],
  { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  const summary = readFileSync(eligible, 'utf8');
  assert.match(summary, /SF:Packages\/MadoKit\/Sources\/MadoCore\/A.swift[\s\S]*FNF:1\nFNH:1[\s\S]*LF:1\nLH:1/);
  assert.match(summary, /SF:Packages\/MadoKit\/Sources\/MadoInfrastructure\/Images\/ImageSourceHeader.swift[\s\S]*LF:2\nLH:2/);
});

test('all 17 reviewed file pins reject source, manifest, toolchain and mapping drift', t => {
  const f = fixture(t);
  const repository = join(dirname(script), '../..');
  const manifestFile = join(f.root, 'scripts/ci/package-coverage-exceptions.json');
  const reviewed = JSON.parse(readFileSync(join(repository, 'scripts/ci/package-coverage-exceptions.json'), 'utf8'));
  const reviewedText = JSON.stringify(reviewed);
  assert.equal(reviewed.length, 17);
  writeFileSync(manifestFile, reviewedText);
  for (const entry of reviewed) {
    const contents = readFileSync(join(repository, entry.path));
    mkdirSync(dirname(join(f.root, entry.path)), { recursive: true });
    writeFileSync(join(f.root, entry.path), contents);
    f.inventory[entry.path] = hash(contents);
  }
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: {
    ...metadata, toolchain: reviewed[0].toolchain, sourceInventory: { ...metadata.sourceInventory, ...f.inventory },
  } }));
  assert.equal(f.run().status, 0, 'the exact reviewed set is accepted');
  const first = reviewed[0];
  writeFileSync(join(f.root, first.path), readFileSync(join(f.root, first.path), 'utf8') + '\n');
  assert.match(f.run().stderr, /source digest drift/i);
  writeFileSync(join(f.root, first.path), readFileSync(join(repository, first.path)));
  writeFileSync(manifestFile, JSON.stringify([{ ...first, sourceSha256: hash('changed') }, ...reviewed.slice(1)]));
  assert.match(f.run().stderr, /manifest pin drift|source digest drift/i);
  writeFileSync(manifestFile, reviewedText);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: {
    ...metadata, toolchain: { ...metadata.toolchain, swift: 'Swift 7' },
  } }));
  assert.match(f.run().stderr, /toolchain drift/i);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: {
    ...metadata, toolchain: reviewed[0].toolchain,
  } }));
  writeFileSync(manifestFile, JSON.stringify([...reviewed, reviewed[0]]));
  assert.match(f.run().stderr, /exception count drift|duplicate/i);
  writeFileSync(manifestFile, reviewedText);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov + record(first.path, [[1, 1]], [[1, 'unexpected.executable', 1]]),
  }));
  assert.match(f.run().stderr, /mapping missing or unexpected/i);
});

test('missing or changed coverage instrumentation provenance fails before aggregation', t => {
  for (const mutation of [undefined, { swiftArgs: [], scratchPath: coverageAtomicScratchPath, flagId: ATOMIC_COVERAGE_FLAG_ID },
    { swiftArgs: coverageAtomicSwiftArgs, scratchPath: 'Packages/MadoKit/.build', flagId: ATOMIC_COVERAGE_FLAG_ID }]) {
    const f = fixture(t);
    f.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, instrumentation: mutation } }));
    const run = f.run();
    assert.equal(run.status, 1, run.stdout + run.stderr);
    assert.match(run.stderr, /coverage instrumentation mismatch/);
  }
});

// #788 item 1: "Re-run failed jobs" keeps a successful shard's artifact from an earlier attempt of the same run. The gate
// accepts it only when the run's job records prove that shard's job succeeded in that attempt at the same head SHA and was
// carried forward unchanged; anything else refuses and says to rerun all jobs. Job names come from ci.yml.
const ciWorkflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const jobName = id => ciWorkflow.match(new RegExp(`^  ${id}:\\n    name: (.+)$`, 'm'))?.[1];
const shardJob = { 'non-ui': jobName('package-tests'), macui: jobName('package-macui-tests') };
function jobRecord(name, attempt, overrides = {}) {
  return { name, conclusion: 'success', runAttempt: attempt, headSha: 'a'.repeat(40), startedAt: '2026-11-19T02:48:04Z',
    completedAt: '2026-11-19T02:52:44Z', runnerName: 'GitHub Actions 1000009885', ...overrides };
}
// Attempt 1: non-UI passed, MacUI failed. Attempt 2 re-ran MacUI only; non-UI is listed again with the same times and runner.
function rerunProof(mutate = proof => proof) {
  const proof = { version: 1, runId: '1234', attempt: 2, attempts: {
    1: { headSha: 'a'.repeat(40), jobs: [jobRecord(shardJob['non-ui'], 1), jobRecord(shardJob.macui, 1, { conclusion: 'failure', startedAt: '2026-11-19T02:51:09Z' })] },
    2: { headSha: 'a'.repeat(40), jobs: [jobRecord(shardJob['non-ui'], 2), jobRecord(shardJob.macui, 2, { startedAt: '2026-11-19T04:05:11Z', completedAt: '2026-11-19T04:11:48Z', runnerName: 'GitHub Actions 1000009890' })] },
  } };
  return mutate(proof);
}
function rerunRun(f, { proof = rerunProof(), attempt = '2' } = {}) {
  const args = [script, '--root', f.root, '--input', f.input, '--out', f.out, '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', attempt, '--formal', 'true'];
  if (proof !== null) {
    const file = join(f.root, 'attempt-jobs.json');
    writeFileSync(file, JSON.stringify(proof));
    args.push('--attempt-jobs', file);
  }
  return spawnSync(process.execPath, args, { encoding: 'utf8' });
}
const rerunFixture = t => {
  const f = fixture(t);
  f.edit('macui', ({ metadata }) => ({ metadata: { ...metadata, runAttempt: 2 } }));
  return f;
};

test('788 job names for the shards are the ci.yml job names', () => {
  assert.equal(shardJob['non-ui'], 'Package tests (non-UI)');
  assert.equal(shardJob.macui, 'Package tests (MacUI)');
});

test('788 a shard carried forward from a successful earlier attempt of the same run and head is accepted and named', t => {
  const f = rerunFixture(t);
  const run = rerunRun(f);
  assert.equal(run.status, 0, run.stderr + run.stdout);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /^non-ui shard from attempt 1 of run 1234 \(job Package tests \(non-UI\) succeeded there and was not re-run; checked against the run's job records\)$/m);
  assert.doesNotMatch(report, /^macui shard from attempt/m);
  assert.match(report, /Package.*lines 5\/5.*functions 4\/4/);
});

test('788 an earlier-attempt shard is refused, with a rerun-all instruction, unless every proof holds', t => {
  const cases = [
    ['no job records', null, /non-ui attempt provenance mismatch: artifact from attempt 1, this is attempt 2; no job records for the earlier attempts/],
    ['job failed there', rerunProof(p => { p.attempts[1].jobs[0].conclusion = 'failure'; return p; }), /did not succeed in attempt 1/],
    ['job re-ran later', rerunProof(p => { p.attempts[2].jobs[0].startedAt = '2026-11-19T04:05:20Z'; return p; }), /ran again in attempt 2/],
    ['other runner later', rerunProof(p => { p.attempts[2].jobs[0].runnerName = 'GitHub Actions 2'; return p; }), /ran again in attempt 2/],
    ['attempt head differs', rerunProof(p => { p.attempts[1].headSha = 'b'.repeat(40); return p; }), /head SHA/],
    ['job head differs', rerunProof(p => { p.attempts[1].jobs[0].headSha = 'b'.repeat(40); return p; }), /head SHA/],
    ['job missing', rerunProof(p => { p.attempts[1].jobs = p.attempts[1].jobs.slice(1); return p; }), /no job Package tests \(non-UI\) in attempt 1/],
    ['job listed twice', rerunProof(p => { p.attempts[1].jobs.push(jobRecord(shardJob['non-ui'], 1)); return p; }), /2 jobs Package tests \(non-UI\) in attempt 1/],
    ['attempt missing', rerunProof(p => { delete p.attempts[2]; return p; }), /no job records for attempt 2/],
    ['records of another run', rerunProof(p => { p.runId = '999'; return p; }), /job records are for run 999/],
    ['records of another attempt', rerunProof(p => { p.attempt = 3; return p; }), /job records are for attempt 3/],
    ['attempt field mismatch', rerunProof(p => { p.attempts[1].jobs[0].runAttempt = 2; return p; }), /job record attempt/],
  ];
  for (const [label, proof, reason] of cases) {
    const f = rerunFixture(t);
    const run = rerunRun(f, { proof });
    assert.equal(run.status, 1, `${label}: ${run.stdout}`);
    assert.match(run.stderr, reason, label);
    assert.match(run.stderr, /rerun all jobs of this run/, label);
    assert.equal(existsSync(f.out), false, `${label}: no report`);
  }
});

test('788 the gate stays strict: later attempt, mixed head SHA, other run and missing shard still fail with job records present', t => {
  const later = rerunFixture(t);
  later.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, runAttempt: 3 } }));
  assert.match(rerunRun(later).stderr, /non-ui attempt provenance mismatch: artifact from attempt 3 is later than this attempt 2/);
  const mixed = rerunFixture(t);
  mixed.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, commit: 'b'.repeat(40) } }));
  assert.match(rerunRun(mixed).stderr, /non-ui commit provenance mismatch/);
  const otherRun = rerunFixture(t);
  otherRun.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, runId: '999' } }));
  assert.match(rerunRun(otherRun).stderr, /non-ui run provenance mismatch/);
  const missing = rerunFixture(t);
  rmSync(join(missing.input, 'non-ui'), { recursive: true });
  assert.match(rerunRun(missing).stderr, /non-ui artifact missing/);
  const malformed = rerunFixture(t);
  assert.match(rerunRun(malformed, { proof: { version: 2 } }).stderr, /attempt job records malformed/);
  const same = fixture(t);
  assert.equal(rerunRun(same, { proof: null, attempt: '1' }).status, 0, 'one attempt needs no job records');
});

test('788 a missing job-records file only matters when a shard comes from an earlier attempt', t => {
  const f = fixture(t);
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: { ...metadata, runAttempt: 2 } }));
  const run = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out, '--sha', 'a'.repeat(40), '--run-id', '1234',
    '--attempt', '2', '--formal', 'true', '--attempt-jobs', join(f.root, 'absent.json')], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  const earlier = rerunFixture(t);
  const refused = spawnSync(process.execPath, [script, '--root', earlier.root, '--input', earlier.input, '--out', earlier.out, '--sha', 'a'.repeat(40), '--run-id', '1234',
    '--attempt', '2', '--formal', 'true', '--attempt-jobs', join(earlier.root, 'absent.json')], { encoding: 'utf8' });
  assert.match(refused.stderr, /no job records for the earlier attempts.*rerun all jobs of this run/);
});

// The fetch mode reads /actions/runs/{run}/attempts/{n} and its jobs for every attempt; a partial or failed read writes no file.
async function fakeApi(t, routes) {
  const { createServer } = await import('node:http');
  const seen = [];
  const server = createServer((req, res) => {
    seen.push({ url: req.url, auth: req.headers.authorization });
    const body = routes(req.url);
    if (body === undefined) { res.statusCode = 500; res.end('{}'); return; }
    res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(body));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  return { url: `http://127.0.0.1:${server.address().port}`, seen };
}
async function fetchMode(api, out, attempt = '2') {
  const { spawn } = await import('node:child_process');
  const child = spawn(process.execPath, [script, '--fetch-attempt-jobs', out, '--repo', 'owner/repo', '--run-id', '1234', '--attempt', attempt],
    { env: { ...process.env, GITHUB_API_URL: api.url, GH_TOKEN: 'token-for-test' } });
  let stdout = '', stderr = '';
  child.stdout.on('data', d => { stdout += d; }); child.stderr.on('data', d => { stderr += d; });
  const status = await new Promise(resolve => child.on('close', resolve));
  return { status, stdout, stderr };
}
const apiJob = (name, attempt, extra = {}) => ({ name, conclusion: 'success', run_attempt: attempt, head_sha: 'a'.repeat(40),
  started_at: '2026-11-19T02:48:04Z', completed_at: '2026-11-19T02:52:44Z', runner_name: 'GitHub Actions 1000009885', status: 'completed', ...extra });

test('788 fetch mode writes the job records of every attempt of this run', async t => {
  const api = await fakeApi(t, url => {
    const m = /^\/repos\/owner\/repo\/actions\/runs\/1234\/attempts\/([12])(\/jobs\?per_page=100&page=1)?$/.exec(url);
    if (!m) return undefined;
    const n = Number(m[1]);
    return m[2] ? { total_count: 1, jobs: [apiJob('Package tests (non-UI)', n)] } : { head_sha: 'a'.repeat(40), run_attempt: n };
  });
  const dir = mkdtempSync(join(tmpdir(), 'attempt-jobs-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const out = join(dir, 'attempt-jobs.json');
  const result = await fetchMode(api, out);
  assert.equal(result.status, 0, result.stderr);
  const proof = JSON.parse(readFileSync(out, 'utf8'));
  assert.deepEqual(proof, { version: 1, runId: '1234', attempt: 2, attempts: {
    1: { headSha: 'a'.repeat(40), jobs: [jobRecord('Package tests (non-UI)', 1)] },
    2: { headSha: 'a'.repeat(40), jobs: [jobRecord('Package tests (non-UI)', 2)] } } });
  assert.ok(api.seen.every(call => call.auth === 'Bearer token-for-test'), 'token sent');
});

test('788 fetch mode writes no file when a read fails or a job list is incomplete, and never fails the step', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'attempt-jobs-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const failing = await fakeApi(t, url => url.endsWith('/attempts/1') ? { head_sha: 'a'.repeat(40), run_attempt: 1 } : undefined);
  const out = join(dir, 'a.json');
  const failed = await fetchMode(failing, out);
  assert.equal(failed.status, 0);
  assert.match(failed.stderr, /cannot read the job records of earlier attempts.*a shard from an earlier attempt will be refused/);
  assert.equal(existsSync(out), false);
  const partial = await fakeApi(t, url => url.includes('/jobs') ? { total_count: 150, jobs: [apiJob('x', 1)] } : { head_sha: 'a'.repeat(40), run_attempt: 1 });
  const out2 = join(dir, 'b.json');
  const truncated = await fetchMode(partial, out2);
  assert.equal(truncated.status, 0);
  assert.match(truncated.stderr, /incomplete/);
  assert.equal(existsSync(out2), false);
  const first = await fakeApi(t, () => undefined);
  const out3 = join(dir, 'c.json');
  assert.equal((await fetchMode(first, out3, '1')).status, 0);
  assert.equal(existsSync(out3), false, 'attempt 1 has no earlier attempt to read');
  assert.equal(first.seen.length, 0, 'attempt 1 makes no API call');
});

test('788 skipped jobs without runner or times in the records do not matter; the shard job without them is refused', t => {
  const skipped = { name: 'App host comparison', conclusion: 'skipped', runAttempt: 1, headSha: 'a'.repeat(40), startedAt: '2026-11-19T02:48:01Z', completedAt: '2026-11-19T02:48:01Z', runnerName: null };
  const ok = rerunFixture(t);
  const accepted = rerunRun(ok, { proof: rerunProof(p => { p.attempts[1].jobs.push(skipped); p.attempts[2].jobs.push({ ...skipped, runAttempt: 2 }); return p; }) });
  assert.equal(accepted.status, 0, accepted.stderr);
  const bare = rerunFixture(t);
  const refused = rerunRun(bare, { proof: rerunProof(p => { for (const n of [1, 2]) p.attempts[n].jobs[0].runnerName = null; return p; }) });
  assert.match(refused.stderr, /job Package tests \(non-UI\) in attempt 1 has no start, end or runner to compare.*rerun all jobs of this run/);
});

// i788a-fix1 (audit F1): on a pull_request run github.sha is the refs/pull/N/merge commit (the artifacts' commit), while
// the run's and jobs' head_sha is the PR head (real run 44446895039: merge a3de15f3…, head d8804d5f…). The gate takes the
// head as --head-sha (default: --sha, as on push) and compares the job records with it; the artifacts stay tied to --sha.
const mergeSha = 'a'.repeat(40), prHead = 'c'.repeat(40);
const prProof = () => rerunProof(p => {
  for (const record of Object.values(p.attempts)) { record.headSha = prHead; for (const job of record.jobs) job.headSha = prHead; }
  return p;
});
function rerunRunHead(f, { proof = prProof(), headSha, sha = mergeSha } = {}) {
  const file = join(f.root, 'attempt-jobs.json');
  writeFileSync(file, JSON.stringify(proof));
  const args = [script, '--root', f.root, '--input', f.input, '--out', f.out, '--sha', sha, '--run-id', '1234', '--attempt', '2',
    '--formal', 'true', '--attempt-jobs', file];
  if (headSha !== undefined) args.push('--head-sha', headSha);
  return spawnSync(process.execPath, args, { encoding: 'utf8' });
}

test('788 fix1 a PR rerun: records at the PR head, artifacts at the merge commit, --head-sha accepts the carried shard', t => {
  const f = rerunFixture(t);
  const run = rerunRunHead(f, { headSha: prHead });
  assert.equal(run.status, 0, run.stderr + run.stdout);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /^Commit a{40}; run 1234; attempt 2; formal full-package evidence$/m);
  assert.match(report, /^non-ui shard from attempt 1 of run 1234 \(job Package tests \(non-UI\) succeeded there and was not re-run; checked against the run's job records\)$/m);
});

test('788 fix1 a push rerun: head and merge SHA are one commit, with or without --head-sha', t => {
  const plain = rerunFixture(t);
  assert.equal(rerunRunHead(plain, { proof: rerunProof() }).status, 0);
  const same = rerunFixture(t);
  assert.equal(rerunRunHead(same, { proof: rerunProof(), headSha: mergeSha }).status, 0);
});

test('788 fix1 the PR head is still checked: a wrong or missing head refuses, and the artifacts stay tied to --sha', t => {
  const cases = [
    ['PR records, no --head-sha', { headSha: undefined }, /attempt 1 head SHA c{40} is not a{40}/],
    ['other head', { headSha: 'd'.repeat(40) }, /attempt 1 head SHA c{40} is not d{40}/],
    ['job at another head', { headSha: prHead, proof: rerunProof(p => {
      for (const record of Object.values(p.attempts)) record.headSha = prHead;
      p.attempts[2].jobs[0].headSha = prHead;
      return p;
    }) }, /job Package tests \(non-UI\) head SHA a{40} in attempt 1 is not c{40}/],
  ];
  for (const [label, options, reason] of cases) {
    const f = rerunFixture(t);
    const run = rerunRunHead(f, options);
    assert.equal(run.status, 1, `${label}: ${run.stdout}`);
    assert.match(run.stderr, reason, label);
    assert.match(run.stderr, /rerun all jobs of this run/, label);
  }
  const headAsCommit = rerunFixture(t);
  const tied = rerunRunHead(headAsCommit, { headSha: prHead, sha: prHead });
  assert.match(tied.stderr, /commit provenance mismatch/, 'artifacts at the merge commit are not the PR head commit');
  const malformed = rerunFixture(t);
  assert.match(rerunRunHead(malformed, { headSha: 'xyz' }).stderr, /expected head SHA malformed/);
});

test('788 fix1 malformed or truncated job records refuse with the rerun-all instruction (gpt M1)', t => {
  for (const [label, body] of [['truncated', '{"version":1,"runId":"12'], ['wrong version', '{"version":2}'], ['not an object', 'null']]) {
    const f = rerunFixture(t);
    const file = join(f.root, 'attempt-jobs.json');
    writeFileSync(file, body);
    const run = spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out, '--sha', mergeSha, '--run-id', '1234',
      '--attempt', '2', '--formal', 'true', '--attempt-jobs', file], { encoding: 'utf8' });
    assert.equal(run.status, 1, label);
    assert.match(run.stderr, /attempt job records malformed.*rerun all jobs of this run/, label);
  }
});

test('788 fix1 the invalid-counter report also names a carried shard (opus L1)', t => {
  const f = rerunFixture(t);
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:1,1', 'DA:1,9223372036854775808') }));
  const run = rerunRun(f);
  assert.equal(run.status, 1, run.stderr);
  const report = readFileSync(f.out, 'utf8');
  assert.match(report, /Invalid coverage evidence/);
  assert.match(report, /^non-ui shard from attempt 1 of run 1234 \(job Package tests \(non-UI\) succeeded there and was not re-run; checked against the run's job records\)$/m);
});

// #788 item 2: while COVERAGE_ENFORCE is off, the shard upload may fail without failing its job, so the gate can find a
// shard artifact absent. Absent (no directory, or an empty one) is reported as unavailable and passes only with enforcement
// off; a shard that is present but wrong still fails either way.
const enforceRun = (f, enforce, { summary } = {}) => spawnSync(process.execPath, [script, '--root', f.root, '--input', f.input, '--out', f.out,
  '--sha', 'a'.repeat(40), '--run-id', '1234', '--attempt', '1', '--formal', 'true', ...(enforce === undefined ? [] : ['--enforce', enforce])],
{ encoding: 'utf8', env: { ...process.env, GITHUB_STEP_SUMMARY: summary ?? '' } });

test('788 item 2 verdict: enforcement off/on x shard present/missing', t => {
  for (const enforce of ['false', 'true']) {
    const present = fixture(t);
    const ok = enforceRun(present, enforce);
    assert.equal(ok.status, 0, `${enforce} present: ${ok.stderr}`);
    assert.match(readFileSync(present.out, 'utf8'), /^Coverage gate: PASS /m);
    assert.doesNotMatch(readFileSync(present.out, 'utf8'), /unavailable/i);
  }
  const off = fixture(t);
  rmSync(join(off.input, 'macui'), { recursive: true });
  const summary = join(off.root, 'summary.md');
  const pending = enforceRun(off, 'false', { summary });
  assert.equal(pending.status, 0, pending.stderr + pending.stdout);
  const report = readFileSync(off.out, 'utf8');
  assert.match(report, /^- macui: unavailable \(artifact package-coverage-macui absent; its upload failed or did not run\)$/m);
  assert.match(report, /^- non-ui: present and valid; not evaluated alone$/m);
  assert.match(report, /^Coverage gate: UNAVAILABLE \(COVERAGE_ENFORCE=false: a missing shard is reported, not failed; coverage not evaluated\)$/m);
  assert.doesNotMatch(report, /Coverage gate: (PASS|FAIL)/);
  assert.equal(pending.stdout, report);
  assert.match(readFileSync(summary, 'utf8'), /macui: unavailable/);
  for (const enforce of ['true', undefined]) {
    const on = fixture(t);
    rmSync(join(on.input, 'macui'), { recursive: true });
    const blocked = enforceRun(on, enforce);
    assert.equal(blocked.status, 1, `${enforce}: ${blocked.stdout}`);
    assert.match(blocked.stderr, /macui artifact missing or malformed/);
    assert.ok(!existsSync(on.out), 'no report claims a verdict');
  }
});

test('788 item 2 an empty download directory or both shards absent are unavailable only with enforcement off', t => {
  const empty = fixture(t);
  rmSync(join(empty.input, 'non-ui'), { recursive: true });
  mkdirSync(join(empty.input, 'non-ui'));
  const run = enforceRun(empty, 'false');
  assert.equal(run.status, 0, run.stderr);
  assert.match(readFileSync(empty.out, 'utf8'), /^- non-ui: unavailable /m);
  assert.equal(enforceRun(empty, 'true').status, 1);
  const both = fixture(t);
  rmSync(join(both.input, 'non-ui'), { recursive: true });
  rmSync(join(both.input, 'macui'), { recursive: true });
  const none = enforceRun(both, 'false');
  assert.equal(none.status, 0, none.stderr);
  const report = readFileSync(both.out, 'utf8');
  assert.match(report, /^- non-ui: unavailable /m);
  assert.match(report, /^- macui: unavailable /m);
  assert.match(report, /^Coverage gate: UNAVAILABLE /m);
});

test('788 item 2 a present but wrong or partial shard still fails with enforcement off', t => {
  const wrong = fixture(t);
  rmSync(join(wrong.input, 'macui'), { recursive: true });
  wrong.edit('non-ui', ({ metadata }) => ({ metadata: { ...metadata, commit: 'b'.repeat(40) } }));
  const mixed = enforceRun(wrong, 'false');
  assert.equal(mixed.status, 1, mixed.stdout);
  assert.match(mixed.stderr, /non-ui commit provenance mismatch/);
  const later = fixture(t);
  rmSync(join(later.input, 'non-ui'), { recursive: true });
  later.edit('macui', ({ metadata }) => ({ metadata: { ...metadata, runAttempt: 2 } }));
  assert.match(enforceRun(later, 'false').stderr, /macui attempt provenance mismatch/);
  const partial = fixture(t);
  rmSync(join(partial.input, 'macui', 'coverage.lcov'));
  const half = enforceRun(partial, 'false');
  assert.equal(half.status, 1, half.stdout);
  assert.match(half.stderr, /macui artifact missing or malformed/);
  const uncovered = fixture(t);
  for (const shard of ['non-ui', 'macui']) uncovered.edit(shard, ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:4,1', 'DA:4,0').replace('LH:2', 'LH:1') }));
  assert.equal(enforceRun(uncovered, 'false').status, 1, 'a real coverage FAIL is not softened by enforcement off');
});

test('788 item 2 --enforce accepts only true or false', t => {
  const f = fixture(t);
  for (const value of ['yes', 'TRUE', '1']) {
    const run = enforceRun(f, value);
    assert.equal(run.status, 1, value);
    assert.match(run.stderr, /invalid --enforce/);
  }
});

test('788 item 2 a present shard with wrapped counters still fails while the other shard is absent', t => {
  const f = fixture(t);
  rmSync(join(f.input, 'non-ui'), { recursive: true });
  f.edit('macui', ({ metadata, lcov }) => ({ metadata, lcov: lcov.replace('DA:1,1', 'DA:1,9223372036854775808') }));
  const run = enforceRun(f, 'false');
  assert.equal(run.status, 1, run.stdout);
  assert.match(run.stderr, /invalid counter evidence in a present shard:\n- shard=macui /);
});
