#!/usr/bin/env node
// #788 item 4: list every failed job attempt of a PR's (or a head SHA's) workflow runs, including the ones a rerun hid,
// with the failed step and the failing test names from the job log, and flag failing tests that have no ticket.
//
//   node scripts/ci/attempt-history.mjs --pr <n> [--require-tickets] [--body-file <f>]
//   node scripts/ci/attempt-history.mjs --sha <head-sha> [--body-file <f>] [--require-tickets]
//   options: --repo <owner/name> (default anzchy/mado), --fixture <json> (replay recorded API responses, no network),
//            --record <json> (write the responses this run read, for a new fixture), --lists-root <dir> (default: cwd)
//
// Ticket rule: a failing test has a ticket when a line of the PR body (or --body-file) names it as a whole word together
// with `#<n>`, or when scripts/tdd/app-quarantine.json, .agents/skills/mado-verify/known-flakes.json or
// scripts/ci/known-flaky.mjs lists it (by name, or by an entry's `pattern` regular expression) with an issue.
// Swift test names match with or without their `(args:)` suffix. A failed job whose log names no test (an aggregate
// such as Walking skeleton, an upload step, a timeout, an expired log) is listed as `no-test-names` and needs no ticket.
// Advisory by default: exit 0 and print `needs-ticket:` lines. --require-tickets exits 1 when any remain. Exit 2: usage or API error.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const PER_PAGE = 100;
const FAILED = new Set(['failure', 'timed_out', 'startup_failure']);

class HttpError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

const stripStamp = line => line.replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z ?/, '');
const unique = names => [...new Set(names.filter(Boolean))];

/** Failing test names in a job log: node spec (✖), TAP (not ok), Swift Testing (✘ Test … failed after) and XCTest. */
export function parseFailingTests(log) {
  const lines = String(log ?? '').split(/\r?\n/).map(stripStamp);
  const names = [];
  const spec = line => line.match(/^\s*✖ (.+?) \(\d+(?:\.\d+)?m?s\)$/)?.[1];
  const section = lines.findIndex(line => /^\s*✖ failing tests:\s*$/.test(line));
  if (section >= 0) {
    for (const line of lines.slice(section + 1)) names.push(spec(line));
  } else {
    for (const line of lines) names.push(spec(line));
  }
  for (const line of lines) {
    const tap = line.match(/^\s*not ok \d+ - (.+?)\s*$/);
    if (tap && !/\s#\s*(?:TODO|SKIP)\b/i.test(tap[1])) names.push(tap[1]);
    const swift = line.match(/^\s*✘ Test (.+?)(?: with \d+ test cases?)? failed after /);
    if (swift && !/^run with \d+ tests? /.test(swift[1])) names.push(swift[1]);
    const xc = line.match(/Test Case '-\[(?:[\w]+\.)?([\w]+) ([\w]+)\]' failed/);
    if (xc) names.push(`${xc[1]}.${xc[2]}`);
  }
  return unique(names);
}

/** A `get(path)` over recorded responses: `{ responses: { "<api path>": <json or log text> } }`. Missing paths are 404s. */
export function fixtureGetter(fixture) {
  const responses = fixture?.responses ?? {};
  return async path => {
    if (!Object.hasOwn(responses, path)) throw new HttpError(`fixture has no response for ${path} (HTTP 404)`, 404);
    return structuredClone(responses[path]);
  };
}

function ghGetter() {
  return async path => {
    const isLog = /\/actions\/jobs\/\d+\/logs$/.test(path);
    try {
      const out = execFileSync('gh', ['api', path], { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] });
      return isLog ? out : JSON.parse(out);
    } catch (error) {
      const text = `${error.stderr ?? ''}${error.stdout ?? ''}${error.message ?? ''}`;
      const status = Number(text.match(/HTTP (\d{3})/)?.[1]) || undefined;
      throw new HttpError(`gh api ${path} failed${status ? ` (HTTP ${status})` : ''}: ${text.trim().split('\n')[0]}`, status);
    }
  };
}

