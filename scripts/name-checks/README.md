# Identity checks (#549)

`identity.json` is the single expected identity source. `expectedName` is **Picsee** for this ticket; `knownNames` contains Picsee and Mado. Both checks reject any other known identity, case-insensitively at word or identifier-part boundaries (`PicseeKit`, `launchPicseeWindow`, `PICSEE_LOCK`, `picsee-wt`). Ordinary containing words such as `amador` and `picseeing` do not match.

The bundle-ID template comes from the application target in `project.yml`, the feed URL from `App/Info.plist`, and the Sparkle suffixes from `App/Resources/Picsee.entitlements` (ADR-0015). No app build input reads this configuration. Feed URLs are declared per name: Picsee keeps its current URL, while Mado is explicitly undecided (`null`). Until #552 chooses a separate new feed path, every Mado product check reports `SUFeedURL undecided for Mado (decided in #552)`, regardless of the observed feed value.

```sh
node scripts/name-checks/code-name.mjs
node scripts/name-checks/built-product.mjs .build/dd-ci/Build/Products/Debug/Picsee.app \
  --entitlements App/Resources/Picsee.entitlements
node --test scripts/name-checks/*.test.mjs
```

Both CLIs accept `--expected-name Mado` to prove the checks reject today's Picsee inputs. Changing only `expectedName` in the JSON has the same effect. The code check also accepts `--root <repo>` and `--exceptions <json>`; the product check accepts `--root <repo>` and repeatable `--catalog <file>` overrides for fixtures. Catalog discovery uses `git ls-files -z -- '*.xcstrings'` and fails if none exist.

The product check reads the **built** `Contents/Info.plist`. English and Chinese catalog localizations, including nested plural/device/substitution variants, are checked by JSON pointer and value offset. If the source-language translation is missing, the source key is checked as the visible fallback. Catalog comments and translated-away keys are not displayed values.

Unsigned builds have no signature entitlements. Explicit `--entitlements` mode inspects the source template, expands only `$(PRODUCT_BUNDLE_IDENTIFIER)` with the built bundle ID, and reports that this is unsigned template inspection. It does not prove signed entitlements. Without this flag, the checker reads the app's signature with codesign; the existing release entitlement checker still enforces the complete signed entitlement set.

`exceptions.json` is the only code-name exception list. Each entry has a reason. Exact paths, directory prefixes and path regexes cover frozen/history inputs. Text-pattern entries exempt only individual matching spans, so a deferred tooling path cannot conceal an old module on the same line. Paths and every content occurrence are reported separately. Binary contents are skipped (their paths are checked); tracked symlinks are checked as stored target text without following them. Untracked files are not scanned. In Picsee mode, a living document that names Mado before the identity flip needs a reasoned exception in this list or must wait for the flip.

CI reuses the required Ubuntu ledger job for the code check and Node tests. The product check runs in the macOS unsigned-build step so its failure changes that step's outcome consumed by Walking skeleton. Required check names stay unchanged. Exit statuses: 0 passed, 1 identity violations, 2 invalid arguments/input or read failures.
