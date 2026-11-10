import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";
import { createHash } from "node:crypto";
import { emptyAppcast, updateAppcast } from "./appcast.mjs";
import { registerAppcastRCContracts } from "./appcast-rc-cases.mjs";

const fixture = readFileSync(new URL("./fixtures/appcast-one-item.xml", import.meta.url), "utf8");
const madoRelease = readFileSync(new URL("./fixtures/appcast-mado-v0.0.1.xml", import.meta.url), "utf8");
const signature = Buffer.alloc(64, 7).toString("base64");
const item = {
  version: "312",
  shortVersion: "0.0.1",
  url: "https://github.com/anzchy/mado/releases/download/mado-v0.0.1-rc.2/Mado-0.0.1.dmg",
  length: 9123456,
  edSignature: signature,
  minimumSystemVersion: "14.0",
  pubDate: new Date(Date.UTC(2026, 9, 30, 12, 34, 56)),
};

const items = (xml) => [...xml.matchAll(/<item>[\s\S]*?<\/item>/g)].map((match) => match[0]);
const versions = (xml) => items(xml).map((entry) => /<sparkle:version>([^<]*)</.exec(entry)?.[1]);

// Test-local contract for the generated Mado feed, independently of the writer.
function isMadoFeed(xml) {
  if (!/<channel>\s*<title>Mado<\/title>/.test(xml) || /Picsee|picsee/.test(xml)) return false;
  return items(xml).every((entry) => {
    const title = /<title>([^<]*)<\/title>/.exec(entry)?.[1];
    const version = /<sparkle:version>([^<]*)<\/sparkle:version>/.exec(entry)?.[1];
    const shortVersion = /<sparkle:shortVersionString>([^<]*)<\/sparkle:shortVersionString>/.exec(entry)?.[1];
    const enclosure = /<enclosure\s[^>]*\/>/.exec(entry)?.[0] ?? "";
    const attribute = (name) => new RegExp(`\\s${name}="([^"]*)"`).exec(enclosure)?.[1];
    // Match the workflow's final/RC tags; an RC appcast PR still needs the owner's rollout decision.
    const releaseURL = /^https:\/\/github\.com\/anzchy\/mado\/releases\/download\/mado-v(\d+\.\d+\.\d+)(?:-rc\.[1-9]\d*)?\/Mado-(\d+\.\d+\.\d+)\.dmg(?![\s\S])/.exec(attribute("url") ?? "");
    return Boolean(title?.startsWith("Mado ") && version?.trim() && shortVersion?.trim() &&
      releaseURL && releaseURL[1] === shortVersion && releaseURL[2] === shortVersion &&
      attribute("length")?.trim() && attribute("sparkle:edSignature")?.trim());
  });
}

registerAppcastRCContracts(isMadoFeed);

test("the Mado feed contract accepts empty and released feeds", () => {
  assert.equal(items(madoRelease).length, 1, "fixture is the first release from #593 (0816622e)");
  assert.equal(isMadoFeed(emptyAppcast()), true);
  assert.equal(isMadoFeed(madoRelease), true);
});

test("the Mado feed contract checks every item regardless of position", () => {
  const [first] = items(madoRelease);
  const second = first.replaceAll("0.0.1", "0.0.2").replaceAll("1691", "1700");
  const bad = second.replace(/ sparkle:edSignature="[^"]*"/, "");
  const feed = (entries) => madoRelease.replace(first, entries.join("\n        "));
  for (const entries of [[first, second], [second, first]]) {
    assert.equal(isMadoFeed(feed(entries)), true);
  }
  for (const entries of [[first, bad], [bad, first]]) {
    assert.equal(isMadoFeed(feed(entries)), false, "an unsigned item invalidates the whole feed");
  }
});

test("the Mado feed contract rejects foreign product and channel identities", () => {
  // Reuse the historical-name oracle already allowed by the repository identity check.
  const [legacyTitle, legacyName] = /Picsee|picsee/.source.split("|");
  for (const xml of [
    madoRelease.replace("<title>Mado 0.0.1", `<title>${legacyTitle} 0.0.1`),
    madoRelease.replace("<title>Mado 0.0.1", "<title>Other 0.0.1"),
    madoRelease.replace("<title>Mado</title>", "<title>Other</title>"),
    madoRelease.replace("Mado updates", `${legacyName} updates`),
  ]) {
    assert.equal(isMadoFeed(xml), false);
  }
});

test("the Mado feed contract rejects foreign or mismatched release URLs", () => {
  const url = /(<enclosure url=")([^"]+)(")/;
  const original = url.exec(madoRelease)[2];
  for (const wrong of [
    original.replace("https:", "http:"),
    original.replace("github.com", "example.com"),
    original.replace("github.com", "github.com.example.com"),
    original.replace("anzchy/mado/", "anzchy/other/"),
    original.replace("Mado-", "Other-"),
    original.replace("mado-v0.0.1/", "mado-v0.0.2/"),
    original.replace("Mado-0.0.1", "Mado-0.0.2"),
    original + "?download=1",
    original + "/extra",
  ]) {
    assert.equal(isMadoFeed(madoRelease.replace(url, `$1${wrong}$3`)), false, wrong);
  }
});

