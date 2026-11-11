// The completion ladder is shared by the evidence writer and Stop hook.
export const MANDATORY_GATES = Object.freeze(['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'node', 'ledger', 'design']);

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
    else if (gate.exitCode !== 0) problems.push(`failed ${name}: ${gate.exitCode}`);
  }
  return { complete: problems.length === 0, problems };
}
