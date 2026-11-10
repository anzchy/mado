import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { updateAppcast } from "./appcast.mjs";

// Exact appcast-mado.xml from PR #627, commit 3cd5f69bdc48d87f1425661dcb836fd9a25013ac.
const candidate = readFileSync(new URL("./fixtures/appcast-mado-v0.0.1-rc.2.xml", import.meta.url), "utf8");
const released = readFileSync(new URL("./fixtures/appcast-mado-v0.0.1.xml", import.meta.url), "utf8");
const items = (xml) => [...xml.matchAll(/<item>[\s\S]*?<\/item>/g)].map((match) => match[0]);
const versions = (xml) => items(xml).map((entry) => /<sparkle:version>([^<]*)</.exec(entry)?.[1]);
const releaseURL = (version, suffix = "") =>
  `https://github.com/anzchy/mado/releases/download/mado-v${version}${suffix}/Mado-${version}.dmg`;
const rcURL = releaseURL("0.0.1", "-rc.2");
const withURL = (url) => candidate.replace(rcURL, url);

export function registerAppcastRCContracts(isMadoFeed) {
  test("the exact #627 RC and final feed satisfies the Mado contract", () => {
    assert.deepEqual(versions(candidate), ["1740", "1691"]);
    assert.ok(candidate.includes(rcURL));
    assert.equal(isMadoFeed(candidate), true);
  });

  test("the feed contract accepts final and positive RC tag boundaries", () => {
    for (const suffix of ["", "-rc.1", "-rc.2", "-rc.10", "-rc.12345678901234567890"]) {
      const url = releaseURL("0.0.1", suffix);
      assert.equal(isMadoFeed(withURL(url)), true, url);
    }
  });

  test("consistent version renaming preserves RC validity", () => {
    const renamed = candidate.replaceAll("0.0.1", "1.2.3").replace("-rc.2/", "-rc.4/");
    assert.equal(isMadoFeed(candidate), true);
    assert.equal(isMadoFeed(renamed), true);
    assert.equal(isMadoFeed(renamed.replace("mado-v1.2.3-rc.4/", "mado-v1.2.4-rc.4/")), false);
  });

  test("the feed contract rejects malformed RC tags and mismatched RC URLs", () => {
    const wrong = [
      ...["-rc.0", "-rc.01", "-rc.", "-rc.-1", "-rc.1.2", "-RC.2", "-beta.2", "-rc.2extra"]
        .map((suffix) => releaseURL("0.0.1", suffix)),
      rcURL.replace("mado-v0.0.1-", "mado-v0.0.2-"),
      rcURL.replace("Mado-0.0.1", "Mado-0.0.2"),
      rcURL.replace("https:", "http:"),
      rcURL.replace("github.com", "example.com"),
      rcURL.replace("github.com", "github.com.example.com"),
      rcURL.replace("anzchy/mado/", "anzchy/other/"),
      rcURL.replace("Mado-", "Other-"),
      rcURL + "?download=1", rcURL + "#fragment", rcURL + "/extra", rcURL + "\n",
    ];
    for (const url of wrong) assert.equal(isMadoFeed(withURL(url)), false, url);
    assert.equal(isMadoFeed(candidate.replaceAll("0.0.1", "0x0x1")), false);
  });

  test("mixed RC/final validity and rejection are independent of item position", () => {
    const [rc, final] = items(candidate);
    const feed = (entries) => candidate.replace(/<item>[\s\S]*<\/item>/, entries.join("\n        "));
    for (const entries of [[rc, final], [final, rc]]) assert.equal(isMadoFeed(feed(entries)), true);
    for (const bad of [rc.replace("-rc.2/", "-rc.0/"), rc.replace(/ sparkle:edSignature="[^"]*"/, "")]) {
      for (const entries of [[bad, final], [final, bad]]) assert.equal(isMadoFeed(feed(entries)), false);
    }
  });

  test("real generator final and RC feeds validate, retain history and regenerate idempotently", () => {
    for (const shortVersion of ["0.0.1", "1.2.3"]) {
      for (const suffix of ["", "-rc.2"]) {
        const item = {
          version: "1740", shortVersion, url: releaseURL(shortVersion, suffix), length: 5359209,
          edSignature: Buffer.alloc(64, 7).toString("base64"), minimumSystemVersion: "14.0",
          pubDate: new Date("2026-11-10T00:22:13Z"),
        };
        const generated = updateAppcast(released, item);
        assert.equal(isMadoFeed(generated), true, item.url);
        assert.deepEqual(versions(generated), ["1740", "1691"]);
        assert.equal(items(generated)[1], items(released)[0]);
        assert.equal(updateAppcast(generated, item), generated);
      }
    }
  });
}
