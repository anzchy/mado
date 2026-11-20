import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { gateVerdict, MANDATORY_GATES } from './gate-policy.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const allowlistPath = '.agents/skills/mado-verify/scripts/reuse-allowlist.json';
const policyPath = '.agents/skills/mado-verify/scripts/gate-policy.mjs';
const reusePolicyPath = '.agents/skills/mado-verify/scripts/reuse-policy.mjs';
export const REUSED_LANES = Object.freeze(['swift', 'lcov']);
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const command = (cwd, bin, args) => {
  const r = spawnSync(bin, args, { cwd, encoding: 'buffer', maxBuffer: 20_000_000 });
  if (r.status !== 0) throw new Error(`${bin} ${args[0]} failed: ${String(r.stderr || r.stdout).trim()}`);
  return r.stdout;
};
const git = (cwd, ...args) => command(cwd, 'git', args).toString().trim();
const allowed = (name, list) => list.exact.includes(name) || list.prefixes.some(prefix => name.startsWith(prefix));
const blob = (cwd, ref, name) => command(cwd, 'git', ['show', `${ref}:${name}`]);
const listAt = (cwd, ref) => JSON.parse(blob(cwd, ref, allowlistPath).toString());
export function allowlistVersion(cwd, ref) { return sha(blob(cwd, ref, allowlistPath)); }
export function basesAreValid(cwd, oldBase, newBase, oldHead, newHead) {
  return git(cwd, 'merge-base', oldBase, oldHead) === oldBase &&
    git(cwd, 'merge-base', newBase, newHead) === newBase &&
    git(cwd, 'merge-base', oldBase, newBase) === oldBase &&
    git(cwd, 'merge-base', oldHead, newBase) === oldBase &&
    git(cwd, 'merge-base', 'origin/main', newHead) === newBase;
}
export function toolchainFingerprint(cwd = process.cwd()) {
  try {
    const xcode = command(cwd, 'xcodebuild', ['-version']).toString().trim();
    const swift = command(cwd, 'swift', ['--version']).toString().trim();
    return { xcode, swift };
  } catch { return null; }
}
export function testedInputHash(cwd, ref) {
  const list = listAt(cwd, ref).inputExclusions;
  if (!list || !Array.isArray(list.exact) || !Array.isArray(list.prefixes)) throw new Error('input exclusions invalid');
  const rows = command(cwd, 'git', ['ls-tree', '-r', '--full-tree', '-z', ref]).toString().split('\0').filter(Boolean);
  return sha(rows.filter(row => !allowed(row.slice(row.indexOf('\t') + 1), list)).join('\0'));
}
export function directFingerprints(cwd, head) {
  const toolchain = toolchainFingerprint(cwd);
  if (!toolchain) return null;
  try {
    return { toolchain, gatePolicy: sha(command(cwd, 'git', ['show', `${head}:${policyPath}`])),
      allowlistVersion: allowlistVersion(cwd, head), testedInputs: testedInputHash(cwd, head) };
  } catch { return null; }
}
export function evaluateReuse(cwd, oldBase, newBase, oldHead, newHead) {
  const rerun = reason => ({ reuse: false, reason });
  try {
    for (const ref of [oldBase, newBase, oldHead, newHead]) git(cwd, 'rev-parse', '--verify', `${ref}^{commit}`);
    if (oldBase === newBase || oldHead === newHead) return rerun('bases/heads did not move');
    if (!basesAreValid(cwd, oldBase, newBase, oldHead, newHead))
      return rerun('wrong base ancestry');
    const policyFiles = [allowlistPath, policyPath, reusePolicyPath];
    for (const name of policyFiles) {
      const versions = [oldBase, newBase, oldHead, newHead].map(ref => sha(blob(cwd, ref, name)));
      if (versions.some(version => version !== versions[0])) return rerun(`${name} changed between bases or heads`);
    }
    const list = listAt(cwd, newBase);
    if (list.version !== 1 || !Array.isArray(list.exact) || !Array.isArray(list.prefixes)) return rerun('allow-list version invalid');
    const changed = command(cwd, 'git', ['diff', '--name-only', '--no-renames', '-z', oldBase, newBase]).toString().split('\0').filter(Boolean);
    for (const name of changed) {
      if (!allowed(name, list)) return rerun(name);
      for (const ref of [oldBase, newBase]) {
        const row = command(cwd, 'git', ['ls-tree', ref, '--', name]).toString();
        if (/^(120000|160000)\s/.test(row)) return rerun(`${name}: symlink/submodule`);
      }
    }
    const proof = spawnSync('zsh', [path.join(here, '../../mado-delegator/scripts/rebase-verify.sh'), oldBase, oldHead, newBase, newHead],
      { cwd, encoding: 'utf8', maxBuffer: 20_000_000 });
    if (proof.status !== 0 || !/^CODE same(?:, DOCS differ)? /m.test(proof.stdout || '')) return rerun('CODE differs or rebase proof failed');
    const recordPath = path.join(cwd, '.build/mado-verify', `${oldHead}.json`);
    let original;
    try { original = JSON.parse(fs.readFileSync(recordPath, 'utf8')); } catch { return rerun('old record missing'); }
    if (original.head !== oldHead || original.base !== oldBase || original.link || original.complete !== true || !gateVerdict(original.gates).complete)
      return rerun('old record/base invalid');
    for (const name of REUSED_LANES) {
      const gate = original.gates.find(item => item.name === name);
      if (!gate || gate.exitCode !== 0 || gate.scopeSkip || gate.notVerified || original.lanes?.[name]?.status !== 'executed')
        return rerun(`${name}: old lane was not an executed pass`);
    }
    if (!original.fingerprints) return rerun('historical fingerprint missing');
    const oldActual = directFingerprints(cwd, oldHead);
    const newActual = directFingerprints(cwd, newHead);
    if (!oldActual || !newActual) return rerun('toolchain fingerprint unavailable');
    for (const key of ['gatePolicy', 'allowlistVersion', 'testedInputs'])
      if (original.fingerprints[key] !== oldActual[key]) return rerun(`historical ${key} fingerprint changed`);
    if (JSON.stringify(original.fingerprints.toolchain) !== JSON.stringify(newActual.toolchain)) return rerun('historical fingerprint changed');
    if (oldActual.testedInputs !== newActual.testedInputs) return rerun('tested input tree changed');
    return { reuse: true, fingerprints: newActual, changed, original };
  } catch (error) { return rerun(`unknown: ${error.message}`); }
}
export function linkedLanes(gates, oldHead, original) {
  const lanes = {};
  for (const gate of gates) if (gate.reusedFrom !== undefined && !REUSED_LANES.includes(gate.name))
    throw new Error(`${gate.name}: reuse not allowed`);
  for (const name of MANDATORY_GATES) {
    const gate = gates.find(item => item.name === name);
    if (!gate) throw new Error(`missing ${name}`);
    if (REUSED_LANES.includes(name)) {
      if (gate.reusedFrom !== oldHead || gate.exitCode !== 0) throw new Error(`${name}: reusedFrom must be old head`);
      const prior = original?.gates?.find(item => item.name === name);
      if (!prior || original.lanes?.[name]?.status !== 'executed') throw new Error(`${name}: old executed gate missing`);
      const { reusedFrom, ...claimed } = gate;
      const canonical = value => JSON.stringify(Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b))));
      if (canonical(claimed) !== canonical(prior)) throw new Error(`${name}: reused gate must copy old result exactly`);
      lanes[name] = { status: 'reused', from: oldHead };
    } else {
      if (gate.reusedFrom !== undefined || gate.scopeSkip || gate.notVerified || gate.exitCode !== 0)
        throw new Error(`${name}: must be executed on new head`);
      lanes[name] = { status: 'executed' };
    }
  }
  return lanes;
}
export function verifyLinkedRecord(cwd, record) {
  if (!record.link || record.head !== record.link.newHead || record.base !== record.link.newBase)
    throw new Error('linked record head/base mismatch');
  if (record.ciBinding !== 'required-new-head') throw new Error('linked record must keep new-head CI binding');
  const { oldBase, newBase, oldHead, newHead } = record.link;
  const result = evaluateReuse(cwd, oldBase, newBase, oldHead, newHead);
  if (!result.reuse) throw new Error(`linked reuse refused: ${result.reason}`);
  if (JSON.stringify(record.fingerprints) !== JSON.stringify(result.fingerprints)) throw new Error('linked fingerprint mismatch');
  const expected = linkedLanes(record.gates, oldHead, result.original);
  if (JSON.stringify(record.lanes) !== JSON.stringify(expected)) throw new Error('linked lane provenance mismatch');
  const old = JSON.parse(fs.readFileSync(path.join(cwd, '.build/mado-verify', `${oldHead}.json`), 'utf8'));
  if (old.issue !== record.issue || !old.complete || !gateVerdict(old.gates).complete) throw new Error('linked original record is not green for this issue');
  return true;
}
