#!/usr/bin/env node
// #912 (owner 2026-11-27): hosted App evidence before audit. For an App-facing diff the delegator dispatches `ci.yml`
// on the implementer's verified head and dispatches the audits only after this script says GREEN for that head.
// The result is diagnostic: PR merge evidence stays the regular PR CI (gates-rows.mjs, which never accepts a dispatch).
//
//   hosted-preaudit.mjs app-facing --worktree <wt> --base <sha> --head <sha>
//       prints `app-facing=yes|no` from owner-gates.sh's own `app_facing=` pattern (one source for both).
//   hosted-preaudit.mjs dispatch --worktree <wt> --ref <branch> --head <sha> [--filter <re>] [--repeat <n>] [--out <dir>]
//       refuses unless origin/<branch> is exactly <head>; runs `gh workflow run ci.yml` (app_tests=true), finds the new
//       run for that head, waits, exports run.json, downloads app-crash-evidence, then evaluates as below.
//   hosted-preaudit.mjs evaluate --run <run.json> --head <sha> [--log <app-tests.log>] [--result <app-result.json>]
//
// Every mode that judges a run prints exactly one line
//   Hosted-Preaudit: <GREEN|RED|NOT COUNTED (<reason>)> head=<40> run=<id> attempt=<n> event=<e> app-job=<c>
//     run-step=<c> counts=<run>/<fail>|unknown retried=<yes|no|unknown> url=<url>
// and exits 0 for GREEN, 1 for RED, 3 for NOT COUNTED, 2 for a usage or input error.
// A cancelled, stale, rerun (attempt > 1), still-running, skipped-native, build-only or filtered/repeated run is
// NOT COUNTED. GREEN also needs the counts from the run's own App log: a pass whose counts cannot be read is not counted.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const EXIT = Object.freeze({ green: 0, red: 1, usage: 2, notCounted: 3 });
const here = path.dirname(fileURLToPath(import.meta.url));
const FULL_SHA = /^[0-9a-f]{40}$/;
const REPEAT_STEPS = ['Record repeat job start', 'Upload App repeat logs'];

/** The last combined `Tests run:` line of an App lane log, or null. */
export function parseCounts(log) {
  if (typeof log !== 'string') return null;
  const all = [...log.replace(/\r/g, '').matchAll(/^Tests run: (\d+), Failures: (\d+), Errors: \d+, Skipped: (\d+)$/gm)];
  const last = all.at(-1);
  return last ? { run: Number(last[1]), failed: Number(last[2]), skipped: Number(last[3]) } : null;
}

const clean = value => String(value ?? 'unknown').replace(/[\s|]+/g, '_') || 'unknown';

/**
 * Judge one `gh run view <id> --json headSha,url,status,conclusion,jobs,event,attempt,databaseId` export for <head>.
 * `log` is the run's app-tests.log text (artifact app-crash-evidence), `result` its parsed app-result.json.
 */
