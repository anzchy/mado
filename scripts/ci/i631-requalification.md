# #631 requalification batch (after #647)

The batch on 069238d4 FAILED: 8 runs succeeded and 2 failed, both on the #647 watchdog flake. astra acted as delegated owner-decider (not an owner approval). DECISION-A required a fresh, predeclared batch of 10 cold runs plus 1 cache-restored run, on a new frozen SHA that contains the #647 fix. It amends item 4's "no batch restart" provision only to allow this requalification after verified remediation. No run of the 069238d4 batch counts toward acceptance.

## #647 remediation evidence

- Merged to main as PR #652 (c6f0be97):
  - 27d37931: deterministic RED reproduction;
  - 53411542: re-observe the owned host after the leader group drains;
  - 438ba580: leader-exit barrier, so the test no longer relies on timing.
- The delegator ran these checks under the heavy lock:
  - base RED replay: 30 of 30 failed correctly, with status 70;
  - fixed test: 50 of 50 passed under 10 CPU workers;
  - `node --test scripts/ci/*.test.mjs scripts/tdd/*.test.mjs`: 574 pass, 0 fail.
- PR #652 passed hosted CI on 438ba580.

## Candidate

- **Code.** The code under test is commit 83c205e8. It is `ci/631-package-coverage-gate` rebased onto main 4964a424, with nothing else added.
  - `rebase-verify` against the audited 069238d4 reports MESSAGES same and CODE same.
  - The only conflict was a test title in `owner-gates.test.mjs`, resolved by keeping both of main's npm test and #631's renamed test.
- **Frozen SHA.** It is the commit that adds this file; its parent is 83c205e8. The delegator posts the exact frozen SHA on #631 before the first dispatch.
- **Manifests**, as git blob IDs at 83c205e8:
  - `Packages/MadoKit/Package.swift`: 6e6119d4784c5b8c7121b2845a374f8a5254398a
  - `package-lock.json`: 812c872d7d797fb4a1fc441999a3bd4e249b8bb5
  - `.github/workflows/ci.yml`: d156de23d93f334c301690c0c88b0c8f6e4d69f4
- **Toolchain.** Native jobs run on `runs-on: macos-26`, using the runner image's default Xcode, and node 22 through setup-node v4.4.0. Each run records the actual runner image, Xcode and Swift versions in its logs. All 11 runs must report the same versions; if they differ, the batch is invalid.
- `COVERAGE_ENFORCE` stays `'false'`. Enabling it needs a separate approval.

## Run plan (declared before dispatch)

1. **Run 1, the designated seed.** `gh workflow run ci.yml --ref ci/631-package-coverage-gate -f cold=true -f coverage_cache_seed=true`.
2. **Runs 2–10.** `-f cold=true -f coverage_cache_seed=false`, dispatched one after another without waiting for results.
3. **Run 11, cache-restored.** `-f cold=false`, dispatched only after the seed run has succeeded and saved its cache.

Every dispatch is on the same frozen SHA. The delegator checks each run's `headSha` before counting it.

## Acceptance

- All 11 runs pass every test and produce complete coverage evidence:
  - exactly 100% of lines and functions, under the pinned exceptions;
  - the `ImageSourceHeader.swift` loop-exit throw is hit at least once in every cold run.
- Run 11 shows an actual cache restore from this candidate's seed.
- Local and CI evaluators agree, and the artifacts and overhead are recorded.
- There are no retries, no replacement runs and no exclusions. Any failed run, any miss and any invalid evidence fails the batch.
- Every outcome is reported on #631.
