#!/usr/bin/env node
/** Run the compiled App test bundle. Set PICSEE_APP_LANE_NO_RETRY=1 for RED receipts. */
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { classifyFlaky } from "../ci/flaky-gate.mjs";

const lock = fileURLToPath(new URL("../heavy-lock.sh", import.meta.url));
const bundle = ".build/dd-ci/Build/Products/Debug/PicseeAppTests.xctest";
const crashRecords = [
  /^error: (?:Process '[^'\r\n]+' )?Exited with [^\r\n]*\bsignal\b[^\r\n]*$/i,
  /^(?:[^:\r\n]+\.swift:\d+(?::\d+)?: )?Fatal error:(?: |$)/,
  /^Test (?:Case|Suite) '.+' crashed(?: \([^\r\n]*\))?\.?$/,
  /^✘ Test .+ crashed after \d+(?:\.\d+)? seconds(?: with \d+ issues?)?\.$/,
  /^(?:[^:\r\n]+: )?(?:Segmentation fault|Bus error|Abort trap)(?:: \d+)?\s*$/i,
];
const testName = label => label.endsWith('()') ? label.slice(0, -2) : label;

/** Shared completeness and failure parser. Importing this module never launches native tests. */
export function parseAppResult(run) {
  const stdout = run.stdout ?? "", stderr = run.stderr ?? "";
  const output = `${stdout}\n${stderr}`;
  const clean = output.replace(/\x1b\[[0-9;]*m/g, '').replace(/\r/g, '');
  const rootDone = /Test Suite 'All tests' (?:passed|failed) at /.test(clean) &&
    /Executed \d+ tests?, with \d+ failures? \(\d+ unexpected\)/.test(clean);
  const rootFailures = [...clean.matchAll(/Executed \d+ tests?, with (\d+) failures? \((\d+) unexpected\)/g)]
    .some(match => Number(match[1]) || Number(match[2]));
  const starts = [...clean.matchAll(/^◇ Test run started\.$/gm)];
  const summaries = [...clean.matchAll(/^[✔✘] Test run with (\d+) tests? in \d+ suites? (passed|failed) after .+ seconds(?:\.| with (\d+) issues?\.)$/gm)];
  const passed = [...clean.matchAll(/^✔ Test (?!run with ).+ passed after /gm)].length;
  const failures = [...clean.matchAll(/^✘ Test (?!run with )(.+) failed after /gm)];
  const failureNames = failures.map(match => testName(match[1]));
  const failed = failures.length;
  const skipped = [...clean.matchAll(/^➜ Test .+ skipped(?::| after |\.)/gm)].length;
  const count = summaries.length === 1 ? Number(summaries[0][1]) : 0;
  const issues = [...clean.matchAll(/^✘ Test (.+) recorded an issue at (.+)$/gm)]
    .map(match => ({ name: testName(match[1]), signature: match[2] }));
  const issueRecords = clean.split('\n').filter(line => line.startsWith('✘') && line.includes('recorded an issue'));
  const unattributedIssues = issueRecords.length !== issues.length || issues.some(issue => !failureNames.includes(issue.name)) ||
    (summaries.length === 1 && Number(summaries[0][3] ?? 0) !== issues.length);
  const crash = clean.split('\n').some(line => crashRecords.some(record => record.test(line)));
  const reliable = !(run.error || run.signal || crash || rootFailures || !rootDone || starts.length !== 1 || summaries.length !== 1 || !count ||
    passed + failed + skipped !== count || (summaries[0]?.[2] === "failed") !== (failed > 0) ||
    ![0, 1].includes(run.status) || (run.status === 0) !== (failed === 0));
  return { reliable, status: reliable ? run.status : 70, output, count, passed, failed, skipped, failureNames, issues, unattributedIssues };
}

function nativeSpawn(env, spawnSync) {
  return spawnSync(lock, ["xcrun", "xctest", bundle], {
    encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: 2100000,
    env: { ...env, SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: "1" },
  });
}

/** One attempt, plus at most one strictly authorized retry. Inject only the process boundary. */
export function runAppLane({ spawn = spawnSync, env = process.env,
  evidencePath = '.build/app-lane-attempt1.log', stdout = s => process.stdout.write(s), stderr = s => process.stderr.write(s) } = {}) {
  const execute = () => {
    const run = nativeSpawn(env, spawn);
    stdout(run.stdout ?? ''); stderr(run.stderr ?? '');
    return { run, parsed: parseAppResult(run) };
  };
  let attempt = execute();
  if (attempt.parsed.failed) stdout(`\napp-lane: first-attempt failures: ${attempt.parsed.failureNames.join(', ')}\n`);
  if (attempt.parsed.status !== 0) {
    try {
      mkdirSync(path.dirname(evidencePath), { recursive: true });
      writeFileSync(evidencePath, attempt.parsed.output);
    } catch (error) {
      stderr(`app-lane: cannot preserve first-attempt evidence ${evidencePath}: ${error.message}\n`);
      return 70;
    }
    const gate = classifyFlaky(attempt.run);
    if (env.PICSEE_APP_LANE_NO_RETRY !== '1' && gate.decision === 'retry-eligible') {
      stdout(`app-lane: known flaky ${gate.names.join(', ')} (${gate.issues.map(issue => `#${issue}`).join(', ')}); retrying once\n`);
      attempt = execute();
    }
  }
  const final = attempt.parsed;
  if (!final.reliable) stderr('app-lane: no reliable completed App test result; environment failure\n');
  else stdout(`\nTests run: ${final.count}, Failures: ${final.failed}, Errors: 0, Skipped: ${final.skipped}\n`);
  return final.status;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = runAppLane();
