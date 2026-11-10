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

WI-2 still needs the same-final-SHA legacy/hosted comparison dispatch commands,
per-iteration durations and launchd-owned host cancellation/drain verification.
No repeated comparison result or overall workflow completion is claimed here.
