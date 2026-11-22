// #734 Phase 1: one hash over the App build inputs, so a device smoke verdict follows those inputs, not the head SHA.
// Black-box: every case builds a real temporary Git repository and runs the CLI; nothing in the hash is mocked.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { isAppInput } from './app-inputs-hash.mjs';

const SCRIPT = fileURLToPath(new URL('./app-inputs-hash.mjs', import.meta.url));
const PIN = ['name: Xcode setup', 'runs:', '  steps:', '    - run: |',
  "        grep -Fx 'Xcode 26.6' /tmp/xcode-version.txt",
  "        grep -Fx 'Build version 17F113' /tmp/xcode-version.txt",
  "        .build/ci-tools/xcodegen/bin/xcodegen --version | grep -Fx 'Version: 2.44.1'", ''].join('\n');
const FILES = {
  'App/Viewer.swift': 'let zoom = 1\n',
  'App/Info.plist': '<plist>1</plist>\n',
  'App/Resources/Localizable.xcstrings': '{"strings":{"Open":{"localizations":{"zh-Hans":"打开"}}}}\n',
  'App/Resources/Mado.entitlements': '<plist>sandbox</plist>\n',
  'App/Resources/en.lproj/InfoPlist.strings': '"CFBundleName" = "Mado";\n',
  'Packages/MadoKit/Package.swift': '// swift-tools-version:6.0\n',
  'Packages/MadoKit/Sources/MadoCore/Item.swift': 'struct Item {}\n',
  'Packages/MadoKit/Sources/MadoMacUI/Resources/icon.svg': '<svg/>\n',
  'project.yml': 'name: Mado\nsettings:\n  DEVELOPMENT_TEAM: GRT84NAK4T\n',
  '.github/actions/xcode-setup/action.yml': PIN,
  'docs/guide.md': '# Guide\n',
  'README.md': '# Mado\n',
  'design/DESIGN.md': '# Design\n',
  'AppTests/ViewerTests.swift': 'func testZoom() {}\n',
  'scripts/ci/tool.mjs': 'export {};\n',
};

function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 't',
    GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.invalid' } });
  assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
  return result.stdout.trim();
}

function write(root, files) {
  for (const [file, text] of Object.entries(files)) {
    if (text === null) { rmSync(path.join(root, file)); continue; }
    mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    writeFileSync(path.join(root, file), text);
  }
}

