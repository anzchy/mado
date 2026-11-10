# #632 audit fix round1 — M1 verification COMPLETE

Base c6f3bf04. M1 only; M2 fixture budget/L1 and L2–L4 remain outside this commit. No App/Package source or workflow changes; no coverage policy change. Native commands use the standing owner-approved temporary CI split until632lands; no configured full-parallel native PASS claimed.

## Behavior

External INT/TERM/HUP cancels async diagnostic/snapshot subprocess groups, enumerates owned work before leader termination, validates remembered descendants by PID+command (one whole1s batch if full enumeration fails), TERM then short grace/KILL/reap before exit. First signal controls status unless deadline already committed124. Tests assert death at follower admission and signal-to-admission<8s within parent10s. Normal600s deadline/capture90/grace15/timeout124 retained. If both OS queries fail, explicit unverified-ownership/group-only warning documents the limit. No temporary debug hooks remain.

## RED and fixture exception

- Independent real auditor pattern reproduced before implementation: heavy-lock exit-15, follower0, Swift alive at admission; finally cleaned before releasing the outer lock.
- I632-FIX-R1-WI-1 recorded assertion-failure5/12 before production edits. Later I632-FIX-R1-WI-1-FALLBACK recorded2/13 against partial implementation; its dirty-source Medium remains explicit.
- New ps fixture immediate process.exit truncated stdout: expected152246/captured65536bytes despite exit0. Affected orphan/fallback path-specific RED setup was compromised; do not claim every recorded failure proved its intended path.
- Corrected natural pipe drain: independent145904/145904bytes, SHA and last record match. Atomic successful snapshots plus actual helperPID/full-command proof strengthen setup. Original C6 testprefix byte-identical; every earlier M1 behavioral assertion/timing input preserved.
- Corrected private diagnostic copies use real historical C6 and exact pre-fallback implementation hashes, with only3 path-plumbing substitutions. Both validate complete helper snapshots then fail specifically at follower admission with[false,true]. Diagnostic counterfactuals, NOT retroactive TDD RED receipts.
- Corrected current pair2/2PASS9.269s. Both official receipt verifications subsequently ran the13-test lane GREEN, then reported actual High SEPARATION-BROKEN due changed helper lines. Both findings retained; no re-record, no relabelling. Independent reviewer accepted the demonstrated fixture-I/O correction with notes. See amendment-20261110-i632-fix-r1-fixture-io.md.

## Gates and review

- Existing watchdog API/runtime suite16/16PASS,0fail/error/skip,18.214s.
- Fresh native split1079+708=1787tests/43suites PASS,48.083s+68.742s; two known issues in non-MacUI only. Same test binary, current profiles merged; original exporter/official parser/100% thresholds PASS:16701/16701lines,3212/3212functions, statements mirrorlines. Branches unmeasured; critical paths NOT CONFIGURED; mutation disabled. Generated-closure limitation and lack of JS instrumentation disclosed in coverage audit.
- Independent final code review APPROVED WITH NOTES; prior Medium resolved. Fresh coverage audit PASS. Native/source7hashes match final candidate. All jobs sequential under heavy-lock7200; no gate-bypass env used.
- These fresh owner-authorized split/coverage gates satisfy this fix's taskCompleted/commit native acceptance. No passing configured full-parallel run fabricated. Node tooling behavior has real process/lock/signal integration coverage.

Raw evidence in gpt-imple-1 evidence dir: i632-fix-r1-auditor-repro.log; m1-red.log/fallback-red.log; pre-fallback-raw.log; ps-{truncation,corrected}-proof.json; counterfactual/{sources,results}.json and case logs; corrected-pair.log; final-verify-{original,fallback}.log/m1-verify-results.json; existing-watchdog.log; native/results.json; coverage.json/.log; final-source-hashes.json (all prefixed i632-fix-r1 where applicable). Temporary traces remain private historical evidence only.

Refs #632. Tooling only; no user-visible ledger row. No push/PR. Round remains active until M2 complete; L2–L4 Still open.
