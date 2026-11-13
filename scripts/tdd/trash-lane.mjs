#!/usr/bin/env node
/**
 * Serialized, explicitly selected real-Trash integration lane (#672, DECISION-TRASH-TESTS on #650).
 *
 *   node scripts/tdd/trash-lane.mjs             build, list, then run every scenario
 *   node scripts/tdd/trash-lane.mjs --discover  prove default-lane exclusion and integration presence
 *
 * Real DesktopServices/`trashItem` tests compile only with -DMADO_TRASH_INTEGRATION
 * into their own scratch path, so the default package lane never builds or lists them.
 * Compilation is a separate heavy-lock admission. The run phase is one admission with
 * a 600 s budget; inside it each scenario is a nested heavy-lock child with a 120 s
 * deadline, then TERM, 10 s, KILL, 5 s. The lane stops at the first timeout, surviving
 * child, unverified cleanup or incomplete output, and never retries. A missing
 * prerequisite or skipped scenario is reported by name and is never counted as a pass.
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runAttestedSync } from './status-channel.mjs';
import { parseOutput, supervisedStdio } from './swift-lane.mjs';

export const TRASH_LIMITS = Object.freeze({ scenarioSeconds: 120, graceSeconds: 10, killWaitSeconds: 5,
  commandSeconds: 600, drainSeconds: 2 });
const root = fileURLToPath(new URL('../..', import.meta.url));
const lock = fileURLToPath(new URL('../heavy-lock.sh', import.meta.url));
const manifestPath = fileURLToPath(new URL('./trash-integration.json', import.meta.url));

export function loadManifest(file = manifestPath) {
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (manifest.define !== 'MADO_TRASH_INTEGRATION' || typeof manifest.scratchPath !== 'string' ||
      !Array.isArray(manifest.scenarios) || !manifest.scenarios.length ||
      new Set(manifest.scenarios).size !== manifest.scenarios.length ||
      !manifest.scenarios.every(id => /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\([A-Za-z0-9_:]*\)$/.test(id)))
    throw new Error('invalid trash-integration manifest');
  return manifest;
}

export function swiftFlags(manifest) {
  return ['--package-path', 'Packages/MadoKit', '--scratch-path', manifest.scratchPath,
    '-Xswiftc', `-D${manifest.define}`];
}

/** `swift test list` prints one identifier per line; keep only identifier-shaped lines. */
export function parseListing(text) {
  return text.split(/\r?\n/).map(line => line.trim()).filter(line => /^[A-Za-z_][\w]*\.[^\s]+$/.test(line));
}

/** Both directions: none of the scenarios in the default lane, all of them (and only them) added by the define. */
export function discoveryVerdict({ defaultIDs, integrationIDs, scenarios }) {
  const lines = [];
  const defaults = new Set(defaultIDs), integration = new Set(integrationIDs);
  if (!defaults.size) lines.push('default listing is empty');
  if (!integration.size) lines.push('integration listing is empty');
  for (const id of scenarios) {
    if (defaults.has(id)) lines.push(`default lane still lists ${id}`);
    if (!integration.has(id)) lines.push(`integration lane is missing ${id}`);
  }
  const added = [...integration].filter(id => !defaults.has(id));
  for (const id of added) if (!scenarios.includes(id)) lines.push(`integration-only test not in manifest: ${id}`);
  for (const id of defaults) if (!integration.has(id)) lines.push(`default test missing from integration build: ${id}`);
  return { ok: lines.length === 0, lines };
}

/** Swift Testing filters match the qualified name; parentheses never reach the regex. */
export function scenarioFilter(id) {
  const name = id.slice(0, id.indexOf('('));
  return `^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\(`;
}

function say(write, line) { write(`trash-lane: ${line}\n`); }

/**
 * Must run inside one heavy-lock admission (inherited control FD). Each scenario is a
 * nested heavy-lock child; nested supervisors inherit the parent's command deadline.
 * Returns 0 (all passed), 1 (completed assertion failures) or 70 (stopped or incomplete).
 */
