import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, lstatSync, existsSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const base = 'bf5052b2f20edc42fcc474165cf09995e4495d09';
const git = (...args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const paths = git('ls-files', '-z').split('\0').filter(Boolean);
const read = path => readFileSync(new URL('../../' + path, import.meta.url), 'utf8');
const note = '\n注：Picsee 是 Mado 的旧名（#547、ADR-0017）。\n';
const normalize = text => text.replace(/picsee/gi, 'Mado');
const allowedAcceptance = new Set(['OPEN-03', 'CMD-05', 'WIN-02', 'EXT-03']);

// Historical reports, static research, provenance, fixtures and frozen records are not living instructions.
function living(path) {
  return path.endsWith('.md') && !/^(?:docs\/(?:adr|validation|audit|test)\/|\.claude\/(?:skills|tdd-guardian)\/|evidence\/)/.test(path) &&
    !/(?:^|\/)(?:CHANGELOG|PROVENANCE)\.md$|^docs\/PICVIEW_|\/(?:fixtures|reviews)\//.test(path) &&
    !lstatSync(new URL('../../' + path, import.meta.url)).isSymbolicLink();
}
function staleIdentifiers(text) {
  // These are app identities, never tool names; do not exempt whole lines containing a tooling path.
  return text.match(/Packages\/PicseeKit\b|\bPicsee(?:Kit|Core|Application|Infrastructure|MacUI|App|UITests|GitSHA)\w*|(?:-scheme\s+|Build\/Products\/(?:Debug|Release)\/)Picsee\b|\bPicsee\.(?:app|xcodeproj|entitlements)|-Picsee[A-Za-z]+|io\.github\.anzchy\.picsee\b/g) ?? [];
}
function cells(text) {
  const result = new Map();
  // Split only table separators outside inline code; paths and acceptance may contain literal pipes.
  for (const line of text.split('\n')) {
    if (!/^\| [A-Z]+-\d+ \|/.test(line)) continue;
    let code = false, cell = '', parts = [];
    for (const c of line.slice(1, -1)) {
      if (c === '`') code = !code;
      if (c === '|' && !code) { parts.push(cell.trim()); cell = ''; } else cell += c;
    }
    parts.push(cell.trim());
    assert.equal(parts.length, 7, parts[0]);
    assert.equal(result.has(parts[0]), false, 'duplicate ' + parts[0]);
    result.set(parts[0], parts[6]);
  }
  assert.ok(result.size > 100, 'must inspect the real ledger, not an empty parse');
  return result;
}
function compareAcceptance(before, after) {
  assert.deepEqual([...after.keys()], [...before.keys()], 'ledger row IDs/order');
  for (const [id, old] of before) {
    const current = after.get(id);
    const split = value => { const i = value.indexOf('限制：'); return i < 0 ? [value, ''] : [value.slice(0, i), value.slice(i)]; };
    const [oldAcceptance, oldLimit] = split(old), [newAcceptance, newLimit] = split(current);
    assert.equal(newAcceptance, allowedAcceptance.has(id) ? normalize(oldAcceptance) : oldAcceptance, id + ' acceptance');
    // Amendment 1 permits mechanical app-name fixes in limitations, never other evidence changes.
    assert.equal(normalize(newLimit), normalize(oldLimit), id + ' limitations');
  }
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

test('every frozen ADR and validation record has exactly one former-name note and no other change', () => {
  const records = paths.filter(path => /^docs\/(adr|validation)\/.*\.md$/.test(path));
  const baseline = git('ls-tree', '-r', '--name-only', base, '--', 'docs/adr', 'docs/validation').trim().split('\n').filter(p => p.endsWith('.md'));
  assert.deepEqual(records.sort(), baseline.sort(), 'no frozen record added, removed or renamed');
  for (const path of records) {
    const old = git('show', `${base}:${path}`), current = read(path);
    assert.equal(current, old + note, path);
  }
});

test('ledger acceptance is preserved with exactly four app-name substitutions authorized by amendment 1', () => {
  const before = cells(git('show', `${base}:docs/feature-ledger.md`)), after = cells(read('docs/feature-ledger.md'));
  compareAcceptance(before, after);
  for (const id of allowedAcceptance) assert.match(after.get(id), /Mado/, id);
});

test('ledger guard rejects unrelated acceptance or limitation edits and row loss', () => {
  const before = cells(git('show', `${base}:docs/feature-ledger.md`));
  const expected = new Map([...before].map(([id, value]) => [id, allowedAcceptance.has(id) ? normalize(value) : value]));
  compareAcceptance(before, expected);
  for (const id of ['OPEN-03', 'OPEN-01', 'CMD-05']) {
    const changed = new Map(expected); changed.set(id, changed.get(id) + ' weakened');
    assert.throws(() => compareAcceptance(before, changed), { code: 'ERR_ASSERTION' });
  }
  const missing = new Map(expected); missing.delete('OPEN-01');
  assert.throws(() => compareAcceptance(before, missing), { code: 'ERR_ASSERTION' });
});

test('generated ledger presents the current app name', () => {
  const html = read('docs/feature-ledger.html');
  assert.match(html, /<title>功能账簿 · Mado<\/title>/);
  assert.match(html, /<span>Mado · 功能账簿<\/span>/);
});


test('glossary defines Mado and records Picsee as the former name', () => {
  const glossary = read('GLOSSARY.md');
  assert.match(glossary, /\*\*Mado\*\*/);
  assert.match(glossary, /Picsee.*(?:former|旧名)|(?:former|旧名).*Picsee/);
});

test('mechanical rewrite performs real first-run changes and idempotent replay from a subdirectory', () => {
  const script = join(root, 'scripts/name-checks/rename-living-docs.mjs');
  assert.ok(existsSync(script), 'the documented replay CLI must exist');
  const dir = mkdtempSync(join(tmpdir(), 'mado-docs-replay-'));
  execFileSync('git', ['init', '-q', dir]);
  const files = {
    'AGENTS.md': '# picsee\nPackages/PicseeKit PicseeCore -scheme Picsee Picsee.app PicseeGitSHA -PicseeReady io.github.anzchy.picsee\n~/.picsee/ PICSEE_XCODE picsee-delegator anzchy/picsee design/picsee-ui-system/README.md\n',
    'docs/adr/a.md': '# Decision\n-PicseeReady\n',
    'docs/validation/P2.md': '# Tested Picsee\n-PicseeReady\n',
    'CHANGELOG.md': '# Picsee v0.0.1\n',
    'docs/feature-ledger.md': '# picsee\n| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |\n| OPEN-03 | open | Partial | unit | P1 | `Packages/PicseeKit/` | 打开方式 → picsee。限制：Picsee 未验。 |\n',
    'scripts/name-checks/rename-living-docs.mjs': readFileSync(script, 'utf8'),
  };
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true }); writeFileSync(join(dir, path), content);
  }
  execFileSync('git', ['-C', dir, 'add', '--', ...Object.keys(files)]);
  const run = () => spawnSync(process.execPath, [join(dir, 'scripts/name-checks/rename-living-docs.mjs')], { cwd: join(dir, 'docs'), encoding: 'utf8' });
  const first = run(); assert.equal(first.status, 0, first.stderr);
  const actual = path => readFileSync(join(dir, path), 'utf8');
  assert.equal(actual('AGENTS.md'), '# Mado\nPackages/MadoKit MadoCore -scheme Mado Mado.app MadoGitSHA -MadoReady io.github.anzchy.mado\n~/.picsee/ PICSEE_XCODE picsee-delegator anzchy/picsee design/picsee-ui-system/README.md\n');
  for (const path of ['docs/adr/a.md', 'docs/validation/P2.md']) assert.equal(actual(path), files[path] + note);
  assert.equal(actual('CHANGELOG.md'), files['CHANGELOG.md']);
  // Default replay leaves the four acceptance prefixes to the separately reviewed acceptance commit.
  assert.match(actual('docs/feature-ledger.md'), /`Packages\/MadoKit\/` \| 打开方式 → picsee。限制：Mado 未验。/);
  const snapshot = Object.keys(files).map(path => [path, actual(path)]);
  const second = run(); assert.equal(second.status, 0, second.stderr);
  assert.deepEqual(Object.keys(files).map(path => [path, actual(path)]), snapshot);
  assert.match(second.stdout, /0 .*rewritten/);
});


test('replay preserves the actual herdr session, GUI lock protocol and quoted owner name', () => {
  const dir = mkdtempSync(join(tmpdir(), 'mado-docs-tools-'));
  execFileSync('git', ['init', '-q', dir]);
  const path = 'scripts/name-checks/rename-living-docs.mjs';
  mkdirSync(join(dir, 'scripts/name-checks'), { recursive: true });
  writeFileSync(join(dir, path), readFileSync(join(root, path)));
  const input = '# picsee\nsession `picsee`, `project=picsee`\n用户：「picsee」\n';
  writeFileSync(join(dir, 'README.md'), input);
  execFileSync('git', ['-C', dir, 'add', '--', 'README.md', path]);
  const run = spawnSync(process.execPath, [join(dir, path)], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(readFileSync(join(dir, 'README.md'), 'utf8'), input.replace('# picsee', '# Mado'));
});


test('Codex gardener wrapper names the current app while retaining its tooling name', () => {
  const config = read('.codex/agents/picsee-doc-gardener.toml');
  assert.match(config, /name = "picsee-doc-gardener"/);
  assert.match(config, /description = "Doc gardener for Mado's feature ledger/);
});
