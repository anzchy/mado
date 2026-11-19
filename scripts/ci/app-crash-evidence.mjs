#!/usr/bin/env node
// #732: crash evidence for the App tests job. When the App test process dies mid-run, state the signal or status,
// the last test that started but did not finish, and the uncaught exception text, from the App log and the crash
// reports written during the job. Evidence only: it never changes the lane's result and always exits 0.
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const SWIFT_START = /^◇ Test (?!case passing |run started\.)(.+) started\.$/;
const SWIFT_END = /^\S+ Test (?!run )(.+?)(?: with \d+ test cases?)? (?:passed|failed|skipped)(?: after|\.|$)/;
const XCTEST_START = /^Test Case '(.+)' started\.$/;
const XCTEST_END = /^Test Case '(.+)' (?:passed|failed|skipped)\b/;
const CRASH_MARKERS = [/^status-channel: invalid supervisor exit$/m, /\*\*\* Terminating app due to uncaught exception/,
  /libc\+\+abi: terminating/, /Fatal error: /];
const REPORT_NAME = /^(?:xctest|Mado\w*)[-_ ].*\.(?:ips|crash)$/;

const oneLine = text => String(text).replace(/\s+/g, ' ').trim().slice(0, 500);

/** Tests that started and have not ended, oldest first. */
function unfinishedTests(log) {
  const open = new Map();
  for (const raw of log.split('\n')) {
    const text = raw.replace(/\r$/, '');
    const start = SWIFT_START.exec(text) ?? XCTEST_START.exec(text);
    if (start) { open.delete(start[1]); open.set(start[1], true); continue; }
    const end = SWIFT_END.exec(text) ?? XCTEST_END.exec(text);
    if (end) open.delete(end[1]);
  }
  return [...open.keys()];
}

/** The first uncaught-exception or fatal-error text in some lines of output. */
function exceptionIn(text) {
  const thrown = /\*\*\* Terminating app due to uncaught exception '([^']+)', reason: '(.*)'\s*$/m.exec(text);
  if (thrown) return `${thrown[1]}: ${thrown[2]}`;
  const fatal = /(Fatal error: .*)$/m.exec(text);
  if (fatal) return fatal[1];
  const abi = /libc\+\+abi: terminating due to (uncaught exception of type .+)$/m.exec(text);
  return abi ? abi[1] : null;
}

/** Signal, process and application-specific text of one .ips (JSON) or legacy .crash (text) report. */
export function parseReport({ name, text }) {
  const newline = text.indexOf('\n');
  try {
    const header = JSON.parse(text.slice(0, newline));
    const body = JSON.parse(text.slice(newline + 1));
    const asi = Object.values(body.asi ?? {}).flat().filter(entry => typeof entry === 'string').join('\n');
    return { name, process: body.procName ?? header.app_name ?? 'unknown', signal: body.exception?.signal ?? null,
      indicator: body.termination?.indicator ?? null, exception: exceptionIn(asi) };
  } catch {
    const info = /^Application Specific Information:\n([\s\S]*?)(?:\n\s*\n|$)/m.exec(text)?.[1] ?? '';
    return { name, process: /^Process:\s+(\S+)/m.exec(text)?.[1] ?? 'unknown',
      signal: /^Exception Type:.*\((SIG[A-Z]+)\)/m.exec(text)?.[1] ?? null, indicator: null, exception: exceptionIn(info) };
  }
}

/**
 * log: App lane output (null when missing); status: the lane's exit status (null when unknown); signal: the signal
 * that ended the process, if known; outcome: the GitHub step outcome; reports: [{name, text}] crash reports.
 */
export function crashSummary({ log = null, status = null, signal = null, outcome = null, reports = [] }) {
  const known = Number.isInteger(status);
  const parsed = reports.map(parseReport);
  const crashed = Boolean(signal) || (known ? ![0, 1].includes(status)
    : CRASH_MARKERS.some(marker => marker.test(log ?? '')) || outcome === 'failure' || parsed.length > 0);
  if (!crashed) return { crashed, lines: [`crash.detected=no status=${known ? status : 'unknown'}`] };

  const open = log === null ? null : unfinishedTests(log);
  const fromReport = parsed.find(report => report.signal);
  const signalText = signal ? String(signal)
    : fromReport ? `${fromReport.signal}${fromReport.indicator ? ` (${fromReport.indicator})` : ''}` : 'unknown';
  const exception = (log === null ? null : exceptionIn(log)) ?? parsed.find(report => report.exception)?.exception
    ?? (log === null && !parsed.length ? 'unknown' : 'none');
  const lines = [
    `crash.status=${known ? status : 'unknown'}`,
    `crash.signal=${oneLine(signalText)}`,
    `crash.last_test=${open === null ? 'unknown' : open.length ? oneLine(open.at(-1)) : 'none'}`,
    `crash.unfinished=${open === null ? 'unknown' : open.length}`,
    `crash.exception=${oneLine(exception)}`,
    `crash.reports=${parsed.length}`,
    ...parsed.map(report => `crash.report=${report.name} process=${report.process} signal=${report.signal ?? 'unknown'}`),
  ];
  return { crashed, lines };
}

function parseArgs(argv) {
  const args = { reportsDirs: [] };
  for (let i = 0; i < argv.length; i += 2) {
    const [key, value] = [argv[i], argv[i + 1]];
    if (value === undefined) throw new Error(`missing value for ${key}`);
    if (key === '--reports-dir') args.reportsDirs.push(value);
    else if (['--log', '--result', '--since-ms', '--out', '--outcome'].includes(key)) args[key.slice(2)] = value;
    else throw new Error(`unknown argument ${key}`);
  }
  return args;
}

/** Crash reports for xctest and Mado written since the job started. */
function reportsSince(dirs, sinceMs) {
  const found = [];
  for (const dir of dirs) {
    let names;
    try { names = readdirSync(dir); } catch { continue; }
    for (const name of names.filter(entry => REPORT_NAME.test(entry)).sort()) {
      const path = join(dir, name);
      try {
        const info = statSync(path);
        if (info.isFile() && info.mtimeMs >= sinceMs) found.push({ name, path, text: readFileSync(path, 'utf8') });
      } catch { /* unreadable report: skip */ }
    }
  }
  return found;
}

function main(argv) {
  const args = parseArgs(argv);
  const readIf = path => (path && existsSync(path) ? readFileSync(path, 'utf8') : null);
  let status = null;
  try { status = JSON.parse(readIf(args.result) ?? 'null')?.status ?? null; } catch { status = null; }
  const since = Number(args['since-ms']);
  const reports = reportsSince(args.reportsDirs, Number.isFinite(since) ? since : 0);
  const { lines } = crashSummary({ log: readIf(args.log), status, outcome: args.outcome ?? null, reports });
  if (args.out) {
    mkdirSync(args.out, { recursive: true });
    for (const report of reports) copyFileSync(report.path, join(args.out, report.name));
    writeFileSync(join(args.out, 'crash-summary.txt'), `${lines.join('\n')}\n`);
  }
  process.stdout.write(`${lines.join('\n')}\n`);
  if (process.env.GITHUB_STEP_SUMMARY)
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `### App crash evidence\n\n\`\`\`text\n${lines.join('\n')}\n\`\`\`\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { main(process.argv.slice(2)); } catch (error) {
    process.stdout.write(`crash.evidence_error=${oneLine(error.message)}\n`);
  }
}
