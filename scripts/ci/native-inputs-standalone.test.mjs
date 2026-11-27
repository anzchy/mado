// #861 WI-4: owner-gates-tools.mjs imports skippable from native-inputs.mjs, and owner-gates.test.mjs copies that file
// alone into a scratch tree. It must load there; only main() may reach the release-contents filter, and a missing
// filter must not change the native decision.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

const source = new URL('./native-inputs.mjs', import.meta.url);

function alone(body) {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), 'mado-native-alone-')));
  try {
    mkdirSync(path.join(dir, 'scripts/ci'), { recursive: true });
    copyFileSync(source, path.join(dir, 'scripts/ci/native-inputs.mjs'));
    return body(dir);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('#861 WI-4: native-inputs.mjs has no static import of a repository module', () => {
  const imports = [...readFileSync(source, 'utf8').matchAll(/^import .* from '([^']+)';$/gm)].map(match => match[1]);
  assert.deepEqual(imports.filter(spec => !spec.startsWith('node:')), []);
});

test('#861 WI-4: copied alone, skippable still loads, as owner-gates uses it', () => alone(dir => {
  const run = spawnSync(process.execPath, ['--input-type=module', '-e',
    `import { skippable } from ${JSON.stringify(path.join(dir, 'scripts/ci/native-inputs.mjs'))};` +
    `console.log(skippable('docs/a.md'), skippable('App/a.swift'));`], { encoding: 'utf8' });
  assert.equal(run.status, 0, 'skippable must load from a lone copy');
  assert.equal(run.stdout, 'true false\n');
}));

test('#861 WI-4: copied alone, main keeps the native decision and runs the Release build', () => alone(dir => {
  const event = path.join(dir, 'event.json'), output = path.join(dir, 'output');
  writeFileSync(output, '');
  const run = spawnSync(process.execPath, [path.join(dir, 'scripts/ci/native-inputs.mjs')], { encoding: 'utf8',
    env: { PATH: process.env.PATH, GITHUB_EVENT_NAME: 'push', GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: output } });
  assert.equal(run.status, 0, 'main must run from a lone copy');
  assert.equal(readFileSync(output, 'utf8'), 'native=true\nrelease_contents=true\n');
  assert.match(run.stdout, /^native-inputs: native=true \(event push always runs native jobs\)$/m);
  assert.match(run.stdout, /^native-inputs: release_contents=true \(release-contents filter unavailable: /m);
}));

// #861 fix 1 (F1): run as the entry script in a tree that also holds the release-contents filter, native-inputs.mjs
// must not wait on itself through an import cycle (top-level await plus a module that imports it back), and must write
// both output lines. The in-process tests above cannot see that: their module has already finished evaluating.
const filter = new URL('../release/release-contents.mjs', import.meta.url);

test('#861 fix 1: release-contents.mjs has no static import of a repository module', () => {
  const imports = [...readFileSync(filter, 'utf8').matchAll(/^import .* from '([^']+)';$/gm)].map(match => match[1]);
  assert.deepEqual(imports.filter(spec => !spec.startsWith('node:')), []);
});

function entry(dir, env) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [path.join(dir, 'scripts/ci/native-inputs.mjs')],
      { env: { PATH: process.env.PATH, ...env } });
    let stdout = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.resume();
    const timer = setTimeout(() => child.kill('SIGKILL'), 20000);
    child.on('close', status => { clearTimeout(timer); resolve({ status, stdout }); });
  });
}

async function withFilter(body) {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), 'mado-native-entry-')));
  try {
    mkdirSync(path.join(dir, 'scripts/ci'), { recursive: true });
    mkdirSync(path.join(dir, 'scripts/release'), { recursive: true });
    copyFileSync(source, path.join(dir, 'scripts/ci/native-inputs.mjs'));
    copyFileSync(filter, path.join(dir, 'scripts/release/release-contents.mjs'));
    return await body(dir);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

/** A local stand-in for GET /repos/{repo}/pulls/{n}/files that serves one page. */
async function filesApi(page) {
  const server = http.createServer((request, response) => {
    if (!request.url.startsWith('/repos/o/r/pulls/7/files?')) { response.writeHead(404).end('{}'); return; }
    response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(page));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(resolve => server.close(resolve)) };
}

test('#861 fix 1: the entry script writes both outputs on a push', () => withFilter(async dir => {
  const output = path.join(dir, 'output');
  writeFileSync(output, '');
  const run = await entry(dir, { GITHUB_EVENT_NAME: 'push', GITHUB_EVENT_PATH: path.join(dir, 'none.json'), GITHUB_OUTPUT: output });
  assert.equal(run.status, 0, 'the entry script must finish');
  assert.equal(readFileSync(output, 'utf8'), 'native=true\nrelease_contents=false\n');
  assert.match(run.stdout, /^native-inputs: release_contents=false \(event push: the PR-time Release build runs on pull requests only\)$/m);
}));

test('#861 fix 1: the entry script writes both outputs on a pull request', () => withFilter(async dir => {
  for (const [files, expected] of [
    [['docs/a.md'], 'native=false\nrelease_contents=false\n'],
    [['docs/a.md', 'App/AppDelegate.swift'], 'native=true\nrelease_contents=false\n'],
    [['docs/a.md', 'App/CaptureHelper/CaptureHelper.entitlements'], 'native=true\nrelease_contents=true\n'],
  ]) {
    const api = await filesApi(files.map(filename => ({ filename, status: 'modified' })));
    try {
      const output = path.join(dir, 'output'), event = path.join(dir, 'event.json');
      writeFileSync(output, '');
      writeFileSync(event, JSON.stringify({ pull_request: { number: 7, changed_files: files.length } }));
      const run = await entry(dir, { GITHUB_EVENT_NAME: 'pull_request', GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: output,
        GITHUB_REPOSITORY: 'o/r', GITHUB_API_URL: api.url, GH_TOKEN: 'test-token' });
      assert.equal(run.status, 0, `the entry script must finish (${files.join(', ')})`);
      assert.equal(readFileSync(output, 'utf8'), expected, files.join(', '));
    } finally { await api.close(); }
  }
}));
