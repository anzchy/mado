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
const generate = (args) => spawnSync(process.execPath, [helper, ...args], { encoding: "utf8", env: process.env });

function repository() {
  const dir = mkdtempSync(join(tmpdir(), "mado-pr-body-"));
  const git = (...args) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", ...args], { cwd: dir, encoding: "utf8" }).trim();
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "appcast-mado.xml"), "<rss/>\n");
  git("add", "appcast-mado.xml"); git("commit", "-q", "-m", "base");
  git("update-ref", "refs/remotes/origin/main", git("rev-parse", "HEAD"));
  writeFileSync(join(dir, "appcast-mado.xml"), "<rss><channel/></rss>\n");
  git("add", "appcast-mado.xml"); git("commit", "-q", "-m", "appcast item");
  assert.equal(git("diff", "--name-only", "origin/main...HEAD"), "appcast-mado.xml");
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
const lintBody = (dir, file) => spawnSync(process.execPath, [lint, "--base", "origin/main", "--body-file", file], { cwd: dir, encoding: "utf8" });

test("generated appcast-only body passes the real trusted lint with honest Gates and original warning", () => {
  const repo = repository();
  try {
    const file = join(repo.dir, "body.md");
    const run = generate([...fixture, file]);
    assert.equal(run.status, 0, run.stderr);
    const body = readFileSync(file, "utf8");
    assert.ok(body.includes(warning(...fixture)), "complete original warning retained");
    assert.match(body, /^Device-Smoke: n\/a — .+appcast-mado\.xml/m);
    assert.match(body, /^Ledger-Gardener: n\/a — .+ledger.+/m);
    const rows = body.split("\n").filter((line) => /^\| (?:package-tests|package-coverage|app-tests|unsigned-build|node-tooling|ledger|diff-check|design-check|audit|device-smoke) \|/.test(line));
    assert.equal(rows.length, 10);
    for (const lane of lanes) {
      const row = rows.find((line) => line.startsWith(`| ${lane} |`));
      assert.ok(row, `${lane} present`);
      assert.match(row, /^\| [\w-]+ \| (N\/A|NOT RUN) \| — \| [^|]+\S \|$/, `${lane} has an honest status and reason`);
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
    for (const file of [first, second]) assert.equal(generate([...fixture, file]).status, 0);
    assert.equal(readFileSync(first, "utf8"), readFileSync(second, "utf8"));
    const alternative = ["mado-v2.0.0", "2.0.0", "3579"];
    assert.equal(generate([...alternative, changed]).status, 0);
    const body = readFileSync(changed, "utf8");
    assert.ok(body.includes(warning(...alternative)));
    for (const old of fixture) assert.ok(!body.includes(old), `no stale ${old}`);
    assert.equal(lintBody(repo.dir, changed).status, 0);
  } finally { repo.cleanup(); }
});

test("invalid CLI arguments neither create nor overwrite a body", () => {
  const dir = mkdtempSync(join(tmpdir(), "mado-body-guard-"));
  try {
    const file = join(dir, "body.md");
    const invalid = [
      [], fixture, ["mado-v1.2.3\n## Gates", "1.2.3", "2468", file],
      ["mado-v1.2.3", "2.0.0", "2468", file],
      ["mado-v1.2.3", "1.2.3", "0", file], ["mado-v1.2.3", "1.2.3", "oops", file],
      [...fixture, file, "unexpected"],
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
    const run = generate([...fixture, dir]);
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /write|EISDIR/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("release runbook documents owner Actions permission and rerun body refresh", () => {
  const readme = readFileSync(join(root, "docs/release/README.md"), "utf8");
  assert.match(readme, /Settings → Actions → General/);
  assert.match(readme, /Allow GitHub Actions to create and approve pull requests/);
  assert.match(readme, /rerun[^\n]*(?:refresh|updat)[^\n]*body/i);
});