export function runScenarios({ scenarios, manifest, swift = 'swift', cwd = root, env = process.env,
  scenarioSeconds = TRASH_LIMITS.scenarioSeconds, graceSeconds = TRASH_LIMITS.graceSeconds,
  drainSeconds = TRASH_LIMITS.drainSeconds, write = text => process.stdout.write(text) }) {
  if (env.PICSEE_HEAVY_LOCK_HELD !== '1' || !env.PICSEE_HEAVY_CONTROL_FD) {
    say(write, 'refused: the run phase must run inside one heavy-lock admission');
    return 70;
  }
  let stdio;
  try { stdio = supervisedStdio(env); } catch (error) { say(write, `refused: ${error.message}`); return 70; }
  stdio = ['ignore', 'pipe', 'pipe', ...stdio.slice(3)];
  const totals = { passed: 0, failed: 0, missing: [] };
  for (const [index, id] of scenarios.entries()) {
    say(write, `scenario ${index + 1}/${scenarios.length} ${id} (deadline ${scenarioSeconds}s)`);
    const childEnv = { ...env, PICSEE_HEAVY_LOCK_EXEC_SECS: String(scenarioSeconds),
      PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: String(graceSeconds), PICSEE_HEAVY_LOCK_DRAIN_SECS: String(drainSeconds) };
    const run = runAttestedSync(lock, [swift, 'test', '--skip-build', ...swiftFlags(manifest),
      '--filter', scenarioFilter(id)], { cwd, env: childEnv, stdio, maxBuffer: 64 * 1024 * 1024,
      timeout: (scenarioSeconds + graceSeconds + TRASH_LIMITS.killWaitSeconds + 15) * 1000 }, { rejectDrain: true });
    const stdout = run.stdout ?? '', stderr = run.stderr ?? '';
    write(stdout); write(stderr);
    // The nested supervisor's timeout makes its status record unattested (status 70);
    // its own deadline line distinguishes a timeout from other unverified cleanup.
    if (run.status === 124 || run.signal || run.error || /^\[heavy-lock\] execution timeout after /m.test(stderr)) {
      say(write, `TIMEOUT ${id}: no result within ${scenarioSeconds}s; lane stopped, no retry`);
      return 70;
    }
    if (!run.attested) {
      const survivor = /drain expired/.test(stderr) ? 'leader exited with surviving descendants'
        : 'cleanup not verified (surviving child or unknown process state)';
      say(write, `SURVIVOR ${id}: ${survivor}; lane stopped, no retry`);
      return 70;
    }
    const out = parseOutput(stdout), err = parseOutput(stderr);
    const counts = out.invalid || err.invalid || (out.counts && err.counts) ? null : out.counts || err.counts;
    if (counts?.skipped) {
      say(write, `PREREQUISITE MISSING ${id}: scenario skipped; not counted as a pass`);
      totals.missing.push(id);
      continue;
    }
    if (!counts || counts.total !== 1 || ![0, 1].includes(run.status) || (run.status === 0) !== (counts.failed === 0)) {
      say(write, `INCOMPLETE ${id}: no reliable completed result for exactly this scenario; lane stopped`);
      return 70;
    }
    if (counts.failed) { totals.failed += 1; say(write, `FAILED ${id}`); }
    else { totals.passed += 1; say(write, `PASSED ${id}`); }
  }
  if (totals.missing.length) {
    say(write, `PREREQUISITE MISSING for ${totals.missing.length} scenario(s): ${totals.missing.join(', ')}; no counts`);
    return 70;
  }
  write(`\ntrash-lane scenarios=${scenarios.length}\nTests run: ${scenarios.length}, Failures: ${totals.failed}, Errors: 0, Skipped: 0\n`);
  return totals.failed ? 1 : 0;
}

function status(result) {
  if (result.error) return 127;
  return result.status ?? (result.signal ? 128 + (os.constants.signals[result.signal] ?? 0) : 70);
}

