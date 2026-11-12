import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, unlinkSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { scanRepository } from './code-name.mjs';

const script = fileURLToPath(new URL('./code-name.mjs', import.meta.url));
function repo() {
  const root = mkdtempSync(join(tmpdir(), 'identity-code-'));
  execFileSync('git', ['init', '-q', root]);
  return root;
}
function file(root, path, content, tracked = true) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), content);
  if (tracked) execFileSync('git', ['-C', root, 'add', '--', path]);
}
const scan = (root, expectedName = 'Picsee', exceptions = []) => scanRepository({ root, expectedName, exceptions });
const cli = (root, extra = []) => spawnSync(process.execPath, [script, '--root', root, ...extra], { encoding: 'utf8' });

test('new Mado Xcode transport identifiers need no name exception and preserve adjacent identity checks', () => {
  for (const path of ['scripts/ci/app-compare.test.mjs', 'scripts/ci/app-repeat-process.mjs',
    'scripts/ci/app-repeat.mjs', 'scripts/ci/hosted-cancel-probe.mjs', 'App/live.swift']) {
    const root = repo();
    file(root, path, 'const marker = TEST_RUNNER_MADO_TEST_RUN_TOKEN; const app = PicseeApp();\n');
    const problems = scan(root, 'Mado', []);
    assert.equal(problems.length, 1, problems.join('\n'));
    assert.ok(problems[0].includes('Picsee'));
  }
});

test('new Xcode tooling adds no exception for the wrong wrapped legacy name', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  for (const path of ['scripts/ci/app-compare.test.mjs', 'scripts/ci/app-repeat-process.mjs',
    'scripts/ci/app-repeat.mjs', 'scripts/ci/hosted-cancel-probe.mjs', 'App/live.swift', 'scripts/ci/unrelated.mjs']) {
    const root = repo();
    file(root, path, 'const marker = TEST_RUNNER_PICSEE_TEST_RUN_TOKEN;\n');
    assert.equal(scan(root, 'Mado', exceptions).length, 1, path);
  }
});

test('tracked paths and every text occurrence are reported in both directions; binary paths still count', () => {
  for (const [expected, other] of [['Picsee', 'Mado'], ['Mado', 'Picsee']]) {
    const root = repo();
    file(root, `${other} Folder/entry.swift`, `import ${other}Kit\nlet x = launch${other}Window(); ${other.toUpperCase()}_LOG\n`);
    file(root, 'project.yml', `name: ${other}\nscheme: ${other}\n`);
    file(root, '.github/workflows/ci.yml', `run: build -scheme ${other}\n`);
    file(root, `${other}.png`, Buffer.from([0, 1, 2, ...Buffer.from(other)]));
    file(root, 'ignored.swift', `import ${other}Kit`, false);
    const problems = scan(root, expected);
    assert.equal(problems.length, 8, problems.join('\n'));
    for (const location of [`${other} Folder/entry.swift:path:`, `${other} Folder/entry.swift:1:`,
      `${other} Folder/entry.swift:2:`, 'project.yml:1:', 'project.yml:2:', '.github/workflows/ci.yml:1:', `${other}.png:path:`]) {
      assert.ok(problems.some(message => message.startsWith(location)), location);
    }
    assert.equal(problems.filter(message => message.startsWith(`${other} Folder/entry.swift:2:`)).length, 2);
    assert.ok(problems.every(message => !message.includes('ignored.swift') && !message.startsWith(`${other}.png:1:`)));
    file(root, 'empty-exceptions.json', '[]', false);
    const result = cli(root, ['--expected-name', expected, '--exceptions', join(root, 'empty-exceptions.json')]);
    assert.equal(result.status, 1, result.stderr);
    for (const problem of problems) assert.ok(result.stderr.includes(problem));
  }
});

