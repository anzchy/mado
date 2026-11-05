#!/usr/bin/env node
/** Archive cwd receipts by ID with immutable worktree provenance.
 * Usage: node scripts/tdd/archive-receipts.mjs <worktree-label>
 * PICSEE_RECEIPT_ARCHIVE_ROOT overrides the receipts directory (not its parent).
 * Existing differing evidence is a conflict; use a new receipt ID for a new cycle.
 */
import { readFileSync, lstatSync, mkdirSync, writeFileSync, linkSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { isObject, safeComponent, readReceipts } from './red-receipt-trailer.mjs';

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
function existing(file) {
  let stat;
  try { stat = lstatSync(file); }
  catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw new Error('Archive conflict: cannot inspect existing evidence.');
  }
  if (!stat.isFile()) throw new Error('Archive conflict: existing entry is not a regular file.');
  try { return JSON.parse(readFileSync(file, 'utf8')); }
  catch { throw new Error('Archive conflict: existing evidence is unreadable or invalid.'); }
}
function publish(file, content, root) {
  // Publish a complete file atomically. link is exclusive, unlike rename, and a
  // racing reader never observes the partial bytes of a writer using open(wx).
  const temporary = join(root, `.receipt-${randomUUID()}.tmp`);
  writeFileSync(temporary, content, { flag: 'wx', mode: 0o600 });
  try {
    try { linkSync(temporary, file); return true; }
    catch (error) { if (error.code === 'EEXIST') return false; throw error; }
  } finally { unlinkSync(temporary); }
}
function archive(receipt, worktree, root) {
  const envelope = { schemaVersion: 1, worktree, receipt };
  const content = canonical(envelope) + '\n';
  const primary = join(root, `${receipt.id}.json`);
  const suffixed = join(root, `${receipt.id}.${worktree}.json`);
  let destination = primary;
  for (;;) {
    const prior = existing(destination);
    if (prior !== undefined) {
      if (canonical(prior) === canonical(envelope)) return `No-op: ${receipt.id} (${worktree})`;
      if (destination === primary && prior?.worktree !== worktree &&
          safeComponent(prior?.worktree) && prior?.receipt?.id === receipt.id && prior?.schemaVersion === 1) {
        destination = suffixed;
        continue;
      }
      throw new Error(`Archive conflict for ${receipt.id} (${worktree}); existing evidence preserved.`);
    }
    if (publish(destination, content, root)) return `Archived: ${receipt.id} (${worktree})`;
    // Another process won the exclusive publication. Inspect its complete file.
  }
}
function main() {
  const args = process.argv.slice(2);
  if (args.length !== 1 || !safeComponent(args[0])) throw new Error('Usage: archive-receipts.mjs <safe-worktree-label>');
  const receipts = readReceipts(); // Validate the entire batch before any writes.
  if (!receipts.length) { process.stdout.write('No receipts to archive.\n'); return; }
  const root = process.env.PICSEE_RECEIPT_ARCHIVE_ROOT ?? join(homedir(), '.picsee/archive/tdd-guardian/receipts');
  try {
    mkdirSync(root, { recursive: true, mode: 0o700 });
    for (const receipt of receipts) process.stdout.write(archive(receipt, args[0], root) + '\n');
  } catch (error) {
    if (error.message.startsWith('Archive conflict')) throw error;
    throw new Error('Cannot write receipt archive; check destination access.');
  }
}
try { main(); } catch (error) {
  process.stderr.write(`archive-receipts: ${error.message}\n`);
  process.exitCode = 1;
}
