#!/usr/bin/env node
// #916 WI-3 (item 5, #909 / #871 fix 5): the app-red receipt lane. It builds both App test bundles under the heavy lock,
// then runs scripts/tdd/app-lane.mjs with the same arguments.
//
// Why not a setupCommand: tdd-guardian 0.10.2 runs a lane's setupCommand under a fixed 300 s timeout
// (lib/lanes.js `opts.setupTimeoutMs || 300000`; config.json cannot change it), and the old setup
// (`scripts/heavy-lock.sh xcodebuild build-for-testing …`) spent that time waiting in the heavy-lock queue: #871 fix 5
// timed out there seven times, the build never started. Inside the lane command the build waits on heavy-lock's own
// acquisition budget (MADO_HEAVY_LOCK_WAIT_SECS, default 1800 s) under the lane's timeoutMs.
//
// A failed build, a lock-wait timeout (heavy-lock exit 75) or a killed build exits 70 (a runner error for the plugin),
// never 1, so a build failure cannot be recorded as a RED. The build output goes to <logDir>/build.log, not to the
// lane output, so build noise cannot reach the receipt's output classifier; a failure prints its tail to stderr.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const lock = path.join(root, 'scripts/heavy-lock.sh');
const appLane = path.join(root, 'scripts/tdd/app-lane.mjs');

// Same derived data path app-lane.mjs reads (MADO_APP_DERIVED_DATA_PATH, default .build/dd-ci). The old setupCommand
// read PICSEE_APP_DERIVED_DATA_PATH, a pre-rename name app-lane.mjs never reads.
export function buildArgs(env = process.env) {
  return ['xcodebuild', 'build-for-testing', '-scheme', 'Mado', '-destination', 'platform=macOS', 'CODE_SIGNING_ALLOWED=NO',
    '-derivedDataPath', env.MADO_APP_DERIVED_DATA_PATH ?? '.build/dd-ci'];
}

export function runAppRed({ spawn = spawnSync, env = process.env, argv = [], logDir = path.join(root, '.build/app-red'),
  stdout = s => process.stdout.write(s), stderr = s => process.stderr.write(s) } = {}) {
  fs.mkdirSync(logDir, { recursive: true });
  const log = path.join(logDir, 'build.log');
  const fd = fs.openSync(log, 'w');
  let build;
  try { build = spawn(lock, buildArgs(env), { env, stdio: ['ignore', fd, fd] }); }
  finally { fs.closeSync(fd); }
  if (build.status !== 0) {
    const tail = fs.readFileSync(log, 'utf8').split('\n').slice(-40).join('\n');
    stderr(`${tail}\napp-red: build-for-testing failed (exit ${build.status ?? `signal ${build.signal}`}; log ${log}); ` +
      'a setup failure, not a RED\n');
    return 70;
  }
  stderr(`app-red: build-for-testing ok (log ${log})\n`);
  const tests = spawn(process.execPath, [appLane, ...argv], { env, stdio: 'inherit' });
  return tests.status ?? 70;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  process.exitCode = runAppRed({ argv: process.argv.slice(2) });
