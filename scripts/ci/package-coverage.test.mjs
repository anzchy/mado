import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';

const script = new URL('./package-coverage.mjs', import.meta.url).pathname;
const modules = ['MadoCore', 'MadoApplication', 'MadoInfrastructure', 'MadoMacUI'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const pathOf = (module) => module === 'MadoInfrastructure'
  ? 'Packages/MadoKit/Sources/MadoInfrastructure/Images/ImageSourceHeader.swift'
  : `Packages/MadoKit/Sources/${module}/A.swift`;
const source = module => module === 'MadoInfrastructure'
  ? 'func header() {\n  while false { break }\n  // end chunk\n  throw ImageDecodeError.unreadableImage\n}\n'
  : `func ${module}() {}\n`;
function record(file, lineHits, functionHits, sf = file) {
  const lines = lineHits.map(([line, hits]) => `DA:${line},${hits}`).join('\n');
  const fns = functionHits.map(([line, name, hits]) => `FN:${line},${name}\nFNDA:${hits},${name}`).join('\n');
  return `SF:${sf}\n${fns}\nFNF:${functionHits.length}\nFNH:${functionHits.filter(x => x[2] > 0).length}\n${lines}\nLF:${lineHits.length}\nLH:${lineHits.filter(x => x[1] > 0).length}\nend_of_record\n`;
}
function fixture(t, { left = {}, right = {} } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'package-coverage-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const input = join(root, 'artifacts');
  const inventory = {};
  for (const module of modules) {
    const file = pathOf(module), contents = source(module);
    mkdirSync(dirname(join(root, file)), { recursive: true });
    writeFileSync(join(root, file), contents);
    inventory[file] = hash(contents);
  }
  mkdirSync(join(root, 'scripts/ci'), { recursive: true });
  writeFileSync(join(root, 'scripts/ci/package-coverage-exceptions.json'), '[]\n');
  for (const [shard, hits] of [['non-ui', left], ['macui', right]]) {
    const directory = join(input, shard);
    mkdirSync(directory, { recursive: true });
    const lcov = modules.map(module => {
      const file = pathOf(module);
      const count = hits[module] ?? 1;
      return record(file, [[1, count], ...(module === 'MadoInfrastructure' ? [[4, count]] : [])], [[1, `${module}.fn`, count]]);
    }).join('');
    writeFileSync(join(directory, 'coverage.lcov'), lcov);
    writeFileSync(join(directory, 'metadata.json'), JSON.stringify({
      version: 1, shard, commit: 'a'.repeat(40), runId: '1234', runAttempt: 1,
      toolchain: { xcode: 'Xcode 26.6\nBuild version 17F113', swift: 'Swift 6.3.3', llvmCov: 'LLVM 21' },
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
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov.replace('FNDA:1,MadoCore.fn', 'FNDA:0,MadoCore.fn').replace('FNH:1', 'FNH:0') }));
  const run = f.run();
  assert.equal(run.status, 1, run.stderr);
  assert.match(readFileSync(f.out, 'utf8'), /MadoCore\/A.swift:1 function MadoCore.fn/);
});

test('reviewed declaration-only source is listed, while an empty module denominator fails', t => {
  const f = fixture(t);
  const extra = 'Packages/MadoKit/Sources/MadoCore/Declarations.swift';
  const contents = 'protocol EmptyPort { func read() }\n';
  writeFileSync(join(f.root, extra), contents);
  writeFileSync(join(f.root, 'scripts/ci/package-coverage-exceptions.json'),
    JSON.stringify([{ path: extra, reason: 'Protocol requirement only.' }]));
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata }) => ({ metadata: {
    ...metadata, sourceInventory: { ...metadata.sourceInventory, [extra]: hash(contents) },
  } }));
  assert.equal(f.run().status, 0);
  assert.match(readFileSync(f.out, 'utf8'), /Declarations.swift: Protocol requirement only/);
  // Exempting every mapped file in a module cannot make its zero denominator pass.
  writeFileSync(join(f.root, 'scripts/ci/package-coverage-exceptions.json'),
    JSON.stringify([{ path: extra, reason: 'Protocol requirement only.' }, { path: pathOf('MadoCore'), reason: 'Fixture declaration.' }]));
  for (const shard of ['non-ui', 'macui']) f.edit(shard, ({ metadata, lcov }) => ({ metadata,
    lcov: lcov.replace(new RegExp(`SF:${pathOf('MadoCore')}[\\s\\S]*?end_of_record\\n`), '') }));
  assert.match(f.run().stderr, /MadoCore: zero denominator/);
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
