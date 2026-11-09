# Reproduce an App-test flake on CI

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
