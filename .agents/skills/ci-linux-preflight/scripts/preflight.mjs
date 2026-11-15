#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const scriptDir = import.meta.dirname;
const repoRoot = resolve(scriptDir, '../../../..');
const workflowPath = '.github/workflows/pr-body.yml';

function extract(file) {
  const lines = readFileSync(file, 'utf8').split(/\r?\n/);
  const start = lines.findIndex(line => /^  agent-tests:\s*$/.test(line));
  if (start < 0) throw Error('Agent tooling job missing');
  const result = [];
  let step;
  let block = false;
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (/^  [\w-]+:\s*$/.test(line)) break;
    if (/^      - name:\s*/.test(line)) {
      if (step?.run && step.cwd === 'pr-head') result.push(step);
      step = { name: line.replace(/^      - name:\s*/, '').trim() };
      block = false;
    } else if (step && /^        working-directory:\s*/.test(line)) {
      step.cwd = line.replace(/^        working-directory:\s*/, '').trim();
    } else if (step && /^        run:\s*/.test(line)) {
      const value = line.replace(/^        run:\s*/, '');
      block = value === '|';
      step.run = block ? '' : value;
    } else if (block && /^          /.test(line)) {
      step.run += `${line.slice(10)}\n`;
    } else if (block && line.trim() && !/^          /.test(line)) {
      block = false;
    }
  }
  if (step?.run && step.cwd === 'pr-head') result.push(step);
  if (!result.length || result.some(s => !s.name || !s.run)) throw Error('no complete Agent tooling run steps');
  return result;
}

