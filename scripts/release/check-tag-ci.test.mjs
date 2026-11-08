import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { evaluateTagCI } from "./check-tag-ci.mjs";

const SHA = "a".repeat(40), OTHER = "b".repeat(40);
const NAMES = ["Walking skeleton", "App tests"];
const script = fileURLToPath(new URL("./check-tag-ci.mjs", import.meta.url));
const root = fileURLToPath(new URL("../../", import.meta.url));
const run = (patch = {}) => ({ id: 100, head_sha: SHA, head_branch: "main", event: "push",
  path: ".github/workflows/ci.yml", run_attempt: 1, status: "completed", conclusion: "success", ...patch });
const job = (name, patch = {}) => ({ id: name === NAMES[0] ? 1001 : 1002, run_id: 100,
  head_sha: SHA, run_attempt: 1, name, status: "completed", conclusion: "success", ...patch });
const jobs = (patch = {}) => NAMES.map((name) => job(name, patch));
const evidence = (patch = {}) => ({ sha: SHA, runs: [run()], jobs: jobs(), ...patch });
function denied(input, name = NAMES) {
  const result = evaluateTagCI(input);
  assert.equal(result.pass, false, JSON.stringify(input));
  assert.ok(result.reason.includes(SHA), result.reason);
  for (const item of [].concat(name)) assert.ok(result.reason.includes(item), result.reason);
  return result;
}

test("both exact jobs must succeed; unrelated overall CI conclusion adds no gate", () => {
  for (const conclusion of ["success", "failure"]) {
    const result = evaluateTagCI(evidence({ runs: [run({ conclusion })] }));
    assert.equal(result.pass, true, result.reason);
    for (const value of [SHA, ...NAMES]) assert.ok(result.reason.includes(value), result.reason);
  }
});

test("no CI run or only other SHA, branch, event, workflow cannot authorize", () => {
  denied(evidence({ runs: [] }));
  for (const patch of [{ head_sha: OTHER }, { head_branch: "topic" }, { event: "workflow_dispatch" },
    { event: "pull_request" }, { path: ".github/workflows/other.yml" }]) {
    denied(evidence({ runs: [run(patch)] }));
  }
});

for (const status of ["queued", "in_progress", "waiting", null]) {
  test(`run status ${status} fails even with green-looking jobs`, () => {
    denied(evidence({ runs: [run({ status })] }));
  });
}

for (const name of NAMES) {
  for (const conclusion of ["failure", "cancelled", "skipped", "timed_out", "action_required", "neutral", null, "unknown"]) {
    test(`${name} ${conclusion} fails and names SHA and job`, () => {
      denied(evidence({ jobs: jobs().map((j) => j.name === name ? { ...j, conclusion } : j) }), name);
    });
  }
  test(`${name} must be present, exact, completed and unambiguous`, () => {
    const other = jobs().filter((j) => j.name !== name);
    denied(evidence({ jobs: other }), name);
    denied(evidence({ jobs: [...other, job(`${name} extra`)] }), name);
    denied(evidence({ jobs: [...other, job(name, { status: "in_progress" })] }), name);
    denied(evidence({ jobs: [...jobs(), job(name, { id: 9999, conclusion: "failure" })] }), name);
  });
}

test("greatest eligible run ID wins regardless of order, timestamp or dispatch", () => {
  const old = run({ updated_at: "2099-01-01T00:00:00Z", run_attempt: 4 });
  const latest = run({ id: 101 });
  for (const runs of [[old, latest], [latest, old]]) {
    const currentJobs = jobs({ run_id: 101 });
    assert.equal(evaluateTagCI(evidence({ runs, jobs: currentJobs })).pass, true);
    denied(evidence({ runs, jobs: currentJobs.map((j) => ({ ...j, conclusion: "failure" })) }));
    denied(evidence({ runs: runs.map((r) => r.id === 101 ? { ...r, status: "in_progress" } : r), jobs: currentJobs }));
    denied(evidence({ runs, jobs: [] }));
  }
  denied(evidence({ runs: [run(), run({ id: 999, event: "workflow_dispatch" })],
    jobs: jobs().map((j) => ({ ...j, conclusion: "failure" })) }));
});

