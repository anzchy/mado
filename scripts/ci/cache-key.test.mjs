import test from 'node:test';
import assert from 'node:assert/strict';
import { cacheKey, FORMAT } from './cache-key.mjs';

const hash = c => c.repeat(64);
const base = { family: 'spm', manifest: hash('a'), inputs: hash('b'), os: 'macOS', arch: 'ARM64',
  xcodeVersion: 'Xcode 26.6\nBuild version 17F113\n',
  swiftVersion: 'swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0\n' };

test('key names family, format, runner, Xcode build, toolchain, manifest and inputs; prefix drops only the inputs', () => {
  const { key, prefix } = cacheKey(base);
  assert.match(prefix, new RegExp(`^spm-v${FORMAT}-macOS-ARM64-xcode17F113-swift[0-9a-f]{16}-${hash('a')}-$`));
  assert.equal(key, `${prefix}${hash('b')}`);
});

test('every input that can change the build changes the key, and all but the inputs hash change the prefix', () => {
  const { key, prefix } = cacheKey(base);
  const variants = {
    family: { family: 'dd' }, os: { os: 'Linux' }, arch: { arch: 'X64' },
    xcode: { xcodeVersion: 'Xcode 26.7\nBuild version 17G1\n' },
    swift: { swiftVersion: 'Apple Swift version 6.3.4 (swiftlang-6.3.4)\n' },
    manifest: { manifest: hash('c') },
  };
  for (const [name, change] of Object.entries(variants)) {
    const other = cacheKey({ ...base, ...change });
    assert.notEqual(other.prefix, prefix, name);
    assert.notEqual(other.key, key, name);
  }
  const inputs = cacheKey({ ...base, inputs: hash('d') });
  assert.equal(inputs.prefix, prefix);
  assert.notEqual(inputs.key, key);
});

test('missing or malformed parts are errors, never a weaker key', () => {
  for (const change of [{ family: 'x' }, { manifest: '' }, { inputs: '' }, { inputs: 'abc' }, { os: '' }, { arch: undefined },
    { xcodeVersion: 'Xcode 26.6' }, { swiftVersion: 'Target: arm64' }]) {
    assert.throws(() => cacheKey({ ...base, ...change }), undefined, JSON.stringify(change));
  }
});
