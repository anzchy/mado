// The completion ladder is shared by the evidence writer and the manual `evidence.mjs check`.
export const MANDATORY_GATES = Object.freeze(['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'apptests', 'node', 'ledger', 'design']);

// Codex sandboxed panes cannot get a key window, so hosted App focus tests cannot run there. Such a run is recorded as
// NOT VERIFIED with a reason; the delegator's owner-gates run in the desktop session is the binding App test result.
export const NOT_VERIFIABLE = Object.freeze(['apptests']);

export function notVerifiedGates(gates) {
  return Array.isArray(gates) ? gates.filter(g => g && NOT_VERIFIABLE.includes(g.name) && g.exitCode !== 0 && typeof g.notVerified === 'string' && g.notVerified.trim()) : [];
}

export function gateVerdict(gates) {
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
    else if (gate.exitCode !== 0 && !(NOT_VERIFIABLE.includes(name) && typeof gate.notVerified === 'string' && gate.notVerified.trim())) problems.push(`failed ${name}: ${gate.exitCode}`);
  }
  return { complete: problems.length === 0, problems };
}
