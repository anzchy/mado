import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const root = new URL("../../", import.meta.url).pathname;
const helper = join(root, "scripts/release/appcast-pr-body.mjs");
const lint = join(root, "scripts/agents/ui-parity-pr-body-lint.mjs");
const fixture = ["mado-v1.2.3-rc.4", "1.2.3", "2468"];
const lanes = ["package-tests", "package-coverage", "app-tests", "unsigned-build", "node-tooling", "ledger", "diff-check", "design-check", "audit", "device-smoke"];
const warning = (tag, version, build) => `Adds ${tag} to appcast-mado.xml. Merging this offers Mado ${version} (${build}) to every installed copy that has update checks on, as soon as it lands on main; GitHub's pre-release flag does not filter the feed. For a release candidate, close this PR unless you mean a general rollout. Merge only after publishing the draft release ${tag}: the enclosure URL works once the release is public.`;
const ownerAction = "Owner action: after every bot create or update, close and reopen this PR once as yourself (or push a commit as a human) so PR body Gates and CI run. A body edit alone does not trigger CI. Follow [the release runbook](docs/release/README.md#what-the-owner-does) and wait for those checks before publishing or merging.";
const generate = (args) => spawnSync(process.execPath, [helper, ...args], { encoding: "utf8", env: process.env });

