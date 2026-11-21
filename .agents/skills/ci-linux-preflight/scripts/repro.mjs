import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, renameSync, symlinkSync, rmSync, existsSync } from 'node:fs';
import { tmpdir, homedir, release } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';

const sshOptions = ['-a', '-x', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4'];
const commandPath = '/opt/node/bin:/usr/local/bin:/usr/bin:/bin';
const hex = /^[a-f0-9]{40}$/;
const safeToken = /^[A-Za-z0-9_./=:+,-]+$/;
const fail = (message, code = 2) => Object.assign(new Error(message), { exitCode: code });
const run = (cmd, args, options = {}) => spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, ...options });
const quote = value => `'${String(value).replaceAll("'", "'\\''")}'`;
const ssh = (host, command, input = '') => run('ssh', [...sshOptions, host, command], { input });
const positive = (value, label) => {
  if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 86400) throw fail(`invalid ${label}`);
  return Number(value);
};

function parse(args) {
  const heads = [];
  const opts = { stepTimeout: 600, deadline: 1200 };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (['--cmd', '--expect', '--step-timeout', '--deadline', '--repo'].includes(arg)) {
      if (!args[i + 1]) throw fail(`missing ${arg}`);
      const value = args[++i];
      if (arg === '--cmd') opts.command = value;
      else if (arg === '--expect') opts.expect = value.split(',');
      else if (arg === '--repo') opts.repo = value;
      else if (arg === '--step-timeout') opts.stepTimeout = positive(value, arg);
      else opts.deadline = positive(value, arg);
    } else if (arg.startsWith('-')) throw fail(`unknown option ${arg}`);
    else heads.push(arg);
  }
  if (!heads.length || !opts.command) throw fail('usage: repro <sha>... --cmd "..." [--expect fail,pass]');
  if (opts.expect && (opts.expect.length !== heads.length || opts.expect.some(v => !['fail', 'pass'].includes(v)))) throw fail('--expect must have one fail or pass per commit');
  opts.heads = heads;
  opts.argv = parseCommand(opts.command);
  return opts;
}

