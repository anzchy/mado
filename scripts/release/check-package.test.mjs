import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { checkInfo, checkPackage, classifyPath, SPARKLE_LICENCE_PATH } from "./check-package.mjs";

const samples = ["alley", "gate", "hillside", "lakehouse", "lakeside", "temple"];
const bundle = "Contents/Resources/MadoKit_MadoMacUI.bundle/Contents/Resources";
const sparkleLicence = "Copyright (c) 2006-2013 Andy Matuschak.\nPermission is hereby granted\nEXTERNAL LICENSES\nbsdiff\n";

/** A clean release-shaped bundle: what the real build plus the workflow's licence copy produce. */
function cleanTree() {
  return {
    "Contents/Info.plist": "<plist/>",
    "Contents/PkgInfo": "APPL????",
    "Contents/MacOS/Mado": "\u0000binary",
    "Contents/Resources/AppIcon.icns": "icns",
    "Contents/Resources/Assets.car": "car",
    "Contents/Resources/en.lproj/Localizable.strings": "\"a\" = \"b\";",
    "Contents/Resources/zh-Hans.lproj/Localizable.strings": "\"a\" = \"乙\";",
    "Contents/Resources/en.lproj/Localizable.stringsdict": "<plist/>",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle": "bin",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate": "bin",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/ReleaseNotesColorStyle.css": "body{}",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/SUUpdateAlert.nib": "nib",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer": "bin",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater": "bin",
    "Contents/_CodeSignature/CodeResources": "<plist/>",
    [`${bundle}/../Info.plist`]: "<plist/>",
    ...Object.fromEntries(samples.map((name) => [`${bundle}/${name}.jpg`, "jpeg"])),
    [`${bundle}/PROVENANCE.md`]: "Unsplash",
    [SPARKLE_LICENCE_PATH]: sparkleLicence,
  };
}

function materialise(tree) {
  const root = mkdtempSync(join(tmpdir(), "picsee-package-")) + "/Mado.app";
  for (const [path, content] of Object.entries(tree)) {
    const file = join(root, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, content);
  }
  return root;
}

function withTree(tree, body) {
  const root = materialise(tree);
  try { return body(root); } finally { rmSync(dirname(root), { recursive: true, force: true }); }
}

test("a clean release bundle passes, including the B4 samples, Sparkle and its licence", () => {
  withTree(cleanTree(), (root) => assert.deepEqual(checkPackage(root, { requireSparkleLicence: true }), []));
});

test("every forbidden path is reported, each by its own path", () => {
  const forbidden = [
    "Contents/Resources/evidence/strings.txt",
    "Contents/Resources/docs/PICSEE_ARCHITECTURE.md",
    "Contents/Resources/design/DESIGN.md",
    "Contents/Resources/TestAssets/synthetic/landscape-3x2.png",
    "Contents/Resources/node_modules/rea-agents/package.json",
    "Contents/Resources/.stitch/generated/a.png",
    "Contents/Resources/states/settings.html",
    "Contents/Resources/prototype.css",
    "Contents/Resources/Developer.p12",
    "Contents/Resources/AuthKey_ABC.p8",
    "Contents/Resources/sparkle-private-key.txt",
    "Contents/Resources/server.pem",
    "Contents/Resources/.env",
    "Contents/Resources/.env.local",
    "Contents/Resources/.DS_Store",
    "Contents/Resources/deep-dispatch.json",
    "Contents/Resources/PICVIEW_ANALYSIS.md",
    "Contents/Resources/analyze_picview.py",
    "Contents/Resources/holiday.jpg",
    "Contents/Resources/alley.jpg",
    `${bundle}/IMG_0042.HEIC`,
    "Contents/Resources/notes.md",
    "Contents/Resources/script.mjs",
  ];
  const tree = cleanTree();
  for (const path of forbidden) tree[path] = "x";
  withTree(tree, (root) => {
    const problems = checkPackage(root, { requireSparkleLicence: true });
    const reported = problems.map((problem) => problem.path).sort();
    assert.deepEqual(reported, [...forbidden].sort());
    for (const problem of problems) assert.ok(problem.reason.length > 0, problem.path);
  });
});

test("classifyPath allows only the listed exceptions", () => {
  assert.equal(classifyPath("Contents/Frameworks/Sparkle.framework/Versions/B/Resources/ReleaseNotesColorStyle.css"), null);
  assert.notEqual(classifyPath("Contents/Resources/ReleaseNotesColorStyle.css"), null, "css outside Sparkle");
  assert.equal(classifyPath(`${bundle}/PROVENANCE.md`), null);
  assert.notEqual(classifyPath("Contents/Resources/PROVENANCE.md"), null, "provenance outside the sample bundle");
  for (const name of samples) assert.equal(classifyPath(`${bundle}/${name}.jpg`), null, name);
  assert.notEqual(classifyPath(`${bundle}/alley.png`), null);
  assert.notEqual(classifyPath(`${bundle}/seventh.jpg`), null);
  assert.equal(classifyPath(SPARKLE_LICENCE_PATH), null);
  assert.notEqual(classifyPath("Contents/Resources/other-notes.txt"), null);
  assert.equal(classifyPath("Contents/Resources/zh-Hans.lproj/Localizable.strings"), null);
});

