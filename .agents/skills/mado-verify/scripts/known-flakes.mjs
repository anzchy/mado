import fs from 'node:fs';
import path from 'node:path';

// #759: known-flakes.json entries carry the scripts/tdd/app-quarantine.json shape (issue, owner, expires) plus the
// file, exact test name and anchored rerun pattern. The node lane runs known-flakes.test.mjs, so an invalid or expired
// entry fails the lane. Nothing reads this list to retry or pass a gate; evidence.mjs and gate-policy.mjs ignore it.
const FIELDS = ['expires', 'file', 'issue', 'name', 'owner', 'pattern', 'why'];
const MAX_DAYS = 30;
const DAY_MS = 86_400_000;
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const isoDay = text => {
  if (typeof text !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(text)) return null;
  const date = new Date(`${text}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === text ? date : null;
};

/** Every problem with the list, as text; empty when the list is valid on `today` (YYYY-MM-DD, UTC). */
export function knownFlakeProblems(list, { root, today }) {
  const problems = [];
  const day = isoDay(today);
  if (!day) return [`today must be a real ISO date, got ${today}`];
  if (!list || !Array.isArray(list.flakes)) return ['known-flakes.json must have a flakes array'];
  const names = new Set();
  for (const entry of list.flakes) {
    const label = typeof entry?.name === 'string' ? entry.name : JSON.stringify(entry);
    const say = text => problems.push(`${label}: ${text}`);
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) { say('entry must be an object'); continue; }
    for (const key of Object.keys(entry)) if (!FIELDS.includes(key)) say(`unknown field ${key}`);
    for (const key of FIELDS) if (!(key in entry)) say(`missing ${key}`);
    if ('issue' in entry && (!Number.isSafeInteger(entry.issue) || entry.issue <= 0)) say('issue must be a positive integer');
    if ('owner' in entry && (typeof entry.owner !== 'string' || !entry.owner.trim())) say('owner must be nonblank');
    if ('why' in entry && (typeof entry.why !== 'string' || entry.why.trim().length <= 10)) say('why must explain the flake');
    if ('expires' in entry) {
      const expiry = isoDay(entry.expires);
      if (!expiry) say(`expires must be a real ISO date (YYYY-MM-DD), got ${entry.expires}`);
      else if (expiry < day) say(`expired ${entry.expires} (issue #${entry.issue}, owner ${entry.owner})`);
      else if ((expiry - day) / DAY_MS > MAX_DAYS) say(`expires ${entry.expires} is more than ${MAX_DAYS} days after ${today}`);
    }
    if (typeof entry.name !== 'string' || !entry.name) { say('name must be the exact test name'); continue; }
    if (names.has(entry.name)) say('duplicate entry');
    names.add(entry.name);
    if (entry.pattern !== `^${escape(entry.name)}$`) say('pattern must be the exact anchored test name');
    let source = null;
    try { source = typeof entry.file === 'string' ? fs.readFileSync(path.join(root, entry.file), 'utf8') : null; } catch {}
    if (source === null) say(`file not found: ${entry.file}`);
    else {
      // A mode-suffixed name, e.g. "x (managed-wrapper)", is built from a template literal in the test file.
      const mode = entry.name.match(/^(.*) \(([a-z-]+)\)$/);
      const found = source.includes(entry.name) ||
        (mode && source.includes(`${mode[1]} (\${mode})`) && source.includes(`'${mode[2]}'`));
      if (!found) say(`test name not found in ${entry.file}`);
    }
  }
  return problems;
}
