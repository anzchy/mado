import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../..', import.meta.url));
const owner = fileURLToPath(new URL('./owner-gates.sh', import.meta.url));
function fixture(t, mode = 'pass', covered = 2, npmInstalled = true) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-bound-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const rel of ['scripts/heavy-lock.sh', 'scripts/tdd/heavy-lock.py', 'scripts/ci/test-watchdog.mjs', 'scripts/ci/coverage-atomic.mjs', 'scripts/tdd/unit-lane.mjs', 'scripts/tdd/unit-locked.mjs', 'scripts/tdd/swift-lcov.sh']) {
    const dest = path.join(dir, rel); fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.copyFileSync(path.join(root, rel), dest);
  }
  for (const group of ['agents', 'tdd', 'ledger', 'name-checks']) { fs.mkdirSync(path.join(dir, 'scripts', group), { recursive: true }); fs.writeFileSync(path.join(dir, 'scripts', group, 'fixture.test.mjs'), ''); }
  fs.mkdirSync(path.join(dir, 'scripts', 'ci'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'scripts', 'ci', 'name-checks-ci.test.mjs'), '');
  const bin = path.join(dir, 'bin'), build = path.join(dir, 'build'), out = path.join(dir, 'out');
  fs.mkdirSync(bin); fs.mkdirSync(path.join(build, 'codecov'), { recursive: true });
  if (npmInstalled) fs.mkdirSync(path.join(dir, 'node_modules'));
  fs.mkdirSync(path.join(build, 'MadoKitPackageTests.xctest/Contents/MacOS'), { recursive: true });
  fs.writeFileSync(path.join(build, 'codecov/default.profdata'), 'old profile');
  fs.mkdirSync(path.join(dir, 'coverage')); fs.writeFileSync(path.join(dir, 'coverage/lcov.info'), 'old passing report');
  const exe = (name, body) => fs.writeFileSync(path.join(bin, name), body, { mode: 0o755 });
  exe('swift', `#!${process.execPath}
const fs=require('node:fs');
if(process.argv[2]==='build'){fs.appendFileSync(process.env.EXPORT_MARKER,'discovery\\n');console.log(process.env.BUILD);}
else{console.log('Swift started');if(process.env.MODE==='hang'){setTimeout(()=>process.exit(0),4000);setInterval(()=>{},100);}else{console.log('✔ Test run with 7 tests in 1 suite passed after 0.001 seconds.');process.exit(process.env.MODE==='fail'?1:0);}}
`);
  exe('node', `#!${process.execPath}
const path=require('node:path');
if(process.argv[2]==='scripts/tdd/unit-lane.mjs'){
 if(process.env.MODE==='coverage-fail'){console.log('✔ Test run with 7 tests in 1 suite passed after 0.001 seconds.');process.exitCode=65;}
 else import(path.resolve(process.argv[2])).then(m=>{process.exitCode=m.runUnit({timeoutSeconds:process.env.MODE==='hang'?2:30,captureSeconds:0.2,graceSeconds:0.1,verifyCoverage:false});});
}
else if(process.argv[2]==='scripts/ci/package-coverage-local.mjs'){require('fs').appendFileSync(process.env.EXPORT_MARKER,'evaluate\\n');console.log('Package: lines ${covered}/2; functions ${covered}/2; raw functions ${covered}/2; exceptions 0; eligible functions ${covered}/2');console.log('Coverage gate: ${covered === 2 ? 'PASS' : 'FAIL'}');process.exit(${covered === 2 ? 0 : 1});}
else if(process.argv[2]==='--test'){require('fs').writeFileSync(process.env.NODE_MARKER,process.argv.slice(2).join('\\n'));}
else process.exit(0);
`);
  exe('xcrun', `#!${process.execPath}
require('fs').appendFileSync(process.env.EXPORT_MARKER,'export\\n');
console.log('SF:/fixture.swift\\nFN:1,a\\nFN:2,b\\nFNDA:1,a\\nFNDA:${covered === 2 ? 1 : 0},b\\nFNF:2\\nFNH:${covered}\\nDA:1,1\\nDA:2,${covered === 2 ? 1 : 0}\\nLF:2\\nLH:${covered}\\nend_of_record');
`);
  for (const name of ['xcodegen', 'xcodebuild', 'npm']) exe(name, '#!/bin/sh\nexit 0\n');
  const shell = path.join(dir, 'invoke.zsh');
  fs.writeFileSync(shell, `git() { if [[ "$1" == rev-parse ]]; then print fixture-sha; fi; }
node() { export PATH="$FIXTURE_BIN:$PATH"; "$FIXTURE_BIN/node" "$@"; }
xcodegen() { "$FIXTURE_BIN/xcodegen" "$@"; }
source "$OWNER" "$FIXTURE_DIR" fixture-sha run fixture-base
`);
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, FIXTURE_BIN: bin, FIXTURE_DIR: dir, OWNER: owner,
    MODE: mode, BUILD: build, EXPORT_MARKER: path.join(dir, 'exports'), NODE_MARKER: path.join(dir, 'node-args'), PICSEE_GATES_OUT: out,
    PICSEE_HEAVY_LOCK: path.join(dir, 'heavy.lock'), PICSEE_MDPRO_LOCK: path.join(dir, 'shared.lock'),
    PICSEE_HEAVY_LOCK_HELD: '', MDPRO_HEAVY_LOCK_HELD: '' };
  const result = spawnSync('/bin/zsh', [shell], { env, cwd: dir, encoding: 'utf8', timeout: 90_000 });
  return { dir, out, result, marker: env.EXPORT_MARKER, nodeMarker: env.NODE_MARKER, summary: fs.readFileSync(path.join(out, 'run-summary.txt'), 'utf8') };
}

