# Recorded and derived App outputs for #424 / #425

Complete test-output sections extracted from `gh run view --log-failed` (CI timestamps/step prefixes removed; private home prefixes sanitized to `/SCRATCH/`). No native tests were run to create these fixtures.

- `app-a1.txt`: run 41273898355, attempt 1, A1 180-second test limit.
- `app-a4.txt`: run 41562256618, attempt 1, A4 restore-A-tree wait timeout.
- `app-a5.txt`: run 40993675568, attempt 1, A5 180-second test limit.

Negative and retry outcomes in the tests are explicitly derived mutations of these recordings.

`app-a4-diagnostic.txt` is explicitly derived from `app-a4.txt` for #425 fix1; it is not a native failure capture. Only its recorded issue line changes: the test annotation moves to `305:2`, the restore-A wait call moves to `389`, and an illustrative, path-free `; state: …` payload is appended. The original recording stays unchanged for a negative stale-signature test. A source-location test checks the derived fixture against the live Swift test.

The A4 known-flaky entry covers the 100-second restore-A wait error with diagnostic state. Its 180-second test-time-limit variant is not covered and remains ineligible for retry.


## Sanitized App outputs for #587

These four fixtures retain complete test-output sections from `gh run view --log-failed`, with GitHub timestamps and job/step prefixes removed. They are normalized evidence fixtures, not byte-for-byte raw logs. No native tests were run to create them. Run IDs, attempts and full SHAs are also recorded in `i587-provenance.json`.

| Fixture | Source run / attempt | Normalization |
|---|---|---|
| `i587-140.txt` | 42173760903 / 1 | Pre-rename capture; upload/job tail removed. No historical namespace remains in the retained test section. |
| `i587-521-old.txt` | 42270208258 / 1 | Pre-rename capture; `Picsee` is sanitized to `Mado`, including `PicseeAppTests` → `MadoAppTests` in the child diagnostic. Upload/job tail removed. |
| `i587-521-new.txt` | 42437734660 / 3 | Current-name capture; trailing blank lines normalized. |
| `i587-527.txt` | 42399022708 / 1 | Current-name capture retained as a denied, insufficient-evidence example; trailing blank lines normalized. |

Extraction starts at the first `Test Suite 'All tests' started` line. It preserves child stderr that appears after the outer Swift test-root summary. The first subsequent `##[group]Run actions/upload-artifact` line, when present, starts the discarded post-test tail, including artifact URLs, git configuration and runner paths. App-lane metadata/count lines and GitHub error wrappers are excluded. Any retained runner home path is sanitized to `/SCRATCH/`, matching the convention above; none remains in these retained sections. Each fixture ends with exactly one newline.

The pre-rename module spelling is deliberately normalized under the owner's amendment 2; future signatures match only the current `MadoAppTests` spelling. Original source locations, assertion expressions, pointer values and test timings remain as captured. Negative/retry cases are explicitly derived mutations in the Node tests.


`i587-521-old.txt` is retained only as a negative for obsolete parent source locations 104/105/106. Current retry eligibility requires 110/111/112; the modern capture remains the positive control. Its sanitized child output is historical evidence, not permission to retry current failures at obsolete locations.