function prerequisites({ swift, env, write }) {
  const missing = [];
  const probe = spawnSync(swift, ['--version'], { env, encoding: 'utf8', timeout: 30000 });
  if (probe.error || probe.status !== 0) missing.push(`Swift toolchain (${swift} --version failed)`);
  const trash = path.join(env.HOME || os.homedir(), '.Trash');
  if (!fs.existsSync(trash)) missing.push(`user Trash directory ${trash}`);
  for (const item of missing) say(write, `PREREQUISITE MISSING: ${item}`);
  return missing.length === 0;
}

function listIDs(manifest, flags, env) {
  const result = spawnSync(lock, ['swift', 'test', 'list', ...flags], { cwd: root, env, encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024 });
  return { status: status(result), ids: parseListing(result.stdout ?? ''), stderr: result.stderr ?? '' };
}

function main(argv) {
  const write = text => process.stdout.write(text);
  const manifest = loadManifest();
  if (argv.length === 1 && argv[0] === '--scenarios-under-lock') {
    return runScenarios({ scenarios: manifest.scenarios, manifest, write });
  }
  if (argv.length > 1 || (argv.length === 1 && argv[0] !== '--discover')) {
    process.stderr.write('usage: node scripts/tdd/trash-lane.mjs [--discover]\n');
    return 64;
  }
  const env = { ...process.env };
  for (const name of ['PICSEE_HEAVY_LOCK_EXEC_SECS', 'PICSEE_HEAVY_LOCK_KILL_GRACE_SECS', 'PICSEE_HEAVY_LOCK_DRAIN_SECS'])
    delete env[name];
  if (!prerequisites({ swift: 'swift', env, write })) return 70;
  if (argv[0] === '--discover') {
    const base = listIDs(manifest, ['--package-path', 'Packages/MadoKit'], env);
    const integration = base.status === 0 ? listIDs(manifest, swiftFlags(manifest), env) : base;
    if (base.status !== 0 || integration.status !== 0) {
      process.stderr.write(base.stderr + integration.stderr);
      say(write, 'PREREQUISITE MISSING: test listing failed; discovery not proven');
      return 70;
    }
    const verdict = discoveryVerdict({ defaultIDs: base.ids, integrationIDs: integration.ids, scenarios: manifest.scenarios });
    for (const line of verdict.lines) say(write, `DISCOVERY ${line}`);
    say(write, `discovery default=${base.ids.length} integration=${integration.ids.length} ` +
      `scenarios=${manifest.scenarios.length} ${verdict.ok ? 'PROVEN' : 'FAILED'}`);
    return verdict.ok ? 0 : 70;
  }
  say(write, 'compile (separate admission; not part of the 10-minute run budget)');
  const build = spawnSync(lock, ['swift', 'build', '--build-tests', ...swiftFlags(manifest)], { cwd: root, env, stdio: 'inherit' });
  if (status(build) !== 0) { say(write, `PREREQUISITE MISSING: integration build failed (${status(build)})`); return 70; }
  const listed = listIDs(manifest, ['--skip-build', ...swiftFlags(manifest)], env);
  const absent = manifest.scenarios.filter(id => !listed.ids.includes(id));
  if (listed.status !== 0 || absent.length) {
    process.stderr.write(listed.stderr);
    for (const id of absent) say(write, `PREREQUISITE MISSING: scenario not in integration build: ${id}`);
    if (listed.status !== 0) say(write, 'PREREQUISITE MISSING: integration listing failed');
    return 70;
  }
  const runEnv = { ...env, PICSEE_HEAVY_LOCK_EXEC_SECS: String(TRASH_LIMITS.commandSeconds) };
  const run = spawnSync(lock, [process.execPath, fileURLToPath(import.meta.url), '--scenarios-under-lock'],
    { cwd: root, env: runEnv, stdio: 'inherit' });
  const code = status(run);
  if (code === 124) { say(write, `COMMAND BUDGET EXCEEDED: ${TRASH_LIMITS.commandSeconds}s; lane stopped, no retry`); return 70; }
  return [0, 1].includes(code) ? code : 70;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = main(process.argv.slice(2));
}
