#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, renameSync, symlinkSync, existsSync } from 'node:fs';
import { tmpdir, homedir, release } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { workflowAt, WorkflowError } from './workflow.mjs';
import { blankSummary, serializeSummary, checkSummary } from './summary.mjs';

const root = resolve(import.meta.dirname, '../../../..');
const sshOptions = ['-a', '-x', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4'];
const stepPath = '/opt/node/bin:/usr/local/bin:/usr/bin:/bin';
const runScript = join(import.meta.dirname, 'remote-run.sh');

function exec(cmd, args, options = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options });
}
function must(result, label, code = 75) {
  if (result.error || result.status !== 0) {
    const error = new Error(`${label}: ${result.error?.message ?? result.stderr?.trim() ?? result.status}`);
    error.exitCode = code;
    throw error;
  }
  return result.stdout;
}
function quote(value) { return `'${String(value).replaceAll("'", "'\\''")}'`; }
function ssh(host, command, input = '') { return exec('ssh', [...sshOptions, host, command], { input }); }
function positive(value, label) {
  if (!/^\d+$/.test(String(value)) || Number(value) < 1 || Number(value) > 86400) throw Object.assign(new Error(`invalid ${label}`), { exitCode: 2 });
  return Number(value);
}
function parseFlags(args) {
  const opts = { job: 'agent-tests', stepTimeout: 600, deadline: 1200, allowDirty: false };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--allow-dirty') opts.allowDirty = true;
    else if (['--job', '--step-timeout', '--deadline', '--repo', '--expect-head', '--time-bin'].includes(arg)) {
      if (!args[i + 1]) throw Object.assign(new Error(`missing ${arg}`), { exitCode: 2 });
      const value = args[++i];
      if (arg === '--job') opts.job = value;
      else if (arg === '--step-timeout') opts.stepTimeout = positive(value, arg);
      else if (arg === '--deadline') opts.deadline = positive(value, arg);
      else if (arg === '--repo') opts.repo = value;
      else if (arg === '--expect-head') opts.expectHead = value;
      else opts.timeBin = value;
    } else throw Object.assign(new Error(`unknown option ${arg}`), { exitCode: 2 });
  }
  return opts;
}

function resolveHead(repo, value) {
  const head = must(exec('git', ['rev-parse', '--verify', `${value}^{commit}`], { cwd: repo }), 'resolve commit', 2).trim();
  if (!/^[a-f0-9]{40}$/.test(head)) throw Object.assign(new Error('expected 40-hex commit'), { exitCode: 2 });
  return head;
}

function writeAttempt(head, summary, rawLog) {
  const dir = join(homedir(), '.picsee/ci-linux', head);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stamp = new Date().toISOString().replaceAll(':', '').replaceAll('-', '').replaceAll('.', '') + '-' + randomBytes(3).toString('hex');
  const name = `${stamp}-summary.txt`;
  const target = join(dir, name);
  const temp = join(dir, `.${name}.tmp`);
  writeFileSync(temp, summary, { mode: 0o600, flag: 'wx' });
  renameSync(temp, target);
  const logName = `${stamp}-raw.log`;
  writeFileSync(join(dir, logName), rawLog, { mode: 0o600, flag: 'wx' });
  const linkTemp = join(dir, `.latest-${stamp}`);
  symlinkSync(name, linkTemp);
  renameSync(linkTemp, join(dir, 'latest'));
  return target;
}

