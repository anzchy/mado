import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const fixtureTests = fileURLToPath(new URL('./unit-lane.test.mjs', import.meta.url));

test('i632M2 normal status and output survive three seconds of external Swift startup', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-startup-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const events = path.join(dir, 'delays.jsonl'), preload = path.join(dir, 'delay.cjs');
  fs.writeFileSync(preload, `
const path=require('node:path');
if(path.basename(process.argv[1]||'')==='swift'){
 const fs=require('node:fs'),cp=require('node:child_process');
 const parent=cp.execFileSync('/bin/ps',['-p',String(process.ppid),'-o','command='],{encoding:'utf8'});
 fs.appendFileSync(${JSON.stringify(events)},JSON.stringify({delayMs:3000,parent})+'\\n');
 Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,3000);
}
`);
  // This is an independent test runner, not a recursive node:test worker.
  const childEnv = { ...process.env };
  delete childEnv.NODE_TEST_CONTEXT;
  const r = spawnSync(process.execPath, ['--test', '--test-reporter=tap',
    '--test-name-pattern=full unit success and ordinary failure preserve output, status and single execution', fixtureTests], {
    env: { ...childEnv, NODE_OPTIONS: `${process.env.NODE_OPTIONS || ''} --require ${JSON.stringify(preload)}`.trim() },
    encoding: 'utf8', timeout: 90_000,
  });
  assert.equal(r.error, undefined, r.stderr);
  assert.equal(r.signal, null, r.stderr);
  assert.ok(fs.existsSync(events), 'the controlled external Swift startup delay was entered');
  const delayed = fs.readFileSync(events, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(delayed[0]?.delayMs, 3000, 'the first controlled delay occurred before checking the fixture result');
  console.log('i632M2 controlled startup evidence', JSON.stringify({ events: delayed.length, delayMs: delayed[0].delayMs }));
  assert.equal(r.status, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /# pass 1(?:\r?\n|$)/);
  assert.match(r.stdout, /# fail 0(?:\r?\n|$)/);
  assert.equal(delayed.length, 2, 'one delayed external Swift for each ordinary exit status0/1');
  for (const event of delayed) {
    assert.equal(event.delayMs, 3000);
    assert.match(event.parent, /--timeout-seconds\s+30(?:\s|$)/);
  }
});
