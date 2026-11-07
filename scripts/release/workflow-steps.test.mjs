import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { emptyAppcast } from "./appcast.mjs";

const root = new URL("../../", import.meta.url).pathname;
const workflow = readFileSync(join(root, ".github/workflows/release.yml"), "utf8");

/** The `run: |` script of the named step, de-indented, exactly as the runner receives it. */
export function stepScript(name) {
  const lines = workflow.split("\n");
  const start = lines.findIndex((line) => line === `      - name: ${name}`);
  assert.ok(start >= 0, `no step ${name}`);
  const run = lines.findIndex((line, index) => index > start && line === "        run: |");
  assert.ok(run > start, `step ${name} has no run block`);
  const body = [];
  for (const line of lines.slice(run + 1)) {
    if (line.trim() !== "" && !line.startsWith("          ")) break;
    body.push(line.slice(10));
  }
  return body.join("\n").replace(/\s+$/, "") + "\n";
}

/** Runs a step the way GitHub's macOS runner does (bash --noprofile --norc -eo pipefail) under /bin/bash 3.2. */
export function runStep(name, { env = {}, cwd = root, fakes = {} } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "picsee-step-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  for (const [command, script] of Object.entries(fakes)) {
    writeFileSync(join(bin, command), `#!/bin/bash\n${script}`);
    chmodSync(join(bin, command), 0o755);
  }
  const file = join(dir, "step.sh");
  writeFileSync(file, stepScript(name));
  const result = spawnSync("/bin/bash", ["--noprofile", "--norc", "-eo", "pipefail", file], {
    cwd, encoding: "utf8", env: { PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: dir, RUNNER_TEMP: dir, ...env },
  });
  return { ...result, dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("/bin/bash is the 3.2 shell the macos-26 runner has", () => {
  assert.match(execFileSync("/bin/bash", ["--version"], { encoding: "utf8" }), /version 3\.2\./);
});

for (const [tag, prerelease] of [["v0.0.1-rc.1", true], ["v0.0.1", false]]) {
  test(`the draft-release step calls gh with the full argument list for ${tag}`, () => {
    const step = runStep("Create the draft release", {
      env: { TAG: tag, VERSION: "0.0.1", BUILD: "312", SHA256: "ab".repeat(32), DMG: "/build/Picsee-0.0.1.dmg", GH_TOKEN: "token" },
      fakes: { gh: 'printf "%s\\n" "$@" > "$RUNNER_TEMP/gh-argv"\n' },
    });
    try {
      assert.equal(step.status, 0, step.stderr);
      const argv = readFileSync(join(step.dir, "gh-argv"), "utf8").trimEnd().split("\n");
      assert.deepEqual(argv, ["release", "create", tag, "/build/Picsee-0.0.1.dmg", "/build/Picsee-0.0.1.dmg.sha256",
        "--draft", "--verify-tag", "--title", `picsee 0.0.1 (${tag.slice(1)})`, "--notes-file", join(step.dir, "notes.md"),
        ...(prerelease ? ["--prerelease"] : [])]);
      const notes = readFileSync(join(step.dir, "notes.md"), "utf8");
      assert.match(notes, new RegExp(`${"ab".repeat(32)}  Picsee-0\\.0\\.1\\.dmg`));
      assert.match(notes, /build 312/);
      assert.doesNotMatch(notes, /\{\{/);
    } finally { step.cleanup(); }
  });
}

/** A repository with two commits on main and one side commit, like a tag pushed from a branch. */
function repository() {
  const dir = mkdtempSync(join(tmpdir(), "picsee-tag-"));
  const git = (...args) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", ...args],
    { cwd: dir, encoding: "utf8" }).trim();
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "project.yml"), "targets:\n  MadoApp:\n    settings:\n      base:\n        MARKETING_VERSION: 0.0.1\n");
  git("add", "project.yml"); git("commit", "-q", "-m", "a");
  const first = git("rev-parse", "HEAD");
  git("commit", "-q", "--allow-empty", "-m", "b");
  const second = git("rev-parse", "HEAD");
  git("update-ref", "refs/remotes/origin/main", second);
  git("switch", "-q", "-c", "side"); git("commit", "-q", "--allow-empty", "-m", "c");
  const side = git("rev-parse", "HEAD");
  git("switch", "-q", "main");
  return { dir, first, second, side };
}

