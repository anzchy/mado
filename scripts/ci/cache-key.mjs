#!/usr/bin/env node
// Prints the cache key and restore prefix for a build-products cache (SwiftPM .build or Xcode DerivedData).
//
//   node scripts/ci/cache-key.mjs <spm|dd> <manifest-hash> <inputs-hash>
//
// key    = <family>-v<FORMAT>-<os>-<arch>-xcode<build>-swift<toolchain>-workspace<path-hash>-<manifest-hash>-<inputs-hash>
// prefix = the key without <inputs-hash>
// The manifest hash covers what decides the package graph: Package.swift and any Package.resolved for `spm`, plus
// project.yml and the xcode-setup action for `dd`. The inputs hash covers every source and resource the build reads. A restore by prefix therefore only ever starts from a
// build of the same toolchain and package graph; the compiler's incremental file hashing rebuilds what differs.
// Build products embed absolute paths (including compiled module-cache paths). Hash the absolute GITHUB_WORKSPACE
// into both key and prefix so neither an exact nor a fallback restore can cross checkout paths.
// Bump FORMAT to discard every existing entry.
import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const FORMAT = 1;
const FAMILIES = new Set(['spm', 'spm-coverage', 'dd']);

export function cacheKey({ family, manifest, inputs, os, arch, xcodeVersion, swiftVersion, workspace }) {
  if (!FAMILIES.has(family)) throw new Error(`unknown cache family ${family}`);
  for (const [name, hash] of Object.entries({ manifest, inputs })) {
    if (!/^[0-9a-f]{64}$/.test(hash ?? '')) throw new Error(`${name} hash must be 64 hex characters (empty means no files matched)`);
  }
  if (!/^[A-Za-z]+$/.test(os ?? '') || !/^[A-Za-z0-9]+$/.test(arch ?? '')) throw new Error('runner OS and arch are required');
  const build = (xcodeVersion ?? '').match(/^Build version ([0-9A-Za-z]+)$/m)?.[1];
  if (!build) throw new Error('cannot read the Xcode build version');
  const swift = (swiftVersion ?? '').split(/\r?\n/).find(line => /Swift version/.test(line));
  if (!swift) throw new Error('cannot read the Swift toolchain version');
  if (typeof workspace !== 'string' || !path.isAbsolute(workspace)) throw new Error('absolute workspace path is required');
  const checkout = createHash('sha256').update(workspace).digest('hex').slice(0, 16);
  const toolchain = createHash('sha256').update(swift.trim()).digest('hex').slice(0, 16);
  const prefix = `${family}-v${FORMAT}-${os}-${arch}-xcode${build}-swift${toolchain}-workspace${checkout}-${manifest}-`;
  return { prefix, key: `${prefix}${inputs}` };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [family, manifest, inputs] = process.argv.slice(2);
  const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const { prefix, key } = cacheKey({ family, manifest, inputs, os: process.env.RUNNER_OS, arch: process.env.RUNNER_ARCH, workspace: process.env.GITHUB_WORKSPACE,
    xcodeVersion: run('xcodebuild', ['-version']), swiftVersion: run('xcrun', ['swift', '--version']) });
  console.log(`cache-key: ${key}`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `key=${key}\nprefix=${prefix}\n`);
}