test('reasoned exceptions are scoped by path and occurrence, never by the containing line', () => {
  const root = repo();
  for (const path of ['docs/adr/0017.md', 'docs/validation/P0.md', 'evidence/research.txt', 'appcast.xml', 'docs/former-name.md']) {
    file(root, path, 'Picsee and Mado history');
  }
  file(root, 'docs/adr-live.swift', 'import MadoKit');
  file(root, 'live.swift', 'let x = "~/.mado/state"; import MadoKit\n');
  const exceptions = [
    { prefix: 'docs/adr/', reason: 'Frozen decisions' },
    { prefix: 'docs/validation/', reason: 'Historical evidence' },
    { prefix: 'evidence/', reason: 'Research evidence' },
    { path: 'appcast.xml', reason: 'Frozen old feed' },
    { path: 'docs/former-name.md', reason: 'Former-name note' },
    { path: 'live.swift', pattern: '~[/]\\.mado[/]state', scopes: ['content'], reason: 'Deferred fixture tooling path' },
  ];
  const problems = scan(root, 'Picsee', exceptions);
  assert.equal(problems.length, 2, problems.join('\n'));
  assert.ok(problems.some(message => message.startsWith('docs/adr-live.swift:1:')));
  assert.ok(problems.some(message => message.startsWith('live.swift:1:') && message.includes('Mado')));
  const pathOnly = [{ path: 'live.swift', scopes: ['path'], reason: 'Path only cannot hide contents' }];
  assert.equal(scan(root, 'Picsee', pathOnly).filter(message => message.startsWith('live.swift:1:')).length, 2);
});

test('the single production exception list permits history in either direction and only the deferred tooling spans', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  assert.ok(exceptions.length > 0);
  assert.ok(exceptions.every(entry => typeof entry.reason === 'string' && entry.reason.trim()));
  const root = repo();
  for (const path of ['docs/adr/0017.md', 'docs/validation/P0.md', 'evidence/history.md', 'appcast.xml']) {
    file(root, path, 'Picsee Mado');
  }
  file(root, 'live.swift', 'let path = "~/.picsee/state"; import PicseeKit\nlet e = PICSEE_LOCK; let x = PicseeApp()\n');
  const problems = scan(root, 'Mado', exceptions);
  assert.equal(problems.length, 2, problems.join('\n'));
  assert.ok(problems.some(message => message.includes('live.swift:1:')));
  assert.ok(problems.some(message => message.includes('live.swift:2:')));
  assert.deepEqual(scan(root, 'Picsee', exceptions), []);
});

test('stored symlink target text is scanned without following missing or external destinations', () => {
  const root = repo(), outside = mkdtempSync(join(tmpdir(), 'identity-external-'));
  writeFileSync(join(outside, 'safe.txt'), 'Mado external content must not be scanned');
  writeFileSync(join(outside, 'Mado.txt'), 'safe external content');
  for (const [path, target] of [['external-link', join(outside, 'safe.txt')], ['target-link', join(outside, 'Mado.txt')],
    ['missing-link', '../Mado-missing'], ['Mado-link', '../safe-missing']]) {
    symlinkSync(target, join(root, path));
    execFileSync('git', ['-C', root, 'add', '--', path]);
  }
  const problems = scan(root);
  assert.equal(problems.length, 3, problems.join('\n'));
  for (const location of ['target-link:1:', 'missing-link:1:', 'Mado-link:path:']) {
    assert.ok(problems.some(message => message.startsWith(location)), location);
  }
  assert.ok(problems.every(message => !message.startsWith('external-link:')));
});

test('symmetry, additive diagnostics, untracked invariance and repeated scans are deterministic', () => {
  for (const [own, other] of [['Picsee', 'Mado'], ['Mado', 'Picsee']]) {
    const root = repo();
    file(root, 'live.swift', `import ${own}Kit\n`);
    assert.deepEqual(scan(root, own), []);
    const before = scan(root, other);
    assert.equal(before.length, 1);
    assert.deepEqual(scan(root, other), before);
    file(root, 'untracked.swift', `import ${own}Kit`, false);
    assert.deepEqual(scan(root, other), before);
    file(root, 'permitted.swift', `import ${other}Kit`);
    assert.deepEqual(scan(root, other), before);
    file(root, 'new.swift', `import ${own}Kit`);
    const after = scan(root, other);
    assert.equal(after.length, before.length + 1);
    assert.deepEqual(after.filter(message => !message.startsWith('new.swift:')), before);
  }
});

