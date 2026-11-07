#!/usr/bin/env node
import { checkFeed } from '../name-checks/identity.mjs';
/**
 * Check a built Mado.app for content that must never ship (DIST-03, spec #212 story 34).
 *
 *   node scripts/release/check-package.mjs <Mado.app> [--require-sparkle-licence]
 *        [--expect-version 0.0.1] [--expect-build 312]
 *
 * Fails closed: every file and symlink must belong to the enumerated 0.0.1 release layout, and each
 * offending path is listed (research or prototype material, credentials, photos, scripts, documents, or
 * anything unknown). Allowed files must not contain a private key or a build path; symlinks must point at
 * exactly the target Sparkle ships and resolve, as the OS resolves them, inside the bundle. Also checks the Sparkle keys in
 * the shipped Info.plist and, in release mode, that Sparkle's full licence is bundled (#220 M2).
 */
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, normalize, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const SPARKLE_LICENCE_PATH = "Contents/Resources/ThirdPartyNotices/Sparkle-2.10.0-LICENSE.txt";

const SPARKLE = String.raw`Contents/Frameworks/Sparkle\.framework`;

// The 0.0.1 release layout (scripts/release/fixtures/release-layout-0.0.1.txt): anything else fails closed.
const LAYOUT_FILES = [
  /^Contents\/(Info\.plist|PkgInfo|MacOS\/Mado|_CodeSignature\/CodeResources|CodeResources)$/,
  /^Contents\/Resources\/(AppIcon\.icns|Assets\.car)$/,
  /^Contents\/Resources\/(en|zh-Hans)\.lproj\/(Localizable\.strings|Localizable\.stringsdict)$/,
  new RegExp(`^${SPARKLE_LICENCE_PATH.replace(/[.]/g, "\\.")}$`),
  /^Contents\/Resources\/PicseeKit_PicseeMacUI\.bundle\/Contents\/(Info\.plist|Resources\/(alley|gate|hillside|lakehouse|lakeside|temple)\.jpg|Resources\/PROVENANCE\.md)$/,
  // Xcode signs the B4 resource bundle with a detached signature (observed on a signed Release build).
  /^Contents\/Resources\/PicseeKit_PicseeMacUI\.bundle\/Contents\/_CodeSignature\/(CodeDirectory|CodeRequirements|CodeResources|CodeSignature)$/,
  new RegExp(`^${SPARKLE}/Versions/B/(Autoupdate|Sparkle|_CodeSignature/CodeResources|` +
    String.raw`Resources/(Info\.plist|ReleaseNotesColorStyle\.css|SUUpdateAlert\.nib|SUUpdatePermissionPrompt\.nib|(Base|[a-z]{2,3}([_-][A-Za-z]{2,4})?)\.lproj/Sparkle\.strings)|` +
    String.raw`Updater\.app/Contents/(Info\.plist|PkgInfo|MacOS/Updater|_CodeSignature/CodeResources)|` +
    String.raw`XPCServices/(Installer|Downloader)\.xpc/Contents/(Info\.plist|_CodeSignature/CodeResources))$`),
  new RegExp(`^${SPARKLE}/Versions/B/XPCServices/(Installer|Downloader)\\.xpc/Contents/MacOS/\\1$`),
];
const LAYOUT_LINKS = [new RegExp(String.raw`^${SPARKLE}/(Sparkle|Resources|Autoupdate|Updater\.app|XPCServices|Versions/Current)$`)];
// Each framework link's exact target, as Sparkle 2.10.0 ships it in a built Mado.app.
const LINK_TARGETS = new Map([
  ...["Sparkle", "Resources", "Autoupdate", "Updater.app", "XPCServices"]
    .map((name) => [`Contents/Frameworks/Sparkle.framework/${name}`, `Versions/Current/${name}`]),
  ["Contents/Frameworks/Sparkle.framework/Versions/Current", "B"],
]);