export function evaluateRun(run, head, { log = null, result = null } = {}) {
  if (!FULL_SHA.test(String(head ?? ''))) throw new Error('--head must be a full 40-hex SHA');
  if (!run || typeof run !== 'object' || !Array.isArray(run.jobs)) throw new Error('run export needs jobs');
  const jobs = run.jobs.filter(job => job?.name === 'App tests');
  const job = jobs.length === 1 ? jobs[0] : null;
  const steps = Array.isArray(job?.steps) ? job.steps : [];
  const step = steps.filter(s => s?.name === 'Run App tests');
  const runStep = step.length === 1 ? (step[0].status === 'completed' ? step[0].conclusion : step[0].status) : 'absent';
  const counts = parseCounts(log);
  const retried = result && result.complete === true && [1, 2].includes(result.attempts)
    ? (result.attempts === 2 ? 'yes' : 'no') : 'unknown';
  const fields = {
    head, run: clean(run.databaseId), attempt: clean(run.attempt), event: clean(run.event),
    'app-job': job ? clean(job.status === 'completed' ? job.conclusion : job.status) : jobs.length ? 'ambiguous' : 'absent',
    'run-step': clean(runStep), counts: counts ? `${counts.run}/${counts.failed}` : 'unknown', retried, url: clean(run.url),
  };
  const verdict = (() => {
    if (String(run.headSha ?? '').toLowerCase() !== head.toLowerCase())
      return `NOT COUNTED (stale: run head ${clean(run.headSha).slice(0, 12)})`;
    if (!['workflow_dispatch', 'pull_request'].includes(run.event)) return `NOT COUNTED (event ${clean(run.event)})`;
    if (run.attempt !== 1) return `NOT COUNTED (attempt ${clean(run.attempt)}: dispatch a fresh run)`;
    if (run.status !== 'completed') return `NOT COUNTED (run ${clean(run.status)})`;
    if (jobs.length !== 1) return `NOT COUNTED (App tests job ${jobs.length ? 'ambiguous' : 'absent'})`;
    if (job.status !== 'completed') return `NOT COUNTED (App job ${clean(job.status)})`;
    if (job.conclusion === 'cancelled' || run.conclusion === 'cancelled') return 'NOT COUNTED (cancelled)';
    if (job.conclusion === 'skipped') return 'NOT COUNTED (App job skipped: no native input)';
    if (steps.some(s => REPEAT_STEPS.includes(s?.name) && !(s.status === 'completed' && s.conclusion === 'skipped')))
      return `NOT COUNTED (filtered or repeated dispatch, run-step=${clean(runStep)}: the full bundle is required)`;
    if (runStep === 'skipped' || runStep === 'absent') return `NOT COUNTED (App tests not run: run-step=${clean(runStep)})`;
    if (runStep === 'failure' || job.conclusion === 'failure') return 'RED';
    if (runStep !== 'success' || job.conclusion !== 'success') return `NOT COUNTED (run-step=${clean(runStep)} app-job=${clean(job.conclusion)})`;
    if (!counts) return 'NOT COUNTED (counts unavailable: app-tests.log missing from app-crash-evidence)';
    if (counts.failed !== 0 || counts.run === 0) return `NOT COUNTED (log counts ${counts.run}/${counts.failed} contradict a passing step)`;
    if (result && (result.complete !== true || result.status !== 0)) return 'NOT COUNTED (app-result.json is not a complete pass)';
    return 'GREEN';
  })();
  const line = `Hosted-Preaudit: ${verdict} ${Object.entries(fields).map(([k, v]) => `${k}=${v}`).join(' ')}`;
  const exit = verdict === 'GREEN' ? EXIT.green : verdict === 'RED' ? EXIT.red : EXIT.notCounted;
  return { verdict, line, exit, fields };
}

/** owner-gates.sh's `app_facing='…'` pattern, so the dispatch rule and the local App lane select the same diffs. */
export function appFacingPattern(script = fs.readFileSync(path.join(here, 'owner-gates.sh'), 'utf8')) {
  const found = /^app_facing='([^']+)'$/m.exec(script);
  if (!found) throw new Error('owner-gates.sh has no app_facing pattern');
  return new RegExp(found[1]);
}
export const isAppFacing = (files, pattern = appFacingPattern()) => files.some(file => pattern.test(file));

function git(worktree, args) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  const r = spawnSync('git', ['-C', worktree, ...args], { encoding: 'utf8', env });
  if (r.status !== 0) throw new Error(`git ${args[0]} failed: ${(r.stderr || '').trim().split('\n')[0]}`);
  return r.stdout;
}

/**
 * Dispatch and wait. `gh` is injectable for tests: (args) => { status, stdout, stderr }.
 * Returns { line, exit } like evaluateRun, after writing run.json and the artifact into `out`.
 */
export function dispatchAndEvaluate({ worktree, ref, head, filter = '', repeat = 1, out,
  gh = args => spawnSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }),
  sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms), now = () => Date.now(),
  findTimeoutMs = 180_000, log = text => process.stderr.write(text) }) {
  if (!FULL_SHA.test(String(head ?? ''))) throw new Error('--head must be a full 40-hex SHA');
  if (!/^[A-Za-z0-9._/-]+$/.test(String(ref ?? '')) || ref.startsWith('-')) throw new Error('--ref must be a branch name');
  if (!Number.isSafeInteger(repeat) || repeat < 1 || repeat > 50) throw new Error('--repeat must be 1–50');
  const remote = git(worktree, ['ls-remote', 'origin', `refs/heads/${ref}`]).trim().split(/\s+/)[0] ?? '';
  if (remote.toLowerCase() !== head.toLowerCase())
    throw Object.assign(new Error(`origin/${ref} is ${remote || 'absent'}, not ${head}: push the verified head first (push-guard)`), { notCounted: true });
  const started = now();
  const run = gh(['workflow', 'run', 'ci.yml', '--ref', ref, '-f', 'app_tests=true', '-f', `app_filter=${filter}`, '-f', `app_repeat=${repeat}`]);
  if (run.status !== 0) throw new Error(`gh workflow run failed: ${(run.stderr || '').trim()}`);
  let id;
  while (!id) {
    const list = gh(['run', 'list', '--workflow', 'ci.yml', '--event', 'workflow_dispatch', '--branch', ref, '--limit', '20',
      '--json', 'databaseId,headSha,createdAt']);
    if (list.status === 0) {
      const runs = JSON.parse(list.stdout || '[]').filter(r => String(r.headSha).toLowerCase() === head.toLowerCase() &&
        Date.parse(r.createdAt) >= started - 60_000).sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
      id = runs[0]?.databaseId;
    }
    if (!id) {
      if (now() - started > findTimeoutMs) throw new Error('dispatched run did not appear');
      sleep(5000);
    }
  }
  log(`hosted-preaudit: run ${id} for ${head.slice(0, 12)}; waiting\n`);
  gh(['run', 'watch', String(id), '--interval', '30']);
  const view = gh(['run', 'view', String(id), '--json', 'headSha,url,status,conclusion,jobs,event,attempt,databaseId']);
  if (view.status !== 0) throw new Error(`gh run view failed: ${(view.stderr || '').trim()}`);
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'run.json'), view.stdout);
  const artifact = path.join(out, 'app-crash-evidence');
  const download = gh(['run', 'download', String(id), '-n', 'app-crash-evidence', '-D', artifact]);
  if (download.status !== 0) log(`hosted-preaudit: app-crash-evidence not downloaded: ${(download.stderr || '').trim()}\n`);
  return evaluateFiles({ run: path.join(out, 'run.json'), head, log: path.join(artifact, 'app-tests.log'),
    result: path.join(artifact, 'app-result.json') });
}

