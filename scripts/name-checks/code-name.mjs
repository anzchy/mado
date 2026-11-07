#!/usr/bin/env node
import { readFileSync, readlinkSync, lstatSync } from 'node:fs';
import { isUtf8 } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { identityFor, forbiddenMatches } from './identity.mjs';

function reviewedRules(entries) {
  if (!Array.isArray(entries)) throw new Error('exceptions must be an array');
  return entries.map((entry, index) => {
    const invalid = () => { throw new Error(`invalid exception ${index + 1}: requires a selector, valid scopes and a nonempty reason`); };
    if (!entry || typeof entry !== 'object' || typeof entry.reason !== 'string' || !entry.reason.trim()) invalid();
    if (!entry.path && !entry.prefix && !entry.pathRegex && !entry.pattern) invalid();
    for (const key of ['path', 'prefix', 'pathRegex', 'pattern']) {
      if (entry[key] !== undefined && (typeof entry[key] !== 'string' || !entry[key])) invalid();
    }
    if (entry.prefix && !entry.prefix.endsWith('/')) invalid();
    const scopes = entry.scopes ?? ['path', 'content'];
    if (!Array.isArray(scopes) || !scopes.length || scopes.some(scope => !['path', 'content'].includes(scope))) invalid();
    try {
      const pattern = entry.pattern === undefined ? null : new RegExp(entry.pattern, 'g');
      const pathRegex = entry.pathRegex === undefined ? null : new RegExp(entry.pathRegex);
      if (pattern?.test('') || pathRegex?.test('')) invalid();
      return { ...entry, scopes, pattern, pathRegex };
    } catch (error) { throw new Error(`invalid exception ${index + 1}: ${error.message}`); }
  });
}

/** Reads exactly git's tracked paths; symlink targets are data, never directories to follow. */
export function scanRepository({ root = process.cwd(), expectedName, exceptions = [] }) {
  const expected = identityFor(expectedName);
  const rules = reviewedRules(exceptions);
  const paths = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'] }).split('\0').filter(Boolean).sort();
  if (!paths.length) throw new Error(`${root}: no tracked files to inspect`);
  const problems = [];
  function check(path, scope, text, location) {
    const applicable = rules.filter(rule => rule.scopes.includes(scope) && (!rule.path || rule.path === path) &&
      (!rule.prefix || path.startsWith(rule.prefix)) && (!rule.pathRegex || rule.pathRegex.test(path)));
    const allowed = applicable.flatMap(rule => rule.pattern
      ? [...text.matchAll(rule.pattern)].map(match => [match.index, match.index + match[0].length])
      : [[0, text.length]]);
    for (const hit of forbiddenMatches(text, expected.name)) {
      if (allowed.some(([start, end]) => hit.index >= start && hit.index + hit.length <= end)) continue;
      problems.push(`${path}:${location}:${hit.index + 1}: unexpected ${JSON.stringify(hit.name)}; expected ${expected.name}`);
    }
  }
  for (const path of paths) {
    check(path, 'path', path, 'path');
    let text;
    try {
      const absolute = resolve(root, path);
      if (lstatSync(absolute).isSymbolicLink()) text = readlinkSync(absolute);
      else {
        const buffer = readFileSync(absolute);
        if (buffer.includes(0) || !isUtf8(buffer)) continue;
        text = buffer.toString('utf8');
      }
    } catch (error) { throw new Error(`${path}: ${error.message}`); }
    for (const [index, line] of text.split(/\r?\n/).entries()) check(path, 'content', line, index + 1);
  }
  return problems;
}

function main(argv) {
  const options = { root: process.cwd(), exceptions: fileURLToPath(new URL('./exceptions.json', import.meta.url)) };
  while (argv.length) {
    const flag = argv.shift(), value = argv.shift();
    if (!['--root', '--exceptions', '--expected-name'].includes(flag) || !value || value.startsWith('--')) {
      throw new Error(`invalid argument ${flag}; expected --root, --exceptions or --expected-name and a value`);
    }
    options[flag.slice(2)] = value;
  }
  const expected = identityFor(options['expected-name']);
  let exceptions;
  try { exceptions = JSON.parse(readFileSync(options.exceptions, 'utf8')); }
  catch (error) { throw new Error(`${options.exceptions}: ${error.message}`); }
  const problems = scanRepository({ root: resolve(options.root), expectedName: expected.name, exceptions });
  for (const problem of problems) console.error(`FAIL ${problem}`);
  if (problems.length) return 1;
  console.log(`PASS tracked code identity ${expected.name}`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { console.error(`ERROR code-name: ${error.message}`); process.exitCode = 2; }
}