test("the version step accepts a tag on main whose version matches and exports the build", () => {
  const repo = repository();
  try {
    for (const [tag, sha, build] of [["v0.0.1", repo.second, "2"], ["v0.0.1-rc.3", repo.first, "1"]]) {
      const env = join(repo.dir, `env-${tag}`);
      writeFileSync(env, "");
      const step = runStep("Check the tag against the project version", { cwd: repo.dir,
        env: { GITHUB_REF_NAME: tag, GITHUB_SHA: sha, GITHUB_ENV: env, DEVELOPMENT_TEAM: "GRT84NAK4T" } });
      try {
        assert.equal(step.status, 0, step.stderr);
        assert.deepEqual(readFileSync(env, "utf8").trim().split("\n"), [`TAG=${tag}`, "VERSION=0.0.1", `BUILD=${build}`]);
      } finally { step.cleanup(); }
    }
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});

test("the version step fails on a mismatched or malformed tag, a commit off main, or no team", () => {
  const repo = repository();
  try {
    const cases = [
      ["v0.0.2", repo.second, "GRT84NAK4T", /does not match MARKETING_VERSION/],
      ["v0.0.1", repo.side, "GRT84NAK4T", /is not on main/],
      ["v0.0.1-rc.0", repo.second, "GRT84NAK4T", /unexpected tag/],
      ["v0.0.1-beta", repo.second, "GRT84NAK4T", /unexpected tag/],
      ["0.0.1", repo.second, "GRT84NAK4T", /unexpected tag/],
      ["v0.0.1", repo.second, "", /DEVELOPMENT_TEAM is not set/],
    ];
    for (const [tag, sha, team, message] of cases) {
      const env = join(repo.dir, "env");
      writeFileSync(env, "");
      const step = runStep("Check the tag against the project version", { cwd: repo.dir,
        env: { GITHUB_REF_NAME: tag, GITHUB_SHA: sha, GITHUB_ENV: env, DEVELOPMENT_TEAM: team } });
      try {
        assert.notEqual(step.status, 0, `${tag} ${team}`);
        assert.match(step.stdout + step.stderr, message, tag);
        assert.equal(readFileSync(env, "utf8"), "", `${tag} must export nothing`);
      } finally { step.cleanup(); }
    }
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});

/** An origin with main (appcast.xml + the real appcast script) and a fresh clone to run the appcast step in. */
function appcastWorld() {
  const dir = mkdtempSync(join(tmpdir(), "picsee-appcast-"));
  const git = (cwd, ...args) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", ...args],
    { cwd, encoding: "utf8" }).trim();
  const origin = join(dir, "origin.git"), seed = join(dir, "seed"), work = join(dir, "work");
  git(dir, "init", "-q", "--bare", "-b", "main", origin);
  git(dir, "init", "-q", "-b", "main", seed);
  mkdirSync(join(seed, "scripts/release"), { recursive: true });
  writeFileSync(join(seed, "scripts/release/appcast.mjs"), readFileSync(join(root, "scripts/release/appcast.mjs")));
  writeFileSync(join(seed, "appcast.xml"), emptyAppcast());
  git(seed, "add", "."); git(seed, "commit", "-q", "-m", "main");
  git(seed, "remote", "add", "origin", origin); git(seed, "push", "-q", "origin", "main");
  git(dir, "clone", "-q", origin, work);
  const tools = join(dir, "sparkle");
  mkdirSync(join(tools, "bin"), { recursive: true });
  const signature = Buffer.alloc(64, 5).toString("base64");
  writeFileSync(join(tools, "bin/sign_update"), `#!/bin/bash\nprintf '%s\\n' "$@" > "${dir}/sign-argv"\ncat > "${dir}/sign-stdin"\nprintf '%s\\n' '${signature}'\n`);
  chmodSync(join(tools, "bin/sign_update"), 0o755);
  const dmg = join(dir, "Picsee-0.0.1.dmg");
  writeFileSync(dmg, Buffer.alloc(4321, 1));
  return { dir, origin, work, tools, dmg, signature, git };
}

/** A fake-command prologue that fails the command if any of `names` is still in its environment. */
const refuseSecrets = (...names) => `for v in ${names.join(" ")}; do
  if [[ -n "\${!v+x}" ]]; then printf '%s still set for %s\\n' "$v" "$(basename "$0") $*" >&2; exit 97; fi
done
`;

function runAppcast(world, { openPR = "" } = {}) {
  const ghLog = join(world.dir, "gh-calls");
  const guard = refuseSecrets("SPARKLE_ED_PRIVATE_KEY");
  return runStep("Sign the update and open the appcast PR", {
    cwd: world.work,
    env: { TAG: "v0.0.1", VERSION: "0.0.1", BUILD: "312", DMG: world.dmg, SPARKLE_TOOLS: world.tools,
      GITHUB_REPOSITORY: "anzchy/picsee", GH_TOKEN: "token", SPARKLE_ED_PRIVATE_KEY: "private-key-material",
      GIT_CONFIG_GLOBAL: "/dev/null" },
    // Everything after sign_update runs without the Sparkle key in its environment.
    fakes: {
      gh: `${guard}printf '%s\\n' "$*" >> "${ghLog}"\nif [[ "$1 $2" == "pr list" ]]; then printf '%s' '${openPR}'; fi\n`,
      git: `${guard}exec /usr/bin/git "$@"\n`,
      node: `${guard}exec "${process.execPath}" "$@"\n`,
    },
  });
}
const ghCalls = (world) => { try { return readFileSync(join(world.dir, "gh-calls"), "utf8").trim().split("\n"); } catch { return []; } };
const remoteFeed = (world) => world.git(world.origin, "show", "appcast/v0.0.1:appcast.xml");

test("the appcast step signs from stdin, pushes appcast/<tag> and opens one PR", () => {
  const world = appcastWorld();
  try {
    const step = runAppcast(world);
    try { assert.equal(step.status, 0, step.stderr); } finally { step.cleanup(); }
    assert.equal(readFileSync(join(world.dir, "sign-stdin"), "utf8"), "private-key-material");
    assert.doesNotMatch(readFileSync(join(world.dir, "sign-argv"), "utf8"), /private-key-material/);
    const feed = remoteFeed(world);
    assert.match(feed, /url="https:\/\/github\.com\/anzchy\/picsee\/releases\/download\/v0\.0\.1\/Picsee-0\.0\.1\.dmg" length="4321"/);
    assert.ok(feed.includes(`sparkle:edSignature="${world.signature}"`));
    assert.equal(world.git(world.origin, "rev-parse", "main"), world.git(world.origin, "rev-parse", "appcast/v0.0.1~1"));
    const calls = ghCalls(world);
    assert.equal(calls.filter((c) => c.startsWith("pr create")).length, 1, calls.join("\n"));
    assert.match(calls.find((c) => c.startsWith("pr create")), /--base main --head appcast\/v0\.0\.1/);
  } finally { rmSync(world.dir, { recursive: true, force: true }); }
});

test("a rerun of the same tag replaces its appcast branch and reuses the open PR", () => {
  const world = appcastWorld();
  try {
    const first = runAppcast(world); first.cleanup();
    assert.equal(first.status, 0, first.stderr);
    const before = world.git(world.origin, "rev-parse", "appcast/v0.0.1");
    // A fresh runner: a new clone, while the branch and its PR already exist.
    rmSync(world.work, { recursive: true, force: true });
    world.git(world.dir, "clone", "-q", world.origin, world.work);
    writeFileSync(world.dmg, Buffer.alloc(5000, 2));
    const again = runAppcast(world, { openPR: "17" });
    try { assert.equal(again.status, 0, again.stderr); } finally { again.cleanup(); }
    assert.notEqual(world.git(world.origin, "rev-parse", "appcast/v0.0.1"), before);
    assert.match(remoteFeed(world), /length="5000"/);
    assert.equal((remoteFeed(world).match(/<item>/g) ?? []).length, 1);
    assert.equal(ghCalls(world).filter((c) => c.startsWith("pr create")).length, 1, "no second PR");
  } finally { rmSync(world.dir, { recursive: true, force: true }); }
});

test("a rerun after a failed PR creation pushes over the branch and opens the PR", () => {
  const world = appcastWorld();
  try {
    const first = runAppcast(world); first.cleanup();
    rmSync(join(world.dir, "gh-calls"));
    rmSync(world.work, { recursive: true, force: true });
    world.git(world.dir, "clone", "-q", world.origin, world.work);
    const again = runAppcast(world);
    try { assert.equal(again.status, 0, again.stderr); } finally { again.cleanup(); }
    assert.equal(ghCalls(world).filter((c) => c.startsWith("pr create")).length, 1);
  } finally { rmSync(world.dir, { recursive: true, force: true }); }
});

test("the appcast PR body says that merging offers the build to every installed copy", () => {
  const world = appcastWorld();
  try {
    const step = runAppcast(world);
    try { assert.equal(step.status, 0, step.stderr); } finally { step.cleanup(); }
    const create = ghCalls(world).find((c) => c.startsWith("pr create"));
    assert.match(create, /offers picsee 0\.0\.1 \(312\) to every installed copy that has update checks on/);
    assert.match(create, /release candidate, close this PR unless you mean a general rollout/);
    assert.match(create, /Merge only after publishing the draft release v0\.0\.1/);
  } finally { rmSync(world.dir, { recursive: true, force: true }); }
});

for (const [name, target] of [["Notarise the app", "APP"], ["Notarise the DMG", "DMG"]]) {
  test(`"${name}" unsets the Apple ID and app-specific password after notarisation, before stapling`, () => {
    const dir = mkdtempSync(join(tmpdir(), "picsee-notary-"));
    try {
      mkdirSync(join(dir, "scripts/release"), { recursive: true });
      // The helper itself must still receive the credentials.
      writeFileSync(join(dir, "scripts/release/notarize.sh"),
        `#!/bin/bash\nprintf 'notarize %s %s\\n' "$APPLE_ID" "$APPLE_APP_SPECIFIC_PASSWORD" >> "$RUNNER_TEMP/calls"\n`);
      chmodSync(join(dir, "scripts/release/notarize.sh"), 0o755);
      const guard = refuseSecrets("APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD");
      const log = (command) => `${guard}printf '${command} %s\\n' "$*" >> "$RUNNER_TEMP/calls"\n`;
      writeFileSync(join(dir, "artifact"), "x");
      const step = runStep(name, { cwd: dir,
        env: { [target]: join(dir, "artifact"), APP: join(dir, "artifact"), APPLE_ID: "owner@example.com",
          APPLE_APP_SPECIFIC_PASSWORD: "abcd-efgh-ijkl-mnop", DEVELOPMENT_TEAM: "GRT84NAK4T" },
        fakes: { xcrun: log("xcrun"), spctl: log("spctl"), ditto: `printf 'ditto\\n' >> "$RUNNER_TEMP/calls"\n` } });
      try {
        assert.equal(step.status, 0, step.stderr);
        const calls = readFileSync(join(step.dir, "calls"), "utf8").trim().split("\n");
        assert.ok(calls.includes("notarize owner@example.com abcd-efgh-ijkl-mnop"), calls.join("\n"));
        assert.ok(calls.some((c) => c.startsWith("xcrun stapler staple")), calls.join("\n"));
      } finally { step.cleanup(); }
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}

/** A fake `security` that logs each call and the mode of any file it imports. */
const fakeSecurity = (team) => `log="$RUNNER_TEMP/security-calls"
printf '%s\\n' "$*" >> "$log"
case "$1" in
  create-keychain) : > "$4" ;;
  import) printf 'mode %s\\n' "$(stat -f %Lp "$2")" >> "$log" ;;
  find-identity) printf '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Owner (${team})"\\n' ;;
  list-keychains) printf '    "%s"\\n' "$HOME/login.keychain-db" ;;
esac
`;

test("the certificate step keeps the .p12 private and short-lived and exports the team's identity", () => {
  const env = join(mkdtempSync(join(tmpdir(), "picsee-env-")), "env");
  writeFileSync(env, "");
  const p12 = Buffer.from("fake p12 bytes").toString("base64");
  const step = runStep("Import the Developer ID certificate", {
    env: { GITHUB_ENV: env, DEVELOPMENT_TEAM: "GRT84NAK4T", DEVELOPER_ID_P12_BASE64: p12,
      DEVELOPER_ID_P12_PASSWORD: "p12-password", KEYCHAIN_PASSWORD: "keychain-password" },
    fakes: { security: fakeSecurity("GRT84NAK4T") },
  });
  try {
    assert.equal(step.status, 0, step.stderr);
    const calls = readFileSync(join(step.dir, "security-calls"), "utf8");
    assert.match(calls, /^mode 600$/m, "the decoded .p12 is created owner-only");
    assert.doesNotMatch(calls, new RegExp(p12.replace(/[+/=]/g, "\\$&")), "the base64 secret never reaches argv");
    assert.equal(spawnSync("/bin/test", ["-e", join(step.dir, "developer-id.p12")]).status, 1, "the .p12 is removed");
    const exported = readFileSync(env, "utf8");
    assert.match(exported, /^KEYCHAIN=.*picsee-release\.keychain-db$/m);
    assert.match(exported, /^IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567$/m);
  } finally { step.cleanup(); rmSync(dirname(env), { recursive: true, force: true }); }
});

test("the certificate step fails when no Developer ID identity belongs to the team", () => {
  const env = join(mkdtempSync(join(tmpdir(), "picsee-env-")), "env");
  writeFileSync(env, "");
  const step = runStep("Import the Developer ID certificate", {
    env: { GITHUB_ENV: env, DEVELOPMENT_TEAM: "GRT84NAK4T", DEVELOPER_ID_P12_BASE64: "eA==",
      DEVELOPER_ID_P12_PASSWORD: "p", KEYCHAIN_PASSWORD: "k" },
    fakes: { security: fakeSecurity("OTHERTEAM1") },
  });
  try {
    assert.notEqual(step.status, 0);
    assert.match(step.stdout, /no Developer ID Application identity for team GRT84NAK4T/);
    assert.doesNotMatch(readFileSync(env, "utf8"), /IDENTITY=/);
  } finally { step.cleanup(); rmSync(dirname(env), { recursive: true, force: true }); }
});

test("keychain clean-up reports a failed deletion instead of swallowing it", () => {
  for (const [exit, expected] of [[0, 0], [1, 1]]) {
    const keychain = join(mkdtempSync(join(tmpdir(), "picsee-kc-")), "picsee-release.keychain-db");
    writeFileSync(keychain, "");
    const step = runStep("Delete the temporary keychain", { env: { KEYCHAIN: keychain },
      fakes: { security: `printf '%s\\n' "$*" >> "$RUNNER_TEMP/security-calls"\nexit ${exit}\n` } });
    try {
      assert.equal(step.status, expected, step.stdout + step.stderr);
      assert.equal(readFileSync(join(step.dir, "security-calls"), "utf8"), `delete-keychain ${keychain}\n`);
      if (expected) assert.match(step.stdout, /::error::could not delete the temporary keychain/);
    } finally { step.cleanup(); rmSync(dirname(keychain), { recursive: true, force: true }); }
  }
  const none = runStep("Delete the temporary keychain", { fakes: { security: "exit 1\n" } });
  try { assert.equal(none.status, 0, none.stderr); } finally { none.cleanup(); }
});