test('invalid exception rules, identities, git enumeration and tracked read failures fail closed', () => {
  const root = repo();
  file(root, 'live.swift', 'safe');
  for (const exceptions of [null, {}, [{ path: 'live.swift' }], [{ path: 'live.swift', reason: ' ' }],
    [{ reason: 'No selector' }], [{ prefix: '', reason: 'Too broad' }], [{ pattern: '[', reason: 'Bad regex' }],
    [{ pattern: '.*', reason: 'Empty matches' }], [{ path: 'live.swift', scopes: ['bogus'], reason: 'Bad scope' }]]) {
    assert.throws(() => scan(root, 'Picsee', exceptions), /exception/i);
  }
  assert.throws(() => scan(root, 'Other'), /unknown.*identity/i);
  const notGit = mkdtempSync(join(tmpdir(), 'identity-not-git-'));
  const badGit = cli(notGit);
  assert.notEqual(badGit.status, 0);
  assert.match(badGit.stderr, /git|repository/i);
  const empty = cli(repo());
  assert.notEqual(empty.status, 0);
  assert.match(empty.stderr, /tracked/i);
  unlinkSync(join(root, 'live.swift'));
  const missing = cli(root);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /live.swift/);
});

test('CLI exposes success, invalid options and malformed exception files with useful statuses', () => {
  const root = repo();
  file(root, 'live.swift', 'import MadoKit');
  const pass = cli(root);
  assert.equal(pass.status, 0, pass.stderr);
  assert.match(pass.stdout, /PASS.*Mado/);
  for (const args of [['--expected-name', 'Other'], ['--wat'], ['--root']]) {
    const result = cli(root, args);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /identity|argument|expected|usage/i);
  }
  file(root, 'bad.json', '{', false);
  const bad = cli(root, ['--exceptions', join(root, 'bad.json')]);
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /bad.json/);
  const missing = cli(root, ['--exceptions', join(root, 'absent.json')]);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /absent.json/);
});

test('path regex exceptions retain neighboring executable config and support content-only spans', () => {
  const root = repo();
  file(root, '.claude/tdd-guardian/plan-history.md', 'Picsee Mado');
  file(root, '.claude/tdd-guardian/config.json', '{"module":"PicseeKit"}');
  const exceptions = [{ pathRegex: '^\\.claude/tdd-guardian/plan-[^/]+\\.md$', reason: 'Frozen plan only' }];
  const problems = scan(root, 'Mado', exceptions);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /^\.claude\/tdd-guardian\/config.json:1:/);
  for (const pathRegex of ['[', '.*']) assert.throws(() => scan(root, 'Picsee', [{ pathRegex, reason: 'Bad selector' }]), /exception/i);
});

test('deferred dot-directory paths cannot exempt bundle IDs or member identifiers', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  const root = repo();
  file(root, 'project.yml', 'state: "~/.picsee/state"; id: io.github.anzchy.picsee\ntestID: io.github.anzchy.picsee.tests\n');
  file(root, 'live.swift', 'let state = ".picsee/locks"; let value = object.picsee\n');
  file(root, 'paths.sh', 'a="$HOME/.picsee"; b="/Users/jack/.picsee/locks"\n');
  const problems = scan(root, 'Mado', exceptions);
  assert.equal(problems.length, 3, problems.join('\n'));
  for (const location of ['project.yml:1:', 'project.yml:2:', 'live.swift:1:']) {
    assert.ok(problems.some(message => message.startsWith(location)), location);
  }
  assert.ok(problems.every(message => !message.startsWith('paths.sh:')));
});

test('a shorthand enum identifier is code while quoted or slash-qualified dot directories are tooling paths', () => {
  const root = repo();
  file(root, 'live.swift', 'let value: Identity = .picsee\nlet second = use(.picsee)\nlet bare = ".picsee"\nlet relative = ".picsee/locks"\n');
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  const problems = scan(root, 'Mado', exceptions);
  assert.equal(problems.length, 2, problems.join('\n'));
  assert.ok(problems.some(message => message.startsWith('live.swift:1:')));
  assert.ok(problems.some(message => message.startsWith('live.swift:2:')));
});