test("build paths inside any file are developer paths", () => {
  for (const leak of ["/Users/jack/Documents/mac-app/picsee/App/Access/", "/Users/runner/work/picsee/picsee/.build/x", "/home/runner/work/x", "/private/var/folders/yc/x/T/y"]) {
    const tree = cleanTree();
    tree["Contents/MacOS/Mado"] = `\u0000\u0001prefix${leak}suffix\u0000`;
    withTree(tree, (root) => {
      const problems = checkPackage(root);
      assert.equal(problems.length, 1, leak);
      assert.equal(problems[0].path, "Contents/MacOS/Mado");
      assert.match(problems[0].reason, /developer path/);
    });
  }
});

test("the Sparkle licence is required in release mode and must be the full file", () => {
  const missing = cleanTree();
  delete missing[SPARKLE_LICENCE_PATH];
  withTree(missing, (root) => {
    assert.deepEqual(checkPackage(root), []);
    const problems = checkPackage(root, { requireSparkleLicence: true });
    assert.deepEqual(problems.map((p) => p.path), [SPARKLE_LICENCE_PATH]);
  });
  const truncated = cleanTree();
  truncated[SPARKLE_LICENCE_PATH] = "Copyright (c) 2006-2013 Andy Matuschak.\n";
  withTree(truncated, (root) => {
    const problems = checkPackage(root, { requireSparkleLicence: true });
    assert.deepEqual(problems.map((p) => p.path), [SPARKLE_LICENCE_PATH]);
    assert.match(problems[0].reason, /EXTERNAL LICENSES/);
  });
});

test("a missing bundle root is an error, not an empty pass", () => {
  assert.throws(() => checkPackage(join(tmpdir(), "picsee-no-such-app.app")), /not a directory/);
});

const goodInfo = {
  CFBundleIdentifier: "io.github.anzchy.picsee",
  CFBundleShortVersionString: "0.0.1",
  CFBundleVersion: "312",
  SUFeedURL: "https://raw.githubusercontent.com/anzchy/picsee/main/appcast.xml",
  SUPublicEDKey: "XaqePs6p9CwP2w+sJAC+eAKcExNITNS9W54AtIZGpSs=",
  SUEnableSystemProfiling: false,
  SUEnableInstallerLauncherService: true,
};

test("checkInfo accepts the shipped Sparkle settings and expected versions", () => {
  assert.deepEqual(checkInfo(goodInfo, { expectedName: "Picsee", version: "0.0.1", build: "312" }), []);
  assert.deepEqual(checkInfo(goodInfo, { expectedName: "Picsee" }), []);
});

test("checkInfo rejects each changed Sparkle or version setting", () => {
  const cases = [
    [{ SUEnableAutomaticChecks: true }, /SUEnableAutomaticChecks/],
    [{ SUEnableAutomaticChecks: false }, /SUEnableAutomaticChecks/],
    [{ SUEnableSystemProfiling: true }, /SUEnableSystemProfiling/],
    [{ SUEnableSystemProfiling: "NO" }, /SUEnableSystemProfiling/],
    [{ SUEnableInstallerLauncherService: false }, /SUEnableInstallerLauncherService/],
    [{ SUEnableDownloaderService: true }, /SUEnableDownloaderService/],
    [{ SUFeedURL: "http://raw.githubusercontent.com/anzchy/picsee/main/appcast.xml" }, /SUFeedURL/],
    [{ SUPublicEDKey: "short" }, /SUPublicEDKey/],
    [{ CFBundleShortVersionString: "0.0.2" }, /CFBundleShortVersionString/],
    [{ CFBundleVersion: "1" }, /CFBundleVersion/],
  ];
  for (const [patch, pattern] of cases) {
    const problems = checkInfo({ ...goodInfo, ...patch }, { expectedName: "Picsee", version: "0.0.1", build: "312" });
    assert.equal(problems.length, 1, JSON.stringify(patch));
    assert.match(problems[0], pattern);
  }
});