test("latest attempt supersedes old failure and old success symmetrically", () => {
  const runs = [run({ run_attempt: 2 })];
  for (const name of NAMES) {
    const old = jobs().map((j) => ({ ...j, conclusion: "failure" }));
    const current = jobs({ run_attempt: 2 }).map((j) => ({ ...j, id: j.id + 10 }));
    assert.equal(evaluateTagCI(evidence({ runs, jobs: [...old, ...current] })).pass, true);
    for (const patch of [{ conclusion: "failure" }, { status: "in_progress", conclusion: null }]) {
      denied(evidence({ runs, jobs: [...jobs(), ...current.map((j) => j.name === name ? { ...j, ...patch } : j)] }), name);
    }
  }
});

test("failed-job-only rerun carries forward successful jobs without stale failures", () => {
  const runs = [run({ run_attempt: 2 })];
  const before = jobs().map((j) => j.name === "App tests" ? { ...j, conclusion: "failure" } : j);
  const rerun = job("App tests", { id: 2002, run_attempt: 2 });
  assert.equal(evaluateTagCI(evidence({ runs, jobs: [...before, rerun] })).pass, true);
  denied(evidence({ runs, jobs: [...jobs(), { ...rerun, conclusion: "failure" }] }), "App tests");
  // Ambiguity in a superseded attempt cannot veto unique current proof.
  assert.equal(evaluateTagCI(evidence({ runs, jobs: [...before, job("App tests", { id: 1999 }), rerun] })).pass, true);
});

test("irrelevant evidence and permutations preserve the verdict without mutating inputs", () => {
  for (const conclusion of ["success", "failure"]) {
    const input = evidence({ jobs: jobs().map((j) => ({ ...j, conclusion })) });
    const snapshot = structuredClone(input);
    const expected = evaluateTagCI(input);
    for (const extra of [{ event: "workflow_dispatch" }, { head_branch: "topic" }, { head_sha: OTHER }]) {
      const transformed = { ...input, runs: [run({ id: 999, ...extra }), ...input.runs].reverse(),
        jobs: [...input.jobs, job("Unrelated", { id: 8888 })].reverse() };
      assert.deepEqual(evaluateTagCI(transformed), expected);
    }
    assert.deepEqual(input, snapshot);
  }
});

test("malformed evidence and impossible associations never authorize", () => {
  for (const patch of [{ runs: null }, { runs: {} }, { jobs: null }, { jobs: {} },
    { runs: [null] }, { jobs: [null] }, { runs: [run(), run({ status: "queued" })] },
    { jobs: [...jobs(), jobs()[0]] }]) denied(evidence(patch));
  for (const patch of [{ id: undefined }, { id: "100" }, { id: 0 }, { run_attempt: undefined },
    { run_attempt: 0 }, { run_attempt: 1.5 }, { head_sha: undefined }, { status: undefined }]) {
    denied(evidence({ runs: [run(patch)] }));
  }
  for (const patch of [{ id: undefined }, { run_id: 101 }, { head_sha: OTHER }, { run_attempt: 2 },
    { run_attempt: undefined }, { run_attempt: 0 }, { name: null }, { conclusion: {} }]) {
    denied(evidence({ jobs: [job(NAMES[0], patch), job(NAMES[1])] }), NAMES[0]);
  }
  const result = evaluateTagCI(null);
  assert.equal(result.pass, false);
});

test("rechecked run list must retain selected ID, attempt and completed status", () => {
  for (const confirmedRuns of [[], [run({ id: 101 })], [run(), run({ id: 101, status: "queued" })],
    [run({ run_attempt: 2 })], [run({ status: "in_progress" })]]) {
    denied(evidence({ confirmedRuns }));
  }
  assert.equal(evaluateTagCI(evidence({ confirmedRuns: [run()] })).pass, true);
});

