# Identity checks (#549)

`identity.json` is the single expected identity source. `expectedName` is **Mado**; `knownNames` contains the former name Picsee and the current name Mado. Both checks reject any other known identity, case-insensitively at word or identifier-part boundaries (`MadoKit`, `launchMadoWindow`, `PICSEE_LOCK`, `picsee-wt`). Ordinary containing words such as `amador` and `picseeing` do not match.

The bundle-ID template comes from the application target in `project.yml`, the feed URL from `App/Info.plist`, and the Sparkle suffixes from `App/Resources/Mado.entitlements` (ADR-0015). No app build input reads this configuration. Feed URLs are declared per name: the former app keeps its frozen URL, while Mado is explicitly undecided (`null`) on this branch. Until #552 chooses a separate new feed path, every Mado product check reports `SUFeedURL undecided for Mado (decided in #552)`, regardless of the observed feed value.

```sh
node scripts/name-checks/code-name.mjs
node scripts/name-checks/built-product.mjs .build/dd-ci/Build/Products/Debug/Mado.app \
  --entitlements App/Resources/Mado.entitlements
node --test scripts/name-checks/*.test.mjs
```

Both CLIs accept `--expected-name` to select one of the two declared identities. The tests exercise both the current Mado identity and forbidden former-name inputs. The code check also accepts `--root <repo>` and `--exceptions <json>`; the product check accepts `--root <repo>` and repeatable `--catalog <file>` overrides for fixtures. Catalog discovery uses `git ls-files -z -- '*.xcstrings'` and fails if none exist.

The product check reads the **built** `Contents/Info.plist`. English and Chinese catalog localizations, including nested plural/device/substitution variants, are checked by JSON pointer and value offset. If the source-language translation is missing, the source key is checked as the visible fallback. Catalog comments and translated-away keys are not displayed values.

Unsigned builds have no signature entitlements. Explicit `--entitlements` mode inspects the source template, expands only `$(PRODUCT_BUNDLE_IDENTIFIER)` with the built bundle ID, and reports that this is unsigned template inspection. It does not prove signed entitlements. Without this flag, the checker reads the app's signature with codesign; the existing release entitlement checker still enforces the complete signed entitlement set.

`exceptions.json` is the only code-name exception list. Each entry has a reason. Exact paths, directory prefixes and path regexes cover frozen/history inputs. Text-pattern entries exempt only individual matching spans, so a deferred tooling path cannot conceal an old module on the same line. Paths and every content occurrence are reported separately. Binary contents are skipped (their paths are checked); tracked symlinks are checked as stored target text without following them. Untracked files are not scanned. The documentation contract below checks current native-command identities independently of the broader code checker’s Markdown exceptions.

CI reuses the required Ubuntu ledger job for the code check and Node tests. The product check runs in the macOS unsigned-build step so its failure changes that step's outcome consumed by Walking skeleton. Required check names stay unchanged. Exit statuses: 0 passed, 1 identity violations, 2 invalid arguments/input or read failures.

## Living documentation rename (#553)

Replay the mechanical pass from any directory:

```sh
node /absolute/path/to/repo/scripts/name-checks/rename-living-docs.mjs
npm run ledger:build  # from the repository root
node --test scripts/name-checks/living-docs.test.mjs
```

The CLI preserves filenames and link targets, tooling paths and identifiers reserved for #556, repo references reserved for #554, release history, static research and historical audit/test/review/TDD reports. It appends exactly one former-name note to each ADR and validation record. Ledger history and acceptance prefixes remain unchanged during replay; amendment 1's four acceptance-name substitutions are committed separately. The glossary definition, capitalization guidance and this dual-identity explanation are hand edits.

The lasting Node contract scans current native-command identities without reading historical commits. Historical records and sanctioned acceptance changes may evolve after this ticket. Prompt tests check copied design-system globals against each manifest and the actual running bundle. The namespace `PicseeUiSystem_bb8eab` is a generated runtime export, so the replay preserves it; #552 owns the release notes template, which the replay also leaves untouched.

To audit this ticket's preservation rules once, select both immutable revisions explicitly (full history containing them is required):

```sh
node scripts/name-checks/check-living-docs-range.mjs --base bf5052b2 --head <reviewed-commit>
```

This one-shot command checks the former-name notes, original ADR/validation bytes and paths, ledger rows/acceptance and the unchanged release template only across the selected trees. Only OPEN-03, CMD-05, WIN-02 and EXT-03 may substitute the app name in acceptance; limitations permit mechanical names only. It has no default baseline or head, does not read working-tree records, and fails visibly if either chosen object is unavailable. It is outside the always-run test glob. Generic fixture tests verify those command semantics without pinning future project history.
