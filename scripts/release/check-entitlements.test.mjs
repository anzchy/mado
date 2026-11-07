import assert from "node:assert/strict";
import test from "node:test";
import { checkEntitlements, parsePlistXml } from "./check-entitlements.mjs";

const bundleId = "io.github.anzchy.mado";

function entitlementsXml({ extra = "", sandbox = "<true/>", omit = [], mach = [`${bundleId}-spks`, `${bundleId}-spki`] } = {}) {
  const flags = {
    "com.apple.security.app-sandbox": sandbox,
    "com.apple.security.files.bookmarks.app-scope": "<true/>",
    "com.apple.security.files.user-selected.read-only": "<true/>",
    "com.apple.security.network.client": "<true/>",
  };
  const body = Object.entries(flags)
    .filter(([key]) => !omit.includes(key))
    .map(([key, value]) => `\t<key>${key}</key>\n\t${value}`)
    .join("\n");
  const machEntry = omit.includes("mach") ? "" :
    `\t<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>\n\t<array>\n` +
    mach.map((name) => `\t\t<string>${name}</string>`).join("\n") + `\n\t</array>`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
${machEntry}
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

test("exactly the five decided keys pass in release and debug", () => {
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
    "com.apple.security.files.user-selected.read-only",
    "com.apple.security.network.client",
  ]) {
    const problems = check(entitlementsXml({ omit: [key] }), "release");
    assert.equal(problems.length, 1, key);
    assert.ok(problems[0].includes(key), problems[0]);
  }
  const problems = check(entitlementsXml({ omit: ["mach"] }), "release");
  assert.equal(problems.length, 1);
  assert.match(problems[0], /mach-lookup/);
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

test("an unknown configuration is rejected", () => {
  assert.throws(() => checkEntitlements({}, { bundleId, configuration: "profile" }), /configuration/);
  assert.throws(() => checkEntitlements({}, { bundleId: "", configuration: "release" }), /bundle/);
});
