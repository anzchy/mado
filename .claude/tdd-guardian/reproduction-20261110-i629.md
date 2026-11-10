# #629 reproduction and policy decision

Exact source: PR #627, `origin/appcast-mado/mado-v0.0.1-rc.2` at `3cd5f69bdc48d87f1425661dcb836fd9a25013ac`, file `appcast-mado.xml`. Fixture is a byte-for-byte git-show copy.

Before any implementation change, extracted the existing isMadoFeed function from appcast.test.mjs and ran it on that git-show output: **false**.

- Build 1740 actual URL: https://github.com/anzchy/mado/releases/download/mado-v0.0.1-rc.2/Mado-0.0.1.dmg
- Validator expected: https://github.com/anzchy/mado/releases/download/mado-v0.0.1/Mado-0.0.1.dmg
- Build 1691 URL matches the expected final-release URL.

The broken rule is exact enclosure URL equality to the final-only tag derived from shortVersion. Product/channel title, item order and signature fields are not the cause.

Decision: correct the validator. Release workflow explicitly accepts `mado-vX.Y.Z` and `mado-vX.Y.Z-rc.[1-9][0-9]*`, extracts plain marketing version for the DMG, creates a draft/prerelease, and then generates an appcast PR. docs/release/README.md explicitly tells the owner to close an RC appcast PR unless a general rollout is intended. Thus RC PR generation is intentional, pending an owner rollout decision. This task neither authorizes a rollout nor changes that policy.

Narrow accepted URL syntax must preserve HTTPS github.com, anzchy/mado, matching numeric three-component version in tag and DMG filename, optional supported RC suffix only, and no query/fragment/trailing path. Do not relax field, per-item, or historical feed guards.

Refs #629 #429; DIST-05 / P6-08. No app runtime behavior changes; no ledger status upgrade warranted.
