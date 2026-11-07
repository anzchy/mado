import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, lstatSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const paths = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const read = path => readFileSync(new URL('../../' + path, import.meta.url), 'utf8');

// Historical reports, static research, provenance, fixtures and frozen records are not living instructions.
function living(path) {
  // The release notes template is an executable release input owned by #552.
  return path !== 'docs/release/notes-template.md' && path.endsWith('.md') && !/^(?:docs\/(?:adr|validation|audit|test)\/|\.claude\/(?:skills|tdd-guardian)\/|evidence\/)/.test(path) &&
    !/(?:^|\/)(?:CHANGELOG|PROVENANCE)\.md$|^docs\/PICVIEW_|\/(?:fixtures|reviews)\//.test(path) &&
    !lstatSync(new URL('../../' + path, import.meta.url)).isSymbolicLink();
}
function staleIdentifiers(text) {
  // These are app identities, never tool names; do not exempt whole lines containing a tooling path.
  return text.match(/Packages\/PicseeKit\b|\bPicsee(?:Kit|Core|Application|Infrastructure|MacUI|App|UITests|GitSHA)\w*|(?:-scheme\s+|Build\/Products\/(?:Debug|Release)\/)Picsee\b|\bPicsee\.(?:app|xcodeproj|entitlements)|-Picsee[A-Za-z]+|io\.github\.anzchy\.picsee\b/g) ?? [];
}
test('living documentation has no stale package/module/scheme/product/flag/build identities', () => {
  const problems = [];
  for (const path of paths.filter(living)) {
    let content = read(path);
    if (path === 'docs/feature-ledger.md') content = content.split('## Part 3')[0].split('## 变更')[0];
    for (const [index, line] of content.split('\n').entries()) {
      for (const hit of staleIdentifiers(line)) problems.push(`${path}:${index + 1}: ${hit}`);
    }
  }
  assert.deepEqual(problems, []);
});

test('identifier scanner catches app identities beside narrowly allowed tooling references', () => {
  for (const value of ['Packages/PicseeKit', 'PicseeCore', 'PicseeInfrastructureTests', '-scheme Picsee',
    'Picsee.app', 'PicseeGitSHA', '-PicseeReady', 'io.github.anzchy.picsee']) {
    assert.ok(staleIdentifiers(`~/.picsee/ PICSEE_XCODE picsee-delegator ${value}`).length, value);
  }
  assert.deepEqual(staleIdentifiers('~/.picsee/ PICSEE_XCODE picsee-delegator anzchy/picsee docs/PICSEE_ARCHITECTURE.md'), []);
});