// Denials give the specific reason; names, directories and extensions match in any case.
const FORBIDDEN_DIRECTORIES = new Map([
  ["evidence", "Picview research evidence"], ["docs", "repository documentation"], ["design", "design material"],
  ["testassets", "test assets"], ["node_modules", "npm packages"], [".stitch", "Stitch workspace"],
  [".stitch-cli", "Stitch credentials"], [".rea-cache", "REA cache"], [".npm", "npm cache"], [".git", "git metadata"],
  ["qa", "QA captures"], ["states", "prototype state pages"],
]);
const FORBIDDEN_NAMES = [
  [/^\.ds_store$/i, "Finder metadata"], [/^\.env(\..*)?$/i, "environment file"],
  [/^(strings\.txt|deep-.*\.(txt|json))$/i, "reverse-engineering dump"], [/^PICVIEW_/i, "Picview research"],
  [/^(analyze|deepen)_picview\.py$/i, "research script"], [/private[-_]?key/i, "private key"],
  [/^(id_rsa|id_ecdsa|id_ed25519)(\.pub)?$/i, "SSH key"],
];
const FORBIDDEN_EXTENSIONS = new Map([
  ["p12", "certificate bundle"], ["pfx", "certificate bundle"], ["p8", "API private key"], ["pem", "key or certificate"],
  ["key", "private key"], ["mobileprovision", "provisioning profile"], ["html", "HTML page"], ["htm", "HTML page"],
  ["css", "stylesheet"], ["js", "script"], ["mjs", "script"], ["cjs", "script"], ["ts", "script"], ["py", "script"],
  ["sh", "script"], ["bash", "script"], ["zsh", "script"], ["command", "script"], ["rb", "script"], ["pl", "script"],
  ["md", "document"], ["txt", "text file"], ["json", "data file"], ["zip", "archive"],
  ["jpg", "photo"], ["jpeg", "photo"], ["png", "image"], ["heic", "photo"], ["heif", "photo"], ["tif", "image"],
  ["tiff", "image"], ["gif", "image"], ["webp", "image"], ["dng", "raw photo"], ["raw", "raw photo"],
]);
const DEVELOPER_PATHS = [/\/Users\/[^/\0]+\//, /\/home\/[^/\0]+\//, /\/private\/var\/folders\//];
const PRIVATE_KEY = /-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----/;

/** Returns why a bundle-relative path must not ship, or null when it is part of the release layout. */
export function classifyPath(relativePath, kind = "any") {
  const parts = relativePath.split("/");
  const name = parts[parts.length - 1];
  for (const part of parts.slice(0, -1)) {
    const reason = FORBIDDEN_DIRECTORIES.get(part.toLowerCase());
    if (reason) return `${reason} (${part}/)`;
  }
  for (const [pattern, reason] of FORBIDDEN_NAMES) if (pattern.test(name)) return reason;
  const files = kind !== "link" && LAYOUT_FILES.some((pattern) => pattern.test(relativePath));
  const links = kind !== "file" && LAYOUT_LINKS.some((pattern) => pattern.test(relativePath));
  if (files || links) return null;
  const extension = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  return FORBIDDEN_EXTENSIONS.get(extension) ?? "not part of the 0.0.1 release layout";
}

function walk(root, directory, files, links) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const name = relative(root, path).split(sep).join("/");
    if (entry.isSymbolicLink()) links.push(name);
    else if (entry.isDirectory()) walk(root, path, files, links);
    else files.push(name);
  }
  return files;
}

const inside = (base, resolved) => resolved === base || resolved.startsWith(base + sep);

/**
 * Resolves a link as the OS does (realpath(3); Node's own realpathSync folds ".." before following links);
 * it must land inside the bundle. Links are never followed while walking.
 */
function linkProblem(base, root, link) {
  let resolved;
  try { resolved = realpathSync.native(join(root, link)); } catch (error) {
    if (error.code === "ELOOP") return "symlink cycle";
    if (error.code === "ENOENT") {
      const target = readlinkSync(join(root, link));
      const lexical = normalize(join(dirname(link), target));
      if (isAbsolute(target) || lexical === ".." || lexical.startsWith("../")) return `symlink to ${target} points outside the bundle`;
      return `broken symlink to ${target}`;
    }
    return `unresolvable symlink (${error.code})`;
  }
  if (!inside(base, resolved)) return `symlink resolves to ${resolved}, outside the bundle`;
  return null;
}

/** Framework links must point at exactly the target Sparkle ships, not merely somewhere inside the bundle. */
function targetProblem(root, link) {
  const expected = LINK_TARGETS.get(link);
  const target = readlinkSync(join(root, link));
  return expected === undefined || target === expected ? null : `symlink to ${target}, expected ${expected}`;
}

