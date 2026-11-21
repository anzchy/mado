# Reproduce an App-test flake on CI

Known-flaky local node tooling tests are listed in `.agents/skills/mado-verify/known-flakes.json`, normally empty; each entry carries `issue`, `owner` and `expires` (at most 30 days out) and an expired entry fails the node lane (#759). The two-rerun procedure is mado-verify SKILL.md step 1. App-test quarantine is `scripts/tdd/app-quarantine.json` (`docs/agents/test-lanes.md`). This page covers App tests on CI.

Reproduce before fixing. Reproduce on CI first: a local pass does not rule out a runner timing problem (#597, #587).
Push the diagnostic branch, then dispatch one test ×20 or the full bundle ×5:

```sh
gh workflow run ci.yml --ref <branch> -f app_filter=issue606StateRedactionIsIdempotentAndKeepsSafeText -f app_repeat=20
gh workflow run ci.yml --ref <branch> -f app_filter= -f app_repeat=5
```

`app_filter` is a regular expression over runtime test IDs. Empty or whitespace-only selects the full bundle. A repeat count above 1 enables reproduction mode: build once, use an empty temporary quarantine, disable retries, and continue after failures. Every dispatch validates that the count is an integer from 1 to 50 before building, including build-only dispatches; zero, negative, fractional and excessive counts fail clearly. A count of 1 keeps ordinary CI behavior, including its quarantine and bounded retry; the filter applies only in reproduction mode. Push and PR behavior is unchanged.

Find `01 PASS` / `02 FAIL <test names>` and a total in the App tests job summary. Download its single `app-repeat` artifact for `.build/app-repeat/iter-01.log`, `iter-02.log`, etc. Infrastructure failures are also FAIL and point to the iteration log. The ordinary path retains `app-lane-attempt1`.

Only repeat dispatches raise the job timeout from 45 to 120 minutes. The loop's deadline is 115 minutes after the first job step (including build time), reserving 5 minutes for upload. Each iteration runs in a private process group. At its deadline the supervisor sends TERM, then KILL after a short grace, and checks that no live group members remain before another iteration may start. A surviving or unverifiable group prevents subsequent iterations from launching. The repeat worker requires the CI-provided machine-lock authorization; use workflow dispatch for reproduction. Exhausted iterations receive FAIL logs without launching tests. A failure or exhausted budget makes the step fail.

A wait failure on the main thread prints a read-only AppKit snapshot synchronously with `appkit:` prefixes. A background failure returns its error immediately and schedules the snapshot on the main queue with `appkit(async):` prefixes; that later snapshot may describe a changed state. The snapshot includes activation, key/main windows, and one line per window with visibility, level, sheet and alert text. AppKit has no public window-to-NSAlert association, so only the first two noneditable labels are collected, with at most 256 views visited. Capture is limited to 20 windows (then `+N more windows`); each printed line, including its prefix, is under 1024 characters. Long text is truncated with `…`. Paths in titles/text are reduced to their last component; a home directory alone becomes `[home]`. The error description stays unchanged so existing exact failure signatures still match. This does not change AppKit classes or window state.

Each run consumes macOS runner minutes. Use a focused filter before repeating the whole bundle.

## Failed attempts hidden by reruns (#788)

A rerun that ends green hides the failed first attempt. Before merging, list every failed job attempt of a PR:

```sh
node scripts/ci/attempt-history.mjs --pr <n>                     # or --sha <head-sha>; --body-file <draft body>
node scripts/ci/attempt-history.mjs --pr <n> --require-tickets   # exit 1 while a needs-ticket line remains
```

It prints one table row per failed job attempt (attempt, failed step, failing tests from the job log, whether a later attempt or a green/cancelled run hid it) and one line per failing test. A test is `ticketed` when a PR body line names it together with `#<issue>`, or when one of the ticket sources lists it with an issue: `scripts/tdd/app-quarantine.json` (by the last `.`/`/` part of its `id`), `.agents/skills/mado-verify/known-flakes.json` or `scripts/ci/known-flaky.mjs`. Otherwise it is `needs-ticket`. A failed job whose test names cannot be read (expired log, crash or signal, timed-out job) is `needs-ticket-unknown`. Other failed jobs with no test names (Walking skeleton, upload steps) are `no-test-names` and need no ticket. PR mode reads the PR's head-branch runs and drops (`excluded:`) runs whose metadata shows another PR. `--sha` needs the full 40-character SHA.

Advisory by default (exit 0). `--require-tickets` fails closed: exit 1 while a `needs-ticket` or `needs-ticket-unknown` line remains, and exit 2 when a ticket source is missing or does not load, or when no run is found. Usage or API errors exit 2. `--fixture <json>` replays recorded responses without network and `--record <json>` writes new ones (`scripts/ci/fixtures/attempt-history/`).