function repo(t, files = FILES) {
  const root = mkdtempSync(path.join(tmpdir(), 'app-inputs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  git(root, 'init', '-q', '-b', 'main');
  write(root, files);
  git(root, 'add', '-A');
  git(root, 'commit', '-qm', 'base');
  return root;
}

function commit(root, files, message = 'change') {
  write(root, files);
  git(root, 'add', '-A');
  git(root, 'commit', '-qm', message);
}

function run(root, args = [], env = {}) {
  return spawnSync(process.execPath, [SCRIPT, ...args], { cwd: root, encoding: 'utf8', env: { ...process.env, ...env } });
}

function hash(root, args = [], env = {}) {
  const result = run(root, args, env);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^[0-9a-f]{64}\n$/);
  return result.stdout.trim();
}

function refused(result, reason) {
  assert.notEqual(result.status, 0, result.stdout);
  assert.equal(result.stdout, '', 'a refusal never prints a hash');
  assert.match(result.stderr, reason);
}

test('the hash is 64 hex, stable across runs, and independent of history and file creation order', t => {
  const a = repo(t);
  const first = hash(a);
  assert.equal(hash(a), first);
  const b = repo(t, Object.fromEntries(Object.entries(FILES).reverse().filter(([file]) => !file.startsWith('docs/'))));
  commit(b, { 'docs/guide.md': FILES['docs/guide.md'] }, 'later docs');
  assert.equal(hash(b), first);
});

test('a change outside the App inputs keeps the hash', t => {
  for (const [name, files] of Object.entries({
    'docs page': { 'docs/guide.md': '# Guide v2\n' },
    'root README': { 'README.md': '# Mado v2\n' },
    'design doc': { 'design/DESIGN.md': '# Design v2\n' },
    'test target (not in the app bundle)': { 'AppTests/ViewerTests.swift': 'func testZoomTwice() {}\n' },
    'CI tooling': { 'scripts/ci/tool.mjs': 'export const x = 1;\n' },
    'new agent file': { '.agents/skills/x/SKILL.md': 'x\n' },
    'docs rename': { 'docs/guide.md': null, 'docs/handbook.md': '# Guide\n' },
  })) {
    const root = repo(t);
    const before = hash(root);
    commit(root, files);
    assert.equal(hash(root), before, name);
  }
});

test('each App input changes the hash', t => {
  for (const [name, files] of Object.entries({
    'one line of App Swift': { 'App/Viewer.swift': 'let zoom = 2\n' },
    'one line of package Swift': { 'Packages/MadoKit/Sources/MadoCore/Item.swift': 'struct Item { let id = 1 }\n' },
    'a package resource': { 'Packages/MadoKit/Sources/MadoMacUI/Resources/icon.svg': '<svg id="2"/>\n' },
    'Package.swift': { 'Packages/MadoKit/Package.swift': '// swift-tools-version:6.1\n' },
    'a new package file': { 'Packages/MadoKit/Package.resolved': '{}\n' },
    'one xcstrings string': { 'App/Resources/Localizable.xcstrings': FILES['App/Resources/Localizable.xcstrings'].replace('打开', '开启') },
    'an lproj string': { 'App/Resources/en.lproj/InfoPlist.strings': '"CFBundleName" = "Mado2";\n' },
    'entitlements': { 'App/Resources/Mado.entitlements': '<plist>sandbox, files.user-selected</plist>\n' },
    'Info.plist': { 'App/Info.plist': '<plist>2</plist>\n' },
    'project.yml': { 'project.yml': 'name: Mado\nsettings:\n  DEVELOPMENT_TEAM: OTHERTEAM1\n' },
    'an xcconfig anywhere': { 'Config/Signing.xcconfig': 'CODE_SIGN_IDENTITY = Developer ID\n' },
    'an entitlements file outside App': { 'Helpers/Extra.entitlements': '<plist/>\n' },
    'a privacy manifest': { 'Support/PrivacyInfo.xcprivacy': '<plist/>\n' },
    'an lproj outside App': { 'Support/de.lproj/Main.strings': '"a" = "b";\n' },
    'the Xcode pin (toolchain)': { '.github/actions/xcode-setup/action.yml': PIN.replace('17F113', '17F200') },
    'the XcodeGen pin': { '.github/actions/xcode-setup/action.yml': PIN.replace('2.44.1', '2.45.0') },
    'a deleted App file': { 'App/Resources/en.lproj/InfoPlist.strings': null },
    'an App rename with the same content': { 'App/Viewer.swift': null, 'App/Canvas.swift': FILES['App/Viewer.swift'] },
    'an App rename that keeps the sort position': { 'App/Viewer.swift': null, 'App/Viewer2.swift': FILES['App/Viewer.swift'] },
  })) {
    const root = repo(t);
    const before = hash(root);
    commit(root, files);
    assert.notEqual(hash(root), before, name);
  }
});

test('a mode change of an App file changes the hash', t => {
  const root = repo(t);
  const before = hash(root);
  chmodSync(path.join(root, 'App/Viewer.swift'), 0o755);
  git(root, 'commit', '-qam', 'exec bit');
  assert.notEqual(hash(root), before);
});

test('--rev hashes that commit tree, and the default HEAD mode equals --rev HEAD on a clean tree', t => {
  const root = repo(t);
  const base = git(root, 'rev-parse', 'HEAD');
  const before = hash(root);
  commit(root, { 'App/Viewer.swift': 'let zoom = 3\n' });
  assert.equal(hash(root, ['--rev', base]), before);
  assert.equal(hash(root, ['--rev', 'HEAD']), hash(root));
});

test('HEAD mode refuses uncommitted, staged, deleted or untracked App inputs; --rev ignores the worktree', t => {
  for (const [name, change] of Object.entries({
    'modified App file': root => write(root, { 'App/Viewer.swift': 'let zoom = 9\n' }),
    'staged package file': root => { write(root, { 'Packages/MadoKit/Sources/MadoCore/Item.swift': 'struct Item2 {}\n' }); git(root, 'add', '-A'); },
    'deleted App file': root => rmSync(path.join(root, 'App/Info.plist')),
    'untracked App file': root => write(root, { 'App/Stray.swift': 'let stray = 1\n' }),
    'untracked xcconfig elsewhere': root => write(root, { 'Config/Local.xcconfig': 'X = 1\n' }),
  })) {
    const root = repo(t);
    const before = hash(root);
    change(root);
    refused(run(root), /App inputs not committed/);
    assert.equal(hash(root, ['--rev', 'HEAD']), before, name);
  }
});

test('HEAD mode ignores worktree changes outside the App inputs and ignored files', t => {
  const root = repo(t);
  const before = hash(root);
  write(root, { '.gitignore': 'Packages/MadoKit/.build/\n' });
  git(root, 'add', '.gitignore');
  git(root, 'commit', '-qm', 'ignore');
  write(root, { 'docs/draft.md': 'x\n', 'README.md': 'dirty\n', 'Packages/MadoKit/.build/debug/x.o': 'o\n' });
  assert.equal(hash(root), before);
});

test('failure to compute exits non-zero and never prints a hash', t => {
  const plain = mkdtempSync(path.join(tmpdir(), 'app-inputs-nogit-'));
  t.after(() => rmSync(plain, { recursive: true, force: true }));
  refused(run(plain), /git/i);
  const root = repo(t);
  refused(run(root, ['--rev', 'no-such-ref']), /no-such-ref/);
  refused(run(root, ['--rev']), /usage/);
  refused(run(root, ['--bogus']), /usage/);
  const unpinned = repo(t);
  commit(unpinned, { '.github/actions/xcode-setup/action.yml': null });
  refused(run(unpinned), /toolchain pin/);
  const partial = repo(t);
  commit(partial, { '.github/actions/xcode-setup/action.yml': PIN.replace(/.*Build version.*\n/, '') });
  refused(run(partial), /toolchain pin/);
});

test('--verify-host compares the pin with the host xcodebuild and fails closed', t => {
  const root = repo(t);
  const bin = mkdtempSync(path.join(tmpdir(), 'app-inputs-bin-'));
  t.after(() => rmSync(bin, { recursive: true, force: true }));
  const fake = text => {
    writeFileSync(path.join(bin, 'xcodebuild'), text);
    chmodSync(path.join(bin, 'xcodebuild'), 0o755);
  };
  const env = { PATH: `${bin}${path.delimiter}${process.env.PATH}` };
  fake("#!/bin/sh\nprintf 'Xcode 26.6\\nBuild version 17F113\\n'\n");
  assert.equal(hash(root, ['--verify-host'], env), hash(root));
  fake("#!/bin/sh\nprintf 'Xcode 26.6\\nBuild version 17F999\\n'\n");
  refused(run(root, ['--verify-host'], env), /host toolchain/);
  fake('#!/bin/sh\nexit 3\n');
  refused(run(root, ['--verify-host'], env), /xcodebuild/);
  rmSync(path.join(bin, 'xcodebuild'));
  // Only git on PATH: macOS ships a /usr/bin/xcodebuild shim, so the system PATH cannot model a missing xcodebuild.
  const gitBin = mkdtempSync(path.join(tmpdir(), 'app-inputs-git-'));
  t.after(() => rmSync(gitBin, { recursive: true, force: true }));
  const realGit = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
  symlinkSync(realGit, path.join(gitBin, 'git'));
  refused(run(root, ['--verify-host'], { PATH: gitBin }), /xcodebuild/);
});

test('--list prints the hashed paths in byte order, App inputs only', t => {
  const root = repo(t);
  const result = run(root, ['--list']);
  assert.equal(result.status, 0, result.stderr);
  const [toolchain, ...paths] = result.stdout.trim().split('\n');
  assert.equal(toolchain, 'toolchain Xcode 26.6 (17F113); XcodeGen 2.44.1');
  const names = paths.map(line => line.split('\t')[1]);
  assert.deepEqual(names, [...names].sort((x, y) => Buffer.compare(Buffer.from(x), Buffer.from(y))));
  for (const line of paths) assert.match(line, /^(100644|100755|120000) blob [0-9a-f]{40}\t/);
  assert.deepEqual(names, [
    '.github/actions/xcode-setup/action.yml', 'App/Info.plist', 'App/Resources/Localizable.xcstrings',
    'App/Resources/Mado.entitlements', 'App/Resources/en.lproj/InfoPlist.strings', 'App/Viewer.swift',
    'Packages/MadoKit/Package.swift', 'Packages/MadoKit/Sources/MadoCore/Item.swift',
    'Packages/MadoKit/Sources/MadoMacUI/Resources/icon.svg', 'project.yml']);
});

test('isAppInput keeps the lists explicit and treats a malformed path as an input', () => {
  for (const file of ['App/x', 'Packages/MadoKit/Tests/T.swift', 'project.yml', '.github/actions/xcode-setup/action.yml',
    'a/b.xcconfig', 'x.entitlements', 'y/z.xcstrings', 'p/PrivacyInfo.xcprivacy', 'q/Info.plist', 'r/fr.lproj/a.strings',
    '', '/abs/App', 'App/../x', 'a\\b'])
    assert.equal(isAppInput(file), true, JSON.stringify(file));
  for (const file of ['docs/x.md', 'README.md', 'AppTests/T.swift', 'UITests/T.swift', 'TestAssets/a.png',
    'scripts/ci/x.mjs', 'scripts/release/notarize.sh', 'design/x.html', 'Application/x', 'project.yml.bak',
    '.github/workflows/ci.yml', 'THIRD_PARTY_NOTICES.md'])
    assert.equal(isAppInput(file), false, file);
});