function local(value, opts) {
  const repo = resolve(opts.repo ?? root);
  const head = resolveHead(repo, value);
  if (!opts.allowDirty) {
    const unstaged = exec('git', ['diff', '--quiet'], { cwd: repo });
    const staged = exec('git', ['diff', '--cached', '--quiet'], { cwd: repo });
    if (unstaged.status !== 0 || staged.status !== 0) throw Object.assign(new Error('tracked worktree is dirty; use --allow-dirty'), { exitCode: 2 });
  }
  const workflow = workflowAt(repo, head, opts.job);
  const host = process.env.PICSEE_LINUX_HOST || 'mado-ci-linux';
  if (!/^[A-Za-z0-9._-]+$/.test(host) || host.startsWith('-')) throw Object.assign(new Error('invalid PICSEE_LINUX_HOST'), { exitCode: 2 });
  const temp = mkdtempSync(join(tmpdir(), 'ci-linux-preflight-'));
  const bundle = join(temp, 'head.bundle');
  const ref = `refs/preflight/${head}`;
  let remoteDir;
  let rawLog = '';
  try {
    must(exec('git', ['update-ref', ref, head], { cwd: repo }), 'temporary ref', 2);
    must(exec('git', ['bundle', 'create', bundle, ref], { cwd: repo }), 'git bundle', 2);
    must(exec('git', ['update-ref', '-d', ref], { cwd: repo }), 'remove temporary ref', 2);
    const init = `set -e\nmkdir -p "$HOME/ci"\nfind "$HOME/ci" -maxdepth 1 -type d -name 'run.*' -mmin +1440 -exec rm -rf -- {} +\nmktemp -d "$HOME/ci/run.XXXXXX"\n`;
    remoteDir = must(ssh(host, '/bin/bash -s', init), 'remote setup').trim();
    if (!/^\/[A-Za-z0-9._/-]+\/ci\/run\.[A-Za-z0-9]+$/.test(remoteDir)) throw Object.assign(new Error('invalid remote run directory'), { exitCode: 75 });
    const rsyncShell = `ssh ${sshOptions.map(quote).join(' ')}`;
    must(exec('rsync', ['-e', rsyncShell, bundle, `${host}:${remoteDir}/head.bundle`]), 'bundle transfer');
    const args = [remoteDir, head, opts.job, workflow.workflowSha256, opts.stepTimeout, opts.deadline];
    const command = `/bin/bash -s -- ${args.map(quote).join(' ')}`;
    const run = ssh(host, command, readFileSync(runScript, 'utf8'));
    rawLog = run.stderr ?? '';
    if (run.stdout?.endsWith('DONE\n')) {
      try {
        const line = checkSummary(run.stdout, head, workflow);
        const expectedStatus = line.includes(' agent-tooling PASS ') ? 0 : line.includes(' agent-tooling NOT VERIFIED ') ? 75 : 1;
        if (run.status !== expectedStatus) throw Error(`remote exit ${run.status} disagrees with summary`);
        const target = writeAttempt(head, run.stdout, rawLog);
        process.stdout.write(`${line}\nSummary: ${target}\n`);
        return expectedStatus;
      } catch (error) { rawLog += `\ninvalid remote summary: ${error.message}\n${run.stdout ?? ''}`; }
    }
    if (run.status === 124) throw Object.assign(new Error('whole run deadline reached'), { exitCode: 124 });
    throw Object.assign(new Error(run.status === 75 && /busy/.test(rawLog) ? 'busy' : `remote run: ${rawLog.trim() || run.error?.message || run.status}`), { exitCode: 75 });
  } catch (error) {
    const timedOut = error.exitCode === 124;
    const summary = blankSummary(head, workflow, timedOut ? 'TIMEOUT' : 'NOT VERIFIED', error.message);
    const body = serializeSummary(summary);
    const target = writeAttempt(head, body, rawLog || error.message);
    process.stdout.write(`${checkSummary(body, head, workflow)}\nSummary: ${target}\n`);
    return timedOut ? 1 : 75;
  } finally {
    if (remoteDir) ssh(host, `/bin/bash -s -- ${quote(remoteDir)}`, 'rm -rf -- "$1"\n');
    exec('git', ['update-ref', '-d', ref], { cwd: repo });
    rmSync(temp, { recursive: true, force: true });
  }
}

