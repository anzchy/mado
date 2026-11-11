#!/usr/bin/env node
// Clear only SwiftPM coverage data after a build-cache restore. Build objects
// remain available for incremental compilation; old counters never do.
import { existsSync, readdirSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { coverageAtomicScratchPath } from './coverage-atomic.mjs';

const root = process.argv.length === 4 && process.argv[2] === '--root'
  ? path.resolve(process.argv[3])
  : process.argv.length === 2 ? process.cwd() : null;
if (!root) throw new Error('usage: package-coverage-clear.mjs [--root <checkout>]');

const packageDir = path.join(root, 'Packages/MadoKit');
const buildDir = path.join(root, coverageAtomicScratchPath);
if (existsSync(buildDir)) {
  for (const architecture of readdirSync(buildDir, { withFileTypes: true })) {
    if (!architecture.isDirectory()) continue;
    const codecov = path.join(buildDir, architecture.name, 'debug/codecov');
    if (!existsSync(codecov)) continue;
    for (const entry of readdirSync(codecov, { withFileTypes: true })) {
      if (entry.isFile() && /\.(profraw|profdata)$/.test(entry.name)) unlinkSync(path.join(codecov, entry.name));
    }
  }
}
const rootProfile = path.join(packageDir, 'default.profraw');
if (existsSync(rootProfile)) unlinkSync(rootProfile);
console.log('package-coverage-clear: stale profiles removed');
