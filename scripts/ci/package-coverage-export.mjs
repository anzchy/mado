#!/usr/bin/env node
// Export one completed SwiftPM test shard. Metadata is written last, so an
// interrupted or incompatible LLVM export cannot become a complete artifact.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { coverageAtomicSwiftArgs, coverageAtomicScratchPath, ATOMIC_COVERAGE_FLAG_ID } from './coverage-atomic.mjs';

const modules = ['MadoCore', 'MadoApplication', 'MadoInfrastructure', 'MadoMacUI'];
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const readVersion = (command, args, options) => {
  const value = execFileSync(command, args, { ...options, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).trim();
  if (!value) throw new Error(`${command} ${args.join(' ')} returned no version`);
  return value;
};

function parseArgs(args) {
  const accepted = new Set(['root', 'shard', 'out', 'commit', 'run-id', 'attempt', 'not-before']);
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    if (!flag?.startsWith('--') || !accepted.has(flag.slice(2)) || index + 1 >= args.length || options[flag.slice(2)] !== undefined) {
      throw new Error(`invalid or duplicate option ${flag ?? '(missing)'}`);
    }
    options[flag.slice(2)] = args[index + 1];
  }
  const root = path.resolve(options.root ?? process.cwd());
  const shard = options.shard;
  if (!['non-ui', 'macui'].includes(shard)) throw new Error('shard must be non-ui or macui');
  if (!options.out) throw new Error('out directory is required');
  if (!/^[0-9a-f]{40}$/.test(options.commit ?? '')) throw new Error('commit must be a 40-digit lowercase SHA');
  if (!/^[1-9][0-9]*$/.test(options['run-id'] ?? '')) throw new Error('run-id must be a positive decimal integer');
  if (!/^[1-9][0-9]*$/.test(options.attempt ?? '') || !Number.isSafeInteger(Number(options.attempt))) throw new Error('attempt must be a positive integer');
  if (!/^[0-9]+$/.test(options['not-before'] ?? '') || !Number.isSafeInteger(Number(options['not-before']))) {
    throw new Error('not-before must be a Unix timestamp in seconds');
  }
  return { root, shard, out: path.resolve(root, options.out), commit: options.commit, runId: options['run-id'],
    runAttempt: Number(options.attempt), notBefore: Number(options['not-before']) };
}

function sourceInventory(root) {
  const inventory = {};
  for (const module of modules) {
    const directory = path.join(root, 'Packages/MadoKit/Sources', module);
    if (!statSync(directory).isDirectory()) throw new Error(`source module is missing: ${module}`);
    const visit = dir => {
      for (const item of readdirSync(dir, { withFileTypes: true })) {
        const absolute = path.join(dir, item.name);
        if (item.isDirectory()) visit(absolute);
        else if (item.isFile() && item.name.endsWith('.swift')) {
          const relative = path.relative(root, absolute).split(path.sep).join('/');
          inventory[relative] = sha256(readFileSync(absolute));
        }
      }
    };
    visit(directory);
    if (!Object.keys(inventory).some(name => name.startsWith(`Packages/MadoKit/Sources/${module}/`))) {
      throw new Error(`source module has no Swift files: ${module}`);
    }
  }
  return Object.fromEntries(Object.entries(inventory).sort(([a], [b]) => a.localeCompare(b)));
}

function regularNonempty(file, label) {
  if (!existsSync(file)) throw new Error(`${label} is missing: ${file}`);
  const stat = statSync(file);
  if (!stat.isFile() || stat.size === 0) throw new Error(`${label} is empty or not a file: ${file}`);
  return stat;
}

export function exportShard(options) {
  const { root, shard, out, commit, runId, runAttempt, notBefore } = options;
  if (existsSync(path.join(out, 'metadata.json')) || existsSync(path.join(out, 'coverage.lcov'))) {
    throw new Error(`output directory already contains a coverage artifact: ${out}`);
  }
  const packagePath = path.join(root, 'Packages/MadoKit');
  const bin = readVersion('swift', ['build', '--package-path', packagePath, '--scratch-path', path.join(root, coverageAtomicScratchPath), '--show-bin-path'], { cwd: root });
  if (!path.isAbsolute(bin)) throw new Error(`swift returned non-absolute binary path: ${bin}`);
  const profilePath = path.join(bin, 'codecov/default.profdata');
  const profileStat = regularNonempty(profilePath, 'profile');
  if (profileStat.mtimeMs < notBefore * 1000 || profileStat.mtimeMs > Date.now() + 60_000) {
    throw new Error(`profile is stale or has an invalid timestamp: ${profilePath}`);
  }
  const binaryPath = path.join(bin, 'MadoKitPackageTests.xctest/Contents/MacOS/MadoKitPackageTests');
  regularNonempty(binaryPath, 'binary');
  const sourceInventoryHashes = sourceInventory(root);
  const toolchain = {
    xcode: readVersion('xcodebuild', ['-version'], { cwd: root }),
    swift: readVersion('xcrun', ['swift', '--version'], { cwd: root }),
    llvmCov: readVersion('xcrun', ['llvm-cov', '--version'], { cwd: root }),
  };
  // llvm-cov itself rejects a profile that does not match this binary.
  const exported = spawnSync('xcrun', ['llvm-cov', 'export', '-format=lcov', '-instr-profile', profilePath, binaryPath,
    '-ignore-filename-regex=(\\.build/|/Tests/)'], { cwd: root, maxBuffer: 64 * 1024 * 1024 });
  if (exported.error || exported.status !== 0 || exported.signal || exported.stderr?.length) {
    const diagnostic = exported.stderr?.toString('utf8').trim() || exported.error?.message || `exit=${exported.status} signal=${exported.signal}`;
    throw new Error(`LLVM export failed or reported a warning: ${diagnostic}`);
  }
  const lcov = exported.stdout;
  const contents = lcov.toString('utf8');
  if (!/^SF:/m.test(contents) || !/^DA:/m.test(contents) || !/^FN:/m.test(contents) || !/^FNDA:/m.test(contents) ||
      !/^end_of_record$/m.test(contents)) throw new Error('LLVM export contained no complete LCOV production mapping');
  const metadata = {
    version: 1, shard, commit, runId, runAttempt, toolchain,
    instrumentation: { swiftArgs: coverageAtomicSwiftArgs, scratchPath: coverageAtomicScratchPath, flagId: ATOMIC_COVERAGE_FLAG_ID },
    binary: { path: binaryPath, sha256: sha256(readFileSync(binaryPath)) },
    profile: { path: profilePath, sha256: sha256(readFileSync(profilePath)) },
    lcovSha256: sha256(lcov), sourceInventory: sourceInventoryHashes,
  };
  mkdirSync(out, { recursive: true });
  writeFileSync(path.join(out, 'coverage.lcov'), lcov);
  writeFileSync(path.join(out, 'metadata.json'), JSON.stringify(metadata, null, 2) + '\n');
  return metadata;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const result = exportShard(options);
    console.log(`package-coverage-export: ${result.shard} ${Object.keys(result.sourceInventory).length} sources, binary=${result.binary.sha256} profile=${result.profile.sha256}`);
  } catch (error) {
    console.error(`package-coverage-export: ${error.message}`);
    process.exitCode = 1;
  }
}
