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
// App quarantine entries are matched by the last `.`/`/` component of their `id`; a name with `(args:)` matches the
// same arguments only, a name without arguments matches every argument list. A failed job whose log names no test is
// `needs-ticket-unknown` when its names cannot be read (expired log, crash or signal, timed-out job) and `no-test-names`
// otherwise (an aggregate such as Walking skeleton, an upload step); only the second needs no ticket.
// Advisory by default: exit 0 and print the lines. --require-tickets (fail-closed) exits 1 while a needs-ticket or
// needs-ticket-unknown line remains, and exits 2 when a ticket source is missing or does not load or no run was found.
// PR mode keeps the pull_request runs of the PR's head branch, minus runs whose metadata shows another PR (other head
// repository, created before the PR, or a pull_requests list without this PR); runs without that metadata are kept.
// Exit 2: usage or API error.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const PER_PAGE = 100;
const FAILED = new Set(['failure', 'timed_out', 'startup_failure']);
const CRASH = /Exited with (?:unexpected )?signal|[Tt]erminating (?:app )?due to uncaught exception|Fatal error:|watchdog: sending (?:TERM|KILL)|Segmentation fault|Abort trap/;
export const TICKET_SOURCES = Object.freeze(['scripts/tdd/app-quarantine.json', '.agents/skills/mado-verify/known-flakes.json', 'scripts/ci/known-flaky.mjs']);

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
    const total = Number.isInteger(body.total_count) ? body.total_count : Infinity;
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
    prInfo = { number: p.number, headRef: p.head?.ref, headRepo: p.head?.repo?.full_name ?? null, createdAt: p.created_at ?? null, body: p.body ?? '' };
    headSha = p.head?.sha ?? null;
    if (!prInfo.headRef) throw new Error(`PR #${pr} has no head ref`);
    runsBase = `${R}/actions/runs?branch=${encodeURIComponent(prInfo.headRef)}&event=pull_request`;
  } else {
    runsBase = `${R}/actions/runs?head_sha=${sha}`;
  }
  const rawRuns = await paged(get, runsBase, 'workflow_runs');
  const runs = [];
  const excluded = [];
  for (const r of rawRuns.sort((a, b) => a.id - b.id)) {
    const reason = prInfo ? otherPr(r, prInfo) : null;
    if (reason) { excluded.push({ id: r.id, name: r.name, reason }); continue; }
    const run = { id: r.id, name: r.name, headSha: r.head_sha, attempts: r.run_attempt ?? 1, status: r.status, conclusion: r.conclusion, failed: [] };
    for (let attempt = 1; attempt <= run.attempts; attempt++) {
      const jobs = await paged(get, `${R}/actions/runs/${r.id}/attempts/${attempt}/jobs`, 'jobs');
      for (const job of jobs) {
        // A partial rerun lists carried-forward jobs under the later attempt with their own run_attempt; count each once.
        if (!FAILED.has(job.conclusion) || (job.run_attempt != null && job.run_attempt !== attempt)) continue;
        let tests = [];
        let log = 'ok';
        let crash = false;
        try {
          const text = await get(`${R}/actions/jobs/${job.id}/logs`);
          tests = parseFailingTests(text);
          crash = CRASH.test(String(text ?? ''));
        } catch (error) {
          if (![404, 410].includes(error.status)) throw error;
          log = 'unavailable';
        }
        run.failed.push({
          attempt, jobId: job.id, job: job.name, conclusion: job.conclusion,
          steps: (job.steps ?? []).filter(s => FAILED.has(s.conclusion)).map(s => s.name),
          tests, log, crash, hidden: false,
        });
      }
    }
    for (const f of run.failed) f.hidden = hiddenBy(f.attempt, run);
    runs.push(run);
  }
  return { repo, pr: prInfo, sha: sha ?? null, headSha, runs, excluded };
}

// Why a branch run belongs to another PR, from the run's own metadata; null keeps it (missing metadata keeps it too).
function otherPr(run, pr) {
  const repo = run.head_repository?.full_name;
  if (repo && pr.headRepo && repo !== pr.headRepo) return `head repository ${repo}, not ${pr.headRepo}`;
  if (run.created_at && pr.createdAt && Date.parse(run.created_at) < Date.parse(pr.createdAt)) {
    return `created ${run.created_at}, before PR #${pr.number} (${pr.createdAt})`;
  }
  const numbers = Array.isArray(run.pull_requests) ? run.pull_requests.map(p => p?.number).filter(Number.isInteger) : [];
  if (numbers.length && !numbers.includes(pr.number)) return `belongs to PR #${numbers.join(', #')}`;
  return null;
}

