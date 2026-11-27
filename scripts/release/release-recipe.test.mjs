import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

// #861 fix 1: docs/release/README.md's local recipe for the PR-time Release build, run as written against fake
// scripts. It must read the step values as data (a path with spaces survives), stop with a non-zero status at the
// first failing step, and run the build under the heavy lock.
const readme = readFileSync(new URL("../../docs/release/README.md", import.meta.url), "utf8");
const section = readme.slice(readme.indexOf("## Pull-request Release build"));

function recipe() {
  const start = section.indexOf("To run the same build and checks locally");
  assert.ok(start >= 0, "the local recipe paragraph");
  const block = /```sh\n([\s\S]*?)```/.exec(section.slice(start));
  assert.ok(block, "the local recipe block");
  return block[1];
}

// Each fake step logs its argv and $APP; version and build write values the way release-build.sh does.
const FAKE_STEP = `#!/bin/bash
printf '%s|APP=%s|VERSION=%s|BUILD=%s|LOCK=%s\\n' "$*" "\${APP:-}" "\${VERSION:-}" "\${BUILD:-}" "\${IN_LOCK:-}" >> "$LOG"
[[ "$*" == "\${FAIL_STEP:-none}" ]] && exit 7
case "$1" in
  version) printf 'VERSION=0.0.2\\nBUILD=312\\n' >> "$GITHUB_ENV" ;;
  sparkle-tools) printf 'SPARKLE_TOOLS=%s\\n' "$RUNNER_TEMP/sparkle-2.10.0" >> "$GITHUB_ENV" ;;
  build) printf 'APP=%s\\n' "$PWD/.build/dd-release/Build/Products/Release/Mado.app" >> "$GITHUB_ENV" ;;
esac
exit 0
`;
const FAKE_LOCK = `#!/bin/bash
printf 'heavy-lock %s\\n' "$*" >> "$LOG"
IN_LOCK=yes exec "$@"
`;

function runRecipe(shell, env = {}) {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "mado-recipe-")));
  const work = join(base, "task roots", "wt");
  mkdirSync(join(work, "scripts/release"), { recursive: true });
  for (const [file, body] of [["scripts/release/release-build.sh", FAKE_STEP], ["scripts/heavy-lock.sh", FAKE_LOCK]]) {
    writeFileSync(join(work, file), body); chmodSync(join(work, file), 0o755);
  }
  const log = join(base, "log");
  writeFileSync(log, "");
  const run = spawnSync(shell, ["-c", recipe()], { cwd: work, encoding: "utf8",
    env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HOME: base, LOG: log, ...env } });
  const lines = readFileSync(log, "utf8").trimEnd().split("\n").filter(Boolean);
  rmSync(base, { recursive: true, force: true });
  return { ...run, lines, work };
}

for (const shell of ["/bin/bash", "/bin/zsh"].filter(existsSync)) {
  test(`#861 fix 1: the local recipe runs every step in order, the build under the heavy lock (${shell})`, () => {
    const run = runRecipe(shell);
    assert.equal(run.status, 0, "the recipe must finish");
    const app = `${run.work}/.build/dd-release/Build/Products/Release/Mado.app`;
    assert.deepEqual(run.lines, [
      "version|APP=|VERSION=|BUILD=|LOCK=",
      "sparkle-tools|APP=|VERSION=0.0.2|BUILD=312|LOCK=",
      "heavy-lock scripts/release/release-build.sh build ad-hoc",
      "build ad-hoc|APP=|VERSION=0.0.2|BUILD=312|LOCK=yes",
      ...["licence", "check-entitlements", "check-identity", "check-package"]
        .map(step => `${step}|APP=${app}|VERSION=0.0.2|BUILD=312|LOCK=`),
    ]);
  });

  test(`#861 fix 1: a failing step stops the local recipe with a non-zero status (${shell})`, () => {
    for (const failing of ["check-entitlements", "check-package", "build ad-hoc"]) {
      const run = runRecipe(shell, { FAIL_STEP: failing });
      assert.notEqual(run.status, 0, failing);
      assert.ok(run.lines.at(-1).startsWith(`${failing}|`), `${failing} is the last step run: ${run.lines.at(-1)}`);
    }
  });
}

test("#861 fix 1: the runbook states what the ad-hoc build and the rehearsal each cover", () => {
  assert.match(section, /notarisation and stapling[^\n]*only when `notarize_app` is set/);
  assert.match(section, /Gatekeeper[^\n]*only on the tag run/);
  assert.match(section, /`scripts\/ci\/native-inputs\.mjs`/, "the filter list names the classifier it matches");
  assert.match(readme, /`commit_sha`[^\n]*(before|predates)[^\n]*`scripts\/release\/release-build\.sh`/,
    "a rehearsal of a commit without the shared script stops at the input check");
});