/** Every offending path with its reason; an empty list means the bundle may ship. */
export function checkPackage(root, { requireSparkleLicence = false } = {}) {
  let isDirectory = false;
  try { isDirectory = statSync(root).isDirectory(); } catch { isDirectory = false; }
  if (!isDirectory) throw new Error(`${root} is not a directory`);
  const base = realpathSync.native(root);
  const problems = [];
  const links = [];
  const files = walk(root, root, [], links).sort();
  for (const link of links.sort()) {
    const reason = linkProblem(base, root, link) ?? classifyPath(link, "link") ?? targetProblem(root, link);
    if (reason) problems.push({ path: link, reason });
  }
  for (const path of files) {
    const reason = classifyPath(path, "file");
    if (reason) { problems.push({ path, reason }); continue; }
    const real = realpathSync.native(join(root, path));
    if (!inside(base, real)) { problems.push({ path, reason: `resolves to ${real}, outside the bundle` }); continue; }
    const text = readFileSync(real).toString("latin1");
    if (PRIVATE_KEY.test(text)) { problems.push({ path, reason: "contains a private key" }); continue; }
    const leak = DEVELOPER_PATHS.map((pattern) => pattern.exec(text)).find(Boolean);
    if (leak) problems.push({ path, reason: `developer path ${leak[0]}…` });
  }
  if (requireSparkleLicence) {
    if (!files.includes(SPARKLE_LICENCE_PATH)) {
      problems.push({ path: SPARKLE_LICENCE_PATH, reason: "Sparkle 2.10.0 licence missing" });
    } else {
      const licence = readFileSync(join(root, SPARKLE_LICENCE_PATH), "utf8");
      if (!licence.startsWith("Copyright (c) 2006-2013 Andy Matuschak.") || !licence.includes("EXTERNAL LICENSES")) {
        problems.push({ path: SPARKLE_LICENCE_PATH, reason: "not Sparkle's full LICENSE with its EXTERNAL LICENSES notices" });
      }
    }
  }
  return problems;
}

/** Sparkle and version keys of the shipped Info.plist (spec #212 story 7; ADR-015). */
export function checkInfo(info, { version, build, expectedName } = {}) {
  const problems = [];
  if ("SUEnableAutomaticChecks" in info) problems.push("SUEnableAutomaticChecks must stay unset so Sparkle asks on the second launch");
  if (info.SUEnableSystemProfiling !== false) problems.push("SUEnableSystemProfiling must be Boolean false");
  if (info.SUEnableInstallerLauncherService !== true) problems.push("SUEnableInstallerLauncherService must be Boolean true");
  if ("SUEnableDownloaderService" in info) problems.push("SUEnableDownloaderService must stay unset (network.client is granted)");
  problems.push(...checkFeed(info, expectedName, { release: true }));
  const key = typeof info.SUPublicEDKey === "string" ? Buffer.from(info.SUPublicEDKey, "base64") : Buffer.alloc(0);
  if (key.length !== 32 || key.toString("base64") !== info.SUPublicEDKey) problems.push("SUPublicEDKey must be a base64 Ed25519 public key");
  if (version !== undefined && info.CFBundleShortVersionString !== version) {
    problems.push(`CFBundleShortVersionString is ${info.CFBundleShortVersionString}, expected ${version}`);
  }
  if (build !== undefined && info.CFBundleVersion !== build) problems.push(`CFBundleVersion is ${info.CFBundleVersion}, expected ${build}`);
  return problems;
}

function main(argv) {
  const app = argv[0];
  const option = (name) => { const index = argv.indexOf(name); return index >= 0 ? argv[index + 1] : undefined; };
  if (!app || app.startsWith("--")) {
    process.stderr.write("usage: check-package.mjs <Mado.app> [--require-sparkle-licence] [--expect-version V] [--expect-build N]\n");
    return 2;
  }
  const problems = checkPackage(app, { requireSparkleLicence: argv.includes("--require-sparkle-licence") })
    .map(({ path, reason }) => `${path}: ${reason}`);
  const info = JSON.parse(execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" }));
  problems.push(...checkInfo(info, { version: option("--expect-version"), build: option("--expect-build") })
    .map((problem) => `Contents/Info.plist: ${problem}`));
  for (const problem of problems) process.stderr.write(`FAIL ${problem}\n`);
  if (problems.length) return 1;
  process.stdout.write(`PASS package contents of ${app}\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv.slice(2));
}
