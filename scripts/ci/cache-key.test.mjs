import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cacheKey, FORMAT } from './cache-key.mjs';

const hash = c => c.repeat(64);
const base = { workspace: '/Users/runner/work/mado/mado', family: 'spm', manifest: hash('a'), inputs: hash('b'), os: 'macOS', arch: 'ARM64',
  xcodeVersion: 'Xcode 26.6\nBuild version 17F113\n',
  swiftVersion: 'swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0\n' };

test('key names family, format, runner, Xcode build, toolchain, workspace, manifest and inputs; prefix drops only the inputs', () => {
  const { key, prefix } = cacheKey(base);
  assert.equal(FORMAT, 1);
  assert.match(prefix, new RegExp(`^spm-v${FORMAT}-macOS-ARM64-xcode17F113-swift[0-9a-f]{16}-workspace${digest(base.workspace)}-${hash('a')}-$`));
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

const digest = value => createHash('sha256').update(value).digest('hex').slice(0, 16);
const workspaces = ['/Users/runner/work/legacy-app/legacy-app', base.workspace,
  '/opt/runner/work/mado/mado', '/tmp/CI checkout/项目/mado'];

for (const family of ['spm', 'dd']) {
  test(`${family}: checkout paths isolate keys and prefixes while preserving every other component`, () => {
    const results = workspaces.map(workspace => {
      const args = { ...base, family, workspace };
      const result = cacheKey(args);
      const originalPrefix = `${family}-v1-macOS-ARM64-xcode17F113-swift${digest(base.swiftVersion.trim().split('\n')[0])}-`;
      const expectedPrefix = `${originalPrefix}workspace${digest(workspace)}-${base.manifest}-`;
      assert.deepEqual(result, { prefix: expectedPrefix, key: expectedPrefix + base.inputs });
      assert.deepEqual(cacheKey(args), result, 'same workspace is deterministic');
      assert.equal(result.prefix.replace(`workspace${digest(workspace)}-`, ''), originalPrefix + base.manifest + '-');
      assert.equal(result.key.replace(`workspace${digest(workspace)}-`, ''), originalPrefix + base.manifest + '-' + base.inputs);
      return result;
    });
    assert.equal(new Set(results.map(result => result.key)).size, workspaces.length);
    assert.equal(new Set(results.map(result => result.prefix)).size, workspaces.length);
  });

  test(`${family}: missing, empty or non-absolute workspace is an error`, () => {
    const { workspace, ...withoutWorkspace } = { ...base, family };
    assert.throws(() => cacheKey(withoutWorkspace), /workspace/i);
    for (const workspace of [undefined, null, '', 'relative/checkout']) {
      assert.throws(() => cacheKey({ ...base, family, workspace }), /workspace/i);
    }
  });
}

// Real toolchain/process/filesystem integration; the production build caches target macOS.
test('CLI reads GITHUB_WORKSPACE for both cache families and rejects missing or empty workspace',
  { skip: process.platform !== 'darwin' }, t => {
    const directory = mkdtempSync(join(tmpdir(), 'mado-cache-key-'));
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    const versions = {
      xcodeVersion: execFileSync('xcodebuild', ['-version'], { encoding: 'utf8' }),
      swiftVersion: execFileSync('xcrun', ['swift', '--version'], { encoding: 'utf8' }),
    };
    let invocation = 0;
    const invoke = (family, workspace) => {
      const output = join(directory, `output-${invocation++}`);
      const env = { ...process.env, RUNNER_OS: base.os, RUNNER_ARCH: base.arch, GITHUB_OUTPUT: output };
      delete env.GITHUB_WORKSPACE;
      if (workspace !== undefined) env.GITHUB_WORKSPACE = workspace;
      const run = spawnSync(process.execPath, [fileURLToPath(new URL('./cache-key.mjs', import.meta.url)),
        family, base.manifest, base.inputs], { cwd: directory, env, encoding: 'utf8', timeout: 30000 });
      assert.ifError(run.error);
      assert.equal(run.signal, null);
      return { run, content: existsSync(output) ? readFileSync(output, 'utf8') : '' };
    };
    for (const family of ['spm', 'dd']) {
      const contents = workspaces.slice(0, 2).map(workspace => {
        const { run, content } = invoke(family, workspace);
        assert.equal(run.status, 0, run.stdout + run.stderr);
        const { key, prefix } = cacheKey({ ...base, ...versions, family, workspace });
        assert.equal(run.stdout, `cache-key: ${key}\n`);
        assert.equal(content, `key=${key}\nprefix=${prefix}\n`);
        return content;
      });
      assert.notEqual(contents[0], contents[1]);
      for (const workspace of [undefined, '']) {
        const { run, content } = invoke(family, workspace);
        assert.notEqual(run.status, 0);
        assert.match(run.stderr, /workspace/i);
        assert.doesNotMatch(run.stdout, /cache-key:/);
        assert.equal(content, '');
      }
    }
  });
