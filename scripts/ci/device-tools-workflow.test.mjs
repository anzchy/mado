// #668: the macOS device-tools step is bounded, so a hung device tool fails the job instead of eating its budget.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');

test('#668 Test macOS device tools has a step-level two-minute timeout and is never allowed to fail quietly', () => {
  const job = workflow.match(/^  package-tests:\n([\s\S]*?)(?=^  [a-z][a-z0-9-]*:\n)/m)?.[1];
  assert.ok(job, 'package-tests job exists');
  const step = job.split(/^      - name: /m).find(entry => entry.startsWith('Test macOS device tools\n'));
  assert.ok(step, 'the device-tools step exists');
  assert.match(step, /^        timeout-minutes: 2$/m);
  assert.match(step, /^        run: node --test scripts\/device\/tests\/macos\.test\.cjs$/m);
  assert.doesNotMatch(step, /continue-on-error|^        if:/m, 'a timeout or failure fails the job');
});
