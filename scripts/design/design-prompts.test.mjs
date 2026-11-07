import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';

const root = fileURLToPath(new URL('../../', import.meta.url));
test('every design-system global copied by a prompt exists in its manifest and running bundle', () => {
  const paths = execFileSync('git', ['-C', root, 'ls-files', '-z', '--', '*_ds_prompt.md'], { encoding: 'utf8' }).split('\0').filter(Boolean);
  assert.ok(paths.length > 0, 'must inspect tracked prompts');
  for (const path of paths) {
    const directory = dirname(join(root, path));
    const manifest = JSON.parse(readFileSync(join(directory, '_ds_manifest.json'), 'utf8'));
    const globals = {};
    runInNewContext(readFileSync(join(directory, '_ds_bundle.js'), 'utf8'), { window: globals });
    const prompt = readFileSync(join(root, path), 'utf8')
      // This line documents prohibited browser bindings, not a bundle API.
      .replace(/^In text\/babel blocks, never.*$/m, '');
    // React/ReactDOM are the explicitly loaded external prerequisites in the prompt.
    const names = [...new Set([...prompt.matchAll(/window\.([A-Za-z_$][\w$]*)/g)].map(match => match[1]))]
      .filter(name => !['React', 'ReactDOM'].includes(name));
    assert.ok(names.length > 0, path + ': no copied bundle global');
    for (const name of names) {
      assert.equal(name, manifest.namespace, `${path}: window.${name} is not the manifest export`);
      assert.ok(globals[name], `${path}: window.${name} is not exported at runtime`);
      for (const component of manifest.components) assert.equal(typeof globals[name][component.name], 'function', `${path}: ${component.name}`);
    }
  }
});