const pages = (key, entries, total = entries.length) => [{ total_count: total, [key]: entries }];
const responses = (js = jobs()) => [pages("workflow_runs", [run()]), pages("jobs", js), pages("workflow_runs", [run()])];

/** Only the external gh/API boundary is fake. Node CLI, env, files and process exit are real. */
function cli(sequence = responses(), { env = {}, shell = null, noGh = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "mado-tag-ci-"));
  const fixture = join(dir, "responses.json"), counter = join(dir, "counter");
  writeFileSync(fixture, JSON.stringify(sequence));
  if (!noGh) {
    const gh = join(dir, "gh");
    writeFileSync(gh, `#!${process.execPath}\n` + `
const fs = require('node:fs');
const count = fs.existsSync(process.env.FAKE_COUNTER) ? Number(fs.readFileSync(process.env.FAKE_COUNTER)) : 0;
fs.writeFileSync(process.env.FAKE_COUNTER, String(count + 1));
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_COUNTER + '.args', JSON.stringify(args) + '\\n');
const fixture = JSON.parse(fs.readFileSync(process.env.FAKE_FIXTURE))[count];
if (!process.env.GH_TOKEN && !process.env.GITHUB_TOKEN) process.exit(9);
if (fixture && fixture.error) { process.stderr.write('transport error token=' + process.env.GH_TOKEN); process.exit(1); }
if (fixture && fixture.raw !== undefined) { process.stdout.write(fixture.raw); process.exit(0); }
// Simulate gh pagination semantics, so dropping either option cannot pass pagination cases.
const value = args.includes('--paginate') && args.includes('--slurp') ? fixture : fixture?.[0];
process.stdout.write(JSON.stringify(value));
`);
    chmodSync(gh, 0o755);
  }
  try {
    const result = spawnSync(shell ? "/bin/bash" : process.execPath,
      shell ? ["--noprofile", "--norc", "-eo", "pipefail", "-c", shell] : [script], {
        cwd: root, encoding: "utf8", timeout: 10000,
        env: { PATH: dir, GITHUB_SHA: SHA, GITHUB_REPOSITORY: "anzchy/picsee", GH_TOKEN: "fixture-private-token",
          FAKE_FIXTURE: fixture, FAKE_COUNTER: counter, ...env },
      });
    let calls = [];
    try { calls = readFileSync(`${counter}.args`, "utf8").trim().split("\n").map(JSON.parse); } catch { /* preflight can make no calls */ }
    return { ...result, calls, output: (result.stdout ?? "") + (result.stderr ?? "") };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
function cliDenied(result, names = NAMES, sha = SHA) {
  assert.notEqual(result.status, 0, result.output);
  assert.match(result.output, /::error::/);
  assert.ok(result.output.includes(sha), result.output);
  for (const name of [].concat(names)) assert.ok(result.output.includes(name), result.output);
  assert.doesNotMatch(result.output, /fixture-private-token/);
}

test("CLI authenticates from the job token and reports actual success/failure", () => {
  const passed = cli();
  assert.equal(passed.status, 0, passed.output);
  assert.ok(passed.output.includes(SHA), passed.output);
  assert.doesNotMatch(passed.output, /fixture-private-token/);
  assert.equal(passed.calls.length, 3);
  assert.ok(passed.calls[0].some((arg) => arg.includes("/actions/workflows/ci.yml/runs?") &&
    arg.includes(`head_sha=${SHA}`) && arg.includes("event=push") && arg.includes("branch=main")));
  assert.ok(passed.calls[1].some((arg) => arg.includes("/actions/runs/100/jobs?") && arg.includes("filter=all")));
  cliDenied(cli(responses(jobs().map((j) => j.name === "App tests" ? { ...j, conclusion: "failure" } : j))), "App tests");
  assert.equal(cli(responses(), { env: { GH_TOKEN: "", GITHUB_TOKEN: "fixture-private-token" } }).status, 0);
});

test("CLI denies absent run, in-progress run, missing job and non-success jobs", () => {
  cliDenied(cli([pages("workflow_runs", [])]));
  cliDenied(cli([pages("workflow_runs", [run({ status: "in_progress" })])]));
  for (const name of NAMES) {
    cliDenied(cli(responses(jobs().filter((j) => j.name !== name))), name);
    for (const conclusion of ["failure", "cancelled", "skipped"]) {
      cliDenied(cli(responses(jobs().map((j) => j.name === name ? { ...j, conclusion } : j))), name);
    }
  }
});

test("CLI uses latest effective attempts including successful retained jobs", () => {
  const attempts = [run({ run_attempt: 2 })];
  const latestJobs = [job(NAMES[0]), job(NAMES[1], { conclusion: "failure" }), job(NAMES[1], { id: 2002, run_attempt: 2 })];
  assert.equal(cli([pages("workflow_runs", attempts), pages("jobs", latestJobs), pages("workflow_runs", attempts)]).status, 0);
});

test("API failure at each request and invalid JSON fail closed without exposing token", () => {
  for (const index of [0, 1, 2]) {
    for (const bad of [{ error: true }, { raw: "not JSON" }]) {
      const sequence = responses(); sequence[index] = bad;
      cliDenied(cli(sequence));
    }
  }
  cliDenied(cli(responses(), { noGh: true }));
});

test("CLI fails closed for absent or invalid context", () => {
  for (const env of [{ GH_TOKEN: "" }, { GITHUB_REPOSITORY: "" }, { GITHUB_REPOSITORY: "../bad" }]) {
    cliDenied(cli(responses(), { env }));
  }
  for (const sha of ["", "abc", "invalid\nannotation"]) {
    const result = cli(responses(), { env: { GITHUB_SHA: sha } });
    assert.notEqual(result.status, 0);
    assert.match(result.output, /::error::/);
    for (const name of NAMES) assert.ok(result.output.includes(name), result.output);
  }
});

test("pagination uses all run/job pages and rejects truncation or conflicting totals", () => {
  const newer = run({ id: 101 });
  const allRuns = [{ total_count: 2, workflow_runs: [run()] }, { total_count: 2, workflow_runs: [newer] }];
  const splitJobs = [{ total_count: 2, jobs: [job(NAMES[0], { run_id: 101 })] },
    { total_count: 2, jobs: [job(NAMES[1], { run_id: 101 })] }];
  assert.equal(cli([allRuns, splitJobs, allRuns]).status, 0);
  cliDenied(cli([allRuns, [splitJobs[0]], allRuns]));
  cliDenied(cli([pages("workflow_runs", [run()], 2)]));
  cliDenied(cli([[...allRuns.slice(0, 1), { total_count: 3, workflow_runs: [newer] }]]));
  cliDenied(cli([allRuns, { error: true }]));
  cliDenied(cli([[], pages("jobs", jobs())]));
});

test("CLI rejects races to another attempt, incomplete status or newer eligible push", () => {
  for (const final of [[run({ run_attempt: 2 })], [run({ status: "in_progress" })],
    [run(), run({ id: 101, status: "queued" })], [run(), run({ id: 101, conclusion: "failure" })]]) {
    cliDenied(cli([pages("workflow_runs", [run()]), pages("jobs", jobs()), pages("workflow_runs", final)]));
  }
});

test("actual workflow CI step executes the checker and propagates failure", () => {
  const workflow = readFileSync(join(root, ".github/workflows/release.yml"), "utf8");
  const match = /      - name: Check CI on the tag commit\n([\s\S]*?)(?=\n      - name:)/.exec(workflow);
  assert.ok(match, "release must have the tag CI gate");
  const command = /        run: (.*)/.exec(match[1])?.[1];
  assert.equal(command, "node scripts/release/check-tag-ci.mjs");
  const shell = command.replace(/^node /, `"${process.execPath}" `);
  assert.equal(cli(responses(), { shell }).status, 0);
  cliDenied(cli([pages("workflow_runs", [])], { shell }));
});

// WI-2: borrowed successes need corroboration from the final, completed run snapshot.
const borrowedJobs = (name) => jobs().map((j) => j.name === name ? j : { ...j, run_attempt: 2 });
const attempted = (conclusion) => run({ run_attempt: 2, conclusion });
const retainedEvidence = (name, initial, final) => evidence({
  runs: [attempted(initial)], jobs: borrowedJobs(name), confirmedRuns: [attempted(final)],
});

for (const name of NAMES) {
  for (const conclusion of ["failure", "cancelled", null, undefined, "unknown", "skipped", "timed_out", "neutral", "action_required"]) {
    test(`WI-2 retained ${name} requires final success, rejects ${conclusion}`, () => {
      denied(retainedEvidence(name, "success", conclusion), name);
    });
  }
  test(`WI-2 final snapshot overrides initial conclusion for retained ${name}`, () => {
    denied(retainedEvidence(name, "success", "failure"), name);
    for (const initial of ["failure", "cancelled", null]) {
      const result = evaluateTagCI(retainedEvidence(name, initial, "success"));
      assert.equal(result.pass, true, result.reason);
    }
  });
}

test("WI-2 corroboration distinguishes borrowed success from current-attempt unrelated failure", () => {
  for (const name of NAMES) {
    assert.equal(evaluateTagCI(retainedEvidence(name, "success", "success")).pass, true);
  }
  for (const initial of ["success", "failure"]) {
    assert.equal(evaluateTagCI(evidence({ runs: [attempted(initial)], jobs: jobs({ run_attempt: 2 }),
      confirmedRuns: [attempted("failure")] })).pass, true);
  }
  assert.equal(evaluateTagCI(evidence({ runs: [attempted("success")], jobs: jobs() })).pass, true);
  denied(evidence({ runs: [attempted("failure")], jobs: jobs() }));
});

test("WI-2 corroboration is invariant to job ordering and unrelated executions", () => {
  for (const name of NAMES) {
    for (const final of ["success", "failure", "cancelled", null]) {
      const input = retainedEvidence(name, "success", final);
      const before = structuredClone(input);
      const expected = evaluateTagCI(input);
      const transformed = { ...input, jobs: [...input.jobs,
        job("Unrelated", { id: 9998 }), job("Unrelated", { id: 9999, run_attempt: 2 })].reverse() };
      assert.deepEqual(evaluateTagCI(transformed), expected);
      assert.deepEqual(input, before);
    }
  }
});

for (const name of NAMES) {
  for (const conclusion of ["failure", "cancelled", null, "unknown"]) {
    test(`WI-2 CLI rejects retained ${name} when final conclusion is ${conclusion}`, () => {
      cliDenied(cli([pages("workflow_runs", [attempted("success")]), pages("jobs", borrowedJobs(name)),
        pages("workflow_runs", [attempted(conclusion)])]), name);
    });
  }
  test(`WI-2 CLI accepts retained ${name} using final success after initial failure`, () => {
    const result = cli([pages("workflow_runs", [attempted("failure")]), pages("jobs", borrowedJobs(name)),
      pages("workflow_runs", [attempted("success")])]);
    assert.equal(result.status, 0, result.output);
    assert.ok(result.output.includes(SHA), result.output);
    assert.doesNotMatch(result.output, /fixture-private-token/);
  });
}

test("WI-2 CLI preserves current-attempt successes despite unrelated final failure", () => {
  const result = cli([pages("workflow_runs", [attempted("success")]), pages("jobs", jobs({ run_attempt: 2 })),
    pages("workflow_runs", [attempted("failure")])]);
  assert.equal(result.status, 0, result.output);
  assert.ok(result.output.includes(SHA), result.output);
  assert.doesNotMatch(result.output, /fixture-private-token/);
});
