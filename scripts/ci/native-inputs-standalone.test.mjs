// #861 WI-4: owner-gates-tools.mjs imports skippable from native-inputs.mjs, and owner-gates.test.mjs copies that file
// alone into a scratch tree. It must load there; only main() may reach the release-contents filter, and a missing
// filter must not change the native decision.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
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
