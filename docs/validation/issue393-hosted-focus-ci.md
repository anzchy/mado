# Issue 393: first hosted focus-test slice

WI-1 uses a separate `MadoHostedFocusTests` target with `TEST_HOST` and
`BUNDLE_LOADER` pointing at the production Mado executable. The normal retained
bundle excludes the migrated group, so the combined lane runs each behavior once.
The integration proof checks the real executable, production delegate, running
event loop, timer delivery, activation and exact target key window. Product
behavior assertions and historical test time limits are retained.

## CI evidence

[Run 42754392401](https://github.com/anzchy/mado/actions/runs/42754392401)
executed SHA `ab6edf2cf1a3d25a3bcea16b40e0120986db4358` through
`workflow_dispatch`, attempt 1, runner label `macos-26`. The Hosted focus
diagnostic job succeeded. This is test infrastructure evidence, not device
acceptance or the requested repeated before/after comparison.

Official tdd-guardian 0.10.2 at commit
`188ee8c9df5682a0dad37d35444e40fcbe0bb8f8` verified the original
`i393-WI-1-native-prebuilt` assertion RED as `SEPARATION-HELD`. Its original
immutable fields match the exported RED packet; the proof filter was unchanged.
The independent unfiltered combined App phase then passed **326 functions,
zero failures and zero skips**, with retry disabled. Its hosted subset passed
seven functions comprising twelve executions; the preceding receipt proof
passed one function. Both native processes exited zero without signal/error.

The hosted diagnostic job elapsed 317 seconds (5.2833 observed runner minutes,
not billed minutes). Build took 106.854 seconds; proof native process 8.202
seconds; full hosted subset process 20.488 seconds. The configured package lane
also passed 1787 tests in 43 suites, with line/statement/function coverage 100%.

Earlier run 42739686666 at `0290e4b3` already had native success (seven
functions/twelve executions); its diagnostic job failed because the provisional
parser treated function and argument counts as identical. The parser now checks
both levels and exact argument identities against the actual xcresult schema.

Six earlier Node receipts report `SEPARATION-BROKEN` for explicitly approved
fixture corrections: the Probe selection count and the invented parameterized
result shape. Original receipts are retained. Native/product assertions were
preserved; the original native receipt and independent subsequent guards held.

## Local limits and remaining evidence

A prior executable under Documents waited on a TCC Documents-folder prompt;
the delegator established this from tccd logs. Outside-Documents DerivedData
built successfully, but local key acquisition failed in both synchronous and
controlled asynchronous waits. No production fix or timeout change was made.
Agents never answer consent prompts. The positive evidence above is actual CI
execution, separate from local failures and offline parser replay.

## WI-2 diagnostic comparison

The dispatch-only App host comparison job accepts `app_compare_mode=legacy` or
`hosted`, `app_compare_scope=focus` or `full`, and `app_repeat`. It requires
`app_tests=false`, runs on `macos-26`, disables retry and supplies a fresh empty
quarantine. Results are always diagnostic and cannot supply formal App PASS.
The existing App repeat step is preserved.

`Legacy393Tests` contains the eight original group/helper files, byte-identical
to baseline `c5a087f5949e0f087b96f19d0f4c58a8310a8960`, plus a supplemental
runtime identity proof. Validation rejects changed, missing, extra or nested
sources. Its target retains module name `MadoAppTests` and uses separate
DerivedData. Focus runs the proof followed by exactly six original parent
wrappers, which compile/run the original native children. Full runs the complete
legacy bundle **once**, preserving interactions with retained tests and original
disabled-child skip metadata. The runtime proof and all six parents must execute
once. Hosted mode executes the real App-host mechanism established in WI-1.

The owner explicitly approved correcting a newly recorded Node fixture that
initially prescribed three separate legacy/full runs. That partition would lose
the original full-bundle lifecycle interactions. Original receipts remain; the
new full-context receipt reports separation broken for the approved correction.
Earlier settled comparison receipts describe their earlier verification state,
not a fresh verification of subsequently corrected lines.

Each iteration has distinct token/run identity, outcome, supervision duration,
raw logs and fresh worker evidence. Supervision duration includes discovery and
cleanup; it is not called native-only execution time. Hosted `process.json`
retains actual native process duration. Summary runner minutes measure the
recorded job-start-to-summary window, including build, and are not billing data;
Actions job timestamps supply the complete observed job elapsed time.

For hosts launched outside the worker group, the supervisor checks actual kernel
PID, birth identity, UID, canonical executable and invocation token before each
signal. Unknown ownership refuses overlap. Real OS fixtures cover deadline,
leader exit, SIGTERM/SIGINT, a PID-1-adopted orphan, unrelated-token preservation
and a subsequent iteration after drain. A reproduced interval leak during early
cancel completion has a regression and fix. Hosted comparison CI first runs a
controlled cancellation probe using the same worker/supervisor. Actual token
forwarding is established below; owned cancellation still needs CI evidence.

The four requested owner dispatches use a frozen branch head; verify every run's
`head_sha` equals the final implementation SHA before comparing results:

```sh
gh workflow run ci.yml --repo anzchy/mado --ref ci/393-hosted-focus-tests -f app_tests=false -f app_compare_mode=legacy -f app_compare_scope=focus -f app_repeat=20 -f cold=true
gh workflow run ci.yml --repo anzchy/mado --ref ci/393-hosted-focus-tests -f app_tests=false -f app_compare_mode=hosted -f app_compare_scope=focus -f app_repeat=20 -f cold=true
gh workflow run ci.yml --repo anzchy/mado --ref ci/393-hosted-focus-tests -f app_tests=false -f app_compare_mode=legacy -f app_compare_scope=full -f app_repeat=5 -f cold=true
gh workflow run ci.yml --repo anzchy/mado --ref ci/393-hosted-focus-tests -f app_tests=false -f app_compare_mode=hosted -f app_compare_scope=full -f app_repeat=5 -f cold=true
```

Artifacts are named `app-host-comparison-MODE-SCOPE`. They retain build logs,
repeat/worker timing and provenance, cancellation evidence and hosted raw
xcresult even when the job fails. A complete four-part comparison and overall
workflow completion require all of these native artifacts to be validated.

The local legacy target built successfully after regenerating the project, and
its real bare-`xctest` runtime proof passed 1/1. A fresh configured full-package
unit run subsequently failed: 1787 tests, 157 issues including two known issues.
`Packages/MadoKit` is unchanged in this slice. Its one allowed verification
retry is queued under the shared heavy lock; the first 1800-second queue wait
expired before starting any test, so only the queue budget was extended.
Fresh coverage auditing stopped at that failed contributing lane. Historical
100% coverage above is not a fresh PASS for this candidate.

The owner explicitly approved a WI-2 WIP commit for CI despite this blocked
local gate. This permits a reviewable candidate, not a GREEN verdict. CI script
contracts passed 205/205; TDD script checks passed 281 with zero failures and
two explicit skips. These local results do not establish the pending native
comparison or override the failed unit gate.


## First WI-2 CI results at 1730decf

[Legacy focus run 42763854475](https://github.com/anzchy/mado/actions/runs/42763854475)
completed all 20 iterations successfully through the real frozen worker path.
The comparison job succeeded; the workflow failed its separate name/Node checks.
Artifact SHA-256 `1e066c8d849c8ad89ff91894ce7e5397aaf61b92eca983fcab5bc8497806f67d`
was checked before extraction. Repeats took 528.839 seconds; full comparison job
elapsed 732 seconds = 12.2 observed runner minutes, not billing. Its reported
job-start-to-summary window was 717.815 seconds. Every row has status zero,
unique invocation identity, actual bare-xctest proof and matching baseline hashes.
This is partial evidence at this WIP SHA, not a completed final-SHA comparison.

[Hosted focus run 42763864720](https://github.com/anzchy/mado/actions/runs/42763864720)
failed the cancellation bootstrap before starting the requested repeats.
Artifact SHA-256 `0dd92834f6bcec3e0b052540458754276622b5e08c8d3e481483217c1f6e7588`
was checked. The actual Mado host PID5714, PPID1, UID501 printed exactly the
invocation token, proving Xcode forwarding. Seven functions/twelve executions
passed (Swift Testing root 20.582 seconds), and the worker returned status zero.
But the supervisor never established a kernel host identity: repeated generic
query failures, no owned signals, observed=false/drained=false, probe exit70.
It correctly did not claim cancellation success or start later iterations.

The same first workflow's Node job passed 203/205: one real direct-PID query
returned incomplete and one escaped-host deadline could not prove drain. Cold
Python transport exceeding its 1000ms cap is a hypothesis, not a demonstrated
cause. No query budget, test timeout, retry or cleanup authority was changed.
A diagnostic follow-up adds only sanitized transport stage/status/signal/OS
error code/timing/byte counts and bounded failure samples, before existing real
fixture assertions, for the next CI run to distinguish causes.

The naming failure was four Apple `TEST_RUNNER_` wrappers of the deferred
`PICSEE_TEST_RUN_TOKEN` tooling protocol. Its fix is an exact occurrence-only
exception in the four declared CI tooling paths; neighboring live identities,
foreign paths and near-matches remain rejected. Scanner logic and native
assertions are unchanged. New RED receipts for this rule and query diagnostics
held; combined local CI/name checks passed 247/247 and TDD checks 281/0/2 skipped.
The diagnostic follow-up remains WIP with the same unit and native blockers.