test("framework symlinks are checked as links, never read, and must stay inside the bundle", () => {
  const tree = cleanTree();
  const root = materialise(tree);
  try {
    const framework = join(root, "Contents/Frameworks/Sparkle.framework");
    symlinkSync("B", join(framework, "Versions/Current"));
    symlinkSync("Versions/Current/Sparkle", join(framework, "Sparkle"));
    symlinkSync("Versions/Current/Resources", join(framework, "Resources"));
    assert.deepEqual(checkPackage(root, { requireSparkleLicence: true }), []);
    symlinkSync("/Users/jack/Documents/secret", join(root, "Contents/Resources/escape"));
    symlinkSync("../../../outside", join(root, "Contents/Resources/climb"));
    symlinkSync("B", join(root, "Contents/Resources/notes.md"));
    const problems = checkPackage(root, { requireSparkleLicence: true });
    assert.deepEqual(problems.map((p) => p.path).sort(),
      ["Contents/Resources/climb", "Contents/Resources/escape", "Contents/Resources/notes.md"]);
    assert.match(problems.find((p) => p.path.endsWith("escape")).reason, /outside the bundle/);
  } finally { rmSync(dirname(root), { recursive: true, force: true }); }
});

const layout = readFileSync(new URL("./fixtures/release-layout-0.0.1.txt", import.meta.url), "utf8").replaceAll("MacOS/Picsee", "MacOS/Mado")
  .replaceAll("PicseeKit_PicseeMacUI", "MadoKit_MadoMacUI")
  .split("\n").filter((line) => line && !line.startsWith("#"));

test("every entry of the real 0.0.1 release layout is allowed", () => {
  assert.ok(layout.length > 70);
  for (const path of layout) assert.equal(classifyPath(path), null, path);
});

test("anything outside the release layout fails, including look-alikes of allowed files", () => {
  for (const path of [
    "Contents/Resources/Unknown.bin", "Contents/MacOS/helper", "Contents/Frameworks/Other.framework/Other",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/theme.css",
    "Contents/Frameworks/Sparkle.framework/Versions/A/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Downloader",
    "Contents/Resources/fr.lproj/Localizable.strings", "Contents/Resources/en.lproj/Secrets.strings",
    "Contents/Resources/MadoKit_MadoMacUI.bundle/Contents/Resources/sub/alley.jpg",
    "Contents/Resources/ThirdPartyNotices/other.txt", "Contents/Info.plist.bak",
    "Contents/Resources/MadoKit_MadoMacUI.bundle/Contents/_CodeSignature/CodeEntitlements",
    "Contents/Resources/MadoKit_MadoMacUI.bundle/_CodeSignature/CodeDirectory",
    "Contents/Resources/Other.bundle/Contents/_CodeSignature/CodeDirectory", "Contents/_CodeSignature/CodeDirectory",
  ]) assert.notEqual(classifyPath(path), null, path);
});

test("denied names, directories and extensions match in any case", () => {
  const cases = [
    ["Contents/Resources/.ENV", /environment file/], ["Contents/Resources/.Env.Local", /environment file/],
    ["Contents/Resources/Evidence/payload.bin", /evidence/i], ["Contents/Resources/DOCS/notes", /documentation/],
    ["Contents/Resources/tool.BASH", /script/], ["Contents/Resources/tool.bash", /script/],
    ["Contents/Resources/Key.P12", /certificate/], ["Contents/Resources/.ds_store", /Finder/],
  ];
  for (const [path, reason] of cases) assert.match(classifyPath(path) ?? "", reason, path);
});

const PEM = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIA==\n-----END PRIVATE KEY-----\n";
const OPENSSH = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n";

function infoXml(info) {
  const value = (v) => typeof v === "boolean" ? `<${v}/>` : `<string>${v}</string>`;
  return `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>` +
    Object.entries(info).map(([k, v]) => `<key>${k}</key>${value(v)}`).join("") + "</dict></plist>\n";
}

