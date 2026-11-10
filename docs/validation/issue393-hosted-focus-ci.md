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
`Packages/MadoKit` is unchanged in this slice. Fresh coverage auditing stopped
at that failed contributing lane. The first 1800-second queue wait for its one
allowed verification retry expired before starting any test, so only the queue
budget was extended. The eventual retry result is recorded below; the original
failure is preserved and its cause is not established.

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

The diagnostic follow-up at `b8eddefa` added a naming exception. The owner's R1
instruction rejects that approach; the current correction removes the exception
and uses `MADO_TEST_RUN_TOKEN` / `TEST_RUNNER_MADO_TEST_RUN_TOKEN` and Mado names
for the new comparison controls. Scanner logic is unchanged. Earlier receipts
for the exception are superseded; they are retained rather than rewritten.

## R1 corrections and remaining evidence

The legacy/full artifacts show a concrete missing prerequisite: all five runs
failed the retained #611 assertion because the real Debug App at
`.build/dd-ci/Build/Products/Debug/Mado.app/Contents/Info.plist` was absent. The
comparison builder now builds that App before building/running the complete
legacy bundle in its separate DerivedData. It neither substitutes a plist nor
changes the retained assertion. Runs two through five also record #454 folder
row/count/label failures; those separate observed baseline failures remain
visible and their tests are unchanged.

Hosted/full cancellation evidence established the exact host identity, but past
query failures permanently poisoned the tracker and the supervisor attempted
each signal only once. The correction retains bounded diagnostic history while
requiring a fresh complete scan to restore current ownership. Every signal still
requires a fresh PID/birth/UID/executable/token match. The supervisor can retry
an authorization query within the original fixed TERM/KILL phases; it does not
reset or extend either deadline. A targeted query cannot prove global drain.

Real escaped-process fixtures now inject failures independently in TERM and
KILL authorization queries, verify recovery before the fixed drain deadline,
preserve an unrelated same-executable process, and permit the next iteration
only after drain. The focused ownership/cancellation suites passed 30/30.
Original CI transport failure remains undiagnosed: the incomplete direct query
took 1082ms against its 1000ms cap, but the reason it exceeded that cap is not
established. Sanitized diagnostics remain for the next CI run. No query budget
or test timeout was increased.

The owner-mandated namespace fixture correction and earlier approved assertion
corrections remain explicit separation exceptions. New R1 recovery, phase,
prerequisite and naming regressions have genuine RED receipts. Independent
readiness review found no open code findings. The subsequent 16-file R1 review
returned APPROVED WITH NOTES with zero new findings, carrying seven approved
historical separation exceptions and the opaque RED limitation on the Mado
protocol receipt. This scoped approval does not establish native cancellation
or overall workflow completion.

Full CI Node validation acquired the shared heavy lock normally at
2026-11-10 07:43:14 UTC. All six complete command groups passed: portable device
17, Agent tooling 777 plus two explicit skips, Package CI 219, macOS device 3,
name checks 44, release scripts 181. Total: 1241 passed, zero failed, two skipped.
Raw command/status/timing records and complete logs are retained in
`.build/i393-r1-node/`. The single allowed configured unit verification retry
started at 07:45:40 UTC under the same lock and passed: 1787 tests in 43 suites,
two known issues, native root duration 106.459 seconds. The subject command plus
coverage generation took 108.710 seconds; full output and result are
`.build/i393-unit-f-retry.log` and `.build/i393-unit-f-retry-result.json`. It used
the exact configured command without filtering or changing package sources.
Fresh LCOV reports 16701/16701 lines/statements and 3212/3212 functions; branches
are not measured (configured threshold zero). All four native comparisons must
run again at the same corrected SHA before WI-2 can be complete.

## Second WI-2 CI results at d810b12c

All four runs independently match full SHA
`d810b12c01328de83c486bff21ef18bfb1441772`, workflow_dispatch, attempt 1,
macos-26. Legacy focus run42778838008 completed20/20: repeated supervision
467.766s, complete comparison job590s=9.8333 observed runner minutes. Legacy
full run42778866027 completed4PASS/1FAIL, iteration02 #454; repeated supervision
902.764s, complete job1128s=18.8 observed minutes. The real Debug App prerequisite
worked. The #454 failure remains baseline data, without a retry.

