#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { skippable } from '../../../../scripts/ci/native-inputs.mjs';

// CI's classifier is the single definition of documentation-only paths.
export function selectSuites(files) {
  return {
    native: !files.length || files.some(file => !skippable(file)),
    agents: files.some(file => file.startsWith('scripts/agents/') || file.startsWith('.agents/skills/picsee-delegator/scripts/')),
    tdd: files.some(file => file.startsWith('scripts/tdd/') || file.startsWith('scripts/ci/') || file === 'scripts/heavy-lock.sh'),
  };
}

const safe = value => value.replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 80);
export function failureFact(lane, code, output, files = []) {
  if (code === 0) return '';
  const lock = /(?:lock timeout|timed out waiting for (?:picsee|mdpro)|exit 75)/i.test(output);
  if (code === 75 || lock) {
    const holder = /(?:holder|owner)(?: pid)?[=: ]+(\d+)/i.exec(output)?.[1] ?? 'unknown';
    const alive = holder === 'unknown' ? 'unknown' : (() => { try { process.kill(Number(holder), 0); return 'yes'; } catch { return 'no'; } })();
    return `${lane}: lock-timeout holder=${holder} alive=${alive}`;
  }
  if (/hung before establishing connection/i.test(output)) return `${lane}: hung`;
  if (lane === 'design') {
    if (/node_modules/i.test(output)) return 'design: prereq=node_modules';
    if (/playwright|chromium/i.test(output)) return 'design: prereq=Playwright';
  }
  if (lane === 'swift') {
    const timed = [...output.matchAll(/(?:timelimit|time limit)/gi)].length;
    const failed = /Executed (\d+) tests?, with (\d+) failures?/i.exec(output)?.[2] ?? /(?:failed|failure)[=: ]+(\d+)/i.exec(output)?.[1] ?? 'unknown';
    return `swift: failed=${failed} timelimit=${timed} other=${failed === 'unknown' ? 'unknown' : Math.max(0, Number(failed) - timed)}`;
  }
  if (lane === 'node') {
    const names = [...output.matchAll(/^\s*not ok \d+ - (.+)$/gm)].map(m => safe(m[1]));
    const count = names.length || Number(/(?:fail|failed)\s+(\d+)/i.exec(output)?.[1] ?? 0);
    const relevant = names.some(name => files.some(file => name.includes(path.basename(file).replace(/\.test\.mjs$/, ''))));
    return `node: failed=${count || 'unknown'} tests=${names.length ? names.join(',') : 'unknown'} in-diff=${relevant ? 'yes' : 'no'}`;
  }
  const tests = /Tests run: (\d+), Failures: (\d+)/.exec(output);
  if (tests) return `${lane}: tests=${tests[1]} failed=${tests[2]}`;
  return `${lane}: exit=${code}`;
}

export function preflight({ scriptsOwn, nodeModules, playwright, holder }) {
  if (!scriptsOwn) return 'script is not the gated worktree copy';
  if (!nodeModules) return 'missing node_modules; run npm ci --ignore-scripts';
  if (!playwright) return 'missing Playwright Chromium; run npx playwright install chromium';
  if (holder && (!holder.alive || !holder.withinBudget)) return `heavy-lock holder=${holder.pid ?? 'unknown'} alive=${holder.alive ? 'yes' : 'no'} within-budget=${holder.withinBudget ? 'yes' : 'no'}`;
  return null;
}

function lockHolder(wt, env) {
  const lock = env.PICSEE_HEAVY_LOCK ?? path.join(env.HOME, '.picsee/locks/heavy.lock');
  const dir = path.dirname(lock), basename = path.basename(lock);
  let records;
  try { records = fs.readdirSync(dir).filter(name => name.startsWith(`${basename}.guardian-`) && name.endsWith('.owner')); }
  catch { return null; }
  const mdpro = env.PICSEE_MDPRO_LOCK === 'off' ? null : (env.PICSEE_MDPRO_LOCK ?? path.join(env.HOME, '.cache/mdpro-heavy.lock'));
  const paths = records.map(name => path.join(dir, name));
  if (mdpro && fs.existsSync(mdpro)) paths.push(path.join(mdpro, 'owner'));
  for (const record of paths) {
    let content;
    try { content = fs.readFileSync(record, 'utf8'); }
    catch { return {pid:'unknown', alive:false, withinBudget:false}; }
    const pid = Number(/^pid=(\d+)$/m.exec(content)?.[1]);
    const started = /^started=(.+)$/m.exec(content)?.[1];
    if (!pid || !started) return {pid:pid || 'unknown', alive:false, withinBudget:false};
    const alive = spawnSync('ps', ['-p', String(pid), '-o', 'pid='], {encoding:'utf8'}).stdout?.trim() === String(pid);
    const age = (Date.now() - Date.parse(started)) / 1000;
    const withinBudget = Number.isFinite(age) && age >= 0 && age <= Number(env.PICSEE_HEAVY_LOCK_EXEC_SECS ?? 1800) + 60;
    if (!alive || !withinBudget) return {pid, alive, withinBudget};
  }
  return null;
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'select') {
    const files = fs.readFileSync(args[0], 'utf8').split('\n').filter(Boolean);
    const choice = selectSuites(files);
    for (const [key, value] of Object.entries(choice)) console.log(`${key}=${value ? 1 : 0}`);
  } else if (cmd === 'fact') {
    const [lane, code, log, diff] = args;
    console.log(failureFact(lane, Number(code), fs.readFileSync(log, 'utf8'), fs.readFileSync(diff, 'utf8').split('\n').filter(Boolean)));
  } else if (cmd === 'preflight') {
    const [wt, script] = args;
    let own = false;
    try { own = fs.realpathSync(script) === fs.realpathSync(path.join(wt, '.agents/skills/picsee-delegator/scripts/owner-gates.sh')); }
    catch { own = false; }
    let playwright = false;
    if (fs.existsSync(path.join(wt, 'node_modules/playwright'))) {
      try {
        const imported = await import(path.join(wt, 'node_modules/playwright/index.mjs'));
        playwright = fs.existsSync(imported.chromium.executablePath());
      } catch { playwright = false; }
    }
    const reason = preflight({scriptsOwn:own, nodeModules:fs.existsSync(path.join(wt, 'node_modules')),
      playwright, holder:lockHolder(wt, process.env)});
    if (reason) { console.log(`preflight: ${reason}`); process.exitCode = 2; }
    else console.log('preflight: ok');
  } else { console.error('usage: owner-gates-tools.mjs select|fact|preflight'); process.exitCode = 2; }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
