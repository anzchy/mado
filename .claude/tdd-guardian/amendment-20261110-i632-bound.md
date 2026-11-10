# #632 bounded-run fixture timing amendment

Original RED is preserved: `I632-BOUND-WI-1`, assertion-failure, 6 of 7 tests failed. It was recorded before the implementation replaced the compilable API stub. No RED was re-recorded after implementation.

The original 0.5-second integration-test budget incorrectly assumed a fresh Node executable fixture could always start within that interval on this Mac. During GREEN, normal fixtures sometimes first produced their completed output after the watchdog's deadline, and a hang fixture was killed before reaching its first leader-PID write. This was fixture startup timing, not a change to the required 600-second production limit. Removing unnecessary high-frequency snapshot overrides from the wrapper left the existing watchdog defaults intact but did not eliminate the fixture-startup condition.

With explicit orchestration approval, three recorded fixture-input lines changed:

- `scripts/tdd/unit-lane.test.mjs`, `run()` options construction: the fixture run budget is now 2 seconds.
- The same file's Python lock-holder command: its isolated queue hold changes from 1.2 to 3.2 seconds, still longer than the actual execution budget. A stronger additional assertion checks queue elapsed time exceeds 2000ms; the original assertion remains.
- `.agents/skills/picsee-delegator/scripts/owner-gates.test.mjs`, external Node launch shim: its exported-function fixture budget changes from 0.5 to 2 seconds.

Behavioral assertions are unchanged: status/output/no retries; timeout124; actual leader/helper death; retained diagnostics; under15-second overall completion; independent follower lock admission; unique preserved logs; owner truthful summary and rejection of stale coverage; unchanged production600 and coverage thresholds. The hang fixtures' five-second safety exit remains later than the two-second watchdog deadline; exit124 proves the watchdog, rather than that safety exit, ended the run.

The receipt verifier may report the three input-line changes as SEPARATION-BROKEN. Carry this report to the final review; do not overwrite the original receipt or claim no specification file lines changed. No recorded behavioral assertion was relaxed.