Hosted focus run42778851885 failed cancellation before repeats: native tests
passed, but the observer never registered the host. Hosted full run42778879453
registered its actual host and finally proved drain, but recorded no direct
host signal. Both probes correctly returned70. Complete comparison jobs took
208s and215s respectively; these are elapsed time, not billing. All four
required Package Node jobs failed real-kernel timing probes; Walking skeleton
failed as a consequence. Naming checks no longer failed.

The new diagnostics prove repeated1000ms transport expiration with SIGTERM,
ETIMEDOUT and zero output. They do not distinguish Python startup, imports,
enumeration or kernel calls. A local controlled sitecustomize delay reproduces
this startup dependency, but does not prove that hook exists on CI. Local
isolated starts were slower, so isolation is not described as a measured speed
improvement. The concrete design defect is executing repeated synchronous
interpreter launches on the supervisor thread, where one query's cap exceeds
the250ms grace and consumes most1500ms drain. A second race kills the worker/Xcode
session before trying a direct host signal; a coupled host may exit first.

The owner approved preserving the real process assertions in a distinct
**Host ownership integration** step on all four comparison dispatches. Required
Package Node tests retain deterministic identity, protocol, deadline and cleanup
ordering cases. Actual App cancellation remains required. The R2 design prepares
one isolated inspector before the worker under the existing absolute deadline,
uses asynchronous correlated queries capped by1000ms and remaining phase time,
and signals a freshly verified owned host before tearing down its control group.
No query cap or App time-limit policy increase is proposed.

R2 implementation began only after two genuine official REDs: CI integration
step8/35 failed and prepared-inspector/supervisor54/69 failed. Compiling fail
stubs and documentation were present at record time and remain disclosed.
One new recorded coupled-process assertion incorrectly demanded a worker
SIGTERM handler journal, excluding valid KILL and handler-scheduling outcomes.
The owner explicitly approved replacing that oracle with the real external
group-signal call journal, still requiring a verified direct-host signal before
any control-group teardown. Original REDs remain immutable; any BROKEN verdict
will be retained as this accepted exception. All160preexisting assertion
statements remain unchanged through the approved lane relocation.

The corrected R2 source passed79/79 targeted cases and an independent official
verification rerun. The actual short-budget failure was reproduced before its
fix: a global query with8ms of logical time remaining needed22–23ms of processing;
terminal expiry killed the healthy inspector. Logical expiry now rejects that
reply's authority while retaining one physical busy slot. Its matching late
reply is discarded, then a fresh request can proceed. The original physical
start+1000ms hard deadline is never extended. Three strict birth-type cases and
this recovery case produced4/4 focused assertion failures before those fixes;
six privacy/stale-drain cases likewise failed before their fixes.

Full local CI validation acquired the shared lock normally at12:08:25 UTC on
2026-11-10. Every complete command group passed: portable device17, Agent
tooling777 plus2explicit skips, Package CI257, macOS device3, names44, release181,
and real Host ownership integration19. Across those seven CI command executions:
1298 passed, zero failed, two skipped. Complete logs and records are in
`.build/i393-r2-node/`; the report distinguishes repeated command executions
from unique test identities.

The exact configured unfiltered package command then passed1787 tests in43
suites with2known issues, native root119.357s. Subject plus fresh coverage
generation took122.035s, ending12:13:28 UTC. Current LCOV reports147 files,
16701/16701 lines/statements and3212/3212 functions; branches are unmeasured with
configured threshold0. Node/App coverage remains unconfigured. Earlier local
unit failure and its successful R1 retry remain historical evidence; this R2
run is a separate fresh verification, not another retry or a reused report.

The CI-step lane also passes35/35. Its helpers needed two real runner fixes:
remove inherited NODE_TEST_CONTEXT from a new runner, and use a genuine empty
shard plus interruption of the fixture's own runner for zero/crash outcomes.
The actual unchanged strict wrapper returns0/1/70/70 for pass/fail/zero/crash.
Independent statement audit preserves all86original CI assertions exactly and
adds2stronger report checks. Its official receipt nevertheless retains BROKEN
and a High finding because it fingerprints all recorded lines, including the
changed non-assert helpers. This finding is retained for final review; the
coupled-oracle approval does not cover this second file. No receipt was reset
or re-recorded to hide either verdict, and no overall workflow GREEN is claimed.

