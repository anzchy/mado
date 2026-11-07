#!/usr/bin/env node
/**
 * Insert or update one release in picsee's Sparkle appcast (appcast.xml at the repository root, the
 * SUFeedURL in App/Info.plist).
 *
 *   node scripts/release/appcast.mjs appcast.xml --version 312 --short-version 0.0.1 \
 *     --url https://github.com/anzchy/picsee/releases/download/v0.0.1/Mado-0.0.1.dmg \
 *     --length 9123456 --signature <sign_update -p output> [--minimum-system-version 14.0] [--pub-date ISO-8601]
 *
 * The same build number replaces its item; items stay newest first; earlier items are kept as written.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle";

export function emptyAppcast() {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="${SPARKLE_NS}">
    <channel>
        <title>picsee</title>
        <link>https://github.com/anzchy/picsee/releases</link>
        <description>picsee updates</description>
        <language>en</language>
    </channel>
</rss>
`;
}

const escape = (value) => String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (number) => String(number).padStart(2, "0");
const rfc822 = (date) => `${DAYS[date.getUTCDay()]}, ${pad(date.getUTCDate())} ${MONTHS[date.getUTCMonth()]} ${date.getUTCFullYear()} ` +
  `${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} +0000`;

function validate({ version, shortVersion, url, length, edSignature, minimumSystemVersion, pubDate }) {
  if (typeof version !== "string" || !/^[1-9]\d*$/.test(version)) throw new Error(`version must be the build number, not ${JSON.stringify(version)}`);
  if (typeof shortVersion !== "string" || !/^\d+\.\d+\.\d+$/.test(shortVersion)) throw new Error(`shortVersion must be x.y.z, not ${JSON.stringify(shortVersion)}`);
  if (typeof url !== "string" || !url.startsWith("https://")) throw new Error("enclosure url must be https");
  if (!Number.isInteger(length) || length <= 0) throw new Error(`length must be a positive byte count, not ${JSON.stringify(length)}`);
  const decoded = typeof edSignature === "string" && /^[A-Za-z0-9+/]+={0,2}$/.test(edSignature) ? Buffer.from(edSignature, "base64") : null;
  if (!decoded || decoded.length !== 64 || decoded.toString("base64") !== edSignature) throw new Error("edSignature must be a base64 Ed25519 signature (64 bytes)");
  if (typeof minimumSystemVersion !== "string" || !/^\d+\.\d+(\.\d+)?$/.test(minimumSystemVersion)) {
    throw new Error(`minimumSystemVersion must look like 14.0, not ${JSON.stringify(minimumSystemVersion)}`);
  }
  if (!(pubDate instanceof Date) || Number.isNaN(pubDate.getTime())) throw new Error("pubDate must be a valid Date");
}

function render(item) {
  return `<item>
            <title>picsee ${escape(item.shortVersion)} (${escape(item.version)})</title>
            <pubDate>${rfc822(item.pubDate)}</pubDate>
            <sparkle:version>${escape(item.version)}</sparkle:version>
            <sparkle:shortVersionString>${escape(item.shortVersion)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${escape(item.minimumSystemVersion)}</sparkle:minimumSystemVersion>
            <enclosure url="${escape(item.url)}" length="${item.length}" type="application/octet-stream" sparkle:edSignature="${escape(item.edSignature)}"/>
        </item>`;
}

/** Returns the appcast with `item` inserted, or replacing the item of the same build number. */
export function updateAppcast(xml, item) {
  validate(item);
  const close = xml.lastIndexOf("</channel>");
  const open = xml.indexOf("<channel>");
  if (open < 0 || close < open || !xml.includes(`xmlns:sparkle="${SPARKLE_NS}"`)) throw new Error("appcast has no Sparkle <channel>");
  const existing = [...xml.matchAll(/<item>[\s\S]*?<\/item>/g)].map((match) => ({
    text: match[0], start: match.index, end: match.index + match[0].length,
    build: Number(/<sparkle:version>(\d+)<\/sparkle:version>/.exec(match[0])?.[1] ?? 0),
  }));
  const fresh = render(item);
  const same = existing.find((entry) => entry.build === Number(item.version));
  if (same) return xml.slice(0, same.start) + fresh + xml.slice(same.end);
  const before = existing.find((entry) => entry.build < Number(item.version));
  if (before) return xml.slice(0, before.start) + fresh + "\n        " + xml.slice(before.start);
  const after = existing.at(-1);
  if (after) return xml.slice(0, after.end) + "\n        " + fresh + xml.slice(after.end);
  return xml.slice(0, close).replace(/\s*$/, "\n        ") + fresh + "\n    " + xml.slice(close);
}

function main(argv) {
  const [file] = argv;
  const option = (name) => { const index = argv.indexOf(name); return index >= 0 ? argv[index + 1] : undefined; };
  if (!file || file.startsWith("--")) {
    process.stderr.write("usage: appcast.mjs <appcast.xml> --version N --short-version x.y.z --url URL --length BYTES --signature SIG [--minimum-system-version 14.0] [--pub-date ISO]\n");
    return 2;
  }
  const xml = existsSync(file) ? readFileSync(file, "utf8") : emptyAppcast();
  const pubDate = option("--pub-date");
  writeFileSync(file, updateAppcast(xml, {
    version: option("--version"), shortVersion: option("--short-version"), url: option("--url"),
    length: Number(option("--length")), edSignature: option("--signature"),
    minimumSystemVersion: option("--minimum-system-version") ?? "14.0", pubDate: pubDate ? new Date(pubDate) : new Date(),
  }));
  process.stdout.write(`updated ${file}: ${option("--short-version")} (${option("--version")})\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`FAIL ${error.message}\n`); process.exitCode = 1; }
}
