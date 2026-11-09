#!/usr/bin/env node
/** Write metadata for a PR whose only change is appcast-mado.xml; no gate results are inferred. */
import { writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const [tag, version, build, output, baseSHA, headSHA] = args;
const parsedTag = /^mado-v([0-9]+\.[0-9]+\.[0-9]+)(?:-rc\.[1-9][0-9]*)?$/.exec(tag ?? "");
if (args.length !== 6 || !parsedTag || parsedTag[1] !== version || !/^[1-9][0-9]*$/.test(build ?? "") || !output ||
    !/^[0-9a-f]{40}$/i.test(baseSHA) || baseSHA.length !== 40 || !/^[0-9a-f]{40}$/i.test(headSHA) || headSHA.length !== 40) {
  console.error("invalid release metadata; usage: appcast-pr-body.mjs <tag> <version> <build> <output-file> <base-SHA> <head-SHA>");
  process.exit(2);
}

writeFileSync(output, `Adds ${tag} to appcast-mado.xml. Merging this offers Mado ${version} (${build}) to every installed copy that has update checks on, as soon as it lands on main; GitHub's pre-release flag does not filter the feed. For a release candidate, close this PR unless you mean a general rollout. Merge only after publishing the draft release ${tag}: the enclosure URL works once the release is public.

This PR is created or updated with GITHUB_TOKEN, which suppresses pull_request workflows.

Owner action: after every bot create or update, close and reopen this PR once as yourself (or push a commit as a human) so PR body Gates and CI run. A body edit alone does not trigger CI. Follow [the release runbook](docs/release/README.md#what-the-owner-does) and wait for those checks before publishing or merging.

## Gates

| Lane | Status | SHA | Source |
| --- | --- | --- | --- |
| package-tests | N/A | — | appcast-mado.xml only; no package code changes |
| package-coverage | N/A | — | appcast-mado.xml only; no package code changes |
| app-tests | N/A | — | appcast-mado.xml only; no app code changes |
| unsigned-build | N/A | — | appcast-mado.xml only; no build inputs change |
| node-tooling | NOT RUN | — | At body generation: no Node tests run on this generated branch; owner-triggered checks pending |
| ledger | N/A | — | appcast-mado.xml only; no ledger changes |
| diff-check | NOT RUN | — | At body generation: no diff-check gate run on this generated branch |
| design-check | N/A | — | appcast-mado.xml only; no UI or design changes |
| audit | NOT RUN | — | At body generation: manual release and appcast review pending |
| device-smoke | N/A | — | appcast-mado.xml only; no app code changes; release acceptance is separate |

Device-Smoke: n/a — Changes only appcast-mado.xml; release acceptance is separate.
Ledger-Gardener: DAILY ${baseSHA.slice(0, 7)}..${headSHA.slice(0, 7)} (covered by the daily sweep)
`, "utf8");
