#!/usr/bin/env node
// The full local unit suite has one coverage profile; CI has two independent shards.
// Both layouts are evaluated by package-coverage.mjs with the same DA/FNDA policy.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exportShard } from './package-coverage-export.mjs';
import { evaluateCoverage } from './package-coverage.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const pointer = path.join(root, 'coverage/local-unit-current.json');
const publicReport = path.join(root, 'coverage/package-report.md');
const guardianLCOV = path.join(root, 'coverage/package-eligible.lcov');
const sha = () => execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const invalidate = () => {
  for (const file of [pointer, publicReport, guardianLCOV]) if (existsSync(file)) unlinkSync(file);
};

export function runLocal({ out, notBefore, reuse = false }) {
  let state;
  if (reuse) {
    try {
      state = JSON.parse(readFileSync(pointer, 'utf8'));
      if (state.commit !== sha()) throw new Error('local coverage pointer commit drift');
    } catch (error) {
      invalidate();
      throw error;
    }
  } else {
    if (!path.isAbsolute(out) || !Number.isSafeInteger(notBefore) || notBefore <= 0) throw new Error('absolute out and positive notBefore required');
    invalidate();
    state = { input: path.join(out, 'coverage'), commit: sha(), runId: String(Date.now()), attempt: 1 };
    exportShard({ root, shard: 'non-ui', out: path.join(state.input, 'non-ui'), commit: state.commit,
      runId: state.runId, runAttempt: state.attempt, notBefore });
  }
  const report = path.join(state.input, 'report.md');
  mkdirSync(path.dirname(publicReport), { recursive: true });
  if (existsSync(guardianLCOV)) unlinkSync(guardianLCOV);
  try {
    const result = evaluateCoverage({ root, input: state.input, out: report, sha: state.commit,
      runId: state.runId, attempt: state.attempt, formal: false, shards: ['non-ui'], eligibleOut: guardianLCOV });
    copyFileSync(report, publicReport);
    if (!reuse) writeFileSync(pointer, JSON.stringify(state, null, 2) + '\n');
    process.stdout.write(result.report);
    return result.pass ? 0 : 1;
  } catch (error) {
    invalidate();
    throw error;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length === 1 && args[0] === '--reuse') process.exitCode = runLocal({ reuse: true });
    else if (args.length === 4 && args[0] === '--out' && args[2] === '--not-before') {
      process.exitCode = runLocal({ out: path.resolve(args[1]), notBefore: Number(args[3]) });
    } else throw new Error('usage: package-coverage-local.mjs --out <absolute path> --not-before <unix seconds> | --reuse');
  } catch (error) {
    process.stderr.write(`package-coverage-local: ${error.message}\n`);
    process.exitCode = 1;
  }
}
