// #861: CI's path-filtered PR-time Release build. It reuses scripts/release/release-build.sh, the release workflow's
// build and checks, ad-hoc signed and without secrets, and runs only when the trusted classifier's release-contents
// filter (scripts/release/release-contents.mjs) says a pull request touched what decides the shipped app.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
const ci = read(".github/workflows/ci.yml");
const release = read(".github/workflows/release.yml");
const jobBlock = (workflow, id) => {
  const match = workflow.match(new RegExp(`^  ${id}:\\n([\\s\\S]*?)(?=^  [a-z][a-z0-9-]*:\\n|^[a-z]|(?![\\s\\S]))`, "m"));
  assert.ok(match, `job ${id} exists`);
  return match[1];
};
const job = () => jobBlock(ci, "release-build");
const ifExpression = () => job().match(/^    if: (.+)$/m)?.[1];
const scriptCalls = (text) => [...text.matchAll(/scripts\/release\/release-build\.sh ([a-z-]+(?: [a-z-]+)?)$/gm)].map((m) => m[1]);

/** Evaluates the job's `if:` for one run, translating the few GitHub expression operators it may use. */
function runs({ event, releaseContents }) {
  const expression = ifExpression();
  assert.ok(expression, "the job has an if:");
  assert.match(expression, /^[\w.' =!&|()-]+$/, `only plain comparisons: ${expression}`);
  const js = expression.replace(/github\.event_name/g, JSON.stringify(event))
    .replace(/needs\.changes\.outputs\.release_contents/g, JSON.stringify(releaseContents))
    .replace(/!=/g, "!==").replace(/([^!=])==/g, "$1===");
  assert.doesNotMatch(js, /[a-z_]+\.[a-z_]+/, `unknown context in ${expression}`);
  return Function(`return (${js});`)();
}

test("#861: the classifier job exports release_contents, and a base without the classifier runs the build", () => {
  const changes = jobBlock(ci, "changes");
  assert.match(changes, /^      release_contents: \$\{\{ steps\.classify\.outputs\.release_contents \}\}$/m);
  assert.match(changes, /^            echo 'release_contents=true' >> "\$GITHUB_OUTPUT"$/m);
});

test("#861: the job runs only for pull requests whose trusted classification is not release_contents=false", () => {
  const block = job();
  assert.match(block, /^    name: Release build \(ad-hoc\)$/m, "a static name: a skipped job reports a readable check");
  assert.match(block, /^    needs: changes$/m, "it waits only for the classifier, never for the native jobs");
  assert.equal(runs({ event: "pull_request", releaseContents: "true" }), true);
  assert.equal(runs({ event: "pull_request", releaseContents: "false" }), false);
  assert.equal(runs({ event: "pull_request", releaseContents: "" }), true, "an older base classifier without the output runs it");
  for (const event of ["push", "workflow_dispatch"]) {
    for (const releaseContents of ["true", "false", ""]) assert.equal(runs({ event, releaseContents }), false, `${event} ${releaseContents}`);
  }
});

test("#861: skipped, not pending: a job-level condition, no workflow-level path filter", () => {
  const on = ci.slice(0, ci.indexOf("\nconcurrency:"));
  assert.doesNotMatch(on, /paths(-ignore)?:/, "a path-filtered workflow would leave a required check pending");
  assert.doesNotMatch(job(), /continue-on-error/);
});

test("#861: the job uses no secrets, no team variable and no write permission", () => {
  const block = job();
  assert.doesNotMatch(block, /secrets\.|vars\.|DEVELOPER_ID|KEYCHAIN|IDENTITY|APPLE_|SPARKLE_ED/);
  assert.match(block, /^    permissions:\n      contents: read\n(?!      )/m, "only contents: read");
  assert.match(block, /persist-credentials: false/);
  assert.match(block, /fetch-depth: 0/, "the build number is the commit count, as on the tag path");
  assert.match(block, /^    runs-on: macos-26$/m);
  assert.match(block, /^    timeout-minutes: \d+$/m);
});

test("#861: the job runs the release workflow's own build and checks, ad-hoc, in the same order", () => {
  const block = job();
  assert.match(block, /uses: \.\/\.github\/actions\/xcode-setup/);
  assert.doesNotMatch(block, /xcodebuild|check-package\.mjs|check-entitlements\.mjs|built-product\.mjs/,
    "no copied build or check command: only the shared script");
  const releaseCalls = scriptCalls(release).map((call) => (call === "build developer-id" ? "build ad-hoc" : call));
  assert.deepEqual(releaseCalls, ["sparkle-tools", "build ad-hoc", "licence", "check-entitlements", "check-identity", "check-package"]);
  assert.deepEqual(scriptCalls(block), ["version", ...releaseCalls]);
});

test("#861: the Agent tooling job is untouched by the Release build", () => {
  assert.doesNotMatch(read(".github/workflows/pr-body.yml"), /release-build|release_contents/);
});
