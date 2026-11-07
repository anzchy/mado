#!/usr/bin/env node
// One-shot #553 audit of an explicitly selected commit range. Never run by CI's
// *.test.mjs glob: later ADRs, validation runs and sanctioned acceptance edits
// are legitimate work, not violations of a permanent fixed-baseline contract.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

function git(...args) {
  return execFileSync('git', args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
}
function options(argv) {
  const result = {};
  while (argv.length) {
    const flag = argv.shift(), value = argv.shift();
    if (!['--base', '--head'].includes(flag) || !value || value.startsWith('--') || result[flag]) throw new Error('usage: check-living-docs-range.mjs --base <commit> --head <commit>; both revisions required');
    result[flag] = value;
  }
  if (!result['--base'] || !result['--head']) throw new Error('both --base and --head revisions are required');
  return result;
}
function commit(ref) {
  try { return git('rev-parse', '--verify', '--end-of-options', ref + '^{commit}').trim(); }
  catch { throw new Error('commit revision unavailable: ' + ref); }
}
function records(ref) {
  return git('ls-tree', '-r', '--name-only', ref, '--', 'docs/adr', 'docs/validation').trim().split('\n').filter(path => path.endsWith('.md')).sort();
}
function cells(text) {
  const result = new Map();
  for (const line of text.split('\n')) {
    if (!/^\| [A-Z]+-\d+ \|/.test(line)) continue;
    let code = false, cell = '', parts = [];
    for (const c of line.slice(1, -1)) {
      if (c === '`') code = !code;
      if (c === '|' && !code) { parts.push(cell.trim()); cell = ''; } else cell += c;
    }
    parts.push(cell.trim());
    assert.equal(parts.length, 7, 'ledger malformed row ' + parts[0]);
    assert.equal(result.has(parts[0]), false, 'ledger duplicate ' + parts[0]);
    result.set(parts[0], parts[6]);
  }
  assert.ok(result.size > 0, 'ledger must contain rows');
  return result;
}
try {
  const args = options(process.argv.slice(2));
  const base = commit(args['--base']), head = commit(args['--head']);
  const read = (ref, path) => git('show', ref + ':' + path);
  const beforeRecords = records(base), afterRecords = records(head);
  assert.ok(beforeRecords.length > 0, 'range must contain frozen records');
  assert.deepEqual(afterRecords, beforeRecords, 'frozen record paths changed');
  const note = '\n注：Picsee 是 Mado 的旧名（#547、ADR-0017）。\n';
  for (const path of beforeRecords) assert.equal(read(head, path), read(base, path) + note, path);
  const before = cells(read(base, 'docs/feature-ledger.md')), after = cells(read(head, 'docs/feature-ledger.md'));
  assert.deepEqual([...after.keys()], [...before.keys()], 'ledger row IDs/order');
  const allowed = new Set(['OPEN-03', 'CMD-05', 'WIN-02', 'EXT-03']);
  const normalize = text => text.replace(/picsee/gi, 'Mado');
  const split = value => { const i = value.indexOf('限制：'); return i < 0 ? [value, ''] : [value.slice(0, i), value.slice(i)]; };
  for (const [id, old] of before) {
    const [oldAcceptance, oldLimit] = split(old), [newAcceptance, newLimit] = split(after.get(id));
    assert.equal(newAcceptance, allowed.has(id) ? normalize(oldAcceptance) : oldAcceptance, id + ' acceptance');
    assert.equal(normalize(newLimit), normalize(oldLimit), id + ' limitations');
  }
  for (const id of allowed) assert.match(after.get(id) ?? '', /Mado/, id + ' must use the renamed app');
  const release = 'docs/release/notes-template.md';
  assert.equal(read(head, release), read(base, release), release + ' belongs to #552');
  console.log(`PASS #553 range ${base}..${head}: ${beforeRecords.length} records; ${after.size} ledger rows; four authorized acceptance-name substitutions; release input unchanged`);
} catch (error) {
  console.error('FAIL #553 range: ' + error.message);
  process.exitCode = 1;
}
