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
        const nativeSkip = (key === 'swift' || key === 'lcov') && /^skipped \([^|\r\n]+\)$/.test(value ?? '');
        return value !== undefined && !/^\d+$/.test(value) && !nativeSkip;
      });
      const stale = expectedHead && expectedHead.toLowerCase() !== head.toLowerCase();
      // The local App lane (apptests=) is optional in older summaries. With --ci the CI App row is the only one.
      const appLines = lines.filter(line => line.startsWith('apptests='));
      const appValue = appLines[0]?.slice('apptests='.length);
      const retainedLines = lines.filter(line => line.startsWith('apptests-retained='));
      const retainedValue = retainedLines[0]?.slice('apptests-retained='.length);
      const hostedLines = lines.filter(line => line.startsWith('apptests-hosted='));
      const hostedValue = hostedLines[0]?.slice('apptests-hosted='.length);
      const appRow = !ciFile && (appLines.length > 0 || retainedLines.length > 0);
      const appAmbiguous = appLines.length > 1 || retainedLines.length > 1 || hostedLines.length > 1;
      const retainedResult = retainedValue?.match(/^(\d+) (\d+)\/(\d+)$/);
      const retainedSkipped = retainedValue === 'skipped (no App-facing change)';
      const retainedMalformed = retainedValue !== undefined && !retainedSkipped &&
        (!retainedResult || Number(retainedResult[3]) > Number(retainedResult[2]) ||
          (retainedResult[1] === '0' && (Number(retainedResult[2]) === 0 || Number(retainedResult[3]) !== 0)));
      const hostedMalformed = hostedValue !== undefined && !/^\d+$/.test(hostedValue) &&
        !/^skipped \([^|\r\n]+\)$/.test(hostedValue);
      const appMalformed = (appValue !== undefined && !/^\d+$/.test(appValue) && appValue !== 'skip (no App-facing change)') ||
        retainedMalformed || hostedMalformed;
      const summaryLanes = appRow ? [...lanes.slice(0, 3), ['app-tests', retainedValue === undefined ? 'apptests' : 'apptests-retained'], ...lanes.slice(3)] : lanes;
      if (ambiguous || appAmbiguous) {
        rows.push(...summaryLanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary ambiguous |`));
      } else if (malformed || appMalformed) {
        rows.push(...summaryLanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary malformed |`));
      } else if (finalLine !== 'DONE') {
        rows.push(...summaryLanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary incomplete |`));
      } else if (stale) {
        rows.push(...summaryLanes.map(([lane]) => `| ${lane} | NOT VERIFIED | ${head} | owner-gates stale head ${head.slice(0, 7)} |`));
      } else {
        rows.push(...summaryLanes.map(([lane, key]) => {
          if (key === 'apptests-retained') {
            if (retainedSkipped) return `| ${lane} | NOT RUN | — | owner-gates apptests-retained=${retainedValue} |`;
            const source = `owner-gates apptests-retained=${retainedValue}${hostedValue?.startsWith('skipped') ? '; hosted CI binding' : ''}`;
            return `| ${lane} | ${retainedResult[1] === '0' ? 'PASS' : 'FAIL'} | ${head} | ${source} |`;
          }
          if (key === 'apptests' && appValue.startsWith('skip')) return `| ${lane} | NOT RUN | — | owner-gates apptests=${appValue} |`;
          const exit = lines.find(line => line.startsWith(`${key}=`))?.slice(key.length + 1);
          if (exit === undefined) return key === 'design'
            ? `| ${lane} | NOT VERIFIED | ${head} | owner-gates summary missing ${key} |`
            : `| ${lane} | NOT RUN | — | owner-gates summary missing ${key} |`;
          if ((key === 'swift' || key === 'lcov') && exit.startsWith('skipped'))
            return `| ${lane} | N/A | — | owner-gates ${key}=${exit} |`;
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
          if (result === 'success' && job.conclusion === 'success') {
            // A successful job cannot establish current-head or first-attempt provenance by itself.
            const provenanceReason = !expectedHead ? 'App tests --head not supplied'
              : run.event === undefined ? 'App tests event not exported'
                : typeof run.event !== 'string' || !/^[a-z][a-z0-9_]*$/.test(run.event) ? 'App tests event invalid'
                  : run.attempt === undefined ? 'App tests attempt not exported'
                    : !Number.isInteger(run.attempt) || run.attempt <= 0 ? 'App tests attempt invalid'
                      : undefined;
            // gh jobs exports omit dispatch inputs. Executed dispatch/repeat steps cannot prove
            // full-suite scope; skipped markers on ordinary PR/push runs remain valid evidence.
            const diagnosticNames = ['Record repeat job start', 'Validate App repeat input', 'Upload App repeat logs'];
            const diagnostic = run.event === 'workflow_dispatch' ||
              run.attempt !== 1 ||
              steps.some(step => diagnosticNames.includes(step.name) &&
                (step.status !== 'completed' || step.conclusion !== 'skipped'));
            rows.push(provenanceReason
              ? `| app-tests | NOT VERIFIED | ${headSha} | ${provenanceReason} ${url} |`
              : diagnostic
                ? `| app-tests | NOT VERIFIED | ${headSha} | App tests diagnostic run does not prove full-suite scope ${url} |`
                : `| app-tests | PASS | ${headSha} | ${url} |`);
          } else if (result === 'failure') {
            rows.push(`| app-tests | FAIL | ${headSha} | App tests step failure ${url} |`);
          } else if (result === 'skipped' && ['failure', 'cancelled'].includes(job.conclusion)) {
            rows.push(`| app-tests | FAIL | ${headSha} | App tests ${job.conclusion} (test step skipped) ${url} |`);
          } else if (result === 'skipped' && job.conclusion === 'success') {
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
