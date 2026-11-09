#!/usr/bin/env node
/** Write metadata for a PR whose only change is appcast-mado.xml; no gate results are inferred. */
import { writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const [tag, version, build, output] = args;
const parsedTag = /^mado-v([0-9]+\.[0-9]+\.[0-9]+)(?:-rc\.[1-9][0-9]*)?$/.exec(tag ?? "");
if (args.length !== 4 || !parsedTag || parsedTag[1] !== version || !/^[1-9][0-9]*$/.test(build ?? "") || !output) {
  console.error("invalid release metadata; usage: appcast-pr-body.mjs <tag> <version> <build> <output-file>");
  process.exit(2);
}

writeFileSync(output, `Adds ${tag} to appcast-mado.xml. Merging this offers Mado ${version} (${build}) to every installed copy that has update checks on, as soon as it lands on main; GitHub's pre-release flag does not filter the feed. For a release candidate, close this PR unless you mean a general rollout. Merge only after publishing the draft release ${tag}: the enclosure URL works once the release is public.

## Gates

| Lane | Status | SHA | Source |
| --- | --- | --- | --- |
| package-tests | N/A | — | appcast-mado.xml only; no package code changes |
| package-coverage | N/A | — | appcast-mado.xml only; no package code changes |
| app-tests | N/A | — | appcast-mado.xml only; no app code changes |
| unsigned-build | N/A | — | appcast-mado.xml only; no build inputs change |
| node-tooling | NOT RUN | — | No Node tests run on this generated branch; the workflow token does not trigger PR CI |
| ledger | N/A | — | appcast-mado.xml only; no ledger changes |
| diff-check | NOT RUN | — | No diff-check gate run on this generated branch |
| design-check | N/A | — | appcast-mado.xml only; no UI or design changes |
| audit | NOT RUN | — | Manual release and appcast review pending |
| device-smoke | N/A | — | appcast-mado.xml only; no app code changes; release acceptance is separate |

Device-Smoke: n/a — Changes only appcast-mado.xml; release acceptance is separate.
Ledger-Gardener: n/a — appcast-mado.xml only; no ledger changes; no gardener sweep claimed.
`, "utf8");