After the complete local gates and formal review, the owner separately
accepted this CI helper recorded-line exception (「接受此分离例外」). Both current
official BROKEN verdicts and High findings remain intact; review records the
two explicit acceptances rather than rewriting separation history. The fresh
coverage audit passes100% package lines/functions/statements. Actual corrected-
SHA App cancellation and four native comparison waves remain outstanding.


## R3 correction after rebasing onto main05babd67

The R3 hosted-full iter02 retained319-test assertion failure prevented the hosted group from starting. The ownership supervisor correctly refused a missing host registration; iterations03–05 were not started. The coordinator now executes hosted after a reliably completed retained0or1, preserves an earlier1 through hosted0, and lets hosted environment70 dominate. Ownership/drain requirements remain unchanged. A captured retained-failure fixture paired with the **real hosted App** twice confirmed actual registration/drain and that the next iteration starts; this is not an unmodified full-App pass. Both local full-focus attempts timed out in retry442 (first co-occurred with DocumentsTCC, second had no newly observed prompt). They are retained as environment/diagnostic limitations, not native GREEN/RED.

The actual Mado-host key-window regression reproduced1missing pending callback in100delayed-to-ready transitions with the App still running and exact target key. The official native RED repeated that failure and also proved a callback-triggered cancellation was ignored before ready return (one failed function,3issues). The helper now requires an observed native timer callback before success and rechecks cancellation and the original monotonic deadline after servicing. It neither owns the App lifecycle nor extends a timeout. All original assertions remain; new tests distinguish callback entry/running state and exercise cancellation during servicing, with per-transition autorelease pools. The100-transition regression adds work to future hosted comparison timings and is not a pure measure of host-launch overhead.

Official receipts `i393-r3-complete-groups` (RED3/271) and `i393-r3-ready-key-dispatch` (RED1/1,3issues) both verified **SEPARATION-HELD**. Native helper source was unchanged at native record. Its raw Medium already-present warning refers to the separate JS aggregation fix, which already had its own genuine RED/HELD receipt. The warning and nine accepted historical BROKEN/High findings remain retained. After the helper fix, targeted native GREEN and independent official verification each passed the complete key-window function, including100transitions, callback cancellation and all original zero/short/long deadline checks, with owned App/inspector drained/reaped.

Before final validation, the eight-commit stack was rebased from00f2e46f onto `05babd674b0d50dc0e66f79b462000159ea4a9b9` (#636/#634), yielding base `4f9d03818d963edb4596cea7c53d35f6c4bbe18c`. Two `swift-lane.test.mjs` conflicts retained main's appcast assertions and #393 manual lanes; config auto-merged to19lanes. The two-file aggregation WIP patch was byte-identical after exact-stash restoration. Rebase provenance/range mapping is retained in the external handoff evidence.

Fresh local validation on the rebased candidate: seven complete Node CI command groups **1316passed executions,0failed,2explicit skips** (command totals, not unique test identities); exact unfiltered configured Swift unit **1787tests/43suites,2known issues**, native84.623s; command plus fresh coverage reporter86.704s. Independent fresh exact single-LCOV audit passed147package files: L/S16701/16701,F3212/3212=100%. Branches unmeasured with threshold0, criticalPaths none, mutation disabled; App/Node coverage NOT CONFIGURED. Ledger HTML check passed. Independent R3 code/test-quality review APPROVED WITH NOTES, no new High/Medium/Low code findings; raw receipt Medium/history retained. Commit-gate refresh is recorded separately in the handoff.

This is local evidence only. Broader corrected-SHA App cancellation and all four same-SHA comparison dispatches remain required; no full-App or whole-task GREEN, billing-minute figure or performance improvement is claimed. No production entrypoint, sandbox/entitlement, frozen legacy source, quarantine or time-limit-policy change was made. Ledger context VIEW-04/FOLDER-01 is test architecture only; no capability status upgrade.
