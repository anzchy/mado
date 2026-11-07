import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { scanRepository } from './code-name.mjs';

test('tracked repository satisfies the Mado code identity with reviewed exceptions', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  const problems = scanRepository({ expectedName: 'Mado', exceptions });
  assert.equal(problems.length, 0, problems.slice(0, 20).join('\n'));
});
