#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parsePlistXml } from '../release/check-entitlements.mjs';
import { identityFor, forbiddenMatches } from './identity.mjs';

const MACH = 'com.apple.security.temporary-exception.mach-lookup.global-name';
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const part = value => value.replaceAll('~', '~0').replaceAll('/', '~1');
const relevantLocale = locale => /^(en|zh)(-|$)/i.test(locale);

/** Checks observed metadata, resolved entitlements and source catalog values; returns every violation. */
export function checkBuiltProduct({ info, entitlements, catalogs }, expectedName) {
  const expected = identityFor(expectedName);
  const problems = [];
  for (const [key, value] of Object.entries(expected.info)) {
    if (key === 'SUFeedURL' && value === null) {
      problems.push(`Info.plist:SUFeedURL undecided for ${expected.name} (decided in #552)`);
    } else if (info?.[key] !== value) problems.push(`Info.plist:${key}: expected ${JSON.stringify(value)}, found ${JSON.stringify(info?.[key])}`);
  }
  const names = entitlements?.[MACH];
  if (!Array.isArray(names) || names.length !== expected.machLookup.length || !expected.machLookup.every(name => names.includes(name))) {
    problems.push(`entitlements:${MACH}: expected ${JSON.stringify(expected.machLookup)}, found ${JSON.stringify(names)}`);
  }
  if (!Array.isArray(catalogs) || !catalogs.length) throw new Error('no String Catalogs to inspect');
  for (const { path, data } of catalogs) {
    const invalid = location => { throw new Error(`${path}: malformed String Catalog at ${location}`); };
    if (!object(data) || !object(data.strings) || typeof data.sourceLanguage !== 'string') invalid('root');
    const check = (value, location) => {
      for (const hit of forbiddenMatches(value, expected.name)) {
        problems.push(`${path}#${location}:${hit.index + 1}: unexpected ${JSON.stringify(hit.name)}; expected ${expected.name}`);
      }
    };
    function walk(node, location) {
      if (!object(node)) return 0;
      let count = 0;
      if ('stringUnit' in node) {
        if (!object(node.stringUnit) || typeof node.stringUnit.value !== 'string') invalid(location + '/stringUnit/value');
        check(node.stringUnit.value, location + '/stringUnit/value');
        count++;
      }
      for (const [key, child] of Object.entries(node)) {
        if (key !== 'stringUnit') count += walk(child, location + '/' + part(key));
      }
      return count;
    }
    for (const [key, entry] of Object.entries(data.strings)) {
      if (!object(entry) || (entry.localizations !== undefined && !object(entry.localizations))) invalid('/strings/' + part(key));
      const base = '/strings/' + part(key);
      let sourceValues = 0;
      for (const [locale, localization] of Object.entries(entry.localizations ?? {})) {
        if (!relevantLocale(locale)) continue;
        if (!object(localization)) invalid(base + '/localizations/' + part(locale));
        const count = walk(localization, base + '/localizations/' + part(locale));
        if (locale === data.sourceLanguage) sourceValues += count;
      }
      // Without a source-language translation, the catalog key itself is what users see.
      if (relevantLocale(data.sourceLanguage) && !sourceValues) check(key, base + '/source/' + part(data.sourceLanguage));
    }
  }
  return problems;
}

function readPlist(path) {
  try {
    const buffer = readFileSync(path);
    const xml = buffer.subarray(0, 6).toString() === 'bplist'
      ? execFileSync('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', path], { encoding: 'utf8' })
      : buffer.toString('utf8');
    return parsePlistXml(xml);
  } catch (error) { throw new Error(`${path}: ${error.message}`); }
}

function main(argv) {
  const app = argv.shift();
  if (!app || app.startsWith('--')) throw new Error('usage: built-product.mjs <app> [--entitlements <unsigned-source-template>] [--catalog <file>] [--root <repo>] [--expected-name <name>]');
  const options = { root: process.cwd(), catalogs: [] };
  while (argv.length) {
    const flag = argv.shift(), value = argv.shift();
    if (!['--entitlements', '--catalog', '--root', '--expected-name'].includes(flag) || !value || value.startsWith('--')) {
      throw new Error(`invalid argument ${flag}; expected a flag and value`);
    }
    if (flag === '--catalog') options.catalogs.push(value);
    else options[flag.slice(2)] = value;
  }
  const expected = identityFor(options['expected-name']);
  const root = resolve(options.root), appPath = resolve(root, app);
  const info = readPlist(join(appPath, 'Contents/Info.plist'));
  let entitlements;
  if (options.entitlements) {
    const path = resolve(root, options.entitlements);
    entitlements = readPlist(path);
    const names = entitlements[MACH];
    if (Array.isArray(names)) entitlements[MACH] = names.map(name => typeof name === 'string'
      ? name.replaceAll('$(PRODUCT_BUNDLE_IDENTIFIER)', info.CFBundleIdentifier ?? '') : name);
    if (JSON.stringify(entitlements[MACH] ?? null).includes('$(')) throw new Error(`${path}: unresolved mach-lookup build variable`);
    console.log(`unsigned source-template entitlements: ${path} (expanded with built bundle ID; not a signature check)`);
  } else {
    const xml = execFileSync('/usr/bin/codesign', ['-d', '--entitlements', '-', '--xml', appPath], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    entitlements = parsePlistXml(xml);
  }
  const paths = options.catalogs.length ? options.catalogs : execFileSync('git', ['-C', root, 'ls-files', '-z', '--', '*.xcstrings'], { encoding: 'utf8' }).split('\0').filter(Boolean);
  const catalogs = paths.map(path => {
    const absolute = resolve(root, path);
    try { return { path, data: JSON.parse(readFileSync(absolute, 'utf8')) }; }
    catch (error) { throw new Error(`${absolute}: ${error.message}`); }
  });
  const problems = checkBuiltProduct({ info, entitlements, catalogs }, expected.name);
  for (const problem of problems) console.error(`FAIL ${problem}`);
  if (problems.length) return 1;
  console.log(`PASS built-product identity ${expected.name}: ${appPath}; ${catalogs.length} String Catalog(s)`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { console.error(`ERROR built-product: ${error.message}`); process.exitCode = 2; }
}
