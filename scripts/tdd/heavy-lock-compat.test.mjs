import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, existsSync, rmSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fixtureEnv } from './fixture-env.mjs';

// Compat window for callers that still export the former-name variables (rclick and
// older pane sessions): heavy-lock.sh maps them onto the MADO_* names when those are unset.
const root = process.cwd();
const scratch = mkdtempSync(path.join(os.tmpdir(), 'mado-lock-compat-'));
after(() => rmSync(scratch, { recursive: true, force: true }));
const lock = path.join(root, 'scripts/heavy-lock.sh');

function base() {
  const home = mkdtempSync(path.join(scratch, 'home-'));
  mkdirSync(path.join(home, 'locks'));
  const env = { ...fixtureEnv(), HOME: home, MADO_HEAVY_LOCK_WAIT_SECS: '60' };
  for (const key of Object.keys(env)) {
    if (/^(PICSEE|MADO)_(HEAVY|MDPRO)/.test(key) || key === 'MDPRO_HEAVY_LOCK_HELD') delete env[key];
  }
  env.MADO_HEAVY_LOCK_WAIT_SECS = '60';
  return { home, env };
}

test('legacy heavy-lock variables still select the lock file and the mdpro lock', () => {
  const { home, env } = base();
  const old = path.join(home, 'locks/legacy.lock');
  const result = spawnSync(lock, ['sh', '-c', 'printf "%s|%s" "$MADO_HEAVY_LOCK" "$MADO_MDPRO_LOCK"'], {
    env: { ...env, PICSEE_HEAVY_LOCK: old, PICSEE_MDPRO_LOCK: 'off' }, cwd: root, encoding: 'utf8', timeout: 60000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `${old}|off`);
  assert.ok(existsSync(old), 'the lock file named by the legacy variable is the one that was taken');
});

test('a MADO_* value wins over the legacy variable of the same name', () => {
  const { home, env } = base();
  const fresh = path.join(home, 'locks/fresh.lock');
  const old = path.join(home, 'locks/legacy.lock');
  const result = spawnSync(lock, ['sh', '-c', 'printf "%s" "$MADO_HEAVY_LOCK"'], {
    env: { ...env, MADO_HEAVY_LOCK: fresh, MADO_MDPRO_LOCK: 'off', PICSEE_HEAVY_LOCK: old }, cwd: root, encoding: 'utf8', timeout: 60000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, fresh);
  assert.ok(!existsSync(old), 'the legacy lock file is not created when the new name is set');
});
