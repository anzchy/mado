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

// Only the named issue521 child probes are retry-safe. Metadata may be printed
// between records, but all test lifecycles must be complete and attributable.
function completeKnownChildren(entry, lines) {
  const seen = new Set();
  let block = null;
  for (const line of lines) {
    // A completed root never excuses a later crash or runtime exception.
    if (/(?:\b(?:[A-Za-z_]\w*)?exception\b|\bunhandled\b.*\berror\b|\blibc\+\+abi:|\bterminat(?:e|ing|ed|ion)\b|\bcrash(?:ed)?\b|Trace\/(?:BPT|breakpoint) trap|Abort trap|Segmentation fault|Bus error|Fatal error:|^error:|\bsignal(?: code)? (?:\d+|SIG[A-Z]+)|\bSIG(?:ABRT|SEGV|BUS|ILL|TRAP|KILL)\b|\bEXC_[A-Z_]+\b)/i.test(line)) return false;
    if (line === '◇ Test run started.') {
      if (block) return false;
      block = { test: null, cases: new Set(), finished: false, issues: 0 };
      continue;
    }
    const root = /^[✔✘] Test run with (\d+) tests? in (\d+) suites? (passed|failed) after \d+(?:\.\d+)? seconds(?:\.| with (\d+) issues?\.)$/.exec(line);
    if (root) {
      if (!block?.test || !block.finished || Number(root[1]) !== 1 || Number(root[2]) !== 0 ||
          (root[3] === 'failed') !== block.test.failed || Number(root[4] ?? 0) !== block.issues) return false;
      seen.add(block.test.name); block = null;
      continue;
    }
    const start = /^◇ Test (?!case passing )(.+) started\.$/.exec(line);
    if (start) {
      if (!block || block.test || seen.has(start[1])) return false;
      block.test = entry.childTests.find(test => test.name === start[1]);
      if (!block.test) return false;
      continue;
    }
    const parameter = /^◇ Test case passing 1 argument (.+) to (.+) started\.$/.exec(line);
    if (parameter) {
      if (!block?.test || block.finished || parameter[2] !== block.test.name ||
          !block.test.cases.includes(parameter[1]) || block.cases.has(parameter[1])) return false;
      block.cases.add(parameter[1]); continue;
    }
    if (line.startsWith('✘ Test ') && line.includes(' recorded an issue')) {
      if (!block?.test?.failed || block.finished || ++block.issues !== 1) return false;
      continue; // The exact assertion is also checked by childFailureSignatures.
    }
    const finish = /^[✔✘] Test (.+?)(?: with (\d+) test cases)? (passed|failed) after \d+(?:\.\d+)? seconds(?:\.| with (\d+) issues?\.)$/.exec(line);
    if (finish) {
      if (!block?.test || block.finished || finish[1] !== block.test.name ||
          Number(finish[2] ?? 0) !== block.test.cases.length || block.cases.size !== block.test.cases.length ||
          (finish[3] === 'failed') !== block.test.failed || Number(finish[4] ?? 0) !== block.issues) return false;
      block.finished = true; continue;
    }
    // Unknown/malformed test, suite, skip and XCTest records are never metadata.
    if (/^(?:[◇✔✘➜]|Test (?:Suite|Case)|\s*Executed )/.test(line)) return false;
    if (!line.trim()) continue;
    // Unknown freeform output may be a new runtime failure spelling. Only the
    // observed runner headers and this active probe's known debug records pass.
    if (block && (/^↳ (?:Testing Library Version: \d+|Target Platform: [A-Za-z0-9_.-]+)$/.test(line) ||
        block.test?.metadata?.test(line))) continue;
    return false;
  }
  return !block && entry.childTests.filter(test => test.failed).every(test => seen.has(test.name));
}

export function classifyFlaky(run) {
  const parsed = parseAppResult(run);
  const fail = { decision: 'fail', names: [], issues: [] };
  if (!parsed.reliable || !parsed.failed || parsed.unattributedIssues) return fail;
  const entries = parsed.failureNames.map(name => knownFlaky.find(entry => entry.name === name));
  if (entries.some(entry => !entry)) return fail;
  if (parsed.issues.some(issue => !entries.some(entry => entry.name === issue.name && entry.signature.test(issue.signature)))) return fail;
  if (entries.some(entry => !parsed.issues.some(issue => issue.name === entry.name))) return fail;
  for (const entry of entries) if (entry.childFailureSignatures) {
    const childLines = parsed.output.replace(/\x1b\[[0-9;]*m/g, '').replace(/\r/g, '').split('\n')
      .filter(line => line.startsWith(entry.childPrefix))
      .map(line => line.slice(entry.childPrefix.length));
    if (!completeKnownChildren(entry, childLines)) return fail;
    const diagnostics = childLines.filter(line => line.startsWith('✘') || /^(?:error:|(?:[^:\r\n]+\.swift:\d+(?::\d+)?: )?Fatal error:|Segmentation fault|Bus error|Abort trap)/i.test(line));
    // Every failed child assertion, test and root must be the recorded failure.
    // Additional failures or missing child evidence revoke the parent's retry.
    if (diagnostics.length !== entry.childFailureSignatures.length ||
        entry.childFailureSignatures.some(signature => diagnostics.filter(line => signature.test(line)).length !== 1)) return fail;
  }
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