export function parseCommand(command) {
  if (/[;&|<>`$\\'"\r\n]/.test(command)) throw fail('unsafe command');
  const argv = command.trim().split(/\s+/);
  if (argv.some(v => !safeToken.test(v))) throw fail('unsafe command token');
  const [program, first, ...rest] = argv;
  if (program === 'node' && first === '--test' && rest.length && rest.every(isPath)) return argv;
  if (program === 'node' && isPath(first) && rest.every(v => safeToken.test(v) && !v.startsWith('/'))) return argv;
  if (program === 'python3' && first === '-m' && rest[0] === 'unittest' && rest.length > 1 && rest.slice(1).every(isPath)) return argv;
  throw fail('command is outside repro allow-list');
}
function isPath(value) { return !!value && !value.startsWith('-') && !value.startsWith('/') && !value.split('/').includes('..') && !value.includes('//') && /^[A-Za-z0-9_./-]+$/.test(value); }
function sourcePaths(argv) { return argv[0] === 'python3' ? argv.slice(3) : argv[1] === '--test' ? argv.slice(2) : [argv[1]]; }
function resolveHeads(repo, values, argv) {
  return values.map(value => {
    const result = run('git', ['rev-parse', '--verify', `${value}^{commit}`], { cwd: repo });
    const sha = result.stdout?.trim();
    if (result.status !== 0 || !hex.test(sha)) throw fail(`invalid commit ${value}`);
    for (const path of sourcePaths(argv)) {
      const found = run('git', ['ls-tree', sha, '--', path], { cwd: repo });
      if (found.status !== 0 || !/^100(?:644|755) blob /m.test(found.stdout ?? '')) throw fail(`command path missing or not a regular file at ${sha.slice(0, 7)}: ${path}`);
    }
    return sha;
  });
}

function summary(data) {
  const lines = ['mode=repro', `head=${data.heads[0]}`, `heads=${data.heads.join(',')}`, `command=${data.command}`, `expect=${data.expect?.join(',') ?? 'none'}`, `outcome=${data.outcome}`, `kernel=${data.kernel ?? 'unknown'}`, `node=${data.node ?? 'unknown'}`];
  if (data.reason) lines.push(`reason=${String(data.reason).replace(/[\r\n]/g, ' ').slice(0, 300)}`);
  for (const result of data.results ?? []) {
    const key = `result:${result.head}`;
    lines.push(`${key}:exit=${result.exit}`, `${key}:secs=${result.secs}`, `${key}:outcome=${result.outcome}`);
    for (const name of result.failed.slice(0, 5)) lines.push(`${key}:failed=${name.replace(/[\r\n]/g, ' ').slice(0, 250)}`);
  }
  return `${lines.join('\n')}\nDONE\n`;
}

export function checkReproSummary(raw, expectedHead) {
  if (!hex.test(expectedHead)) throw Error('expected full head SHA');
  const lines = raw.split('\n');
  if (lines.at(-1) === '') lines.pop();
  if (lines.at(-1) !== 'DONE' || lines.filter(v => v === 'DONE').length !== 1) throw Error('summary missing or duplicate DONE');
  const fields = new Map();
  for (const line of lines.slice(0, -1)) {
    const at = line.indexOf('=');
    if (at < 1) throw Error('invalid summary line');
    const key = line.slice(0, at);
    if (key.endsWith(':failed')) continue;
    if (fields.has(key)) throw Error(`duplicate ${key}`);
    fields.set(key, line.slice(at + 1));
  }
  const get = key => { if (!fields.has(key)) throw Error(`missing ${key}`); return fields.get(key); };
  if (get('mode') !== 'repro' || get('head') !== expectedHead) throw Error('repro head mismatch');
  const heads = get('heads').split(',');
  if (!heads.length || heads[0] !== expectedHead || heads.some(v => !hex.test(v)) || new Set(heads).size !== heads.length) throw Error('invalid heads');
  parseCommand(get('command'));
  const expect = get('expect') === 'none' ? null : get('expect').split(',');
  if (expect && (expect.length !== heads.length || expect.some(v => !['fail', 'pass'].includes(v)))) throw Error('invalid expect');
  const outcome = get('outcome');
  if (!['MATCH', 'MISMATCH', 'COMPLETE', 'NOT VERIFIED', 'TIMEOUT'].includes(outcome)) throw Error('invalid outcome');
  for (const key of ['kernel', 'node']) get(key);
  if (outcome === 'NOT VERIFIED' || outcome === 'TIMEOUT') get('reason');
  const observed = [];
  for (const head of heads) {
    const prefix = `result:${head}`;
    const exit = get(`${prefix}:exit`);
    const secs = get(`${prefix}:secs`);
    const status = get(`${prefix}:outcome`);
    if (!/^(?:\d+|not-run)$/.test(exit) || !/^\d+(?:\.\d+)?$/.test(secs) || !['PASS', 'FAIL', 'TIMEOUT', 'NOT VERIFIED', 'not-run'].includes(status)) throw Error('invalid result');
    if ((exit === '0') !== (status === 'PASS') && status !== 'not-run') throw Error('result exit mismatch');
    observed.push(status);
  }
  if (['MATCH', 'MISMATCH', 'COMPLETE'].includes(outcome)) {
    if (observed.some(v => !['PASS', 'FAIL'].includes(v))) throw Error('incomplete repro');
    const matches = expect?.every((v, i) => (v === 'pass') === (observed[i] === 'PASS'));
    if ((outcome === 'MATCH') !== (matches === true) || (outcome === 'COMPLETE') !== !expect) throw Error('expectation mismatch');
  }
  return heads.map((head, i) => `Linux-Repro (supplementary): ${head.slice(0, 7)} ${get('command')} ${observed[i]}`).join('\n');
}

function writeAttempt(head, body, raw) {
  const dir = join(homedir(), '.mado/ci-linux', head);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stamp = new Date().toISOString().replace(/[-:.]/g, '') + '-' + randomBytes(3).toString('hex');
  const name = `${stamp}-repro-summary.txt`;
  writeFileSync(join(dir, `.${name}.tmp`), body, { flag: 'wx', mode: 0o600 });
  renameSync(join(dir, `.${name}.tmp`), join(dir, name));
  writeFileSync(join(dir, `${stamp}-repro-raw.log`), raw, { flag: 'wx', mode: 0o600 });
  symlinkSync(name, join(dir, `.latest-${stamp}`));
  renameSync(join(dir, `.latest-${stamp}`), join(dir, 'latest'));
  return join(dir, name);
}

export function reproLocal(args) {
  const opts = parse(args);
  const repo = resolve(opts.repo ?? resolve(import.meta.dirname, '../../../..'));
  const heads = resolveHeads(repo, opts.heads, opts.argv);
  if (new Set(heads).size !== heads.length) throw fail('duplicate commit');
  if (run('git', ['diff', '--quiet'], { cwd: repo }).status !== 0 || run('git', ['diff', '--cached', '--quiet'], { cwd: repo }).status !== 0) throw fail('tracked worktree is dirty');
  const host = process.env.MADO_LINUX_HOST || 'mado-ci-linux';
  if (!/^[A-Za-z0-9._-]+$/.test(host) || host.startsWith('-')) throw fail('invalid MADO_LINUX_HOST');
  const temp = mkdtempSync(join(tmpdir(), 'ci-linux-repro-'));
  const refs = heads.map(head => `refs/preflight/${head}`);
  const bundle = join(temp, 'head.bundle');
  let remoteDir;
  let raw = '';
  try {
    for (let i = 0; i < heads.length; i++) {
      if (run('git', ['update-ref', refs[i], heads[i]], { cwd: repo }).status !== 0) throw fail('temporary ref failed', 75);
    }
    if (run('git', ['bundle', 'create', bundle, ...refs], { cwd: repo }).status !== 0) throw fail('git bundle failed', 75);
    for (const ref of refs) run('git', ['update-ref', '-d', ref], { cwd: repo });
    const init = 'set -e\nmkdir -p "$HOME/ci"\nmktemp -d "$HOME/ci/run.XXXXXX"\n';
    const setup = ssh(host, '/bin/bash -s', init);
    if (setup.status !== 0) throw fail(`remote setup: ${setup.stderr?.trim() || setup.error?.message}`, 75);
    remoteDir = setup.stdout.trim();
    if (!/^\/[A-Za-z0-9._/-]+\/ci\/run\.[A-Za-z0-9]+$/.test(remoteDir)) throw fail('invalid remote run directory', 75);
    const rsyncShell = `ssh ${sshOptions.map(quote).join(' ')}`;
    const transfer = run('rsync', ['-e', rsyncShell, bundle, `${host}:${remoteDir}/head.bundle`]);
    if (transfer.status !== 0) throw fail(`bundle transfer: ${transfer.stderr?.trim()}`, 75);
    const runnerTransfer = run('rsync', ['-e', rsyncShell, join(import.meta.dirname, 'repro.mjs'), `${host}:${remoteDir}/repro.mjs`]);
    if (runnerTransfer.status !== 0) throw fail(`runner transfer: ${runnerTransfer.stderr?.trim()}`, 75);
    const checkTransfer = run('rsync', ['-e', rsyncShell, join(repo, '.agents/skills/ci-linux-preflight/scripts/env-check.sh'), `${host}:${remoteDir}/env-check.sh`]);
    if (checkTransfer.status !== 0) throw fail(`environment check transfer: ${checkTransfer.stderr?.trim()}`, 75);
    const payload = Buffer.from(JSON.stringify({ heads, command: opts.command, argv: opts.argv, expect: opts.expect ?? null, stepTimeout: opts.stepTimeout, deadline: opts.deadline })).toString('base64');
    const script = readFileSync(join(import.meta.dirname, 'remote-repro.sh'), 'utf8');
    const result = ssh(host, `/bin/bash -s -- ${quote(remoteDir)} ${quote(payload)}`, script);
    raw = result.stderr ?? '';
    if (result.stdout?.endsWith('DONE\n')) {
      try {
        const line = checkReproSummary(result.stdout, heads[0]);
        const outcome = result.stdout.match(/^outcome=(.+)$/m)?.[1];
        const status = outcome === 'MATCH' || outcome === 'COMPLETE' ? 0 : outcome === 'MISMATCH' ? 1 : 75;
        if (result.status !== status) throw Error('remote exit disagrees with summary');
        const path = writeAttempt(heads[0], result.stdout, raw);
        process.stdout.write(`${line}\nSummary: ${path}\n`);
        return status;
      } catch (error) { raw += `\ninvalid remote summary: ${error.message}`; }
    }
    throw fail(result.status === 75 && /(?:^|\n)busy\s*$/m.test(raw) ? 'busy' : `remote run: ${raw.trim() || result.error?.message || result.status}`, 75);
  } catch (error) {
    const body = summary({ heads, command: opts.command, expect: opts.expect, outcome: 'NOT VERIFIED', reason: error.message,
      results: heads.map(head => ({ head, exit: 'not-run', secs: '0.0', outcome: 'not-run', failed: [] })) });
    const path = writeAttempt(heads[0], body, raw || error.message);
    process.stdout.write(`${checkReproSummary(body, heads[0])}\nSummary: ${path}\n`);
    return 75;
  } finally {
    if (remoteDir) ssh(host, `/bin/bash -s -- ${quote(remoteDir)}`, 'rm -rf -- "$1"\n');
    for (const ref of refs) run('git', ['update-ref', '-d', ref], { cwd: repo });
    rmSync(temp, { recursive: true, force: true });
  }
}

export function reproRemote(repo, payload) {
  const opts = JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
  if (!Array.isArray(opts.heads) || !opts.heads.length || opts.heads.some(v => !hex.test(v))) throw fail('invalid remote heads', 75);
  if (JSON.stringify(parseCommand(opts.command)) !== JSON.stringify(opts.argv)) throw fail('remote command mismatch', 75);
  const data = { heads: opts.heads, command: opts.command, expect: opts.expect, outcome: 'COMPLETE', kernel: release(),
    node: run('node', ['--version']).stdout?.trim() || 'unknown', results: [] };
  const started = Date.now();
  for (const head of opts.heads) {
    const checkout = run('git', ['checkout', '-q', '--detach', head], { cwd: repo });
    const actual = run('git', ['rev-parse', 'HEAD'], { cwd: repo }).stdout?.trim();
    if (checkout.status !== 0 || actual !== head) { data.outcome = 'NOT VERIFIED'; data.reason = `checkout head mismatch ${head}`; break; }
    if (sourcePaths(opts.argv).some(path => !existsSync(join(repo, path)))) { data.outcome = 'NOT VERIFIED'; data.reason = `command path missing ${head}`; break; }
    const remaining = Math.ceil(opts.deadline - (Date.now() - started) / 1000);
    if (remaining < 1) { data.outcome = 'TIMEOUT'; data.reason = 'whole run deadline reached'; break; }
    const begin = Date.now();
    const result = run('timeout', ['--kill-after=10', String(Math.min(opts.stepTimeout, remaining)), '/usr/bin/env', '-i', `HOME=${repo}`, `PATH=${process.env.PATH || commandPath}`, 'CI=true', 'LANG=C.UTF-8', ...opts.argv], { cwd: repo });
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    const exit = result.status ?? 75;
    const outcome = result.error ? 'NOT VERIFIED' : [124, 137].includes(exit) ? 'TIMEOUT' : exit === 0 ? 'PASS' : 'FAIL';
    const failed = [...output.matchAll(/^(?:not ok \d+ - |FAIL: |ERROR: ).+$/gm)].map(m => m[0].trim()).slice(0, 5);
    data.results.push({ head, exit: String(exit), secs: ((Date.now() - begin) / 1000).toFixed(1), outcome, failed });
    process.stderr.write(`head ${head}:\n${output.slice(0, 100000)}\n`);
    if (outcome === 'NOT VERIFIED' || outcome === 'TIMEOUT') { data.outcome = outcome; data.reason = result.error?.message ?? 'step timeout'; break; }
  }
  for (const head of opts.heads.slice(data.results.length)) data.results.push({ head, exit: 'not-run', secs: '0.0', outcome: 'not-run', failed: [] });
  if (data.outcome === 'COMPLETE' && opts.expect) {
    data.outcome = opts.expect.every((v, i) => (v === 'pass') === (data.results[i].outcome === 'PASS')) ? 'MATCH' : 'MISMATCH';
  }
  process.stdout.write(summary(data));
  return data.outcome === 'MATCH' || data.outcome === 'COMPLETE' ? 0 : data.outcome === 'MISMATCH' ? 1 : 75;
}

if (process.argv[1]?.endsWith('/repro.mjs') && process.argv[2] === 'remote') {
  try { process.exitCode = reproRemote(process.argv[3], process.argv[4]); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = error.exitCode ?? 75; }
}