test("the Mado feed contract requires each release field and its value", () => {
  for (const tag of ["sparkle:version", "sparkle:shortVersionString"]) {
    const element = new RegExp(`<${tag}>[^<]*</${tag}>`);
    for (const replacement of ["", `<${tag}></${tag}>`]) {
      assert.equal(isMadoFeed(madoRelease.replace(element, replacement)), false, `${tag}: ${replacement}`);
    }
  }
  for (const attribute of ["length", "sparkle:edSignature"]) {
    const field = new RegExp(` ${attribute}="[^"]*"`);
    for (const replacement of ["", ` ${attribute}=""`]) {
      assert.equal(isMadoFeed(madoRelease.replace(field, replacement)), false, `${attribute}: ${replacement}`);
    }
  }
  assert.equal(isMadoFeed(madoRelease.replace(/<enclosure[^>]*\/>/, "")), false);
});

test("the empty appcast is a Sparkle RSS channel with no items", () => {
  const xml = emptyAppcast();
  assert.match(xml, /^<\?xml version="1\.0" encoding="utf-8"\?>/);
  assert.match(xml, /xmlns:sparkle="http:\/\/www\.andymatuschak\.org\/xml-namespaces\/sparkle"/);
  assert.match(xml, /<channel>[\s\S]*<title>Mado<\/title>[\s\S]*<\/channel>/);
  assert.deepEqual(items(xml), []);
});

test("an item is added with every Sparkle field the update needs", () => {
  const xml = updateAppcast(emptyAppcast(), item);
  assert.deepEqual(versions(xml), ["312"]);
  const [entry] = items(xml);
  assert.match(entry, /<title>Mado 0\.0\.1 \(312\)<\/title>/);
  assert.match(entry, /<pubDate>Fri, 30 Oct 2026 12:34:56 \+0000<\/pubDate>/);
  assert.match(entry, /<sparkle:shortVersionString>0\.0\.1<\/sparkle:shortVersionString>/);
  assert.match(entry, /<sparkle:minimumSystemVersion>14\.0<\/sparkle:minimumSystemVersion>/);
  assert.match(entry, new RegExp(`<enclosure url="${item.url.replace(/[.]/g, "\\.")}" length="9123456" ` +
    `type="application/octet-stream" sparkle:edSignature="${signature.replace(/[+/=]/g, "\\$&")}"/>`));
});

test("a newer item goes first and earlier items are kept byte for byte", () => {
  const before = items(fixture)[0];
  const xml = updateAppcast(fixture, item);
  assert.deepEqual(versions(xml), ["312", "300"]);
  assert.equal(items(xml)[1], before);
  assert.ok(xml.startsWith(fixture.slice(0, fixture.indexOf("<item>"))));
});

test("updating the same version is idempotent and replaces, never duplicates", () => {
  const once = updateAppcast(fixture, item);
  assert.equal(updateAppcast(once, item), once);
  const resigned = updateAppcast(once, { ...item, length: 9123999, edSignature: Buffer.alloc(64, 9).toString("base64") });
  assert.deepEqual(versions(resigned), ["312", "300"]);
  assert.match(items(resigned)[0], /length="9123999"/);
  assert.doesNotMatch(resigned, new RegExp(signature.replace(/[+/=]/g, "\\$&")));
});

test("items stay ordered by build number whatever order releases arrive in", () => {
  let xml = updateAppcast(fixture, { ...item, version: "320" });
  xml = updateAppcast(xml, item);
  assert.deepEqual(versions(xml), ["320", "312", "300"]);
});

test("values are XML-escaped", () => {
  const xml = updateAppcast(emptyAppcast(), { ...item, url: "https://example.com/a?x=1&y=<2>" });
  assert.match(xml, /url="https:\/\/example\.com\/a\?x=1&amp;y=&lt;2&gt;"/);
});

test("malformed input is refused rather than written", () => {
  const bad = [
    [{ edSignature: "not-base64!" }, /signature/],
    [{ edSignature: Buffer.alloc(63).toString("base64") }, /signature/],
    [{ edSignature: Buffer.alloc(64).toString("base64").replace(/=+$/, "") }, /signature/],
    [{ edSignature: "" }, /signature/],
    [{ url: "http://github.com/anzchy/picsee/releases/download/v0.0.1/Picsee-0.0.1.dmg" }, /https/],
    [{ length: 0 }, /length/],
    [{ length: 12.5 }, /length/],
    [{ length: "9123456" }, /length/],
    [{ version: "0.0.1" }, /version/],
    [{ version: "" }, /version/],
    [{ shortVersion: "v0.0.1" }, /shortVersion/],
    [{ minimumSystemVersion: "14" }, /minimumSystemVersion/],
    [{ pubDate: new Date("nope") }, /pubDate/],
  ];
  for (const [patch, pattern] of bad) {
    assert.throws(() => updateAppcast(fixture, { ...item, ...patch }), pattern, JSON.stringify(patch));
  }
  assert.throws(() => updateAppcast("<rss></rss>", item), /channel/);
});

test("the historical appcast stays byte-identical and Mado has its own valid release feed", () => {
  const root = new URL("../../", import.meta.url);
  const frozen = readFileSync(new URL("appcast.xml", root));
  assert.equal(createHash("sha256").update(frozen).digest("hex"), "d729a9f2e51cbb91901a26369c3cebce95d38bbd0a8abaaa1b7557a2324343fc");
  const path = new URL("appcast-mado.xml", root);
  assert.ok(existsSync(path), "Mado feed must exist independently");
  const mado = readFileSync(path, "utf8");
  assert.equal(isMadoFeed(mado), true);
  assert.match(mado, /<title>Mado<\/title>/); assert.doesNotMatch(mado, /Picsee|picsee/);
});
