import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { classify, fetchPages, main, MAX_FILES, PER_PAGE, skippable } from './native-inputs.mjs';

const entry = (filename, extra = {}) => ({ sha: 'a'.repeat(40), filename, status: 'modified', additions: 1, deletions: 0,
  changes: 1, blob_url: 'https://github.com/x', raw_url: 'https://github.com/x', contents_url: 'https://api.github.com/x',
  patch: '@@ -1 +1 @@', ...extra });
const pr = (...files) => classify({ event: 'pull_request', changedFiles: files.length, pages: [files] });

test('docs and agent files only: native jobs skip', () => {
  const result = pr(entry('docs/feature-ledger.md'), entry('.agents/skills/x/SKILL.md'), entry('AGENTS.md'),
    entry('scripts/agents/gates-rows.mjs'), entry('.github/workflows/pr-body.yml'), entry('CHANGELOG.md'));
  assert.equal(result.native, false, result.reason);
});

test('any native or unlisted input runs native jobs', () => {
  for (const file of ['THIRD_PARTY_NOTICES.md', 'App/AppDelegate.swift', 'AppTests/X.swift', 'Packages/PicseeKit/Package.swift',
    'UITests/X.swift', 'TestAssets/synthetic/a.png', 'design/DESIGN.md', 'scripts/perf/fixtures/signpost-messages.json',
    'scripts/ci/native-inputs.mjs', 'scripts/tdd/app-lane.mjs', 'scripts/heavy-lock.sh', 'project.yml', 'package.json',
    '.github/workflows/ci.yml', '.github/actions/xcode-setup/action.yml', 'appcast.xml', 'NEW.md', 'docs', 'docsx/a.md']) {
    const result = pr(entry('docs/a.md'), entry(file));
    assert.equal(result.native, true, file);
  }
});

test('path tricks are not skippable', () => {
  for (const file of ['docs/../App/x.swift', '/docs/a.md', 'docs//a.md', './docs/a.md', 'docs\\..\\App', '', null]) {
    assert.equal(skippable(file), false, String(file));
  }
});

test('a rename counts both ends: out of App is native, within docs is not', () => {
  assert.equal(pr(entry('docs/moved.swift', { status: 'renamed', previous_filename: 'App/moved.swift' })).native, true);
  assert.equal(pr(entry('docs/b.md', { status: 'renamed', previous_filename: 'docs/a.md' })).native, false);
  assert.equal(pr(entry('docs/b.md', { status: 'copied', previous_filename: 'App/a.md' })).native, true);
});

test('malformed or incomplete lists fail closed', () => {
  const docs = entry('docs/a.md');
  const cases = {
    'rename without previous_filename': pr(entry('docs/b.md', { status: 'renamed' })),
    'previous_filename on a modify': pr(entry('docs/b.md', { previous_filename: 'App/a.swift' })),
    'unknown status': pr(entry('docs/a.md', { status: 'exploded' })),
    'missing filename': pr({ status: 'modified' }),
    'null entry': pr(null),
    'count mismatch (partial list)': classify({ event: 'pull_request', changedFiles: 2, pages: [[docs]] }),
    'count mismatch (extra entries)': classify({ event: 'pull_request', changedFiles: 1, pages: [[docs, docs]] }),
    'zero changed files': classify({ event: 'pull_request', changedFiles: 0, pages: [[]] }),
    'empty list': classify({ event: 'pull_request', changedFiles: 1, pages: [[]] }),
    'no pages': classify({ event: 'pull_request', changedFiles: 1, pages: [] }),
    'missing changed_files': classify({ event: 'pull_request', pages: [[docs]] }),
    'string changed_files': classify({ event: 'pull_request', changedFiles: '1', pages: [[docs]] }),
    'error object page': classify({ event: 'pull_request', changedFiles: 1, pages: [{ message: 'Not Found' }] }),
    'short middle page': classify({ event: 'pull_request', changedFiles: 101, pages: [[docs], Array(100).fill(docs)] }),
    'oversized page': classify({ event: 'pull_request', changedFiles: 101, pages: [Array(101).fill(docs)] }),
    'API cap': classify({ event: 'pull_request', changedFiles: MAX_FILES,
      pages: Array.from({ length: MAX_FILES / PER_PAGE }, () => Array(PER_PAGE).fill(docs)) }),
  };
  for (const [name, result] of Object.entries(cases)) assert.equal(result.native, true, name);
});