test('owner node lane runs the name-check tests required by CI', t => {
  const ci = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
  assert.match(ci, /run: node --test scripts\/name-checks\/\*\.test\.mjs scripts\/ci\/name-checks-ci\.test\.mjs/);
  const f = fixture(t);
  assert.equal(f.result.status, 0, f.result.stderr);
  const args = fs.readFileSync(f.nodeMarker, 'utf8').split('\n');
  assert.ok(args.includes('scripts/name-checks/fixture.test.mjs'), args.join('\n'));
  assert.ok(args.includes('scripts/ci/name-checks-ci.test.mjs'), args.join('\n'));
});

test('owner reports failure and timeout, rejects old coverage and completes later lanes', t => {
  for (const [mode, status] of [['fail', 1], ['hang', 124]]) {
    const f = fixture(t, mode);
    assert.equal(f.result.status, 1, f.result.stderr);
    assert.match(f.summary, new RegExp(`^swift=${status}$`, 'm'));
    assert.match(f.summary, /^lcov=1$/m);
    assert.match(fs.readFileSync(path.join(f.out, 'run-lcov.log'), 'utf8'), /skipped.*Swift.*failed/i);
    assert.equal(fs.existsSync(f.marker), false, 'coverage tools never consume old profile/report');
    for (const lane of ['xcodegen', 'xcodebuild', 'node', 'ledger', 'diffcheck', 'design']) assert.match(f.summary, new RegExp(`^${lane}=0$`, 'm'));
    assert.equal(f.summary.match(/^DONE$/gm)?.length, 1);
    if (mode === 'hang') assert.match(fs.readFileSync(path.join(f.out, 'run-swift.log'), 'utf8'), /exit 124 \(timed out\)/);
  }
});

test('missing npm dependencies report an actionable design failure', t => {
  const f = fixture(t, 'pass', 2, false);
  assert.equal(f.result.status, 1, f.result.stderr);
  assert.match(f.summary, /^design=1$/m);
  assert.match(fs.readFileSync(path.join(f.out, 'run-design.log'), 'utf8'), /npm ci --ignore-scripts/);
});

test('owner normal pass keeps full-suite evidence and applies the strict shared coverage verdict', t => {
  for (const covered of [2, 1]) {
    const f = fixture(t, 'pass', covered);
    assert.equal(f.result.status, covered === 2 ? 0 : 1, f.result.stderr);
    assert.match(f.summary, /^swift=0$/m);
    assert.match(f.summary, new RegExp(`^lcov=${covered === 2 ? 0 : 1}$`, 'm'));
    assert.match(f.summary, new RegExp(`lines ${covered}/2; functions ${covered}/2`));
    assert.match(f.summary, /Test run with 7 tests/); assert.match(f.summary, /^DONE$/m);
    assert.equal(fs.readFileSync(f.marker, 'utf8'), 'evaluate\n');
  }
});

test('owner identifies post-test coverage failure and preserves its invalid-evidence report', t => {
  const f = fixture(t, 'coverage-fail', 1);
  assert.equal(f.result.status, 1, f.result.stderr);
  assert.match(f.summary, /^swift=0$/m);
  assert.match(f.summary, /^lcov=1$/m);
  assert.match(f.summary, /coverage failed after Swift tests passed/i);
  assert.match(f.summary, /Coverage gate: FAIL/);
  assert.doesNotMatch(fs.readFileSync(path.join(f.out, 'run-lcov.log'), 'utf8'), /coverage skipped/i);
});
