import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { checkBuiltProduct } from './built-product.mjs';
import { identityFor, forbiddenMatches } from './identity.mjs';

const mach = 'com.apple.security.temporary-exception.mach-lookup.global-name';
const info = {
  CFBundleName: 'Picsee', CFBundleDisplayName: 'Picsee', CFBundleIdentifier: 'io.github.anzchy.picsee',
  SUFeedURL: 'https://raw.githubusercontent.com/anzchy/picsee/main/appcast.xml',
};
const pair = ['io.github.anzchy.picsee-spks', 'io.github.anzchy.picsee-spki'];
const unit = value => ({ stringUnit: { state: 'translated', value } });
const catalog = strings => ({ path: 'App/Resources/Localizable.xcstrings', data: { sourceLanguage: 'en', strings } });
const fixture = () => ({ info: { ...info }, entitlements: { [mach]: [...pair] }, catalogs: [catalog({
  greeting: { localizations: { en: unit('Welcome to Picsee'), 'zh-Hans': unit('打开 picsee') } },
})] });

test('literal current identity passes; changing only expectation to Mado lists every place', () => {
  assert.deepEqual(checkBuiltProduct(fixture(), 'Picsee'), []);
  const failures = checkBuiltProduct(fixture(), 'Mado');
  assert.equal(failures.length, 7, failures.join('\n'));
  for (const location of ['CFBundleName', 'CFBundleDisplayName', 'CFBundleIdentifier', 'SUFeedURL', mach,
    '/localizations/en/stringUnit/value', '/localizations/zh-Hans/stringUnit/value']) {
    assert.equal(failures.filter(message => message.includes(location)).length, 1, location);
  }
  assert.ok(failures.every(message => message.includes('Mado') || message.includes('mado')));
});

test('every required metadata field and exact entitlement pair are checked independently', () => {
  for (const key of Object.keys(info)) {
    for (const value of ['Wrong', undefined]) {
      const input = fixture();
      input.info[key] = value;
      const failures = checkBuiltProduct(input, 'Picsee');
      assert.equal(failures.length, 1);
      assert.ok(failures[0].includes(key));
    }
  }
  for (const value of [undefined, 'not an array', [], [pair[0]], [pair[0], pair[0]], [...pair, 'extra'],
    ['wrong-spks', 'wrong-spki'], ['$(PRODUCT_BUNDLE_IDENTIFIER)-spks', '$(PRODUCT_BUNDLE_IDENTIFIER)-spki']]) {
    const input = fixture();
    input.entitlements[mach] = value;
    const failures = checkBuiltProduct(input, 'Picsee');
    assert.equal(failures.length, 1);
    assert.ok(failures[0].includes(mach));
  }
  const reordered = fixture();
  reordered.entitlements[mach].reverse();
  assert.deepEqual(checkBuiltProduct(reordered, 'Picsee'), []);
});

test('all en/zh nested variants, each occurrence and source fallback are scanned, not keys or comments', () => {
  const input = fixture();
  input.catalogs = [catalog({
    'Mado key only': { comment: 'Mado comment', localizations: { en: unit('safe'), 'zh-Hans': unit('安全') } },
    variants: { localizations: {
      en: { variations: { plural: { one: unit('Mado'), other: unit('MADO mado') } } },
      'en-GB': { variations: { device: { mac: unit('mado') } } },
      'zh-Hant': unit('使用Mado'), fr: unit('Mado'),
    } },
    'Open Mado': { localizations: { 'zh-Hans': unit('安全') } },
  })];
  const failures = checkBuiltProduct(input, 'Picsee');
  assert.equal(failures.length, 6, failures.join('\n'));
  for (const location of ['/en/variations/plural/one/stringUnit/value', '/en/variations/plural/other/stringUnit/value',
    '/en-GB/variations/device/mac/stringUnit/value', '/zh-Hant/stringUnit/value', '/Open Mado/source/en']) {
    assert.ok(failures.some(message => message.includes(location)), location);
  }
  assert.ok(failures.every(message => !message.includes('Mado key only') && !message.includes('/fr/')));
});

test('finite identity swap and additive localization diagnostics obey symmetry and locality', () => {
  const first = fixture();
  const second = JSON.parse(JSON.stringify(first).replaceAll('Picsee', 'Mado').replaceAll('picsee', 'mado'));
  for (const [artifact, own, other] of [[first, 'Picsee', 'Mado'], [second, 'Mado', 'Picsee']]) {
    assert.deepEqual(checkBuiltProduct(artifact, own), []);
    assert.equal(checkBuiltProduct(artifact, other).length, 7);
    const before = checkBuiltProduct(artifact, other);
    artifact.catalogs[0].data.strings.extra = { localizations: { en: unit(`Open ${own}`) } };
    const after = checkBuiltProduct(artifact, other);
    assert.deepEqual(after.filter(message => !message.includes('/extra/')), before);
    assert.equal(after.length, before.length + 1);
  }
});

