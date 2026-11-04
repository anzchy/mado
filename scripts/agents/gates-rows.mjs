#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const lanes = [
  ['package-tests', 'swift'],
  ['package-coverage', 'lcov'],
  ['unsigned-build', 'xcodebuild'],
  ['node-tooling', 'node'],
  ['ledger', 'ledger'],
  ['diff-check', 'diffcheck'],
  ['design-check', 'design'],
];
const usage = 'usage: node scripts/agents/gates-rows.mjs [<summary.txt>] [--ci <run.json>] [--head <sha>]';
const args = process.argv.slice(2);
let summaryFile, ciFile, expectedHead;
if (args[0] && !args[0].startsWith('--')) summaryFile = args.shift();
let valid = true;
while (args.length) {
  const flag = args.shift();
  const value = args.shift();
  if (!value || (flag !== '--ci' && flag !== '--head') || (flag === '--ci' && ciFile) || (flag === '--head' && expectedHead)) {
    valid = false;
    break;
  }
  if (flag === '--ci') ciFile = value;
  else expectedHead = value;
}
if ((!summaryFile && !ciFile) || (expectedHead && !/^[0-9a-f]{7,40}$/i.test(expectedHead))) valid = false;
if (!valid) {
  console.error(usage);
  process.exitCode = 2;
} else {
  try {
    const rows = [];
    if (summaryFile) {
      const lines = readFileSync(summaryFile, 'utf8').split(/\r?\n/).map(line => {
        const record = line.match(/^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$/);
        return record ? `${record[1]}=${record[2]}` : line;
      });
      const head = lines.find(line => /^head=[0-9a-f]{7,40}$/i.test(line))?.split('=')[1];
      if (!head) throw new Error('owner-gates summary missing valid head');
      const finalLine = lines.filter(line => line.trim()).at(-1);
      const doneCount = lines.filter(line => line === 'DONE').length;
      const ambiguous = lines.filter(line => line.startsWith('head=')).length > 1 || doneCount > 1 ||
        (doneCount === 1 && finalLine !== 'DONE') ||
        lanes.some(([, key]) => lines.filter(line => line.startsWith(`${key}=`)).length > 1);
      const malformed = lanes.some(([, key]) => {
        const value = lines.find(line => line.startsWith(`${key}=`))?.slice(key.length + 1);
        return value !== undefined && !/^\d+$/.test(value);
      });
      const stale = expectedHead && expectedHead.toLowerCase() !== head.toLowerCase();
      if (ambiguous) {
        rows.push(...lanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary ambiguous |`));
      } else if (malformed) {
        rows.push(...lanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary malformed |`));
      } else if (finalLine !== 'DONE') {
        rows.push(...lanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary incomplete |`));
      } else if (stale) {
        rows.push(...lanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates stale head ${head.slice(0, 7)} |`));
      } else {
        rows.push(...lanes.map(([lane, key]) => {
          const exit = lines.find(line => line.startsWith(`${key}=`))?.slice(key.length + 1);
          if (exit === undefined) return key === 'design'
            ? `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary missing ${key} |`
            : `| ${lane} | NOT RUN | — | owner-gates summary missing ${key} |`;
          const status = exit === '0' ? 'PASS' : 'FAIL';
          return `| ${lane} | ${status} | ${head} | owner-gates ${key}=${exit} |`;
        }));
      }
    }
    if (ciFile) {
      const run = JSON.parse(readFileSync(ciFile, 'utf8'));
      if (!run || typeof run.headSha !== 'string' || !/^[0-9a-f]{40}$/i.test(run.headSha) || !Array.isArray(run.jobs)) {
        throw new Error('CI run needs a 40-hex headSha and jobs');
      }
      const { headSha, url, status } = run;
      if (typeof url !== 'string' || /[\r\n|]/.test(url) || !URL.canParse(url) || new URL(url).protocol !== 'https:') {
        throw new Error('CI run url must be an HTTPS URL without CR, LF or pipe');
      }
      if (typeof status !== 'string' || /[\r\n|]/.test(status)) {
        throw new Error('CI run status must be a string without CR, LF or pipe');
      }
      // Validate all jobs before rendering, even for a stale or incomplete run.
      for (const job of run.jobs) {
        if (!job || typeof job !== 'object' || Array.isArray(job) ||
            ['name', 'status', 'conclusion'].some(field =>
              typeof job[field] !== 'string' || /[\r\n|]/.test(job[field]))) {
          throw new Error('CI job name, status and conclusion must be strings without CR, LF or pipe');
        }
        if (Array.isArray(job.steps) && job.steps.some(step => step &&
            ['name', 'status', 'conclusion'].some(field =>
              typeof step[field] === 'string' && /[\r\n|]/.test(step[field])))) {
          throw new Error('CI step fields must not contain CR, LF or pipe');
        }
      }
      const runHead = headSha.toLowerCase();
      const head = expectedHead?.toLowerCase();
      const jobs = run.jobs.filter(job => job?.name === 'App tests');
      if (head && runHead !== head && !runHead.startsWith(head)) {
        rows.push(`| app-tests | NOT VERIFIED | ${headSha} | CI stale head ${headSha.slice(0, 7)} ${url} |`);
      } else if (status !== 'completed') {
        rows.push(`| app-tests | NOT VERIFIED | ${headSha} | CI run ${status} ${url} |`);
      } else if (jobs.length === 0) {
        rows.push(`| app-tests | NOT RUN | — | App tests job absent from ${url} |`);
      } else if (jobs.length > 1) {
        rows.push(`| app-tests | NOT VERIFIED | ${headSha} | CI run ambiguous: ${jobs.length} App tests jobs |`);
      } else {
        if (jobs[0].status !== 'completed') throw new Error('App tests job is not completed');
        if (jobs[0].conclusion === 'skipped') {
          // The run's jobs carry no outputs. A skipped App tests job means native=false only when the classifier
          // succeeded and Walking skeleton passed: with native=true it needs a successful build step from App tests.
          const succeeded = name => {
            const named = run.jobs.filter(job => job.name === name);
            return named.length === 1 && named[0].status === 'completed' && named[0].conclusion === 'success';
          };
          const decided = succeeded('Native inputs') && succeeded('Walking skeleton');
          rows.push(decided
            ? `| app-tests | NOT RUN | — | App tests skipped (no native input changed) ${url} |`
            : `| app-tests | NOT RUN | — | App tests skipped without a classifier decision ${url} |`);
        } else {
          // gh run view --json jobs exports steps[].status/conclusion, not outcome.
          // A successful job can be a build-only dispatch; only the test step proves that tests ran.
          const job = jobs[0];
          const steps = Array.isArray(job.steps) && job.steps.every(step => step &&
            typeof step === 'object' && !Array.isArray(step) &&
            ['name', 'status', 'conclusion'].every(field => typeof step[field] === 'string'))
            ? job.steps : [];
          const tests = steps.filter(step => step.name === 'Run App tests');
          const result = tests.length === 1 && tests[0].status === 'completed' ? tests[0].conclusion : undefined;
          if (result === 'success') {
            rows.push(`| app-tests | PASS | ${headSha} | ${url} |`);
          } else if (result === 'failure') {
            rows.push(`| app-tests | FAIL | ${headSha} | App tests step failure ${url} |`);
          } else if (result === 'skipped') {
            const concluded = (name, conclusion) => {
              const named = steps.filter(step => step.name === name);
              return named.length === 1 && named[0].status === 'completed' && named[0].conclusion === conclusion;
            };
            // The pinned workflow skips Build/Run App tests only for dispatch app_tests=false;
            // require the successful unsigned build too, so a build failure cannot claim that reason.
            const buildOnly = concluded('Build unsigned app', 'success') && concluded('Build App tests', 'skipped');
            rows.push(`| app-tests | NOT RUN | — | App tests skipped${buildOnly ? ' (build-only dispatch, app_tests=false)' : ''} ${url} |`);
          } else if (['failure', 'cancelled'].includes(job.conclusion)) {
            rows.push(`| app-tests | FAIL | ${headSha} | App tests ${job.conclusion} ${url} |`);
          } else {
            rows.push(`| app-tests | NOT VERIFIED | ${headSha} | App tests step evidence missing or invalid ${url} |`);
          }
        }
      }
    }
    console.log(rows.join('\n'));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
  }
}