function readOptional(file, parse = text => text) {
  try { return parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}
export function evaluateFiles({ run, head, log, result }) {
  const exported = JSON.parse(fs.readFileSync(run, 'utf8'));
  return evaluateRun(exported, head, { log: log ? readOptional(log) : null, result: result ? readOptional(result, JSON.parse) : null });
}

function parseArgs(argv, allowed) {
  const options = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.replace(/^--/, '');
    if (!argv[i]?.startsWith('--') || !allowed.includes(key) || argv[i + 1] === undefined || key in options)
      throw Object.assign(new Error(`unexpected argument ${argv[i]}`), { usage: true });
    options[key] = argv[i + 1];
  }
  return options;
}
const USAGE = 'usage: hosted-preaudit.mjs app-facing --worktree <wt> --base <sha> --head <sha>\n' +
  '       hosted-preaudit.mjs dispatch --worktree <wt> --ref <branch> --head <sha> [--filter <re>] [--repeat <n>] [--out <dir>]\n' +
  '       hosted-preaudit.mjs evaluate --run <run.json> --head <sha> [--log <app-tests.log>] [--result <app-result.json>]\n';

export function main(argv = process.argv.slice(2), { stdout = t => process.stdout.write(t), stderr = t => process.stderr.write(t), gh } = {}) {
  const [mode, ...rest] = argv;
  try {
    if (mode === 'app-facing') {
      const o = parseArgs(rest, ['worktree', 'base', 'head']);
      if (!o.worktree || !o.base || !o.head) throw Object.assign(new Error('missing argument'), { usage: true });
      const files = git(o.worktree, ['diff', '--name-only', '-z', `${o.base}...${o.head}`]).split('\0').filter(Boolean);
      stdout(`app-facing=${isAppFacing(files) ? 'yes' : 'no'}\n`);
      return 0;
    }
    if (mode === 'evaluate') {
      const o = parseArgs(rest, ['run', 'head', 'log', 'result']);
      if (!o.run || !o.head) throw Object.assign(new Error('missing argument'), { usage: true });
      const judged = evaluateFiles(o);
      stdout(`${judged.line}\n`);
      return judged.exit;
    }
    if (mode === 'dispatch') {
      const o = parseArgs(rest, ['worktree', 'ref', 'head', 'filter', 'repeat', 'out']);
      if (!o.worktree || !o.ref || !o.head) throw Object.assign(new Error('missing argument'), { usage: true });
      const out = o.out ?? path.join(o.worktree, '.build/hosted-preaudit', o.head.slice(0, 12));
      const judged = dispatchAndEvaluate({ worktree: o.worktree, ref: o.ref, head: o.head, filter: o.filter ?? '',
        repeat: o.repeat === undefined ? 1 : Number(o.repeat), out, ...(gh ? { gh } : {}) });
      stdout(`${judged.line}\n`);
      return judged.exit;
    }
    throw Object.assign(new Error(`unknown mode ${mode ?? '(none)'}`), { usage: true });
  } catch (error) {
    stderr(`hosted-preaudit: ${error.message}\n${error.usage ? USAGE : ''}`);
    return error.notCounted ? EXIT.notCounted : EXIT.usage;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main();