test('identifier matching is symmetric and insensitive without English substring false positives', () => {
  for (const [expected, other] of [['Picsee', 'Mado'], ['Mado', 'Picsee']]) {
    for (const value of [other, other.toLowerCase(), other.toUpperCase(), `${other}Kit`, `launch${other}Window`,
      `${other.toLowerCase()}-wt`, `${other.toUpperCase()}_LOCK`, `io.github.${other.toLowerCase()}`, `打开${other}图片`]) {
      assert.equal(forbiddenMatches(value, expected).length, 1, value);
    }
    assert.deepEqual(forbiddenMatches(`${expected}Kit ${expected.toLowerCase()}-wt`, expected), []);
  }
  for (const word of ['amador', 'madora', 'madonna', 'picseeing', 'epicsee', 'armadorn']) {
    for (const expected of ['Picsee', 'Mado']) assert.deepEqual(forbiddenMatches(word, expected), [], word);
  }
  assert.equal(forbiddenMatches('mAdO', 'Picsee').length, 1);
  assert.equal(forbiddenMatches('pIcSeE', 'Mado').length, 1);
  assert.throws(() => identityFor('Other'), /unknown.*identity/i);
});

test('malformed catalog structures and empty discovery fail closed', () => {
  assert.throws(() => checkBuiltProduct({ ...fixture(), catalogs: [] }, 'Picsee'), /catalog/i);
  for (const data of [{}, { sourceLanguage: 'en', strings: [] }, { sourceLanguage: 'en', strings: { key: {
    localizations: { en: { stringUnit: { value: 123 } } },
  } } }]) {
    assert.throws(() => checkBuiltProduct({ ...fixture(), catalogs: [{ path: 'bad.xcstrings', data }] }, 'Picsee'), /bad.xcstrings/);
  }
});

function plist(value) {
  if (typeof value === 'string') return `<string>${value}</string>`;
  if (Array.isArray(value)) return `<array>${value.map(plist).join('')}</array>`;
  return `<dict>${Object.entries(value).map(([key, item]) => `<key>${key}</key>${plist(item)}`).join('')}</dict>`;
}
const xml = value => `<?xml version="1.0"?><plist version="1.0">${plist(value)}</plist>`;
const script = fileURLToPath(new URL('./built-product.mjs', import.meta.url));
function diskFixture() {
  const root = mkdtempSync(join(tmpdir(), 'identity-product-'));
  const app = join(root, 'Fixture.app');
  mkdirSync(join(app, 'Contents'), { recursive: true });
  writeFileSync(join(app, 'Contents/Info.plist'), xml(info));
  const entitlement = join(root, 'app.entitlements');
  writeFileSync(entitlement, xml({ [mach]: ['$(PRODUCT_BUNDLE_IDENTIFIER)-spks', '$(PRODUCT_BUNDLE_IDENTIFIER)-spki'] }));
  const strings = join(root, 'Localizable.xcstrings');
  writeFileSync(strings, JSON.stringify(fixture().catalogs[0].data));
  return { root, app, entitlement, strings };
}
const run = (f, extra = []) => spawnSync(process.execPath, [script, f.app, '--entitlements', f.entitlement,
  '--catalog', f.strings, ...extra], { encoding: 'utf8' });

test('public CLI reads built metadata and explicit unsigned template with honest output and full bite list', () => {
  const f = diskFixture();
  const before = readFileSync(join(f.app, 'Contents/Info.plist'), 'utf8');
  const pass = run(f);
  assert.equal(pass.status, 0, pass.stderr);
  assert.match(pass.stdout, /PASS.*Picsee/);
  assert.match(pass.stdout, /unsigned.*template/i);
  const fail = run(f, ['--expected-name', 'Mado']);
  assert.equal(fail.status, 1, fail.stderr);
  for (const field of [...Object.keys(info), mach, '/localizations/en/', '/localizations/zh-Hans/']) {
    assert.ok(fail.stderr.includes(field), field);
  }
  assert.equal(readFileSync(join(f.app, 'Contents/Info.plist'), 'utf8'), before);
});

test('public CLI rejects missing, corrupt, unresolved, unknown and empty input instead of passing', () => {
  const f = diskFixture();
  for (const args of [['--expected-name', 'Other'], ['--wat'], ['--expected-name']]) {
    const result = run(f, args);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /identity|argument|usage|expected/i);
  }
  for (const field of ['app', 'entitlement', 'strings']) {
    const result = run({ ...f, [field]: join(f.root, `missing-${field}`) });
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.includes(`missing-${field}`));
  }
  for (const [file, content] of [[f.strings, '{'], [f.entitlement, 'bad plist'],
    [join(f.app, 'Contents/Info.plist'), 'bad plist']]) {
    const original = readFileSync(file);
    writeFileSync(file, content);
    const result = run(f);
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.includes(file));
    writeFileSync(file, original);
  }
  for (const names of [['$(UNKNOWN)-spks', '$(UNKNOWN)-spki'], ['another-spks', 'another-spki']]) {
    writeFileSync(f.entitlement, xml({ [mach]: names }));
    const result = run(f);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /mach-lookup|unresolved/);
  }
  const noCatalog = spawnSync(process.execPath, [script, f.app, '--entitlements', f.entitlement, '--root', f.root], { encoding: 'utf8' });
  assert.notEqual(noCatalog.status, 0);
  assert.match(noCatalog.stderr, /catalog|git/i);
});

test('unsigned CLI missing Sparkle key still lists all identity failures without a generic TypeError', () => {
  const f = diskFixture();
  writeFileSync(f.entitlement, xml({}));
  const result = run(f, ['--expected-name', 'Mado']);
  assert.equal(result.status, 1, result.stderr);
  for (const location of [...Object.keys(info), mach, '/localizations/en/', '/localizations/zh-Hans/']) {
    assert.ok(result.stderr.includes(location), location);
  }
  assert.doesNotMatch(result.stderr, /TypeError|reading 'includes'/);
});
