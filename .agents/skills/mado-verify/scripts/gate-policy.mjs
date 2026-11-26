import { spawnSync } from 'node:child_process';

// The completion ladder is shared by the evidence writer and the manual `evidence.mjs check`.
export const MANDATORY_GATES = Object.freeze(['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'apptests', 'node', 'ledger', 'design']);

// Codex sandboxed panes cannot get a key window, so hosted App focus tests cannot run there. Such a run is recorded as
// NOT VERIFIED with a reason; the delegator's owner-gates run in the desktop session is the binding App test result.
// Only the environment-failure exit (70: no hosted result / no key window) qualifies; a test failure (1) or any other
// non-zero exit stays a failure whatever the reason says.
export const NOT_VERIFIABLE = Object.freeze(['apptests']);
export const ENVIRONMENT_EXIT = 70;

const notVerifiedEscape = g => NOT_VERIFIABLE.includes(g.name) && g.exitCode === ENVIRONMENT_EXIT && typeof g.notVerified === 'string' && g.notVerified.trim() !== '';

export function notVerifiedGates(gates) {
  return Array.isArray(gates) ? gates.filter(g => g && notVerifiedEscape(g)) : [];
}

export function gateVerdict(gates, { today } = {}) {
  const problems = [];
  if (!Array.isArray(gates)) return { complete: false, problems: ['missing gate list'] };
  const byName = new Map();
  for (const gate of gates) {
    if (!gate || typeof gate.name !== 'string' || !Number.isInteger(gate.exitCode)) {
      problems.push('invalid gate entry'); continue;
    }
    if (byName.has(gate.name)) problems.push(`duplicate ${gate.name}`);
    byName.set(gate.name, gate);
  }
  for (const name of MANDATORY_GATES) {
    const gate = byName.get(name);
    if (!gate) problems.push(`missing ${name}`);
    else if (gate.exitCode !== 0 && !notVerifiedEscape(gate) && !gate.disposition) problems.push(`failed ${name}: ${gate.exitCode}`);
  }
  // #892: a flake disposition is checked wherever it appears; only a valid one on a failed node gate counts.
  for (const gate of byName.values()) if (gate.disposition !== undefined) problems.push(...flakeDispositionProblems(gate, today));
  return { complete: problems.length === 0, problems };
}


// #892 (owner 2026-11-25): an implementer runs the node lane only when the diff touches one of these prefixes; the
// delegator's owner-gates run and GitHub CI cover the rest. owner-gates-tools.mjs `select` and evidence.mjs check share it.
// An empty (or unreadable) diff requires the lane: fail closed.
export const NODE_LANE_PREFIXES = Object.freeze(['scripts/', '.agents/', '.github/', '.claude/']);
export function nodeLaneRequired(files) {
  return !files.length || files.some(file => NODE_LANE_PREFIXES.some(prefix => file.startsWith(prefix)));
}

// #892 fix1 (gpt F1 / opus M1): diff paths are read from `git diff --name-only -z`. Git's display form quotes non-ASCII
// and control characters ("scripts/\346\265\213…"), which matched no prefix. owner-gates.sh runs `git <DIFF_NAME_ARGS>` (a
// test checks the text); evidence.mjs check uses listDiffPaths. --no-renames lists a rename as its old and new path.
export const DIFF_NAME_ARGS = Object.freeze(['diff', '--name-only', '-z', '--no-renames']);
export function parseNulPaths(text) {
  return text.split('\0').filter(file => file !== '');
}
// null when Git cannot list the diff (bad base, not a repository): the caller fails closed.
export function listDiffPaths(cwd, base, head) {
  const r = spawnSync('git', [...DIFF_NAME_ARGS, base, head], { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return r.status === 0 ? parseNulPaths(r.stdout) : null;
}

// #892: is a failing node test "in the diff"? Its file is in the diff, the diff touches its directory (the source it
// tests usually sits beside it), or its name contains the base name of a test file in the diff (the failureFact rule).
// #892 fix1 (gpt F2 / opus M2): fail closed. A node test's inputs outside its directory are not proven (owner-gates.test.mjs
// copies and runs scripts/heavy-lock.sh, scripts/tdd/heavy-lock.py, scripts/ci/native-inputs.mjs and gate-policy.mjs;
// owner-gates-tools.test.mjs imports gate-policy.mjs), so any changed path under a NODE_LANE_PREFIXES directory puts every
// failing node test in the diff: no rerun, no disposition. Product files the tests read are the reviewer's check (SKILL.md).
export function failingTestInDiff({ file, name }, diffFiles) {
  if (diffFiles.some(changed => NODE_LANE_PREFIXES.some(prefix => changed.startsWith(prefix)))) return true;
  const dir = file.includes('/') ? file.slice(0, file.lastIndexOf('/') + 1) : '';
  // A test directory named tests/ tests its parent's tree (for example mado-verify/tests and mado-verify/scripts).
  const tree = /(?:^|\/)tests\/$/.test(dir) ? dir.replace(/tests\/$/, '') : null;
  return diffFiles.some(changed => changed === file || (dir && changed.startsWith(dir) && !changed.slice(dir.length).includes('/')) ||
    (tree !== null && tree !== '' && changed.startsWith(tree)) ||
    (/\.test\.[cm]?js$/.test(changed) && name.includes(changed.slice(changed.lastIndexOf('/') + 1).replace(/\.test\.[cm]?js$/, ''))));
}

// #892: the one bounded exception to "no flake exception". A node gate that failed may count only with a reviewed flake
// disposition: attempt 1 failed (its exit is the gate's), exactly one serial rerun of exactly the failed files passed, and
// the disposition names exactly the failing tests, an issue, an owner, a reviewer, an expiry at most 30 days out and the
// retained failed attempt. Whether the tests are outside the diff is checked by evidence.mjs check (it has the diff).
export const FLAKE_MAX_DAYS = 30;
const isoDay = text => {
  if (typeof text !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(text)) return null;
  const date = new Date(`${text}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === text ? date : null;
};
const nonblank = value => typeof value === 'string' && value.trim() !== '';
const testKey = t => `${t.file}\u0000${t.name}`;
// In-diff is decided on repository-relative paths, so a disposition path must be one: no leading /, ./ or ../, no empty,
// . or .. segment.
const repoRelative = file => typeof file === 'string' && file !== '' && !file.startsWith('/') &&
  file.split('/').every(part => part !== '' && part !== '.' && part !== '..');
export function flakeDispositionProblems(gate, today = new Date().toISOString().slice(0, 10)) {
  const problems = [], d = gate.disposition, attempts = gate.attempts;
  if (gate.name !== 'node') return [`${gate.name}: only the node gate can carry a flake disposition`];
  if (gate.exitCode === 0) return ['node: disposition on a passing gate'];
  if (!Array.isArray(attempts) || attempts.length !== 2) return ['node: disposition needs exactly two attempts (the failed run and its one rerun)'];
  const [first, rerun] = attempts;
  if (first?.exitCode !== gate.exitCode) problems.push('node: attempt 1 exit must be the gate exit');
  if (!nonblank(first?.log)) problems.push('node: attempt 1 needs its retained log');
  const tests = Array.isArray(first?.tests) ? first.tests : [];
  if (!tests.length || tests.some(t => !nonblank(t?.file) || !nonblank(t?.name))) problems.push('node: attempt 1 needs the failing tests (file and exact name)');
  else if (tests.some(t => !repoRelative(t.file))) problems.push('node: failing test files must be normalized repository-relative paths');
  const files = [...new Set(tests.map(t => t?.file))].sort();
  if (rerun?.exitCode !== 0) problems.push('node: the rerun did not pass');
  if (!nonblank(rerun?.log)) problems.push('node: the rerun needs its log');
  if (!Array.isArray(rerun?.files) || JSON.stringify([...rerun.files].sort()) !== JSON.stringify(files)) problems.push('node: the rerun must run exactly the failed files');
  if (!d || typeof d !== 'object') return [...problems, 'node: missing disposition'];
  if (d.kind !== 'flaky') problems.push('node: disposition kind must be flaky');
  const named = Array.isArray(d.tests) ? d.tests : [];
  const want = new Set(tests.map(testKey)), got = new Set(named.map(t => testKey(t ?? {})));
  if (named.length !== got.size || want.size !== got.size || [...want].some(key => !got.has(key))) problems.push('node: disposition must name exactly the failing tests');
  if (!Number.isSafeInteger(d.issue) || d.issue < 1) problems.push('node: disposition issue must be a positive integer');
  if (!nonblank(d.owner)) problems.push('node: disposition needs an owner');
  if (!nonblank(d.reviewedBy)) problems.push('node: disposition needs reviewedBy');
  else if (d.reviewedBy.trim() === String(d.owner ?? '').trim()) problems.push('node: disposition reviewedBy must be someone other than its owner');
  if (d.failedAttempt !== first?.log) problems.push('node: disposition failedAttempt must be the retained attempt 1 log');
  const expiry = isoDay(d.expires), now = isoDay(today);
  if (!now) problems.push(`node: cannot judge the disposition expiry: today ${today} is not a real ISO date`);
  if (!expiry) problems.push(`node: disposition expires must be a real ISO date, got ${d.expires}`);
  else if (now && expiry < now) problems.push(`node: disposition expires ${d.expires}, which has passed`);
  else if (now && (expiry - now) / 86_400_000 > FLAKE_MAX_DAYS) problems.push(`node: disposition expires ${d.expires} is more than ${FLAKE_MAX_DAYS} days out`);
  return problems;
}
export const flakyGates = gates => Array.isArray(gates) ? gates.filter(g => g && g.name === 'node' && g.exitCode !== 0 && g.disposition) : [];
