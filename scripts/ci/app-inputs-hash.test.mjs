// #734 Phase 1: one hash over the App build inputs, so a device smoke verdict follows those inputs, not the head SHA.
// Black-box: every case builds a real temporary Git repository and runs the CLI; nothing in the hash is mocked.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { DEVICE_BUILD_DRIVER, DEVICE_INPUT_ROOTS, INPUT_SUFFIXES, isAppInput, pinnedToolchain } from './app-inputs-hash.mjs';

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
  writeFileSync(path.join(bin, 'xcodegen'), "#!/bin/sh\nprintf 'Version: 2.44.1\\n'\n");
  chmodSync(path.join(bin, 'xcodegen'), 0o755);
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
    '', '/abs/App', 'App/../x', 'a\\b', 'UITests/T.swift', 'TestAssets/a.png', 'Resources/r.png', 'resources/r.png',
    'Info.plist', 'scripts/device/device.py', 'scripts/device/build.sh'])
    assert.equal(isAppInput(file), true, JSON.stringify(file));
  for (const file of ['docs/x.md', 'README.md', 'AppTests/T.swift', 'scripts/device/launch.sh', 'scripts/device/tests/t.py',
    'scripts/ci/x.mjs', 'scripts/release/notarize.sh', 'design/x.html', 'Application/x', 'project.yml.bak',
    '.github/workflows/ci.yml', 'THIRD_PARTY_NOTICES.md'])
    assert.equal(isAppInput(file), false, file);
});

// Issue 734 fix round 1 (audit F2, M1, M2): the device build driver decides scheme, configuration and Xcode, so it is an
// App build input; device.py's own input inventory and the hash share one list.
const DEVICE_FILES = { ...FILES,
  'scripts/device/device.py': "INPUT_ROOTS = ('App',)\nargv = ['/usr/bin/xcodebuild', 'build', '-scheme', 'Mado', '-configuration', 'Debug']\n",
  'scripts/device/build.sh': '#!/bin/zsh\nexec "${0:A:h}/../heavy-lock.sh" python3 "${0:A:h}/device.py" build "$@"\n',
  'scripts/device/launch.sh': '#!/bin/zsh\nexec python3 device.py launch "$@"\n',
  'scripts/device/tests/build_test.py': 'pass\n',
};

test('issue 734 fix1 a device build configuration change changes the hash; launch helpers and CI scripts do not', t => {
  for (const [name, files] of Object.entries({
    'device.py builds Release instead of Debug': { 'scripts/device/device.py': DEVICE_FILES['scripts/device/device.py'].replace("'Debug'", "'Release'") },
    'device.py builds another scheme': { 'scripts/device/device.py': DEVICE_FILES['scripts/device/device.py'].replace("'Mado'", "'MadoDev'") },
    'build.sh runs another device.py command': { 'scripts/device/build.sh': DEVICE_FILES['scripts/device/build.sh'].replace(' build ', ' build --release ') },
    'a UI test target file (device.py inventory)': { 'UITests/ViewerUITests.swift': 'func testOpen() {}\n' },
    'a test asset (device.py inventory)': { 'TestAssets/one.png': 'png\n' },
    'a root Resources file (device.py inventory)': { 'Resources/extra.json': '{}\n' },
    'a root lowercase resources file (device.py inventory)': { 'resources/extra.json': '{}\n' },
    'a root Info.plist': { 'Info.plist': '<plist/>\n' },
  })) {
    const root = repo(t, DEVICE_FILES);
    const before = hash(root);
    commit(root, files);
    assert.notEqual(hash(root), before, name);
  }
  for (const [name, files] of Object.entries({
    'CI-only script': { 'scripts/ci/tool.mjs': 'export const y = 2;\n' },
    'device launch helper': { 'scripts/device/launch.sh': '#!/bin/zsh\nexec python3 device.py launch --lang en "$@"\n' },
    'device tool test': { 'scripts/device/tests/build_test.py': 'assert True\n' },
  })) {
    const root = repo(t, DEVICE_FILES);
    const before = hash(root);
    commit(root, files);
    assert.equal(hash(root), before, name);
  }
});