function facts() {
  const result = {};
  try { const osRelease = readFileSync('/etc/os-release', 'utf8'); result.distro = osRelease.match(/^PRETTY_NAME="?([^"\n]+)"?/m)?.[1] ?? 'unknown'; } catch { result.distro = 'unknown'; }
  result.kernel = release();
  const sh = exec('readlink', ['-f', '/bin/sh']); result.sh_target = sh.status === 0 ? sh.stdout.trim() : '/bin/sh';
  for (const [key, cmd, args] of [['node', 'node', ['--version']], ['git', 'git', ['--version']], ['python3', 'python3', ['--version']], ['zsh', 'zsh', ['--version']], ['procps', 'ps', ['--version']]]) {
    const output = exec(cmd, args); result[key] = (output.stdout || output.stderr || 'unknown').trim().split('\n')[0];
  }
  return result;
}
function parseOutput(output, step) {
  const spellings = { tests: 'tests', pass: 'pass', fail: 'fail', skip: 'skipped', todo: 'todo', cancelled: 'cancelled' };
  const footerLines = [];
  for (const [key, label] of Object.entries(spellings)) {
    const matches = [...output.matchAll(new RegExp(`^# ${label} (\\d+)$`, 'gm'))];
    footerLines.push(matches.length);
    for (const match of matches) step[key] += Number(match[1]);
  }
  step.tap_footer = footerLines[0] > 0 && footerLines.every(count => count === footerLines[0]) ? 'complete' : 'missing';
  const py = [...output.matchAll(/^Ran (\d+) tests? in /gm)];
  step.python_tests = py.reduce((sum, match) => sum + Number(match[1]), 0);
  step.python_result = /^(?:FAILED \(|FAILED$)/m.test(output) ? 'FAILED' : /^OK(?:\s|$)/m.test(output) ? 'OK' : 'unknown';
  return [
    ...[...output.matchAll(/^not ok \d+ - (.+)$/gm)].map(match => match[1].trim()),
    ...[...output.matchAll(/^(?:FAIL|ERROR): (.+)$/gm)].map(match => match[1].trim()),
  ];
}

function remote(repo, head, job, expectedHash, stepTimeout, deadline, timeBin) {
  const workflow = workflowAt(repo, head, job);
  const summary = blankSummary(head, workflow);
  summary.facts = facts();
  const started = Date.now();
  if (workflow.workflowSha256 !== expectedHash) {
    summary.reason = 'workflow hash mismatch';
    process.stdout.write(serializeSummary(summary));
    return 75;
  }
  summary.outcome = 'PASS';
  const runDir = dirname(repo);
  const selectedTime = timeBin ?? '/usr/bin/time';
  const timeAvailable = existsSync(selectedTime) && exec(selectedTime, ['--version']).status === 0;
  for (let i = 0; i < workflow.steps.length; i++) {
    const step = workflow.steps[i];
    if (step.kind !== 'run') continue;
    const remaining = Math.ceil(deadline - (Date.now() - started) / 1000);
    if (remaining <= 0) {
      summary.steps[i].kind = 'run'; summary.steps[i].exit = '124';
      summary.steps_run++;
      summary.outcome = 'TIMEOUT';
      break;
    }
    const script = join(runDir, `step-${i}.sh`);
    writeFileSync(script, step.run, { mode: 0o600 });
    const home = mkdtempSync(join(runDir, `home-${i}-`));
    const environment = ['-i', `HOME=${home}`, `PATH=${stepPath}`, 'CI=true', 'GITHUB_ACTIONS=true', 'LANG=C.UTF-8', 'GIT_CONFIG_NOSYSTEM=1', `TMPDIR=${runDir}`];
    const command = timeAvailable ? [selectedTime, '-v', '/bin/bash', '-e', script] : ['/bin/bash', '-e', script];
    const limit = Math.min(stepTimeout, remaining);
    const begin = Date.now();
    const result = exec('timeout', ['--kill-after=10', String(limit), '/usr/bin/env', ...environment, ...command], { cwd: repo });
    const record = summary.steps[i];
    record.kind = 'run';
    record.exit = String(result.status ?? 75);
    record.secs = ((Date.now() - begin) / 1000).toFixed(1);
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    const rss = output.match(/Maximum resident set size \(kbytes\):\s*(\d+)/);
    record.peak_rss_kb = rss ? rss[1] : 'unknown';
    summary.failed.push(...parseOutput(output, record));
    summary.steps_run++;
    process.stderr.write(`step ${step.name}:\n${output}\n`);
    if (result.error) { summary.outcome = 'NOT VERIFIED'; summary.reason = result.error.message; break; }
    if ([124, 137].includes(result.status)) { summary.outcome = 'TIMEOUT'; break; }
    if (result.status !== 0) { summary.outcome = 'FAIL'; break; }
    if (record.tests === 0 || record.tap_footer !== 'complete') {
      summary.outcome = 'NOT VERIFIED'; summary.reason = `missing Node TAP totals ${step.name}`; break;
    }
    if (record.tests > 0 && record.pass + record.fail + record.skip + record.todo + record.cancelled !== record.tests) {
      summary.outcome = 'NOT VERIFIED'; summary.reason = `TAP totals mismatch ${step.name}`; break;
    }
    if (record.cancelled > 0) { summary.outcome = 'FAIL'; break; }
  }
  summary.secs = ((Date.now() - started) / 1000).toFixed(1);
  const rssValues = summary.steps.map(step => Number(step.peak_rss_kb)).filter(Number.isFinite);
  summary.peak_rss_kb = rssValues.length ? String(Math.max(...rssValues)) : 'unknown';
  process.stdout.write(serializeSummary(summary));
  return summary.outcome === 'PASS' ? 0 : summary.outcome === 'NOT VERIFIED' ? 75 : 1;
}

try {
  const [mode, ...args] = process.argv.slice(2);
  let status;
  if (mode === 'run') {
    const [head, ...rest] = args;
    if (!head) throw Object.assign(new Error('usage: run <sha> [options]'), { exitCode: 2 });
    status = local(head, parseFlags(rest));
  } else if (mode === 'remote') {
    const [repo, head, job, hash, stepTimeout, deadline, ...rest] = args;
    status = remote(resolve(repo), head, job, hash, positive(stepTimeout, 'step timeout'), positive(deadline, 'deadline'), parseFlags(rest).timeBin);
  } else if (mode === 'summary-check') {
    const [file, ...rest] = args;
    const opts = parseFlags(rest);
    if (!file || !opts.expectHead) throw Object.assign(new Error('summary-check needs file and --expect-head'), { exitCode: 2 });
    const repo = resolve(opts.repo ?? root);
    process.stdout.write(`${checkSummary(readFileSync(file, 'utf8'), opts.expectHead, workflowAt(repo, opts.expectHead, opts.job))}\n`);
    status = 0;
  } else if (mode === 'extract') {
    const [head, ...rest] = args;
    const opts = parseFlags(rest);
    process.stdout.write(`${JSON.stringify(workflowAt(resolve(opts.repo ?? root), head, opts.job))}\n`);
    status = 0;
  } else throw Object.assign(new Error('usage: preflight.mjs run|remote|extract|summary-check'), { exitCode: 2 });
  process.exitCode = status;
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = error.exitCode ?? (error instanceof WorkflowError ? 2 : 75);
}