async function paged(get, base, key) {
  const items = [];
  for (let page = 1; ; page++) {
    const body = await get(`${base}${base.includes('?') ? '&' : '?'}per_page=${PER_PAGE}&page=${page}`);
    const batch = Array.isArray(body?.[key]) ? body[key] : null;
    if (!batch) throw new Error(`unexpected response for ${base}: no ${key} array`);
    items.push(...batch);
    const total = Number.isInteger(body.total_count) ? body.total_count : items.length;
    if (batch.length === 0 || items.length >= total || batch.length < PER_PAGE) return items;
  }
}

// A rerun hides a failed attempt when a later attempt exists, or when the run ended green or cancelled anyway.
const hiddenBy = (attempt, run) => attempt < run.attempts || ['success', 'cancelled', 'skipped', 'neutral'].includes(run.conclusion);

/** Every failed job attempt of the runs for a PR (its head branch, all its pushes) or for one head SHA. */
export async function collectHistory({ get, repo, pr, sha }) {
  const R = `repos/${repo}`;
  let prInfo = null;
  let runsBase;
  let headSha = sha ?? null;
  if (pr != null) {
    const p = await get(`${R}/pulls/${pr}`);
    prInfo = { number: p.number, headRef: p.head?.ref, body: p.body ?? '' };
    headSha = p.head?.sha ?? null;
    if (!prInfo.headRef) throw new Error(`PR #${pr} has no head ref`);
    runsBase = `${R}/actions/runs?branch=${encodeURIComponent(prInfo.headRef)}&event=pull_request`;
  } else {
    runsBase = `${R}/actions/runs?head_sha=${sha}`;
  }
  const rawRuns = await paged(get, runsBase, 'workflow_runs');
  const runs = [];
  for (const r of rawRuns.sort((a, b) => a.id - b.id)) {
    const run = { id: r.id, name: r.name, headSha: r.head_sha, attempts: r.run_attempt ?? 1, status: r.status, conclusion: r.conclusion, failed: [] };
    for (let attempt = 1; attempt <= run.attempts; attempt++) {
      const jobs = await paged(get, `${R}/actions/runs/${r.id}/attempts/${attempt}/jobs`, 'jobs');
      for (const job of jobs) {
        // A partial rerun lists carried-forward jobs under the later attempt with their own run_attempt; count each once.
        if (!FAILED.has(job.conclusion) || (job.run_attempt != null && job.run_attempt !== attempt)) continue;
        let tests = [];
        let log = 'ok';
        try {
          tests = parseFailingTests(await get(`${R}/actions/jobs/${job.id}/logs`));
        } catch (error) {
          if (![404, 410].includes(error.status)) throw error;
          log = 'unavailable';
        }
        run.failed.push({
          attempt, jobId: job.id, job: job.name, conclusion: job.conclusion,
          steps: (job.steps ?? []).filter(s => FAILED.has(s.conclusion)).map(s => s.name),
          tests, log, hidden: false,
        });
      }
    }
    for (const f of run.failed) f.hidden = hiddenBy(f.attempt, run);
    runs.push(run);
  }
  return { repo, pr: prInfo, sha: sha ?? null, headSha, runs };
}

/** Ticket lists: app quarantine, mado-verify known flakes and the CI known-flaky signatures. */
export async function loadTicketLists(root) {
  const lists = [];
  const add = (source, entries) => {
    for (const e of Array.isArray(entries) ? entries : []) {
      if (e && Number.isInteger(e.issue)) lists.push({ name: e.name, pattern: e.pattern, issue: e.issue, source });
    }
  };
  const json = rel => {
    const path = join(root, rel);
    return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null;
  };
  add('scripts/tdd/app-quarantine.json', json('scripts/tdd/app-quarantine.json'));
  add('.agents/skills/mado-verify/known-flakes.json', json('.agents/skills/mado-verify/known-flakes.json')?.flakes);
  const flaky = join(root, 'scripts/ci/known-flaky.mjs');
  if (existsSync(flaky)) add('scripts/ci/known-flaky.mjs', (await import(pathToFileURL(resolve(flaky)).href)).knownFlaky);
  return lists;
}

