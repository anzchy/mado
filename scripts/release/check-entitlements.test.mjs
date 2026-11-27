import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { checkEntitlements, checkHelperEntitlements, parsePlistXml } from "./check-entitlements.mjs";

const bundleId = "io.github.anzchy.mado";

const readWrite = "com.apple.security.files.user-selected.read-write";
const readOnly = "com.apple.security.files.user-selected.read-only";
// ADR-0022: the app and the Capture helper share one App Group.
const appGroups = "com.apple.security.application-groups";
const captureGroup = "GRT84NAK4T.io.github.anzchy.mado.capture";

function entitlementsXml({ extra = "", sandbox = "<true/>", omit = [], readOnlyKey = false,
  mach = [`${bundleId}-spks`, `${bundleId}-spki`], groups = [captureGroup], groupsXml } = {}) {
  // ADR-020: the user-selected key is read-write; `readOnlyKey` adds the retired read-only key.
  const flags = {
    "com.apple.security.app-sandbox": sandbox,
    "com.apple.security.files.bookmarks.app-scope": "<true/>",
    [readWrite]: "<true/>",
    "com.apple.security.network.client": "<true/>",
  };
  if (readOnlyKey) flags[readOnly] = "<true/>";
  const body = Object.entries(flags)
    .filter(([key]) => !omit.includes(key))
    .map(([key, value]) => `\t<key>${key}</key>\n\t${value}`)
    .join("\n");
  const machEntry = omit.includes("mach") ? "" :
    `\t<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>\n\t<array>\n` +
    mach.map((name) => `\t\t<string>${name}</string>`).join("\n") + `\n\t</array>`;
  const groupValue = groupsXml ?? `<array>\n` + groups.map((name) => `\t\t<string>${name}</string>`).join("\n") + `\n\t</array>`;
  const groupEntry = omit.includes("group") ? "" : `\t<key>${appGroups}</key>\n\t${groupValue}`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
${machEntry}
${groupEntry}
${extra}
</dict>
</plist>
`;
}

const getTaskAllow = "\t<key>com.apple.security.get-task-allow</key>\n\t<true/>";

function check(xml, configuration) {
  return checkEntitlements(parsePlistXml(xml), { bundleId, configuration });
}

test("parsePlistXml decodes dict, booleans, strings and arrays", () => {
  const parsed = parsePlistXml(entitlementsXml({ extra: "\t<key>n</key>\n\t<integer>3</integer>" }));
  assert.equal(parsed["com.apple.security.app-sandbox"], true);
  assert.equal(parsed["com.apple.security.network.client"], true);
  assert.deepEqual(parsed["com.apple.security.temporary-exception.mach-lookup.global-name"],
    [`${bundleId}-spks`, `${bundleId}-spki`]);
  assert.equal(parsed.n, 3);
  assert.equal(parsePlistXml(entitlementsXml({ sandbox: "<false/>" }))["com.apple.security.app-sandbox"], false);
  assert.throws(() => parsePlistXml("<plist><array></array></plist>"), /dict/);
});

test("exactly the six decided keys pass in release and debug", () => {
  for (const configuration of ["release", "debug"]) {
    assert.deepEqual(check(entitlementsXml(), configuration), [], configuration);
  }
  // Order of the two mach names does not matter.
  assert.deepEqual(check(entitlementsXml({ mach: [`${bundleId}-spki`, `${bundleId}-spks`] }), "release"), []);
});

test("get-task-allow passes only in debug", () => {
  const xml = entitlementsXml({ extra: getTaskAllow });
  assert.deepEqual(check(xml, "debug"), []);
  const release = check(xml, "release");
  assert.equal(release.length, 1);
  assert.match(release[0], /com\.apple\.security\.get-task-allow/);
  // Debug only tolerates it as true.
  assert.notDeepEqual(check(entitlementsXml({ extra: "\t<key>com.apple.security.get-task-allow</key>\n\t<string>yes</string>" }), "debug"), []);
});

test("an extra key fails in both configurations", () => {
  const xml = entitlementsXml({ extra: "\t<key>com.apple.security.cs.disable-library-validation</key>\n\t<true/>" });
  for (const configuration of ["release", "debug"]) {
    const problems = check(xml, configuration);
    assert.equal(problems.length, 1, configuration);
    assert.match(problems[0], /disable-library-validation/);
  }
});

test("each missing key fails and is named", () => {
  for (const key of [
    "com.apple.security.app-sandbox",
    "com.apple.security.files.bookmarks.app-scope",
    readWrite,
    "com.apple.security.network.client",
  ]) {
    const problems = check(entitlementsXml({ omit: [key] }), "release");
    assert.equal(problems.length, 1, key);
    assert.ok(problems[0].includes(key), problems[0]);
  }
  const problems = check(entitlementsXml({ omit: ["mach"] }), "release");
  assert.equal(problems.length, 1);
  assert.match(problems[0], /mach-lookup/);
  for (const configuration of ["release", "debug"]) {
    const missingGroup = check(entitlementsXml({ omit: ["group"] }), configuration);
    assert.equal(missingGroup.length, 1, configuration);
    assert.match(missingGroup[0], /missing entitlement com\.apple\.security\.application-groups/);
  }
});

test("the retired read-only key fails and read-write is missing", () => {
  const problems = check(entitlementsXml({ omit: [readWrite], readOnlyKey: true }), "release");
  assert.equal(problems.length, 2, problems.join("\n"));
  assert.ok(problems.some((p) => /unexpected.*user-selected\.read-only/.test(p)), problems.join("\n"));
  assert.ok(problems.some((p) => /missing.*user-selected\.read-write/.test(p)), problems.join("\n"));
});

test("read-only and read-write together fail", () => {
  const problems = check(entitlementsXml({ readOnlyKey: true }), "release");
  assert.equal(problems.length, 1, problems.join("\n"));
  assert.match(problems[0], /user-selected\.read-only/);
});

test("only the exact decided set passes over every subset", () => {
  const keys = ["com.apple.security.app-sandbox", "com.apple.security.files.bookmarks.app-scope", readWrite,
    "com.apple.security.network.client", "mach", "group", readOnly];
  const decided = new Set(keys.filter((key) => key !== readOnly));
  for (let mask = 0; mask < 1 << keys.length; mask++) {
    const present = keys.filter((_, bit) => mask & (1 << bit));
    const omit = keys.filter((key) => key !== readOnly && !present.includes(key));
    const problems = check(entitlementsXml({ omit, readOnlyKey: present.includes(readOnly) }), "release");
    const exact = present.length === decided.size && present.every((key) => decided.has(key));
    assert.equal(problems.length === 0, exact, `${present.join(",")}: ${problems.join("; ")}`);
  }
});

test("sandbox false or a non-boolean flag fails", () => {
  assert.equal(check(entitlementsXml({ sandbox: "<false/>" }), "release").length, 1);
  assert.match(check(entitlementsXml({ sandbox: "<false/>" }), "release")[0], /app-sandbox/);
  assert.equal(check(entitlementsXml({ sandbox: "<string>YES</string>" }), "release").length, 1);
});

test("mach-lookup names must be exactly the two resolved names", () => {
  const cases = [
    ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"],
    [`${bundleId}-spks`],
    [`${bundleId}-spks`, `${bundleId}-spki`, `${bundleId}-extra`],
    [`${bundleId}-spks`, `${bundleId}-spks`],
    ["com.example.other-spks", "com.example.other-spki"],
    [`${bundleId}-spks`, `${bundleId}-SPKI`],
  ];
  for (const mach of cases) {
    const problems = check(entitlementsXml({ mach }), "debug");
    assert.equal(problems.length, 1, JSON.stringify(mach));
    assert.match(problems[0], /mach-lookup/);
  }
});

test("the app group must be exactly the Capture group", () => {
  const cases = [
    { groups: ["GRT84NAK4T.io.github.anzchy.mado.other"] },
    { groups: ["group.io.github.anzchy.mado.capture"] },
    { groups: [captureGroup, "GRT84NAK4T.io.github.anzchy.mado.extra"] },
    { groups: [captureGroup, captureGroup] },
    { groups: [] },
    { groups: [captureGroup.toUpperCase()] },
    { groupsXml: `<string>${captureGroup}</string>` },
    { groupsXml: "<true/>" },
  ];
  for (const configuration of ["release", "debug"]) {
    for (const value of cases) {
      const problems = check(entitlementsXml(value), configuration);
      assert.equal(problems.length, 1, `${configuration} ${JSON.stringify(value)}: ${problems.join("; ")}`);
      assert.match(problems[0], /application-groups must be exactly \["GRT84NAK4T\.io\.github\.anzchy\.mado\.capture"\]/);
    }
  }
});

test("the committed app entitlements pass once Xcode resolves the bundle identifier", () => {
  const source = readFileSync(new URL("../../App/Resources/Mado.entitlements", import.meta.url), "utf8")
    .replaceAll("$(PRODUCT_BUNDLE_IDENTIFIER)", bundleId);
  for (const configuration of ["release", "debug"]) assert.deepEqual(check(source, configuration), [], configuration);
});

test("an unknown configuration is rejected", () => {
  assert.throws(() => checkEntitlements({}, { bundleId, configuration: "profile" }), /configuration/);
  assert.throws(() => checkEntitlements({}, { bundleId: "", configuration: "release" }), /bundle/);
});

test("release identity cannot be replaced with a different app's matching Sparkle pair", () => {
  const other = "com.example.other";
  const entitlements = parsePlistXml(entitlementsXml({ mach: [`${other}-spks`, `${other}-spki`] }));
  assert.ok(checkEntitlements(entitlements, { bundleId: other, expectedBundleId: "io.github.anzchy.mado", configuration: "release" }).some(p => p.includes("bundle identifier")));
  assert.deepEqual(checkEntitlements(parsePlistXml(entitlementsXml()), { bundleId, expectedBundleId: "io.github.anzchy.mado", configuration: "release" }), []);
});

// Keep the configured release-node receipt lane tied to the workflow's actual effects.
// A nested node --test must not inherit the parent test runner control protocol.
test("release workflow and feed integration contracts pass", () => {
  const run = spawnSync(process.execPath, ["--test", "--test-reporter=tap", ...["release-workflow.test.mjs", "workflow-steps.test.mjs", "appcast.test.mjs"].map(name => new URL(name, import.meta.url).pathname)], { env: Object.fromEntries(Object.entries(process.env).filter(([key]) => key !== "NODE_TEST_CONTEXT")), encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  assert.ok(Number(/^# tests (\d+)$/m.exec(run.stdout)?.[1]) > 0, run.stdout + run.stderr);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});

test("the entitlement CLI refuses an explicit bundle-ID option without its value", () => {
  const script = new URL("./check-entitlements.mjs", import.meta.url).pathname;
  for (const args of [["Mado.app", "--configuration", "release", "--expect-bundle-id"],
    ["Mado.app", "--expect-bundle-id", "--configuration", "release"]]) {
    const run = spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
    assert.equal(run.status, 2, run.stderr);
    assert.match(run.stderr, /usage:.*--expect-bundle-id/);
  }
});

// #861 fix 1: the embedded Capture helper's own entitlements (App/CaptureHelper/CaptureHelper.entitlements, ADR-0022)
// are an exact set too: a new grant fails until this allow-list changes.
const helperSource = parsePlistXml(readFileSync(new URL("../../App/CaptureHelper/CaptureHelper.entitlements", import.meta.url), "utf8"));
const helperFlags = ["com.apple.security.app-sandbox", "com.apple.security.files.downloads.read-write",
  "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope"];

test("#861 fix 1: the helper's checked-in entitlements are exactly the decided Release set", () => {
  assert.deepEqual(Object.keys(helperSource).sort(), [...helperFlags, appGroups].sort());
  assert.deepEqual(checkHelperEntitlements(helperSource, { configuration: "release" }), []);
});

test("#861 fix 1: a new, missing, false or changed helper entitlement fails", () => {
  const with_ = (change) => ({ ...helperSource, ...change });
  const without = (key) => Object.fromEntries(Object.entries(helperSource).filter(([name]) => name !== key));
  assert.deepEqual(checkHelperEntitlements(with_({ "com.apple.security.device.camera": true }), { configuration: "release" }),
    ["Capture helper: unexpected entitlement com.apple.security.device.camera"]);
  assert.deepEqual(checkHelperEntitlements(with_({ "com.apple.security.network.client": true }), { configuration: "release" }),
    ["Capture helper: unexpected entitlement com.apple.security.network.client"]);
  for (const key of helperFlags) {
    assert.deepEqual(checkHelperEntitlements(without(key), { configuration: "release" }), [`Capture helper: missing entitlement ${key}`], key);
    assert.deepEqual(checkHelperEntitlements(with_({ [key]: false }), { configuration: "release" }),
      [`Capture helper: ${key} must be true, found false`], key);
  }
  assert.deepEqual(checkHelperEntitlements(without(appGroups), { configuration: "release" }), [`Capture helper: missing entitlement ${appGroups}`]);
  for (const groups of [[], [captureGroup, "GRT84NAK4T.other"], ["group.io.github.anzchy.mado.capture"], captureGroup]) {
    assert.deepEqual(checkHelperEntitlements(with_({ [appGroups]: groups }), { configuration: "release" }),
      [`Capture helper: ${appGroups} must be exactly ${JSON.stringify([captureGroup])}, found ${JSON.stringify(groups)}`]);
  }
});

test("#861 fix 1: get-task-allow is a helper entitlement only in debug, and then only true", () => {
  const taskAllow = { ...helperSource, "com.apple.security.get-task-allow": true };
  assert.deepEqual(checkHelperEntitlements(taskAllow, { configuration: "release" }),
    ["Capture helper: unexpected entitlement com.apple.security.get-task-allow"]);
  assert.deepEqual(checkHelperEntitlements(taskAllow, { configuration: "debug" }), []);
  assert.deepEqual(checkHelperEntitlements({ ...helperSource, "com.apple.security.get-task-allow": false }, { configuration: "debug" }),
    ["Capture helper: com.apple.security.get-task-allow must be true when present in debug"]);
  assert.throws(() => checkHelperEntitlements(helperSource, { configuration: "beta" }), /configuration must be release or debug/);
});
