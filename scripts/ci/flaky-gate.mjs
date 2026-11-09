#!/usr/bin/env node
/** Classify one completed raw App output, with the child process's explicit exit status.
 * CLI: node scripts/ci/flaky-gate.mjs <logfile> <exit-status>
 * Exit 0 prints retry-eligible; exit 1 prints fail. Missing metadata fails closed.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseAppResult } from '../tdd/app-lane.mjs';
import { knownFlaky } from './known-flaky.mjs';

// Remaining retry signatures cover parent assertions only. A prefixed child
// failure has no authorization, even when its parent root completed normally.
const prefixedFailure = /^[ \t]*(?:\[[^\]\r\n]+\][ \t]*)+(?:✘(?:[ \t]|$)|(?:[^:\r\n]+\.swift:\d+(?::\d+)?:[ \t]+)?Fatal error:(?:[ \t]|$)|error:(?:[ \t]|$)|(?:Segmentation fault|Bus error|Abort trap)(?::|[ \t]|$)|Test (?:Case|Suite) '.+' crashed(?:[ \t.(]|$)|libc\+\+abi:)/im;

export function classifyFlaky(run) {
  const parsed = parseAppResult(run);
  const fail = { decision: 'fail', names: [], issues: [] };
  if (!parsed.reliable || !parsed.failed || parsed.unattributedIssues) return fail;
  const clean = parsed.output.replace(/\x1b\[[0-9;]*m/g, '').replace(/\r/g, '');
  if (prefixedFailure.test(clean)) return fail;
  const entries = parsed.failureNames.map(name => knownFlaky.find(entry => entry.name === name));
  if (entries.some(entry => !entry)) return fail;
  if (parsed.issues.some(issue => !entries.some(entry => entry.name === issue.name && entry.signature.test(issue.signature)))) return fail;
  if (entries.some(entry => !parsed.issues.some(issue => issue.name === entry.name))) return fail;
  return { decision: 'retry-eligible', names: parsed.failureNames, issues: [...new Set(entries.map(entry => entry.issue))] };
}

export function main(argv = process.argv.slice(2)) {
  let decision = 'fail';
  try {
    if (argv.length === 2 && /^[01]$/.test(argv[1])) {
      decision = classifyFlaky({ stdout: readFileSync(argv[0], 'utf8'), stderr: '', status: Number(argv[1]) }).decision;
    }
  } catch { /* An unreadable or missing log cannot authorize a retry. */ }
  process.stdout.write(`${decision}\n`);
  return decision === 'retry-eligible' ? 0 : 1;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main();
