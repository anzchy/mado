#!/usr/bin/env node
/** Require the tag SHA's latest main push of ci.yml to prove both release-critical jobs. */
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED = ["Walking skeleton", "App tests"];
const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0;
const result = (sha, pass, detail, names = REQUIRED) => ({
  pass, reason: `SHA ${sha}; jobs ${names.join(", ")}: ${detail}`,
});

/** Highest run ID, not update time: rerunning an older run cannot supersede a newer push. */
function selectRun(runs, sha) {
  if (!Array.isArray(runs) || runs.some((run) => !run || !positiveInteger(run.id))) return null;
  if (new Set(runs.map((run) => run.id)).size !== runs.length) return null;
  return runs.filter((run) => run.head_sha === sha && run.head_branch === "main" &&
    run.event === "push" && run.path === ".github/workflows/ci.yml")
    .sort((a, b) => b.id - a.id)[0] ?? null;
}

/**
 * Pure API-JSON decision. `jobs` is the selected run's complete filter=all response.
 * Each name's most recent execution counts; retain earlier successes only after a green final run.
 * `confirmedRuns` is a second complete run listing, taken after loading jobs, to detect races.
 */
export function evaluateTagCI(input) {
  const { sha = "unknown", runs, jobs, confirmedRuns = runs } = input ?? {};
  const fail = (detail, names) => result(sha, false, detail, names);
  if (typeof sha !== "string" || !/^[0-9a-f]{40}$/i.test(sha)) return fail("invalid commit SHA");
  const run = selectRun(runs, sha);
  if (!run) return fail("no unambiguous ci.yml main push run for this commit");
  if (!positiveInteger(run.run_attempt)) return fail("invalid run attempt");
  if (run.status !== "completed") return fail(`run ${run.id} is not completed`);
  const confirmed = selectRun(confirmedRuns, sha);
  if (!confirmed || confirmed.id !== run.id || confirmed.run_attempt !== run.run_attempt ||
      confirmed.status !== run.status) return fail("latest CI run changed while loading evidence; retry release");
  if (!Array.isArray(jobs) || jobs.some((job) => !job || !positiveInteger(job.id)) ||
      new Set(jobs.map((job) => job.id)).size !== jobs.length) return fail("invalid or duplicate job evidence");
  const failures = [];
  for (const name of REQUIRED) {
    const executions = jobs.filter((job) => job.name === name);
    if (!executions.length) { failures.push(`${name}: required job is missing`); continue; }
    if (executions.some((job) => job.run_id !== run.id || job.head_sha !== sha ||
        !positiveInteger(job.run_attempt) || job.run_attempt > run.run_attempt)) {
      failures.push(`${name}: job does not match the run, commit or attempt`); continue;
    }
    const attempt = Math.max(...executions.map((job) => job.run_attempt));
    const latest = executions.filter((job) => job.run_attempt === attempt);
    if (latest.length !== 1) { failures.push(`${name}: ambiguous job evidence in attempt ${attempt}`); continue; }
    if (latest[0].status !== "completed" || latest[0].conclusion !== "success") {
      failures.push(`${name}: run ${run.id} attempt ${attempt} did not complete successfully (${String(latest[0].conclusion)})`);
    } else if (attempt < run.run_attempt && confirmed.conclusion !== "success") {
      failures.push(`${name}: cannot retain attempt ${attempt} success without a successful final run conclusion`);
    }
  }
  if (failures.length) return fail(failures.join("; "));
  return result(sha, true, `success in run ${run.id}, latest attempt ${run.run_attempt}`);
}

/** gh follows Link headers; slurp preserves page boundaries so incomplete data fails closed. */
function apiEntries(endpoint, key) {
  const output = execFileSync("gh", ["api", "--method", "GET", "--paginate", "--slurp",
    "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", endpoint], {
    encoding: "utf8", timeout: 30000, maxBuffer: 16 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"],
  });
  const pages = JSON.parse(output);
  if (!Array.isArray(pages) || !pages.length) throw new Error("invalid API pages");
  const count = pages[0]?.total_count;
  if (!Number.isSafeInteger(count) || count < 0 || pages.some((page) =>
    page?.total_count !== count || !Array.isArray(page[key]))) throw new Error("inconsistent API pages");
  const entries = pages.flatMap((page) => page[key]);
  if (entries.length !== count) throw new Error("incomplete API pages");
  return entries;
}

function main() {
  const sha = process.env.GITHUB_SHA || "unknown";
  let decision;
  try {
    const repo = process.env.GITHUB_REPOSITORY;
    if (!/^[0-9a-f]{40}$/i.test(sha) || !/^[A-Za-z0-9][A-Za-z0-9-]*\/[\w.-]+$/.test(repo ?? "") ||
        !(process.env.GH_TOKEN || process.env.GITHUB_TOKEN)) {
      decision = result(sha, false, "GITHUB_SHA, GITHUB_REPOSITORY and job token are required");
    } else {
      const endpoint = `repos/${repo}/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha=${sha}&per_page=100`;
      const runs = apiEntries(endpoint, "workflow_runs");
      const run = selectRun(runs, sha);
      // Incomplete/no runs need no job request; the same pure decision formats the denial.
      if (!run || run.status !== "completed" || !positiveInteger(run.run_attempt)) {
        decision = evaluateTagCI({ sha, runs, jobs: [] });
      } else {
        const jobs = apiEntries(`repos/${repo}/actions/runs/${run.id}/jobs?filter=all&per_page=100`, "jobs");
        const confirmedRuns = apiEntries(endpoint, "workflow_runs");
        decision = evaluateTagCI({ sha, runs, jobs, confirmedRuns });
      }
    }
  } catch {
    // Child-process/API diagnostics may contain credentials. Emit only our fixed context.
    decision = result(sha, false, "GitHub Actions API request failed or returned incomplete/invalid JSON");
  }
  const message = decision.reason.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
  if (decision.pass) console.log(message);
  else console.error(`::error::${message}`);
  process.exitCode = decision.pass ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