/**
 * Ticket lists: app quarantine ({id, issue, …}, docs/agents/test-lanes.md), mado-verify known flakes ({flakes: [{name,
 * pattern, issue, …}]}) and the CI known-flaky signatures (knownFlaky: [{name, issue}]). With `strict`, a source that is
 * missing or does not load throws a SourceError; otherwise it is skipped and named in `lists.missing`.
 */
export class SourceError extends Error {
  constructor(source, why) { super(`ticket source ${source} ${why}`); this.source = source; }
}

export async function loadTicketLists(root, { strict = false } = {}) {
  const lists = [];
  lists.missing = [];
  const add = (source, entries) => {
    for (const e of entries) {
      if (e && Number.isInteger(e.issue)) lists.push({ id: e.id, name: e.name, pattern: e.pattern, issue: e.issue, source });
    }
  };
  const read = async (source, load) => {
    const path = join(root, source);
    try {
      if (!existsSync(path)) throw new SourceError(source, `is missing under ${root}`);
      const entries = await load(path);
      if (!Array.isArray(entries)) throw new SourceError(source, 'does not hold a list of entries');
      add(source, entries);
    } catch (error) {
      const failure = error instanceof SourceError ? error : new SourceError(source, `does not load: ${error.message}`);
      if (strict) throw failure;
      lists.missing.push({ source, why: failure.message.slice(`ticket source ${source} `.length) });
    }
  };
  const json = path => JSON.parse(readFileSync(path, 'utf8'));
  await read(TICKET_SOURCES[0], json);
  await read(TICKET_SOURCES[1], path => json(path)?.flakes);
  await read(TICKET_SOURCES[2], async path => (await import(pathToFileURL(resolve(path)).href)).knownFlaky);
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

// The test's own name: the last `.`/`/` component (Module.Suite/func(args:) → func(args:)), split into base and args.
function shortName(name) {
  const args = name.match(/\(.*\)$/)?.[0] ?? '';
  const base = name.slice(0, name.length - args.length);
  return { base: base.slice(Math.max(base.lastIndexOf('.'), base.lastIndexOf('/')) + 1), args };
}

function sameTest(listed, test) {
  const a = shortName(listed);
  const b = shortName(test);
  return a.base === b.base && (!a.args || !b.args || a.args === b.args);
}

function listTicket(lists, test) {
  for (const entry of lists) {
    if ([entry.id, entry.name].some(name => typeof name === 'string' && name && sameTest(name, test))) return entry;
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
  const unknown = [];
  for (const run of history.runs) {
    for (const f of run.failed) {
      const where = { run: run.id, workflow: run.name, attempt: f.attempt, job: f.job };
      if (f.tests.length === 0) {
        const why = f.log === 'unavailable' ? 'log unavailable'
          : f.conclusion === 'timed_out' ? 'timed out'
            : f.crash ? 'crash or signal without failing-test lines' : null;
        if (why) unknown.push({ ...where, why });
        else noTestNames.push({ ...where, steps: f.steps, log: f.log });
      }
      for (const test of f.tests) {
        const issue = bodyTicket(body, test);
        const entry = issue == null ? listTicket(lists, test) : null;
        if (issue != null) ticketed.push({ ...where, test, issue, source: 'PR body' });
        else if (entry) ticketed.push({ ...where, test, issue: entry.issue, source: entry.source });
        else needsTicket.push({ ...where, test });
      }
    }
  }
  return { ticketed, needsTicket, noTestNames, unknown };
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
  for (const t of c.unknown ?? []) out.push(`needs-ticket-unknown: run ${t.run} attempt ${t.attempt}, job ${t.job} (${t.why})`);
  for (const t of c.ticketed) out.push(`ticketed: ${t.test} -> #${t.issue} (${t.source})`);
  for (const t of c.noTestNames) {
    const why = t.log === 'unavailable' ? ', log unavailable' : t.steps.length ? `, step ${t.steps.join('; ')}` : '';
    out.push(`no-test-names: run ${t.run} attempt ${t.attempt}, job ${t.job}${why}`);
  }
  for (const e of history.excluded ?? []) out.push(`excluded: run ${e.id} (${e.reason})`);
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
      if (/✖|✘|not ok \d|Test Case '.*' failed|##\[error\]/.test(line) || CRASH.test(line)) for (let j = Math.max(0, i - 1); j <= Math.min(lines.length - 1, i + 1); j++) keep.add(j);
    });
    return `${[...keep].sort((a, b) => a - b).map(i => lines[i]).join('\n')}\n`;
  }
  if (Array.isArray(value?.workflow_runs)) {
    return { total_count: value.total_count, workflow_runs: value.workflow_runs.map(r => ({ id: r.id, name: r.name, head_sha: r.head_sha, head_branch: r.head_branch, event: r.event, run_attempt: r.run_attempt, status: r.status, conclusion: r.conclusion,
      created_at: r.created_at, head_repository: r.head_repository ? { full_name: r.head_repository.full_name } : r.head_repository, pull_requests: Array.isArray(r.pull_requests) ? r.pull_requests.map(p => ({ number: p.number })) : r.pull_requests })) };
  }
  if (Array.isArray(value?.jobs)) {
    return { total_count: value.total_count, jobs: value.jobs.map(j => ({ id: j.id, name: j.name, run_attempt: j.run_attempt, head_sha: j.head_sha, status: j.status, conclusion: j.conclusion, steps: (j.steps ?? []).map(s => ({ name: s.name, number: s.number, conclusion: s.conclusion })) })) };
  }
  if (/\/pulls\/\d+$/.test(path)) return { number: value.number, created_at: value.created_at, head: { ref: value.head?.ref, sha: value.head?.sha, repo: value.head?.repo ? { full_name: value.head.repo.full_name } : value.head?.repo }, body: value.body };
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
  // The runs API filters head_sha exactly, so an abbreviated SHA would find no runs and look clean.
  if (opts.sha != null && !/^[0-9a-f]{40}$/i.test(opts.sha)) throw new Error(`--sha must be a full 40-character commit SHA, not ${opts.sha}`);
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
  // Fail closed when opted in: every ticket source must load, before anything is fetched.
  let lists;
  try {
    lists = await loadTicketLists(opts.listsRoot, { strict: opts.requireTickets });
  } catch (error) {
    if (error instanceof SourceError) throw new Error(`refused: ${error.message} (--require-tickets needs all of ${TICKET_SOURCES.join(', ')})`);
    throw error;
  }
  const history = await collectHistory({ get, repo: opts.repo, pr: opts.pr, sha: opts.sha });
  const subject = opts.pr != null ? `PR #${opts.pr}` : `head ${opts.sha}`;
  if (history.runs.length === 0 && opts.requireTickets) throw new Error(`refused: no workflow runs found for ${subject}; nothing proves its attempts were clean`);
  const body = opts.bodyFile ? readFileSync(opts.bodyFile, 'utf8') : history.pr?.body ?? '';
  const c = classify(history, { body, lists });
  let text = render(history, c);
  for (const m of lists.missing) text += `ticket-source-missing: ${m.source} ${m.why}\n`;
  if (history.runs.length === 0) text += `no-runs: no workflow runs found for ${subject}\n`;
  if (!opts.requireTickets) {
    if (c.needsTicket.length) text += `advisory: ${c.needsTicket.length} failing tests without a ticket; pass --require-tickets to fail on them\n`;
    if (c.unknown.length) text += `advisory: ${c.unknown.length} failed jobs whose test names cannot be read; --require-tickets counts them\n`;
  }
  process.stdout.write(text);
  if (opts.record) {
    writeFileSync(opts.record, `${JSON.stringify({ $comment: `Recorded by scripts/ci/attempt-history.mjs ${argv.join(' ')}`, responses: recorded }, null, 2)}\n`);
  }
  return opts.requireTickets && (c.needsTicket.length || c.unknown.length) ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => {
    process.stderr.write(`attempt-history: ${error.message}\n`);
    process.exitCode = 2;
  });
}
