import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { gateVerdict, MANDATORY_GATES } from './gate-policy.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const allowlistPath = path.join(here, 'reuse-allowlist.json');
const policyPath = '.agents/skills/mado-verify/scripts/gate-policy.mjs';
export const REUSED_LANES = Object.freeze(['swift', 'lcov']);
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const command = (cwd, bin, args) => {
  const r = spawnSync(bin, args, { cwd, encoding: 'buffer', maxBuffer: 20_000_000 });
  if (r.status !== 0) throw new Error(`${bin} ${args[0]} failed: ${String(r.stderr || r.stdout).trim()}`);
  return r.stdout;
};
const git = (cwd, ...args) => command(cwd, 'git', args).toString().trim();
const allowed = (name, list) => list.exact.includes(name) || list.prefixes.some(prefix => name.startsWith(prefix));
export function allowlistVersion() { return sha(fs.readFileSync(allowlistPath)); }
export function toolchainFingerprint(cwd = process.cwd()) {
  try {
    const xcode = command(cwd, 'xcodebuild', ['-version']).toString().trim();
    const swift = command(cwd, 'swift', ['--version']).toString().trim();
    return { xcode, swift };
  } catch { return null; }
}
export function testedInputHash(cwd, ref) {
  const list = JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
  const rows = command(cwd, 'git', ['ls-tree', '-r', '--full-tree', '-z', ref]).toString().split('\0').filter(Boolean);
  return sha(rows.filter(row => !allowed(row.slice(row.indexOf('\t') + 1), list)).join('\0'));
}
export function directFingerprints(cwd, head) {
  const toolchain = toolchainFingerprint(cwd);
  if (!toolchain) return null;
  try {
    return { toolchain, gatePolicy: sha(command(cwd, 'git', ['show', `${head}:${policyPath}`])),
      allowlistVersion: allowlistVersion(), testedInputs: testedInputHash(cwd, head) };
  } catch { return null; }
}
export function evaluateReuse(cwd, oldBase, newBase, oldHead, newHead) {
  const rerun = reason => ({ reuse: false, reason });
  try {
    for (const ref of [oldBase, newBase, oldHead, newHead]) git(cwd, 'rev-parse', '--verify', `${ref}^{commit}`);
    if (oldBase === newBase || oldHead === newHead) return rerun('bases/heads did not move');
    if (git(cwd, 'merge-base', oldBase, oldHead) !== oldBase ||
        git(cwd, 'merge-base', newBase, newHead) !== newBase ||
        git(cwd, 'merge-base', oldBase, newBase) !== oldBase)
      return rerun('wrong base ancestry');
    const list = JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
    if (list.version !== 1 || !Array.isArray(list.exact) || !Array.isArray(list.prefixes)) return rerun('allow-list version invalid');
    const changed = command(cwd, 'git', ['diff', '--name-only', '--no-renames', '-z', oldBase, newBase]).toString().split('\0').filter(Boolean);
    for (const name of changed) if (!allowed(name, list)) return rerun(name);
    const proof = spawnSync('zsh', [path.join(here, '../../mado-delegator/scripts/rebase-verify.sh'), oldBase, oldHead, newBase, newHead],
      { cwd, encoding: 'utf8', maxBuffer: 20_000_000 });
    if (proof.status !== 0 || !/^CODE same(?:, DOCS differ)? /m.test(proof.stdout || '')) return rerun('CODE differs or rebase proof failed');
    const recordPath = path.join(cwd, '.build/mado-verify', `${oldHead}.json`);
    let original;
    try { original = JSON.parse(fs.readFileSync(recordPath, 'utf8')); } catch { return rerun('old record missing'); }
    if (original.head !== oldHead || original.base !== oldBase || original.link || original.complete !== true || !gateVerdict(original.gates).complete)
      return rerun('old record/base invalid');
    if (!original.fingerprints) return rerun('historical fingerprint missing');
    const oldActual = directFingerprints(cwd, oldHead);
    const newActual = directFingerprints(cwd, newHead);
    if (!oldActual || !newActual) return rerun('toolchain fingerprint unavailable');
    if (JSON.stringify(original.fingerprints) !== JSON.stringify(oldActual)) return rerun('historical fingerprint changed');
    if (JSON.stringify(oldActual.toolchain) !== JSON.stringify(newActual.toolchain)) return rerun('toolchain fingerprint changed');
    if (oldActual.gatePolicy !== newActual.gatePolicy) return rerun(`${policyPath} changed`);
    if (oldActual.allowlistVersion !== newActual.allowlistVersion) return rerun('allow-list version changed');
    if (oldActual.testedInputs !== newActual.testedInputs) return rerun('tested input tree changed');
    return { reuse: true, fingerprints: newActual, changed };
  } catch (error) { return rerun(`unknown: ${error.message}`); }
}
export function linkedLanes(gates, oldHead) {
  const lanes = {};
  for (const gate of gates) if (gate.reusedFrom !== undefined && !REUSED_LANES.includes(gate.name))
    throw new Error(`${gate.name}: reuse not allowed`);
  for (const name of MANDATORY_GATES) {
    const gate = gates.find(item => item.name === name);
    if (!gate) throw new Error(`missing ${name}`);
    if (REUSED_LANES.includes(name)) {
      if (gate.reusedFrom !== oldHead || gate.exitCode !== 0) throw new Error(`${name}: reusedFrom must be old head`);
      lanes[name] = { status: 'reused', from: oldHead };
    } else {
      if (gate.reusedFrom !== undefined || gate.exitCode !== 0) throw new Error(`${name}: must be executed on new head`);
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
  const expected = linkedLanes(record.gates, oldHead);
  if (JSON.stringify(record.lanes) !== JSON.stringify(expected)) throw new Error('linked lane provenance mismatch');
  const old = JSON.parse(fs.readFileSync(path.join(cwd, '.build/mado-verify', `${oldHead}.json`), 'utf8'));
  if (old.issue !== record.issue || !old.complete || !gateVerdict(old.gates).complete) throw new Error('linked original record is not green for this issue');
  return true;
}
