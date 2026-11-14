#!/usr/bin/env node
/**
 * Check a signed Mado.app's entitlements against ADR-015's decided set.
 *
 *   node scripts/release/check-entitlements.mjs <Mado.app> --configuration release|debug [--expect-bundle-id ID]
 *
 * Release: exactly sandbox, user-selected read-write (ADR-020), app-scope bookmarks, network.client (all true) and
 * Sparkle's mach-lookup exception with exactly `<bundle id>-spks` and `<bundle id>-spki`.
 * Debug: the same, plus Xcode's development-signing `get-task-allow = true` if present.
 */
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const FLAGS = [
  "com.apple.security.app-sandbox",
  "com.apple.security.files.user-selected.read-write",
  "com.apple.security.files.bookmarks.app-scope",
  "com.apple.security.network.client",
];
const MACH = "com.apple.security.temporary-exception.mach-lookup.global-name";
const GET_TASK_ALLOW = "com.apple.security.get-task-allow";

/** Minimal XML property-list reader: dict, array, key, string, integer, real, true, false. */
export function parsePlistXml(xml) {
  const tokens = [...xml.replace(/<\?xml[^>]*\?>|<!DOCTYPE[^>]*>|<!--[\s\S]*?-->/g, "")
    .matchAll(/<(\/?)([A-Za-z]+)[^>/]*(\/?)>([^<]*)/g)];
  let index = 0;
  const unescape = (text) => text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'").replace(/&amp;/g, "&");
  function value() {
    const [, closing, tag, selfClosing, text] = tokens[index++] ?? [];
    if (closing || !tag) throw new Error(`plist: unexpected ${closing ? "</" + tag + ">" : "end"}`);
    if (selfClosing) {
      if (tag === "true") return true;
      if (tag === "false") return false;
      if (tag === "dict") return {};
      if (tag === "array") return [];
      if (tag === "string") return "";
      throw new Error(`plist: unsupported <${tag}/>`);
    }
    const close = () => {
      const [, isClose, name] = tokens[index++] ?? [];
      if (!isClose || name !== tag) throw new Error(`plist: expected </${tag}>`);
    };
    if (tag === "string" || tag === "integer" || tag === "real") {
      close();
      return tag === "string" ? unescape(text) : Number(text);
    }
    if (tag === "true" || tag === "false") { close(); return tag === "true"; }
    if (tag === "array") {
      const items = [];
      while (!(tokens[index]?.[1] && tokens[index][2] === "array")) items.push(value());
      close();
      return items;
    }
    if (tag === "dict") {
      const dict = {};
      while (!(tokens[index]?.[1] && tokens[index][2] === "dict")) {
        const [, isClose, keyTag, , keyText] = tokens[index++] ?? [];
        if (isClose || keyTag !== "key") throw new Error("plist: expected <key> in dict");
        if (tokens[index]?.[1] !== "/" || tokens[index][2] !== "key") throw new Error("plist: expected </key>");
        index++;
        dict[unescape(keyText)] = value();
      }
      close();
      return dict;
    }
    throw new Error(`plist: unsupported <${tag}>`);
  }
  const [, , rootTag] = tokens[index] ?? [];
  if (rootTag !== "plist") throw new Error("plist: missing <plist>");
  index++;
  const root = value();
  if (root === null || typeof root !== "object" || Array.isArray(root)) throw new Error("plist: root must be a dict");
  return root;
}

/** Returns one message per violation; an empty list means the entitlements are exactly the decided set. */
export function checkEntitlements(entitlements, { bundleId, configuration, expectedBundleId }) {
  if (configuration !== "release" && configuration !== "debug") {
    throw new Error(`configuration must be release or debug, not ${configuration}`);
  }
  if (!bundleId) throw new Error("bundle identifier is required");
  const problems = [];
  if (expectedBundleId && bundleId !== expectedBundleId) problems.push(`bundle identifier must be ${expectedBundleId}, found ${bundleId}`);
  const allowed = new Set([...FLAGS, MACH]);
  if (configuration === "debug" && GET_TASK_ALLOW in entitlements) {
    allowed.add(GET_TASK_ALLOW);
    if (entitlements[GET_TASK_ALLOW] !== true) problems.push(`${GET_TASK_ALLOW} must be true when present in debug`);
  }
  for (const key of Object.keys(entitlements).sort()) {
    if (!allowed.has(key)) problems.push(`unexpected entitlement ${key}`);
  }
  for (const key of FLAGS) {
    if (!(key in entitlements)) problems.push(`missing entitlement ${key}`);
    else if (entitlements[key] !== true) problems.push(`${key} must be true, found ${JSON.stringify(entitlements[key])}`);
  }
  if (!(MACH in entitlements)) {
    problems.push(`missing entitlement ${MACH}`);
  } else {
    const names = entitlements[MACH];
    const expected = [`${bundleId}-spks`, `${bundleId}-spki`];
    const ok = Array.isArray(names) && names.length === 2 && expected.every((name) => names.includes(name));
    if (!ok) problems.push(`${MACH} must be exactly ${JSON.stringify(expected)}, found ${JSON.stringify(names)}`);
  }
  return problems;
}

function main(argv) {
  const app = argv[0];
  const flag = argv.indexOf("--configuration");
  const configuration = flag >= 0 ? argv[flag + 1] : undefined;
  const expectedFlag = argv.indexOf("--expect-bundle-id");
  const expectedBundleId = expectedFlag >= 0 ? argv[expectedFlag + 1] : undefined;
  if (!app || app.startsWith("--") || !configuration || (expectedFlag >= 0 && (!expectedBundleId || expectedBundleId.startsWith("--")))) {
    process.stderr.write("usage: check-entitlements.mjs <Mado.app> --configuration release|debug [--expect-bundle-id ID]\n");
    return 2;
  }
  const xml = execFileSync("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const bundleId = execFileSync("/usr/bin/plutil",
    ["-extract", "CFBundleIdentifier", "raw", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" }).trim();
  const entitlements = parsePlistXml(xml);
  for (const key of Object.keys(entitlements).sort()) {
    process.stdout.write(`${key} = ${JSON.stringify(entitlements[key])}\n`);
  }
  const problems = checkEntitlements(entitlements, { bundleId, configuration, expectedBundleId });
  for (const problem of problems) process.stderr.write(`FAIL ${problem}\n`);
  if (problems.length) return 1;
  process.stdout.write(`PASS ${configuration} entitlements for ${bundleId}\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv.slice(2));
}
