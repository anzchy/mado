import assert from "node:assert/strict";
import { copyFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

// #861: the shared Release build. release.yml (Developer ID) and CI's PR-time Release build (ad-hoc) both run it.
const root = new URL("../../", import.meta.url).pathname;
const script = join(root, "scripts/release/release-build.sh");

/** Runs one subcommand under the runner's /bin/bash 3.2 with fake tools first on PATH; returns the result and files. */
function run(args, { env = {}, fakes = {}, cwd } = {}) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "mado-release-build-")));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  for (const [command, body] of Object.entries(fakes)) {
    writeFileSync(join(bin, command), `#!/bin/bash\n${body}`);
    chmodSync(join(bin, command), 0o755);
  }
  const work = cwd ?? join(dir, "work");
  mkdirSync(work, { recursive: true });
  const githubEnv = join(dir, "github-env"), summary = join(dir, "summary");
  writeFileSync(githubEnv, ""); writeFileSync(summary, "");
  const result = spawnSync("/bin/bash", ["--noprofile", "--norc", "-eo", "pipefail", script, ...args], {
    cwd: work, encoding: "utf8",
    env: { PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: dir, RUNNER_TEMP: dir,
      GITHUB_ENV: githubEnv, GITHUB_STEP_SUMMARY: summary, ...env },
  });
  const read = (file) => (existsSync(file) ? readFileSync(file, "utf8") : "");
  return { ...result, dir, work, githubEnv: read(githubEnv), summary: read(summary), file: (name) => read(join(dir, name)),
    cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

// Records argv and produces the app the way a successful xcodebuild does.
const XCODEBUILD = 'printf "%s\\n" "$@" > "$RUNNER_TEMP/xcodebuild-argv"\nmkdir -p "$PWD/.build/dd-release/Build/Products/Release/Mado.app"\n';
const COMMON = ["build", "-scheme", "Mado", "-configuration", "Release", "-destination", "generic/platform=macOS",
  "-derivedDataPath", ".build/dd-release", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "ENABLE_HARDENED_RUNTIME=YES",
  "DEPLOYMENT_POSTPROCESSING=YES", "STRIP_INSTALLED_PRODUCT=YES", "CURRENT_PROJECT_VERSION=312", "CODE_SIGN_STYLE=Manual"];

test("#861: the Developer ID build passes the release flags, the identity, the team and the keychain", () => {
  const step = run(["build", "developer-id"], { fakes: { xcodebuild: XCODEBUILD },
    env: { BUILD: "312", IDENTITY: "ABC123", KEYCHAIN: "/tmp/k.keychain-db", DEVELOPMENT_TEAM: "GRT84NAK4T" } });
  try {
    assert.equal(step.status, 0, step.stderr);
    assert.deepEqual(step.file("xcodebuild-argv").trimEnd().split("\n"), [...COMMON, "CODE_SIGN_IDENTITY=ABC123",
      "DEVELOPMENT_TEAM=GRT84NAK4T", "OTHER_CODE_SIGN_FLAGS=--keychain /tmp/k.keychain-db --timestamp"]);
    assert.equal(step.githubEnv, `APP=${step.work}/.build/dd-release/Build/Products/Release/Mado.app\n`);
    assert.doesNotMatch(step.stdout + step.summary, /Ad-hoc/);
  } finally { step.cleanup(); }
});

test("#861: the ad-hoc build shares every other flag, signs with no identity and states its limit", () => {
  const step = run(["build", "ad-hoc"], { fakes: { xcodebuild: XCODEBUILD }, env: { BUILD: "312" } });
  try {
    assert.equal(step.status, 0, step.stderr);
    assert.deepEqual(step.file("xcodebuild-argv").trimEnd().split("\n"), [...COMMON, "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="]);
    assert.match(step.githubEnv, /^APP=.*\/\.build\/dd-release\/Build\/Products\/Release\/Mado\.app$/m);
    for (const text of [step.stdout, step.summary]) {
      assert.match(text, /Ad-hoc signed Release build: no Developer ID identity and no secrets\./);
      assert.match(text, /not covered here: Developer ID signatures and their _CodeSignature entries/);
      assert.match(text, /rehearsal[^\n]*#860/);
      // #861 fix 1 (M1): the rehearsal notarises and staples only when asked to, and only the tag run checks Gatekeeper.
      assert.match(text, /notarisation and stapling[^\n]*only when notarize_app is set/);
      assert.match(text, /Gatekeeper[^\n]*only on the tag run/);
      assert.doesNotMatch(text, /covers those[^\n]*Gatekeeper|Gatekeeper[^\n]*rehearsal[^\n]*covers/);
    }
  } finally { step.cleanup(); }
});

test("#861: the build refuses missing inputs, an unknown mode, or a run that produced no app", () => {
  const cases = [
    [["build", "ad-hoc"], {}, 1, /needs BUILD/],
    [["build", "developer-id"], { BUILD: "1", KEYCHAIN: "k", DEVELOPMENT_TEAM: "T" }, 1, /needs IDENTITY/],
    [["build", "developer-id"], { BUILD: "1", IDENTITY: "I", DEVELOPMENT_TEAM: "T" }, 1, /needs KEYCHAIN/],
    [["build", "developer-id"], { BUILD: "1", IDENTITY: "I", KEYCHAIN: "k" }, 1, /needs DEVELOPMENT_TEAM/],
    [["build", "signed"], { BUILD: "1" }, 2, /usage/],
    [["build"], { BUILD: "1" }, 2, /usage/],
    [["deploy"], {}, 2, /usage/],
  ];
  for (const [args, env, status, message] of cases) {
    const step = run(args, { fakes: { xcodebuild: XCODEBUILD }, env });
    try {
      assert.equal(step.status, status, `${args.join(" ")} ${JSON.stringify(env)}: ${step.stderr}`);
      assert.match(step.stderr, message);
      assert.equal(step.file("xcodebuild-argv"), "", "xcodebuild must not run");
    } finally { step.cleanup(); }
  }
  for (const xcodebuild of ['exit 65\n', 'true\n']) {
    const step = run(["build", "ad-hoc"], { fakes: { xcodebuild }, env: { BUILD: "1" } });
    try {
      assert.notEqual(step.status, 0, xcodebuild);
      assert.equal(step.githubEnv, "", "no APP for a failed build");
    } finally { step.cleanup(); }
  }
});

test("#861: Sparkle's tools are the pinned 2.10.0 tarball, checked by SHA-256 before unpacking", () => {
  const step = run(["sparkle-tools"], { fakes: {
    curl: 'printf "%s\\n" "$@" > "$RUNNER_TEMP/curl-argv"\nwhile [[ $# -gt 0 ]]; do [[ $1 == --output ]] && echo tarball > "$2"; shift; done\n',
    shasum: 'printf "%s\\n" "$@" > "$RUNNER_TEMP/shasum-argv"\ncat > "$RUNNER_TEMP/shasum-stdin"\n',
    tar: 'printf "%s\\n" "$@" > "$RUNNER_TEMP/tar-argv"\ndest="${@: -1}"\nmkdir -p "$dest/bin"\nprintf "#!/bin/sh\\n" > "$dest/bin/sign_update"\nchmod +x "$dest/bin/sign_update"\nprintf "MIT\\nEXTERNAL LICENSES\\n" > "$dest/LICENSE"\n',
  } });
  try {
    assert.equal(step.status, 0, step.stderr);
    assert.ok(step.file("curl-argv").includes("https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz\n"));
    assert.ok(step.file("curl-argv").startsWith("--fail\n"));
    assert.equal(step.file("shasum-argv"), "-a\n256\n--check\n");
    assert.equal(step.file("shasum-stdin"), `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  ${step.dir}/Sparkle-2.10.0.tar.xz\n`);
    assert.equal(step.githubEnv, `SPARKLE_TOOLS=${step.dir}/sparkle-2.10.0\n`);
  } finally { step.cleanup(); }
  const bad = run(["sparkle-tools"], { fakes: { curl: 'while [[ $# -gt 0 ]]; do [[ $1 == --output ]] && echo x > "$2"; shift; done\n',
    shasum: 'exit 1\n', tar: 'touch "$RUNNER_TEMP/tar-ran"\n' } });
  try {
    assert.notEqual(bad.status, 0);
    assert.equal(existsSync(join(bad.dir, "tar-ran")), false, "a checksum mismatch stops before unpacking");
    assert.equal(bad.githubEnv, "");
  } finally { bad.cleanup(); }
});

test("#861: the licence step copies Sparkle's LICENSE only into a 2.10.0 app", () => {
  for (const [embedded, ok] of [["2.10.0", true], ["2.9.0", false]]) {
    const dir = mkdtempSync(join(tmpdir(), "mado-licence-"));
    const app = join(dir, "Mado.app"), tools = join(dir, "tools");
    mkdirSync(tools); writeFileSync(join(tools, "LICENSE"), "Sparkle licence\n");
    mkdirSync(join(app, "Contents/Resources"), { recursive: true });
    const step = run(["licence"], { env: { APP: app, SPARKLE_TOOLS: tools }, fakes: { plutil: `echo ${embedded}\n` } });
    try {
      const copied = join(app, "Contents/Resources/ThirdPartyNotices/Sparkle-2.10.0-LICENSE.txt");
      assert.equal(step.status === 0, ok, step.stderr);
      assert.equal(existsSync(copied), ok);
      if (ok) assert.equal(readFileSync(copied, "utf8"), "Sparkle licence\n");
      else assert.match(step.stderr, /embedded Sparkle is 2\.9\.0, licence is for 2\.10\.0/);
    } finally { step.cleanup(); rmSync(dir, { recursive: true, force: true }); }
  }
});

test("#861: each check runs the release workflow's exact command on the built app", () => {
  const env = { APP: "/b/Mado.app", VERSION: "0.0.2", BUILD: "312" };
  const fakes = { node: 'printf "%s\\n" "$@" > "$RUNNER_TEMP/node-argv"\n' };
  for (const [name, argv] of [
    ["check-entitlements", ["scripts/release/check-entitlements.mjs", "/b/Mado.app", "--configuration", "release", "--expect-bundle-id", "io.github.anzchy.mado"]],
    ["check-identity", ["scripts/name-checks/built-product.mjs", "/b/Mado.app", "--release"]],
    ["check-package", ["scripts/release/check-package.mjs", "/b/Mado.app", "--require-sparkle-licence", "--expect-version", "0.0.2", "--expect-build", "312"]],
  ]) {
    const step = run([name], { env, fakes });
    try {
      assert.equal(step.status, 0, step.stderr);
      assert.deepEqual(step.file("node-argv").trimEnd().split("\n"), argv, name);
    } finally { step.cleanup(); }
    const missing = run([name], { env: {}, fakes });
    try {
      assert.equal(missing.status, 1, name);
      assert.match(missing.stderr, /needs APP/);
      assert.equal(missing.file("node-argv"), "");
    } finally { missing.cleanup(); }
  }
  const failing = run(["check-package"], { env, fakes: { node: "exit 1\n" } });
  try { assert.equal(failing.status, 1, "a failing check fails the step"); } finally { failing.cleanup(); }
});

test("#861: version reads MARKETING_VERSION and counts the commits for the build number", () => {
  const repo = mkdtempSync(join(tmpdir(), "mado-version-"));
  const git = (...args) => execFileSync("git", ["-c", "user.name=T", "-c", "user.email=t@example.com", ...args], { cwd: repo });
  try {
    git("init", "-q", "-b", "main");
    writeFileSync(join(repo, "project.yml"), "targets:\n  MadoApp:\n    settings:\n      base:\n        MARKETING_VERSION: 0.0.3\n");
    git("add", "project.yml"); git("commit", "-q", "-m", "one");
    git("commit", "-q", "--allow-empty", "-m", "two"); git("commit", "-q", "--allow-empty", "-m", "three");
    const step = run(["version"], { cwd: repo });
    try {
      assert.equal(step.status, 0, step.stderr);
      assert.equal(step.githubEnv, "VERSION=0.0.3\nBUILD=3\n");
    } finally { step.cleanup(); }
    writeFileSync(join(repo, "project.yml"), "MARKETING_VERSION: next\n");
    const bad = run(["version"], { cwd: repo });
    try {
      assert.equal(bad.status, 1);
      assert.match(bad.stderr, /MARKETING_VERSION/);
      assert.equal(bad.githubEnv, "");
    } finally { bad.cleanup(); }
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

// Failing-first for the PR-time check (#861 AC-1): the real checks on a real ad-hoc signed bundle pass, and fail
// once a new embedded file or a new entitlement appears without the allow-lists changing.
const sparkleLicence = "Copyright (c) 2006-2013 Andy Matuschak.\nPermission is hereby granted\nEXTERNAL LICENSES\nbsdiff\n";
// The app embeds the Capture helper where Xcode puts it, ad-hoc signed with App/CaptureHelper/CaptureHelper.entitlements
// (plus `helperExtra`), as the Release build does (#861 fix 1).
function signedApp(extraEntitlements = "", { helperExtra = "", helper = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "mado-adhoc-app-"));
  const app = join(dir, "Mado.app");
  const vars = { DEVELOPMENT_LANGUAGE: "en", EXECUTABLE_NAME: "Mado", PRODUCT_BUNDLE_IDENTIFIER: "io.github.anzchy.mado",
    PRODUCT_NAME: "Mado", MARKETING_VERSION: "0.0.2", CURRENT_PROJECT_VERSION: "312", MADO_DISABLE_UPDATES: "NO" };
  const fill = (text) => text.replace(/\$\(([A-Z_]+)\)/g, (_, name) => vars[name] ?? assert.fail(`unknown ${name}`));
  const files = {
    "Contents/Info.plist": fill(readFileSync(join(root, "App/Info.plist"), "utf8")),
    "Contents/PkgInfo": "APPL????",
    "Contents/Resources/AppIcon.icns": "icns",
    "Contents/Resources/en.lproj/Localizable.strings": "\"a\" = \"b\";",
    "Contents/Resources/ThirdPartyNotices/Sparkle-2.10.0-LICENSE.txt": sparkleLicence,
  };
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(app, path)), { recursive: true });
    writeFileSync(join(app, path), content);
  }
  mkdirSync(join(app, "Contents/MacOS"));
  copyFileSync("/usr/bin/true", join(app, "Contents/MacOS/Mado"));
  if (helper) {
    const helperApp = join(app, "Contents/Library/LoginItems/MadoCaptureHelper.app");
    const helperVars = { ...vars, EXECUTABLE_NAME: "MadoCaptureHelper", PRODUCT_NAME: "MadoCaptureHelper",
      PRODUCT_BUNDLE_IDENTIFIER: "io.github.anzchy.mado.capture-helper" };
    const helperInfo = readFileSync(join(root, "App/CaptureHelper/Info.plist"), "utf8")
      .replace(/\$\(([A-Z_]+)\)/g, (_, name) => helperVars[name] ?? assert.fail(`unknown ${name}`));
    mkdirSync(join(helperApp, "Contents/MacOS"), { recursive: true });
    writeFileSync(join(helperApp, "Contents/Info.plist"), helperInfo);
    writeFileSync(join(helperApp, "Contents/PkgInfo"), "APPL????");
    copyFileSync("/usr/bin/true", join(helperApp, "Contents/MacOS/MadoCaptureHelper"));
    writeFileSync(join(dir, "helper.entitlements"), readFileSync(join(root, "App/CaptureHelper/CaptureHelper.entitlements"), "utf8")
      .replace("</dict>", `${helperExtra}</dict>`));
    execFileSync("/usr/bin/codesign", ["-f", "-s", "-", "--entitlements", join(dir, "helper.entitlements"), helperApp], { stdio: "ignore" });
  }
  const entitlements = fill(readFileSync(join(root, "App/Resources/Mado.entitlements"), "utf8"))
    .replace("</dict>", `${extraEntitlements}</dict>`);
  writeFileSync(join(dir, "app.entitlements"), entitlements);
  execFileSync("/usr/bin/codesign", ["-f", "-s", "-", "--entitlements", join(dir, "app.entitlements"), app], { stdio: "ignore" });
  return { app, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
const real = (name, app) => run([name], { cwd: root, env: { APP: app, VERSION: "0.0.2", BUILD: "312" } });

test("#861 AC-1: a new embedded file or entitlement fails the shared checks until the allow-lists change",
  { skip: process.platform !== "darwin" && "needs codesign" }, () => {
    const clean = signedApp();
    try {
      for (const name of ["check-entitlements", "check-package"]) {
        const step = real(name, clean.app);
        try { assert.equal(step.status, 0, `${name}: ${step.stdout}${step.stderr}`); } finally { step.cleanup(); }
      }
      writeFileSync(join(clean.app, "Contents/Resources/helper-settings.json"), "{}");
      const extraFile = real("check-package", clean.app);
      try {
        assert.equal(extraFile.status, 1);
        assert.match(extraFile.stderr, /^FAIL Contents\/Resources\/helper-settings\.json: data file$/m);
      } finally { extraFile.cleanup(); }
    } finally { clean.cleanup(); }
    const camera = signedApp("<key>com.apple.security.device.camera</key><true/>");
    try {
      const step = real("check-entitlements", camera.app);
      try {
        assert.equal(step.status, 1);
        assert.match(step.stderr, /^FAIL unexpected entitlement com\.apple\.security\.device\.camera$/m);
      } finally { step.cleanup(); }
    } finally { camera.cleanup(); }
  });

test("#861 fix 1: a new Capture helper entitlement, or no helper, fails the shared entitlement check",
  { skip: process.platform !== "darwin" && "needs codesign" }, () => {
    const clean = signedApp();
    try {
      const step = real("check-entitlements", clean.app);
      try {
        assert.equal(step.status, 0, `${step.stdout}${step.stderr}`);
        assert.match(step.stdout, /^PASS release entitlements for the Capture helper$/m);
      } finally { step.cleanup(); }
    } finally { clean.cleanup(); }
    const camera = signedApp("", { helperExtra: "<key>com.apple.security.device.camera</key><true/>" });
    try {
      const step = real("check-entitlements", camera.app);
      try {
        assert.equal(step.status, 1);
        assert.match(step.stderr, /^FAIL Capture helper: unexpected entitlement com\.apple\.security\.device\.camera$/m);
      } finally { step.cleanup(); }
    } finally { camera.cleanup(); }
    const none = signedApp("", { helper: false });
    try {
      const step = real("check-entitlements", none.app);
      try {
        assert.equal(step.status, 1);
        assert.match(step.stderr, /^FAIL missing Capture helper Contents\/Library\/LoginItems\/MadoCaptureHelper\.app$/m);
      } finally { step.cleanup(); }
    } finally { none.cleanup(); }
  });
