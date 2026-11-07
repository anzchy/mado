import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const rules = '.codex/rules/picsee.rules';
const app = 'Mado.app';
const file = 'Picsee.entitlements';
const key = 'com.apple.security.app-sandbox';
// A literal dot in plutil keypaths must reach execpolicy as backslash + dot.
const escapedKey = String.raw`com\.apple\.security\.app-sandbox`;

function decision(argv, restricted = false) {
  // Only execpolicy runs; argv is data, never executed or passed through a shell.
  const result = spawnSync('codex', ['execpolicy', 'check', '--rules', rules, ...(restricted ? ['--rules', 'scripts/codex-rules/restricted-role.rules'] : []), '--', ...argv], {
    cwd: root, encoding: 'utf8', timeout: 10_000,
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const output = JSON.parse(result.stdout);
  assert.ok(Array.isArray(output.matchedRules), result.stdout);
  return output;
}

const forbidden = [
  ['tccutil', 'reset', 'All'],
  ['tccutil', 'reset', 'All', 'io.github.anzchy.mado'],
  ['tccutil', 'reset', 'SystemPolicyAllFiles'],
  ['codesign', '--remove-signature', app],
  ['/usr/bin/tccutil', 'reset', 'All'],
  ['/usr/bin/tccutil', 'reset', 'All', 'io.github.anzchy.mado'],
  ['/usr/bin/tccutil', 'reset', 'SystemPolicyAllFiles'],
  ['/usr/bin/codesign', '--remove-signature', app],
];
for (const wrapper of ['xcrun', '/usr/bin/xcrun']) {
  forbidden.push([wrapper, 'codesign', '--remove-signature', app]);
  for (const key of ['com.apple.security.app-sandbox', escapedKey]) {
    forbidden.push([wrapper, 'plutil', '-remove', key, file]);
    forbidden.push([wrapper, 'plutil', '-replace', key, '-bool', 'NO', file]);
    forbidden.push([wrapper, 'plutil', '-insert', key, '-bool', 'YES', file]);
  }
}
// PlistBuddy takes its entire operation as ONE argv token. Cover both executable
// spellings, optional root colon, Set/Add boolean spellings, and Delete.
for (const tool of ['PlistBuddy', '/usr/libexec/PlistBuddy']) {
  for (const entry of [key, `:${key}`]) {
    forbidden.push([tool, '-c', `Delete ${entry}`, file]);
    for (const value of ['false', 'true', '0', '1', 'NO', 'YES']) {
      forbidden.push([tool, '-c', `Set ${entry} ${value}`, file]);
      forbidden.push([tool, '-c', `Add ${entry} bool ${value}`, file]);
    }
  }
}
// plutil key mutations: trailing value/type/file tokens do not affect the ban.
for (const tool of ['plutil', '/usr/bin/plutil']) {
  for (const key of ['com.apple.security.app-sandbox', escapedKey]) {
    forbidden.push([tool, '-remove', key, file]);
    for (const operation of ['-replace', '-insert']) {
      for (const value of ['NO', 'YES']) {
        forbidden.push([tool, operation, key, '-bool', value, file]);
      }
      forbidden.push([tool, operation, key, '-json', 'false', file]);
    }
  }
}

const allowed = [
  ['tccutil', '--help'],
  ['/usr/bin/tccutil', '--help'],
  ['/usr/bin/codesign', '-d', '--entitlements', ':-', app],
  ['/usr/bin/codesign', '--verify', '--deep', '--strict', app],
  ['codesign', '--force', '--sign', '-', app],
  ['codesign', '-d', '--entitlements', ':-', app],
  ['codesign', '--verify', '--deep', '--strict', app],
  ['codesign', '--force', '--sign', 'Apple Development', '--entitlements', file, app],
  ['plutil', '-p', file],
  ['/usr/bin/plutil', '-p', file],
  ['PlistBuddy', '-c', 'Print', file],
  ['/usr/libexec/PlistBuddy', '-c', 'Print', file],
  ['/usr/libexec/PlistBuddy', '-c', `Print :${key}`, file],
  ['plutil', '-replace', 'unrelated.key', '-bool', 'NO', file],
  ['/usr/libexec/PlistBuddy', '-c', 'Set :unrelated.key false', file],
  ['xcrun', 'codesign', '-d', '--entitlements', ':-', app],
  ['/usr/bin/xcrun', 'codesign', '--force', '--sign', 'Apple Development', '--entitlements', file, app],
  ['xcrun', 'plutil', '-p', file],
  ['/usr/bin/xcrun', 'plutil', '-replace', 'unrelated.key', '-bool', 'NO', file],
];

for (const argv of forbidden) {
  test(`forbidden: ${JSON.stringify(argv)}`, () => {
    assert.equal(decision(argv).decision, 'forbidden');
  });
}
for (const argv of allowed) {
  test(`allowed: ${JSON.stringify(argv)}`, () => {
    const output = decision(argv);
    assert.notEqual(output.decision, 'forbidden');
    assert.ok(!output.matchedRules.some(rule => rule.prefixRuleMatch?.decision === 'forbidden'));
  });
}

// Independent legacy contract: deleting a rule must not delete its expectations.
const legacyForbidden = [
  ['rm', '-rf', 'src'], ['rm', '-r', 'docs/old'], ['rm', '--recursive', 'tmp'],
  ['git', 'push'], ['git', 'push', '-f', 'origin', 'main'],
  ['git', 'push', 'origin', 'p0-01/x'], ['git', 'reset', '--hard', 'HEAD~1'],
  ['git', 'checkout', '.'], ['git', 'restore', '.'],
  ['git', 'clean', '-f'], ['git', 'clean', '-fd'], ['git', 'clean', '-fdx'],
  ['git', 'branch', '-D', 'p0-01/x'], ['git', 'branch', '-d', 'p0-01/x'],
  ['git', 'worktree', 'remove', '../picsee-wt/x'],
  ['git', 'add', '-A'], ['git', 'add', '.'], ['git', 'add', '-u'],
  ['git', 'commit', '-a', '-m', 'x'], ['git', 'commit', '-am', 'x'],
  ['git', 'checkout', 'main'], ['git', 'switch', 'main'],
  ['gh', 'release', 'create', 'v1'], ['gh', 'workflow', 'run', 'release.yml'],
  ['gh', 'pr', 'merge', '12'], ['gh', 'pr', 'create'],
];
const legacyAllowed = [
  ['rm', '-f', 'a.txt'], ['rm', 'a.txt'],
  ['git', 'reset', '--soft', 'HEAD~1'], ['git', 'reset', 'HEAD', 'A.swift'],
  ['git', 'checkout', 'Sources/A.swift'], ['git', 'restore', 'Sources/A.swift'],
  ['git', 'clean', '-n'], ['git', 'branch', '--show-current'], ['git', 'branch'],
  ['git', 'worktree', 'list'], ['git', 'add', 'Sources/A.swift', 'Tests/ATests.swift'],
  ['git', 'commit', '-m', 'feat(core): x'],
  ['git', 'checkout', '-b', 'p0-01/x'], ['git', 'switch', 'p0-01/x'],
  ['gh', 'pr', 'view', '12'], ['gh', 'pr', 'diff', '12'],
];
for (const [expectedForbidden, cases] of [[true, legacyForbidden], [false, legacyAllowed]]) {
  for (const argv of cases) {
    test(`legacy ${expectedForbidden ? 'forbidden' : 'allowed'}: ${JSON.stringify(argv)}`, () => {
      assert.equal(decision(argv, true).decision === 'forbidden', expectedForbidden);
    });
  }
}

// Replay every embedded example, including all pre-existing ones. These simple
// examples use shell quotes but no expansions; no shell process is involved.
const source = readFileSync(new URL('../../.codex/rules/picsee.rules', import.meta.url), 'utf8');
for (const block of source.matchAll(/^    (match|not_match) = (\[[^\n]*\]),$/gm)) {
  const expectedForbidden = block[1] === 'match';
  for (const example of JSON.parse(block[2])) {
    const argv = [...example.matchAll(/'([^']*)'|"([^"]*)"|([^\s]+)/g)]
      .map(part => part[1] ?? part[2] ?? part[3]);
    test(`embedded ${block[1]}: ${example}`, () => {
      assert.equal(decision(argv).decision === 'forbidden', expectedForbidden);
    });
  }
}