test('issue 734 fix1 device.py and the hash share one input list and one locked Xcode build', () => {
  const top = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).stdout.trim();
  const device = readFileSync(path.join(top, 'scripts/device/device.py'), 'utf8');
  const roots = /^INPUT_ROOTS = \(([^)]*)\)$/m.exec(device)?.[1];
  assert.ok(roots, 'device.py INPUT_ROOTS tuple not found');
  assert.deepEqual([...roots.matchAll(/'([^']+)'/g)].map(match => match[1]), DEVICE_INPUT_ROOTS);
  assert.match(device, /path\.suffix == '\.entitlements'/);
  assert.ok(INPUT_SUFFIXES.includes('.entitlements'));
  for (const name of DEVICE_INPUT_ROOTS) assert.equal(isAppInput(`${name}/x`) || isAppInput(name), true, name);
  assert.deepEqual(DEVICE_BUILD_DRIVER, ['scripts/device/build.sh', 'scripts/device/device.py']);
  assert.match(readFileSync(path.join(top, 'scripts/device/build.sh'), 'utf8'), /device\.py" build/);
  const locked = /^LOCKED_XCODE_BUILD = 'Build version ([^']+)'$/m.exec(device)?.[1];
  assert.equal(locked, pinnedToolchain(top, 'HEAD').build, 'device.py builds only with the pinned Xcode build');
});

test('issue 734 fix1 --verify-host also requires the host xcodegen to match the pin', t => {
  const root = repo(t);
  const bin = mkdtempSync(path.join(tmpdir(), 'app-inputs-bin-'));
  t.after(() => rmSync(bin, { recursive: true, force: true }));
  const tool = (name, text) => { writeFileSync(path.join(bin, name), text); chmodSync(path.join(bin, name), 0o755); };
  const realGit = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
  symlinkSync(realGit, path.join(bin, 'git'));
  const env = { PATH: bin };
  tool('xcodebuild', "#!/bin/sh\nprintf 'Xcode 26.6\\nBuild version 17F113\\n'\n");
  tool('xcodegen', "#!/bin/sh\nprintf 'Version: 2.44.1\\n'\n");
  assert.equal(hash(root, ['--verify-host'], env), hash(root));
  tool('xcodegen', "#!/bin/sh\nprintf 'Version: 2.46.0\\n'\n");
  refused(run(root, ['--verify-host'], env), /host XcodeGen 2\.46\.0 differs from the pin/);
  tool('xcodegen', '#!/bin/sh\nexit 4\n');
  refused(run(root, ['--verify-host'], env), /xcodegen --version failed/);
  rmSync(path.join(bin, 'xcodegen'));
  refused(run(root, ['--verify-host'], env), /xcodegen --version failed/);
});

// Issue 734 fix round 2: CI installs the pinned XcodeGen into .build/ci-tools; the device build runs the xcodegen on
// PATH. A mismatch refuses (never loosened) and says exactly how to fix it.
test('issue 734 fix2 an XcodeGen mismatch names the host binary and how to put the pinned one on PATH', t => {
  const pin = PIN + [
    '    - run: |',
    '        curl --fail --location https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip --output .build/ci-tools/xcodegen.zip',
    "        echo 'a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73  .build/ci-tools/xcodegen.zip' | shasum -a 256 --check", ''].join('\n');
  const root = repo(t, { ...FILES, '.github/actions/xcode-setup/action.yml': pin });
  const bin = mkdtempSync(path.join(tmpdir(), 'app-inputs-bin-'));
  t.after(() => rmSync(bin, { recursive: true, force: true }));
  const tool = (name, text) => { writeFileSync(path.join(bin, name), text); chmodSync(path.join(bin, name), 0o755); };
  symlinkSync(spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim(), path.join(bin, 'git'));
  tool('xcodebuild', "#!/bin/sh\nprintf 'Xcode 26.6\\nBuild version 17F113\\n'\n");
  tool('xcodegen', "#!/bin/sh\nprintf 'Version: 2.46.0\\n'\n");
  const result = run(root, ['--verify-host'], { PATH: bin });
  refused(result, /host XcodeGen 2\.46\.0 differs from the pin/);
  const message = result.stderr;
  assert.ok(message.includes(`(${path.join(bin, 'xcodegen')})`), message);
  assert.ok(message.includes('https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip'), message);
  assert.ok(message.includes('a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73'), message);
  assert.ok(message.includes('PATH="$PWD/.build/ci-tools/xcodegen/bin:$PATH"'), message);
  assert.match(message, /scripts\/device\/build\.sh/);
  assert.match(message, /app-inputs-hash\.mjs --verify-host/);
  // Without an install step in the pin, the message still points at the pin file instead of inventing a URL.
  const bare = repo(t);
  const plain = run(bare, ['--verify-host'], { PATH: bin }).stderr;
  assert.match(plain, /install XcodeGen 2\.44\.1 as \.github\/actions\/xcode-setup\/action\.yml does/);
  assert.doesNotMatch(plain, /https:/);
});
