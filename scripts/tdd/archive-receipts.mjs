#!/usr/bin/env node
/** Archive cwd receipts by ID with immutable worktree provenance.
 * Usage: node scripts/tdd/archive-receipts.mjs <worktree-label>
 * PICSEE_RECEIPT_ARCHIVE_ROOT must be absolute and resolve outside all Git worktrees.
 * Existing differing evidence is a conflict; use a new receipt ID for a new cycle.
 */
import { readFileSync, lstatSync, realpathSync, statSync, mkdirSync, openSync, closeSync, writeFileSync, linkSync, unlinkSync } from 'node:fs';
import { join, dirname, basename, isAbsolute } from 'node:path';
import { spawnSync } from 'node:child_process';
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
  let descriptor;
  try {
    descriptor = openSync(temporary, 'wx', 0o600);
    writeFileSync(descriptor, content);
    try { linkSync(temporary, file); return true; }
    catch (error) { if (error.code === 'EEXIST') return false; throw error; }
  } finally {
    if (descriptor !== undefined) {
      try { closeSync(descriptor); } finally { unlinkSync(temporary); }
    }
  }
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
function archiveRoot(requested) {
  if (!isAbsolute(requested)) throw new Error('Archive root must be an absolute path outside Git worktrees.');
  // Resolve the closest existing ancestor before appending nonexistent children.
  // This catches aliases into a worktree even when the final leaf is absent.
  let ancestor = requested;
  const missing = [];
  let resolved;
  for (;;) {
    try { resolved = realpathSync(ancestor); break; }
    catch (error) {
      if (error.code !== 'ENOENT' || dirname(ancestor) === ancestor) {
        throw new Error('Cannot inspect archive root.');
      }
      missing.unshift(basename(ancestor));
      ancestor = dirname(ancestor);
    }
  }
  try {
    if (!statSync(resolved).isDirectory()) throw new Error();
  } catch { throw new Error('Cannot write receipt archive; root is not an accessible directory.'); }
  // Inherited Git overrides must not change what worktree contains this path.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  const git = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd: resolved, env: { ...env, LC_ALL: 'C' }, encoding: 'utf8', timeout: 10000 });
  if (git.status === 0) throw new Error('Archive root must resolve outside every Git worktree.');
  if (git.error || git.signal || git.status !== 128 || !/not a git repository/i.test(git.stderr ?? '')) {
    throw new Error('Cannot establish that archive root is outside Git worktrees.');
  }
  return join(resolved, ...missing);
}
function selectReceipts(entries) {
  const receipts = [], skipped = [], ids = new Set();
  for (const [index, entry] of entries.entries()) {
    const label = safeComponent(entry?.id) ? entry.id : `entry ${index + 1}`;
    // Mirror tdd-guardian 0.10.2 scripts/tdd-guardian/lib/verification.js
    // validateReceipts: red.kind, lane, nonempty test_files, fingerprint state,
    // and (for state=ok) lines array. Keep this CLI portable without a dependency
    // on the machine's plugin installation. Never print its path-bearing problems.
    const structural = isObject(entry) && safeComponent(entry.id) &&
      isObject(entry.red) && typeof entry.red.kind === 'string' &&
      typeof entry.lane === 'string' && entry.lane.trim() &&
      isObject(entry.test_files) && Object.keys(entry.test_files).length > 0 &&
      Object.values(entry.test_files).every(f => isObject(f) && typeof f.state === 'string' &&
        (f.state !== 'ok' || Array.isArray(f.lines)));
    if (!structural) { skipped.push(`Skipped: ${label} (invalid receipt structure)`); continue; }
    const verified = typeof entry.verified_at === 'string' && Number.isFinite(Date.parse(entry.verified_at)) &&
      ['SEPARATION-HELD', 'SEPARATION-BROKEN'].includes(entry.verdict);
    if (!verified) { skipped.push(`Skipped: ${label} (unverified receipt)`); continue; }
    if (ids.has(entry.id)) throw new Error('Invalid receipt store: duplicate receipt ID.');
    ids.add(entry.id);
    receipts.push(entry);
  }
  return { receipts: receipts.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0), skipped };
}
function main() {
  const args = process.argv.slice(2);
  if (args.length !== 1 || !safeComponent(args[0])) throw new Error('Usage: archive-receipts.mjs <safe-worktree-label>');
  const { receipts, skipped } = selectReceipts(readReceipts({ rawEntries: true }));
  const root = archiveRoot(process.env.PICSEE_RECEIPT_ARCHIVE_ROOT ?? join(homedir(), '.picsee/archive/tdd-guardian/receipts'));
  for (const line of skipped) process.stdout.write(line + '\n');
  if (!receipts.length) { process.stdout.write('No receipts to archive.\n'); return; }
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