const baseName = name => name.replace(/\(.*\)$/, '');
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function bodyTicket(body, test) {
  for (const candidate of unique([test, baseName(test)])) {
    const word = new RegExp(`(?<![\\w])${escape(candidate)}(?![\\w])`);
    for (const line of String(body ?? '').split(/\r?\n/)) {
      const issue = line.match(/#(\d+)\b/);
      if (issue && word.test(line)) return Number(issue[1]);
    }
  }
  return null;
}

function listTicket(lists, test) {
  for (const entry of lists) {
    if (entry.name && (entry.name === test || entry.name === baseName(test) || baseName(entry.name) === baseName(test))) return entry;
    if (entry.pattern) {
      let re;
      try { re = new RegExp(entry.pattern); } catch { continue; }
      if (re.test(test) || re.test(baseName(test))) return entry;
    }
  }
  return null;
}

/** Split each failed attempt's tests into ticketed and needs-ticket; failed jobs without test names are listed apart. */
export function classify(history, { body, lists }) {
  const ticketed = [];
  const needsTicket = [];
  const noTestNames = [];
  for (const run of history.runs) {
    for (const f of run.failed) {
      const where = { run: run.id, workflow: run.name, attempt: f.attempt, job: f.job };
      if (f.tests.length === 0) noTestNames.push({ ...where, steps: f.steps, log: f.log });
      for (const test of f.tests) {
        const issue = bodyTicket(body, test);
        const entry = issue == null ? listTicket(lists, test) : null;
        if (issue != null) ticketed.push({ ...where, test, issue, source: 'PR body' });
        else if (entry) ticketed.push({ ...where, test, issue: entry.issue, source: entry.source });
        else needsTicket.push({ ...where, test });
      }
    }
  }
  return { ticketed, needsTicket, noTestNames };
}

const cell = text => String(text).replace(/\|/g, '\\|').replace(/\s+/g, ' ').trim() || '-';

export function render(history, c) {
  const failed = history.runs.flatMap(run => run.failed.map(f => ({ run, f })));
  const subject = history.pr ? `PR #${history.pr.number}` : `head ${String(history.sha).slice(0, 8)}`;
  const head = history.pr && history.headSha ? ` head ${history.headSha.slice(0, 8)}` : '';
  const out = [`attempt-history: ${subject}${head} (${history.repo}, ${history.runs.length} runs)`];
  if (failed.length) {
    out.push('', '| run | workflow | attempt | job | failed step | failing tests | hidden |', '|---|---|---|---|---|---|---|');
    for (const { run, f } of failed) {
      const tests = f.log === 'unavailable' ? '(log unavailable)' : f.tests.join('; ');
      out.push(`| ${run.id} | ${cell(run.name)} | ${f.attempt}/${run.attempts} | ${cell(f.job)} | ${cell(f.steps.join('; '))} | ${cell(tests)} | ${f.hidden ? 'yes' : 'no'} |`);
    }
    out.push('');
  }
  for (const t of c.needsTicket) out.push(`needs-ticket: ${t.test} (run ${t.run} attempt ${t.attempt}, job ${t.job})`);
  for (const t of c.ticketed) out.push(`ticketed: ${t.test} -> #${t.issue} (${t.source})`);
  for (const t of c.noTestNames) {
    const why = t.log === 'unavailable' ? ', log unavailable' : t.steps.length ? `, step ${t.steps.join('; ')}` : '';
    out.push(`no-test-names: run ${t.run} attempt ${t.attempt}, job ${t.job}${why}`);
  }
  const runsWithFailures = history.runs.filter(run => run.failed.length).length;
  const hidden = failed.filter(({ f }) => f.hidden).length;
  const tests = c.ticketed.length + c.needsTicket.length;
  out.push(`summary: ${failed.length} failed job attempts in ${runsWithFailures} runs, ${hidden} hidden by a later attempt or a green/cancelled run; ${tests} failing tests, ${c.needsTicket.length} without a ticket`);
  return `${out.join('\n')}\n`;
}

// Keep only the fields this script reads, and only the failure lines of a log, so a recorded fixture stays small.
function trimForRecord(path, value) {
  if (typeof value === 'string') {
    const lines = value.split('\n');
    const keep = new Set();
    lines.forEach((line, i) => {
      if (/✖|✘|not ok \d|Test Case '.*' failed|##\[error\]/.test(line)) for (let j = Math.max(0, i - 1); j <= Math.min(lines.length - 1, i + 1); j++) keep.add(j);
    });
    return `${[...keep].sort((a, b) => a - b).map(i => lines[i]).join('\n')}\n`;
  }
  if (Array.isArray(value?.workflow_runs)) {
    return { total_count: value.total_count, workflow_runs: value.workflow_runs.map(r => ({ id: r.id, name: r.name, head_sha: r.head_sha, head_branch: r.head_branch, event: r.event, run_attempt: r.run_attempt, status: r.status, conclusion: r.conclusion })) };
  }
  if (Array.isArray(value?.jobs)) {
    return { total_count: value.total_count, jobs: value.jobs.map(j => ({ id: j.id, name: j.name, run_attempt: j.run_attempt, head_sha: j.head_sha, status: j.status, conclusion: j.conclusion, steps: (j.steps ?? []).map(s => ({ name: s.name, number: s.number, conclusion: s.conclusion })) })) };
  }
  if (/\/pulls\/\d+$/.test(path)) return { number: value.number, head: { ref: value.head?.ref, sha: value.head?.sha }, body: value.body };
  return value;
}

function parseArgs(argv) {
  const opts = { repo: 'anzchy/mado', listsRoot: process.cwd(), requireTickets: false };
  const takes = new Set(['--pr', '--sha', '--repo', '--fixture', '--record', '--body-file', '--lists-root']);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--require-tickets') { opts.requireTickets = true; continue; }
    if (!takes.has(arg)) throw new Error(`unknown argument ${arg}`);
    const value = argv[++i];
    if (value == null || value.startsWith('--')) throw new Error(`${arg} needs a value`);
    const key = { '--pr': 'pr', '--sha': 'sha', '--repo': 'repo', '--fixture': 'fixture', '--record': 'record', '--body-file': 'bodyFile', '--lists-root': 'listsRoot' }[arg];
    opts[key] = value;
  }
  if ((opts.pr == null) === (opts.sha == null)) throw new Error('pass exactly one of --pr <n> or --sha <head-sha>');
  if (opts.pr != null) {
    if (!/^[1-9]\d*$/.test(opts.pr)) throw new Error(`--pr must be a PR number, not ${opts.pr}`);
    opts.pr = Number(opts.pr);
  }
  if (opts.sha != null && !/^[0-9a-f]{7,40}$/i.test(opts.sha)) throw new Error(`--sha must be a commit SHA, not ${opts.sha}`);
  if (!/^[\w.-]+\/[\w.-]+$/.test(opts.repo)) throw new Error(`--repo must be owner/name, not ${opts.repo}`);
  return opts;
}

async function main(argv) {
  const opts = parseArgs(argv);
  let get = opts.fixture ? fixtureGetter(JSON.parse(readFileSync(opts.fixture, 'utf8'))) : ghGetter();
  const recorded = {};
  if (opts.record) {
    const inner = get;
    // Failed requests are not recorded, so a replay fails (or reports a missing log) the same way.
    get = async path => {
      const value = await inner(path);
      recorded[path] = trimForRecord(path, value);
      return value;
    };
  }
  const history = await collectHistory({ get, repo: opts.repo, pr: opts.pr, sha: opts.sha });
  const body = opts.bodyFile ? readFileSync(opts.bodyFile, 'utf8') : history.pr?.body ?? '';
  const c = classify(history, { body, lists: await loadTicketLists(opts.listsRoot) });
  let text = render(history, c);
  if (c.needsTicket.length && !opts.requireTickets) text += `advisory: ${c.needsTicket.length} failing tests without a ticket; pass --require-tickets to fail on them\n`;
  process.stdout.write(text);
  if (opts.record) {
    writeFileSync(opts.record, `${JSON.stringify({ $comment: `Recorded by scripts/ci/attempt-history.mjs ${argv.join(' ')}`, responses: recorded }, null, 2)}\n`);
  }
  return opts.requireTickets && c.needsTicket.length ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => {
    process.stderr.write(`attempt-history: ${error.message}\n`);
    process.exitCode = 2;
  });
}