/** Runs the CLI on an otherwise valid release bundle with `edit` applied; returns exit code and stderr. */
function cli(edit = () => {}) {
  const tree = cleanTree();
  tree["Contents/Info.plist"] = infoXml(goodInfo);
  const root = materialise(tree);
  try {
    const framework = join(root, "Contents/Frameworks/Sparkle.framework");
    symlinkSync("B", join(framework, "Versions/Current"));
    for (const name of ["Sparkle", "Resources", "Autoupdate", "Updater.app", "XPCServices"]) {
      symlinkSync(`Versions/Current/${name}`, join(framework, name));
    }
    edit(root, framework);
    const result = spawnSync(process.execPath, [new URL("./check-package.mjs", import.meta.url).pathname, root,
      "--require-sparkle-licence", "--expect-version", "0.0.1", "--expect-build", "312"], { encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
  } finally { rmSync(dirname(root), { recursive: true, force: true }); }
}

test("the release CLI refuses the old feed even in an otherwise clean fixture", () => {
  const result = cli();
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /SUFeedURL.*#552/);
});

test("the CLI fails closed on each auditor regression and names the path", () => {
  const write = (root, path, content = "x") => { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), content); };
  const cases = [
    [(root) => write(root, "Contents/Resources/.ENV"), ["Contents/Resources/.ENV"]],
    [(root) => write(root, "Contents/Resources/Evidence/payload.bin"), ["Contents/Resources/Evidence/payload.bin"]],
    [(root) => write(root, "Contents/Resources/signing", PEM), ["Contents/Resources/signing"]],
    [(root) => write(root, "Contents/Resources/tool.bash", "#!/bin/bash\n"), ["Contents/Resources/tool.bash"]],
    [(root) => write(root, "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/theme.css", "a{}"),
      ["Contents/Frameworks/Sparkle.framework/Versions/B/Resources/theme.css"]],
    [(root) => write(root, "Contents/Resources/en.lproj/Localizable.strings", `"a" = "b";\n${PEM}`),
      ["Contents/Resources/en.lproj/Localizable.strings"], /private key/],
    [(root) => write(root, "Contents/Resources/Assets.car", `car\u0000${OPENSSH}`), ["Contents/Resources/Assets.car"], /private key/],
    [(root) => {
      writeFileSync(join(dirname(root), "outside"), "secret");
      symlinkSync("../..", join(root, "Contents/Resources/alias"));
      symlinkSync("alias/../outside", join(root, "Contents/Resources/escape"));
    }, ["Contents/Resources/alias", "Contents/Resources/escape"]],
    // The OS follows alias before "..", so escape reaches the outside sibling: it is an escape, not a broken link.
    [(root) => {
      writeFileSync(join(dirname(root), "outside"), "secret");
      symlinkSync("../..", join(root, "Contents/Resources/alias"));
      symlinkSync("alias/../outside", join(root, "Contents/Resources/escape"));
    }, ["Contents/Resources/escape"], /outside the bundle/],
    // Allowed names chained into an escape: Resources -> the app root, then Sparkle -> Resources/../… beside the app.
    [(root, framework) => {
      write(dirname(root), "Versions/B/Sparkle", "OUTSIDE");
      rmSync(join(framework, "Resources")); symlinkSync("../../..", join(framework, "Resources"));
      rmSync(join(framework, "Sparkle")); symlinkSync("Resources/../Versions/B/Sparkle", join(framework, "Sparkle"));
    }, ["Contents/Frameworks/Sparkle.framework/Resources", "Contents/Frameworks/Sparkle.framework/Sparkle"],
      [/expected Versions\/Current\/Resources/, /outside the bundle/]],
    // Inside the bundle but not the target Sparkle ships: every framework link is pinned to its exact target.
    [(root, framework) => { rmSync(join(framework, "Sparkle")); symlinkSync("Versions/B/Sparkle", join(framework, "Sparkle")); },
      ["Contents/Frameworks/Sparkle.framework/Sparkle"], /expected Versions\/Current\/Sparkle/],
    [(root, framework) => {
      mkdirSync(join(framework, "Versions/C"));
      rmSync(join(framework, "Versions/Current")); symlinkSync("C", join(framework, "Versions/Current"));
    }, ["Contents/Frameworks/Sparkle.framework/Versions/Current"], /expected B/],
    [(root, framework) => {
      mkdirSync(join(dirname(root), "elsewhere"), { recursive: true });
      rmSync(join(framework, "Versions/Current"));
      symlinkSync("../../../../../elsewhere", join(framework, "Versions/Current"));
    }, ["Contents/Frameworks/Sparkle.framework/Versions/Current"], /outside the bundle/],
    [(root, framework) => { rmSync(join(framework, "XPCServices")); symlinkSync("Versions/Current/Missing", join(framework, "XPCServices")); },
      ["Contents/Frameworks/Sparkle.framework/XPCServices"], /broken/],
    [(root, framework) => { rmSync(join(framework, "Autoupdate")); symlinkSync("Autoupdate", join(framework, "Autoupdate")); },
      ["Contents/Frameworks/Sparkle.framework/Autoupdate"], /cycle/],
  ];
  const failures = [];
  for (const [edit, paths, reason] of cases) {
    const result = cli(edit);
    if (result.status !== 1) failures.push(`${paths}: exit ${result.status} ${result.stdout}${result.stderr}`);
    paths.forEach((path, index) => {
      const line = result.stderr.split("\n").find((l) => l.startsWith(`FAIL ${path}: `));
      const expected = Array.isArray(reason) ? reason[index] : reason;
      if (!line) failures.push(`${path} not named`);
      else if (expected && !expected.test(line)) failures.push(`${line} (expected ${expected})`);
    });
  }
  assert.deepEqual(failures, []);
});
