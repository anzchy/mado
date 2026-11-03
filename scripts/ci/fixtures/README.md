# Recorded and derived App outputs for #424 / #425

Complete test-output sections extracted from `gh run view --log-failed` (CI timestamps/step prefixes removed; private home prefixes sanitized to `/SCRATCH/`). No native tests were run to create these fixtures.

- `app-a1.txt`: run 41273898355, attempt 1, A1 180-second test limit.
- `app-a4.txt`: run 41562256618, attempt 1, A4 restore-A-tree wait timeout.
- `app-a5.txt`: run 40993675568, attempt 1, A5 180-second test limit.

Negative and retry outcomes in the tests are explicitly derived mutations of these recordings.

`app-a4-diagnostic.txt` is explicitly derived from `app-a4.txt` for #425 fix1; it is not a native failure capture. Only its recorded issue line changes: the test annotation moves to `305:2`, the restore-A wait call moves to `389`, and an illustrative, path-free `; state: …` payload is appended. The original recording stays unchanged for a negative stale-signature test. A source-location test checks the derived fixture against the live Swift test.

The A4 known-flaky entry covers the 100-second restore-A wait error with diagnostic state. Its 180-second test-time-limit variant is not covered and remains ineligible for retry.