function exec(cmd, args, options = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options });
}
function requireOK(result, label) {
  if (result.error || result.status !== 0) throw Error(`${label}: ${result.error?.message ?? result.stderr ?? result.status}`);
  return result.stdout;
}
function countTAP(output) {
  const totals = { tests: 0, pass: 0, fail: 0, skip: 0 };
  for (const key of Object.keys(totals)) {
    for (const match of output.matchAll(new RegExp(`^# ${key} (\\d+)$`, 'gm'))) totals[key] += Number(match[1]);
  }
  const failed = [...output.matchAll(/^not ok \d+ - (.+)$/gm)].map(match => match[1].trim());
  return { totals, failed };
}
function remote(dir, sha7) {
  const steps = extract(join(dir, workflowPath));
  const start = Date.now();
  let peak = null;
  let output = '';
  const lines = [`head=${sha7}`];
  const nodeBin = join(homedir(), 'opt/node/bin');
  const env = { ...process.env, PATH: existsSync(nodeBin) ? `${nodeBin}:${process.env.PATH}` : process.env.PATH };
  delete env.NODE_TEST_CONTEXT;
  const check = join(dir, '.agents/skills/ci-linux-preflight/scripts/env-check.sh');
  try {
    readFileSync(check);
    const checkResult = exec('/bin/zsh', [check], { cwd: dir, env });
    if (checkResult.status !== 0) {
      lines.push(`step:Environment check=${checkResult.status ?? 70}`);
      process.stderr.write(checkResult.stdout + checkResult.stderr);
      return finish(1);
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  for (const step of steps) {
    const cwd = step.cwd === 'pr-head' ? dir : step.cwd ? join(dir, step.cwd) : dir;
    const command = '/bin/bash';
    const args = ['-eo', 'pipefail', '-c', step.run];
    const timed = process.platform === 'linux' && exec('/usr/bin/time', ['--version']).status === 0;
    const result = timed ? exec('/usr/bin/time', ['-v', command, ...args], { cwd, env }) : exec(command, args, { cwd, env });
    lines.push(`step:${step.name}=${result.status ?? 70}`);
    output += `${result.stdout ?? ''}\n${result.stderr ?? ''}\n`;
    const rss = result.stderr?.match(/Maximum resident set size \(kbytes\):\s*(\d+)/);
    if (rss) peak = Math.max(peak ?? 0, Number(rss[1]));
    if (result.status !== 0) {
      process.stderr.write(`FAILED ${step.name}\n${(result.stdout ?? '') + (result.stderr ?? '')}\n`);
      return finish(1);
    }
  }
  return finish(0);

  function finish(status) {
    const { totals, failed } = countTAP(output);
    if (totals.tests === 0 || totals.fail > 0) status = 1;
    lines.push(`secs=${((Date.now() - start) / 1000).toFixed(1)}`);
    lines.push(`peak_rss_kb=${peak ?? 'unknown'}`);
    for (const key of Object.keys(totals)) lines.push(`${key}=${totals[key]}`);
    for (const name of failed) lines.push(`failed:${name}`);
    lines.push('DONE');
    process.stdout.write(`${lines.join('\n')}\n`);
    return status;
  }
}

function summaryCheck(file) {
  const raw = readFileSync(file, 'utf8');
  const lines = raw.trimEnd().split('\n');
  if (lines.at(-1) !== 'DONE') throw Error('summary missing DONE');
  const entries = new Map();
  const steps = [];
  for (const line of lines.slice(0, -1)) {
    if (line.startsWith('step:')) {
      const split = line.lastIndexOf('=');
      if (split < 6) throw Error('invalid step');
      steps.push({ name: line.slice(5, split), exit: Number(line.slice(split + 1)) });
    } else if (!line.startsWith('failed:')) {
      const split = line.indexOf('=');
      if (split < 1) throw Error('invalid summary field');
      entries.set(line.slice(0, split), line.slice(split + 1));
    }
  }
  const head = entries.get('head');
  if (!/^[a-f0-9]{7,40}$/.test(head ?? '') || !steps.length || steps.some(s => !Number.isInteger(s.exit))) throw Error('invalid head or steps');
  for (const key of ['tests', 'pass', 'fail', 'skip']) if (!/^\d+$/.test(entries.get(key) ?? '')) throw Error(`invalid ${key}`);
  if (!/^\d+(?:\.\d+)?$/.test(entries.get('secs') ?? '') || !/^(?:\d+|unknown)$/.test(entries.get('peak_rss_kb') ?? '')) throw Error('invalid measurements');
  const tests = Number(entries.get('tests'));
  const pass = Number(entries.get('pass'));
  const fail = Number(entries.get('fail'));
  const skip = Number(entries.get('skip'));
  if (pass + fail + skip > tests) throw Error('invalid TAP totals');
  const status = steps.every(s => s.exit === 0) && fail === 0 && tests > 0 ? 'PASS' : 'FAIL';
  return `Linux-Preflight: ${head.slice(0, 7)} agent-tooling ${status} ${pass}/${tests} (${skip} skip)`;
}

function local(sha) {
  const head = requireOK(exec('git', ['rev-parse', '--verify', `${sha}^{commit}`], { cwd: repoRoot }), 'resolve commit').trim();
  const current = requireOK(exec('git', ['rev-parse', 'HEAD'], { cwd: repoRoot }), 'current head').trim();
  if (head !== current) throw Error('preflight commit must be the current HEAD');
  const sha7 = head.slice(0, 7);
  const host = process.env.PICSEE_LINUX_HOST || 'tencent-ci';
  if (!/^[a-zA-Z0-9_.@-]+$/.test(host) || host.startsWith('-')) throw Error('invalid PICSEE_LINUX_HOST');
  const temp = mkdtempSync(join(tmpdir(), 'ci-linux-preflight-'));
  const bundle = join(temp, 'head.bundle');
  const remoteDir = `~/ci/${sha7}`;
  const destination = join(homedir(), '.picsee/ci-linux', `${head}-summary.txt`);
  mkdirSync(join(homedir(), '.picsee/ci-linux'), { recursive: true });
  try {
    requireOK(exec('git', ['bundle', 'create', bundle, 'HEAD'], { cwd: repoRoot }), 'git bundle');
    requireOK(exec('ssh', ['-o', 'BatchMode=yes', host, `mkdir -p ${remoteDir}`]), 'remote mkdir');
    requireOK(exec('rsync', [bundle, `${host}:${remoteDir}/head.bundle`]), 'bundle transfer');
    requireOK(exec('ssh', ['-o', 'BatchMode=yes', host, `git clone -q ${remoteDir}/head.bundle ${remoteDir}/pr-head`]), 'remote clone');
    const remoteCommand = `cd ${remoteDir}/pr-head && if [ -d \"\$HOME/opt/node/bin\" ]; then export PATH=\"\$HOME/opt/node/bin:\$PATH\"; fi; node .agents/skills/ci-linux-preflight/scripts/preflight.mjs remote . ${sha7}`;
    const result = exec('ssh', ['-o', 'BatchMode=yes', host, remoteCommand]);
    if (!result.stdout?.endsWith('DONE\n')) throw Error(`remote summary incomplete: ${result.stderr ?? result.status}`);
    writeFileSync(destination, result.stdout, { mode: 0o600 });
    const line = summaryCheck(destination);
    process.stdout.write(`${line}\nSummary: ${destination}\n`);
    if (result.stderr) process.stderr.write(result.stderr);
    return result.status === 0 && line.includes(' agent-tooling PASS ') ? 0 : 1;
  } finally {
    exec('ssh', ['-o', 'BatchMode=yes', host, `rm -rf ${remoteDir}`]);
    rmSync(temp, { recursive: true, force: true });
  }
}

try {
  const [mode, ...args] = process.argv.slice(2);
  let status;
  if (mode === 'extract' && args.length === 1) { process.stdout.write(`${JSON.stringify(extract(args[0]))}\n`); status = 0; }
  else if (mode === 'remote' && args.length === 2 && /^[a-f0-9]{7,40}$/.test(args[1])) status = remote(resolve(args[0]), args[1]);
  else if (mode === 'summary-check' && args.length === 1) { process.stdout.write(`${summaryCheck(args[0])}\n`); status = 0; }
  else if (mode === 'run' && args.length === 1 && /^[a-f0-9]{7,40}$/.test(args[0])) status = local(args[0]);
  else throw Error('usage: preflight.mjs extract <workflow> | remote <repo> <sha> | summary-check <file> | run <sha>');
  process.exitCode = status;
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 70;
}
