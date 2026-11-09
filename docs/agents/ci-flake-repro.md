# Reproduce an App-test flake on CI

Reproduce before fixing. Reproduce on CI first: a local pass does not rule out a runner timing problem (#597, #587).
Push the diagnostic branch, then dispatch one test ×20 or the full bundle ×5:

```sh
gh workflow run ci.yml --ref <branch> -f app_filter=issue606StateRedactionIsIdempotentAndKeepsSafeText -f app_repeat=20
gh workflow run ci.yml --ref <branch> -f app_filter= -f app_repeat=5
```

`app_filter` is a regular expression over runtime test IDs. Empty selects the full bundle. A repeat count above 1 enables reproduction mode: build once, use an empty temporary quarantine, disable retries, and continue after failures. The cap is 50; invalid counts are rejected. A count of 1 keeps ordinary CI behavior, including its quarantine and bounded retry; the filter applies only in reproduction mode. Push and PR behavior is unchanged.

Find `01 PASS` / `02 FAIL <test names>` and a total in the App tests job summary. Download its single `app-repeat` artifact for `.build/app-repeat/iter-01.log`, `iter-02.log`, etc. Infrastructure failures are also FAIL and point to the iteration log. The ordinary path retains `app-lane-attempt1`.

Only repeat dispatches raise the job timeout from 45 to 120 minutes. The loop's deadline is 115 minutes after the first job step (including build time), reserving 5 minutes for upload. Every native subprocess is bounded by the remaining budget. Exhausted iterations receive FAIL logs without launching tests. A failure or exhausted budget makes the step fail.

Immediately before a wait failure is thrown, the log prints a read-only AppKit snapshot with `appkit:` prefixes: activation, key/main windows, and one line per window with visibility, level, sheet and alert text. Alert message/informative text is read from the alert panel's visible text fields (AppKit has no public window-to-NSAlert association). Paths in titles/text are reduced to their last component; a home directory alone becomes `[home]`. The error description stays unchanged so existing exact failure signatures still match. This does not change AppKit classes or window state.

Each run consumes macOS runner minutes. Use a focused filter before repeating the whole bundle.