function repository() {
  const dir = mkdtempSync(join(tmpdir(), "mado-pr-body-"));
  const git = (...args) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", ...args], { cwd: dir, encoding: "utf8" }).trim();
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "appcast-mado.xml"), "<rss/>\n");
  git("add", "appcast-mado.xml"); git("commit", "-q", "-m", "base");
  const base = git("rev-parse", "HEAD");
  git("update-ref", "refs/remotes/origin/main", base);
  writeFileSync(join(dir, "appcast-mado.xml"), "<rss><channel/></rss>\n");
  git("add", "appcast-mado.xml"); git("commit", "-q", "-m", "appcast item");
  assert.equal(git("diff", "--name-only", "origin/main...HEAD"), "appcast-mado.xml");
  return { dir, base, head: git("rev-parse", "HEAD"), cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
const lintBody = (dir, file) => spawnSync(process.execPath, [lint, "--base", "origin/main", "--body-file", file], { cwd: dir, encoding: "utf8" });

test("generated appcast-only body passes the real trusted lint with honest Gates and original warning", () => {
  const repo = repository();
  try {
    const file = join(repo.dir, "body.md");
    const run = generate([...fixture, file, repo.base, repo.head]);
    assert.equal(run.status, 0, run.stderr);
    const body = readFileSync(file, "utf8");
    assert.ok(body.includes(warning(...fixture)), "complete original warning retained");
    assert.match(body, /^Device-Smoke: n\/a — .+appcast-mado\.xml/m);
    // fix1 explicitly replaces the previous n/a convention with the documented DAILY form.
    assert.ok(body.includes(`Ledger-Gardener: DAILY ${repo.base.slice(0, 7)}..${repo.head.slice(0, 7)} (covered by the daily sweep)`));
    assert.ok(body.includes(ownerAction), "pin the owner trigger and runbook note");
    const rows = body.split("\n").filter((line) => /^\| (?:package-tests|package-coverage|app-tests|unsigned-build|node-tooling|ledger|diff-check|design-check|audit|device-smoke) \|/.test(line));
    assert.equal(rows.length, 10);
    for (const lane of lanes) {
      const row = rows.find((line) => line.startsWith(`| ${lane} |`));
      assert.ok(row, `${lane} present`);
      assert.match(row, /^\| [\w-]+ \| (N\/A|NOT RUN) \| — \| [^|]+\S \|$/, `${lane} has an honest status and reason`);
      if (row.includes("| NOT RUN |")) assert.match(row, /At body generation:/);
    }
    const checked = lintBody(repo.dir, file);
    assert.equal(checked.status, 0, checked.stderr);
    assert.match(checked.stdout, /UI-Parity PR body: PASS/);
    writeFileSync(file, body.replace(/^## Gates\s*$[\s\S]*?(?=^## |$(?![\s\S]))/m, ""));
    const negative = lintBody(repo.dir, file);
    assert.equal(negative.status, 1);
    assert.match(negative.stderr, /missing ## Gates table/);
  } finally { repo.cleanup(); }
});

test("body generation repeats byte-for-byte and reflects different tag, version and build", () => {
  const repo = repository();
  try {
    const first = join(repo.dir, "first.md"), second = join(repo.dir, "second.md"), changed = join(repo.dir, "changed.md");
    for (const file of [first, second]) assert.equal(generate([...fixture, file, repo.base, repo.head]).status, 0);
    assert.equal(readFileSync(first, "utf8"), readFileSync(second, "utf8"));
    const alternative = ["mado-v2.0.0", "2.0.0", "3579"];
    assert.equal(generate([...alternative, changed, repo.base, repo.head]).status, 0);
    const body = readFileSync(changed, "utf8");
    assert.ok(body.includes(warning(...alternative)));
    for (const old of fixture) assert.ok(!body.includes(old), `no stale ${old}`);
    assert.equal(lintBody(repo.dir, changed).status, 0);
    const changedBase = "a".repeat(40), changedHead = "b".repeat(40);
    assert.equal(generate([...fixture, changed, changedBase, changedHead]).status, 0);
    const changedRangeBody = readFileSync(changed, "utf8");
    assert.ok(changedRangeBody.includes("Ledger-Gardener: DAILY aaaaaaa..bbbbbbb (covered by the daily sweep)"));
    assert.ok(!changedRangeBody.includes(`${repo.base.slice(0, 7)}..${repo.head.slice(0, 7)}`));
  } finally { repo.cleanup(); }
});

test("invalid CLI arguments neither create nor overwrite a body", () => {
  const dir = mkdtempSync(join(tmpdir(), "mado-body-guard-"));
  try {
    const file = join(dir, "body.md");
    const base = "a".repeat(40), head = "b".repeat(40);
    const invalid = [
      [], fixture, ["mado-v1.2.3\n## Gates", "1.2.3", "2468", file, base, head],
      ["mado-v1.2.3", "2.0.0", "2468", file, base, head],
      ["mado-v1.2.3", "1.2.3", "0", file, base, head], ["mado-v1.2.3", "1.2.3", "oops", file, base, head],
      [...fixture, file], [...fixture, file, base], [...fixture, file, base, head, "unexpected"],
      [...fixture, file, "abcdef0", head], [...fixture, file, base, "abcdef0"],
      [...fixture, file, "z".repeat(40), head], [...fixture, file, base, "z".repeat(40)],
      [...fixture, file, `${base}\n`, head], [...fixture, file, base, `${head}\n`],
    ];
    for (const args of invalid) {
      rmSync(file, { force: true });
      const run = generate(args);
      assert.notEqual(run.status, 0, `reject ${JSON.stringify(args)}`);
      assert.match(run.stderr, /usage:|invalid/i);
      assert.equal(existsSync(file), false);
      writeFileSync(file, "sentinel");
      assert.notEqual(generate(args).status, 0);
      assert.equal(readFileSync(file, "utf8"), "sentinel");
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("body write failures exit unsuccessfully", () => {
  const dir = mkdtempSync(join(tmpdir(), "mado-body-write-"));
  try {
    const run = generate([...fixture, dir, "a".repeat(40), "b".repeat(40)]);
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /write|EISDIR/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("release runbook documents owner Actions permission and rerun body refresh", () => {
  const readme = readFileSync(join(root, "docs/release/README.md"), "utf8");
  assert.match(readme, /Settings → Actions → General/);
  assert.match(readme, /Allow GitHub Actions to create and approve pull requests/);
  assert.match(readme, /rerun[^\n]*(?:refresh|updat)[^\n]*body/i);
  const owner = readme.split("## What the owner does\n")[1].split("## When a run fails")[0];
  assert.match(owner, /After every workflow create or update/);
  assert.match(owner, /close and reopen[^\n]*once[^\n]*human|close and reopen[^\n]*once[^\n]*yourself/i);
  assert.match(owner, /push a commit as a human/);
  assert.match(owner, /GITHUB_TOKEN[^\n]*suppress[^\n]*pull_request/);
  assert.match(owner, /body edit alone[^\n]*does not[^\n]*CI/i);
  assert.match(owner, /Wait for[^\n]*PR body Gates[^\n]*CI[^\n]*before[^\n]*publishing or merging/);
  assert.ok(owner.indexOf("close and reopen") < owner.indexOf("**Publish the draft."));
});
