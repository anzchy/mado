#!/usr/bin/env node
/** Print public commit trailers from pinned tdd-guardian 0.10.2 receipts.
 * Usage: node scripts/tdd/red-receipt-trailer.mjs [--id ID]
 * spec-files counts test_files keys; the plugin stores no structured test counts.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export function safeComponent(value) {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value);
}
export function readReceipts({ rawEntries = false } = {}) {
  let store;
  try { store = JSON.parse(readFileSync('.claude/tdd-guardian/receipts.json', 'utf8')); }
  catch { throw new Error('Cannot read local receipts: missing file or invalid JSON.'); }
  if (!isObject(store) || store.schemaVersion !== 2 || !Array.isArray(store.receipts)) {
    throw new Error('Invalid receipt store: expected schemaVersion 2 and receipts array.');
  }
  if (rawEntries) return store.receipts;
  const ids = new Set();
  for (const receipt of store.receipts) {
    if (!isObject(receipt) || !safeComponent(receipt.id) || ids.has(receipt.id)) {
      throw new Error('Invalid receipt store: unsafe or duplicate receipt ID.');
    }
    ids.add(receipt.id);
  }
  return store.receipts.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}
export function trailerLines(receipts) {
  return receipts.map(receipt => {
    if (receipt.verdict === 'SEPARATION-BROKEN') {
      throw new Error(`Receipt ${receipt.id} is SEPARATION-BROKEN; re-record under a new ID, never commit it.`);
    }
    if (typeof receipt.verified_at !== 'string' || !receipt.verified_at ||
        !Number.isFinite(Date.parse(receipt.verified_at)) ||
        !['SEPARATION-HELD', 'SEPARATION-BROKEN'].includes(receipt.verdict)) {
      throw new Error(`Receipt ${receipt.id} is unverified; run receipt.js verify first.`);
    }
    if (!safeComponent(receipt.lane) || !isObject(receipt.test_files) || receipt.red?.red !== true ||
        !['assertion-failure', 'opaque-failure'].includes(receipt.red?.kind)) {
      throw new Error(`Receipt ${receipt.id} has invalid trailer fields or no genuine RED.`);
    }
    return `Red-Receipt: ${receipt.id} ${receipt.lane} ${receipt.red.kind} spec-files=${Object.keys(receipt.test_files).length} ${receipt.verdict}`;
  });
}
function main() {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== '--id' || !safeComponent(args[1]))) {
    throw new Error('Usage: red-receipt-trailer.mjs [--id ID]');
  }
  let receipts = readReceipts();
  if (args.length) {
    receipts = receipts.filter(receipt => receipt.id === args[1]);
    if (!receipts.length) throw new Error('Selected receipt ID was not found.');
  }
  // Validate all selected receipts before exposing any partial commit message.
  const lines = trailerLines(receipts);
  if (lines.length) process.stdout.write(lines.join('\n') + '\n');
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(); } catch (error) {
    process.stderr.write(`red-receipt-trailer: ${error.message}\n`);
    process.exitCode = 1;
  }
}
