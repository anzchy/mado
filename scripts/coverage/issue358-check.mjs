#!/usr/bin/env node
// Validate raw coverage for the two real Swift functions affected by #358.
import { readFileSync } from 'node:fs';

const [lcovPath, textPath] = process.argv.slice(2);
if (!lcovPath || !textPath) {
  process.stderr.write('usage: node scripts/coverage/issue358-check.mjs <coverage.lcov> <coverage.json>\n');
  process.exit(2);
}

const targets = [
  {
    path: 'Packages/MadoKit/Sources/MadoInfrastructure/FileAccess/FileAccess.swift',
    symbol: /FileAccessC20persistedDestination/,
  },
  {
    path: 'Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift',
    symbol: /ViewerChromeOverlayC7hitTest.*CGPointVF$/,
  },
];
const floor = 1n << 63n;
const text = JSON.parse(readFileSync(textPath, 'utf8'));
const lcov = readFileSync(lcovPath, 'utf8');
const records = new Map();
let file;
for (const raw of lcov.split(/\r?\n/)) {
  if (raw.startsWith('SF:')) file = raw.slice(3);
  else if (raw.startsWith('end_of_record')) file = undefined;
  else if (file && raw.startsWith('DA:')) {
    const [line, count] = raw.slice(3).split(',');
    const key = `${file}:${line}`;
    if (records.has(key)) throw new Error(`duplicate DA ${key}`);
    records.set(key, BigInt(count));
  }
}

const failures = [];
for (const target of targets) {
  const matches = text.data.flatMap((data) => data.functions)
    .filter((fn) => target.symbol.test(fn.name) && fn.filenames.some((name) => name.endsWith(target.path)));
  if (matches.length !== 1) {
    failures.push(`${target.path}: expected one real function mapping, found ${matches.length}`);
    continue;
  }
  const fn = matches[0];
  const source = fn.filenames.find((name) => name.endsWith(target.path));
  const start = fn.regions[0]?.[0];
  const end = fn.regions[0]?.[2];
  if (!start || !end || end < start) {
    failures.push(`${target.path}: missing executable function region`);
    continue;
  }
  let seen = 0;
  for (let line = start; line <= end; line++) {
    const count = records.get(`${source}:${line}`);
    if (count === undefined) continue;
    seen++;
    if (count >= floor) failures.push(`${target.path}:${line} DA=${count} invalid (>= 2^63)`);
  }
  if (seen === 0) failures.push(`${target.path}: no LCOV DA records within function ${start}-${end}`);
  // The final mapped region is the loop exit and `return nil`, immediately before
  // the function's closing brace. General DA presence does not prove these lines exist.
  const exits = fn.regions.filter((region) => region[0] === end - 2 && region[2] === end - 1);
  if (exits.length !== 1) {
    failures.push(`${target.path}: expected one post-loop region at ${end - 2}-${end - 1}, found ${exits.length}`);
  } else {
    for (const line of [end - 2, end - 1]) {
      const count = records.get(`${source}:${line}`);
      if (count === undefined) failures.push(`${target.path}:${line} missing post-loop DA`);
      else if (count >= floor) failures.push(`${target.path}:${line} post-loop DA=${count} invalid (>= 2^63)`);
    }
  }
  for (const region of fn.regions) {
    if (BigInt(region[4]) >= floor) {
      failures.push(`${target.path}:${region[0]}:${region[1]} region invalid/saturated (>= 2^63)`);
    }
  }
  process.stdout.write(`${target.path}: ${seen} DA records, function ${fn.count}, lines ${start}-${end}\n`);
}
if (failures.length) {
  for (const failure of failures) process.stderr.write(`issue358 coverage RED: ${failure}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write('issue358 coverage GREEN: both function mappings finite\n');
}