test('push, dispatch and other events always run native jobs', () => {
  for (const event of ['push', 'workflow_dispatch', 'pull_request_target', undefined]) {
    assert.equal(classify({ event, changedFiles: 1, pages: [[entry('docs/a.md')]] }).native, true, String(event));
  }
});

test('multi-page lists: full pages then a short one, or an empty page after an exact multiple', async () => {
  const docs = entry('docs/a.md');
  const exact = classify({ event: 'pull_request', changedFiles: 200, pages: [Array(100).fill(docs), Array(100).fill(docs), []] });
  assert.equal(exact.native, false, exact.reason);
  const calls = [];
  const sizes = [100, 100, 37];
  const fetchImpl = async url => {
    calls.push(url);
    const page = Number(new URL(url).searchParams.get('page'));
    return { ok: true, text: async () => JSON.stringify(Array(sizes[page - 1] ?? 0).fill(docs)) };
  };
  const pages = await fetchPages({ api: 'https://api.github.com', repo: 'o/r', number: 7, token: 't', fetchImpl });
  assert.deepEqual(pages.map(page => page.length), [100, 100, 37]);
  assert.equal(calls.length, 3);
  assert.match(calls[0], /\/repos\/o\/r\/pulls\/7\/files\?per_page=100&page=1$/);
  assert.equal(classify({ event: 'pull_request', changedFiles: 237, pages }).native, false);
  assert.equal(classify({ event: 'pull_request', changedFiles: 238, pages }).native, true);
});

test('HTTP and parse failures return no list', async () => {
  const docs = JSON.stringify([entry('docs/a.md')]);
  for (const response of [{ ok: false, text: async () => docs }, { ok: true, text: async () => '{not json' }]) {
    assert.equal(await fetchPages({ api: 'a', repo: 'o/r', number: 1, token: 't', fetchImpl: async () => response }), null);
  }
  assert.equal(await fetchPages({ api: 'a', repo: 'o/r', number: 1, token: 't', fetchImpl: async () => { throw new Error('net'); } }), null);
});

function runMain(event, payload, fetchImpl) {
  const dir = mkdtempSync(path.join(tmpdir(), 'picsee-native-inputs-'));
  const eventPath = path.join(dir, 'event.json');
  const output = path.join(dir, 'output');
  writeFileSync(output, '');
  if (payload !== undefined) writeFileSync(eventPath, typeof payload === 'string' ? payload : JSON.stringify(payload));
  const lines = [];
  return main({ GITHUB_EVENT_NAME: event, GITHUB_EVENT_PATH: eventPath, GITHUB_REPOSITORY: 'o/r', GH_TOKEN: 't', GITHUB_OUTPUT: output },
    { fetchImpl, log: line => lines.push(line) }).then(result => ({ result, output: readFileSync(output, 'utf8'), lines }));
}

test('main writes native=false only for a complete docs-only list, native=true otherwise', async () => {
  const ok = async () => ({ ok: true, text: async () => JSON.stringify([entry('docs/a.md')]) });
  const skip = await runMain('pull_request', { pull_request: { number: 3, changed_files: 1 } }, ok);
  assert.equal(skip.output, 'native=false\n');
  assert.match(skip.lines[0], /^native-inputs: native=false /);
  assert.equal((await runMain('push', undefined, ok)).output, 'native=true\n');
  assert.equal((await runMain('workflow_dispatch', undefined, ok)).output, 'native=true\n');
  assert.equal((await runMain('pull_request', { pull_request: { number: 3, changed_files: 2 } }, ok)).output, 'native=true\n');
  assert.equal((await runMain('pull_request', '{broken', ok)).output, 'native=true\n');
  assert.equal((await runMain('pull_request', undefined, ok)).output, 'native=true\n');
  const failing = async () => ({ ok: false, text: async () => '' });
  assert.equal((await runMain('pull_request', { pull_request: { number: 3, changed_files: 1 } }, failing)).output, 'native=true\n');
});