test('production tooling spans under the delegator skill cannot conceal live app identifiers', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  const root = repo();
  const path = '.agents/skills/picsee-delegator/scripts/owner-gates.sh';
  const tooling = 'picsee-delegator PICSEE_LOCK "~/.picsee/state" picsee-wt';
  file(root, path, `${tooling} -scheme Picsee\n`);
  const before = scan(root, 'Mado', exceptions);
  assert.equal(before.length, 1, before.join('\n'));
  assert.match(before[0], /owner-gates\.sh:1:.*unexpected "Picsee"/);
  assert.deepEqual(scan(root, 'Mado', exceptions), before);
  file(root, path, `${tooling} -scheme Picsee\nPackages/PicseeKit io.github.anzchy.picsee\n`);
  const after = scan(root, 'Mado', exceptions);
  assert.equal(after.length, before.length + 2, after.join('\n'));
  assert.deepEqual(after.filter(message => !message.includes(':2:')), before);
  assert.ok(after.every(message => !message.includes(':path:')));
  assert.deepEqual(scan(root, 'Picsee', exceptions), []);
});

test('deferred executable tooling never conceals live schemes, modules or bundle identities', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  for (const path of ['scripts/agents/live.mjs', 'scripts/codex-rules/live.py',
    'scripts/git-hooks/live', 'scripts/testassets/live.py']) {
    const root = repo();
    file(root, path, '-scheme Picsee\nPackages/PicseeKit\nio.github.anzchy.picsee\n');
    const problems = scan(root, 'Mado', exceptions);
    assert.equal(problems.length, 3, `${path}: ${problems.join('\n')}`);
  }
});

test('reviewed release, roster and ledger artifacts cannot hide adjacent live identities', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  for (const path of ['.github/workflows/release.yml', 'scripts/release/appcast.mjs',
    'scripts/release/workflow-steps.test.mjs', 'scripts/release/check-package.test.mjs',
    '.agents/skills/picsee-delegator/scripts/gui-lock.sh',
    '.agents/skills/picsee-delegator/scripts/prefs.py',
    '.agents/skills/picsee-delegator/scripts/listen-notify.py',
    'scripts/ledger/build.mjs', 'scripts/ledger/garden-gate.test.mjs']) {
    const root = repo();
    file(root, path, '-scheme Picsee\nRelease/Picsee.app\nopen Picsee.app\nio.github.anzchy.picsee\nimport PicseeCore\n');
    assert.equal(scan(root, 'Mado', exceptions).length, 5, path);
  }
});

test('historical Info identity is confined to the named release fixture', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  for (const [path, count] of [['scripts/release/check-package.test.mjs', 0],
    ['scripts/release/appcast.test.mjs', 1], ['scripts/release/workflow-steps.test.mjs', 1]]) {
    const root = repo();
    file(root, path, 'CFBundleIdentifier: "io.github.anzchy.picsee"\n');
    assert.equal(scan(root, 'Mado', exceptions).length, count, path);
  }
});

test('the issue637 GUI-lock owner token is exempt only in its perf runner comparison', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  const issue637Exceptions = exceptions.filter(entry => entry.reason.includes('#637'));
  assert.equal(issue637Exceptions.length, 1);
  const exception = issue637Exceptions[0];
  const runnerPath = process.env.PICSEE_ISSUE637_NAME_RUNNER ?? new URL('../perf/issue637-run.py', import.meta.url);
  const runner = readFileSync(runnerPath, 'utf8');
  assert.equal([...runner.matchAll(new RegExp(exception.pattern, 'g'))].length, 1,
    'the tracked issue637 perf runner must contain exactly one exempt owner token');
  const root = repo();
  file(root, 'scripts/perf/issue637-run.py', "if values.get('project') != 'picsee':\nif values.get('other') != 'picsee':\n");
  file(root, 'x/scripts/perf/issue637-run.py', "if values.get('project') != 'picsee':\n");
  file(root, 'scripts/device/issue637-desktop.py', "if values.get('project') != 'picsee':\n");
  const problems = scan(root, 'Mado', exceptions);
  assert.equal(problems.length, 3, problems.join('\n'));
  assert.ok(problems.some(message => message.startsWith('scripts/perf/issue637-run.py:2:')));
  assert.ok(problems.some(message => message.startsWith('x/scripts/perf/issue637-run.py:1:')));
  assert.ok(problems.some(message => message.startsWith('scripts/device/issue637-desktop.py:1:')));
});
