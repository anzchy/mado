# Ordering policy

The scheduler script applies these steps in this order and writes the rule ids it used in `status.md`. Every number named here lives in `~/.mado/broker/config.json` with a note on how it was measured; the values below are **initial and conservative, to be calibrated** (see "Measurement"). A case the rules do not cover is not guessed: it becomes a question in `status.md` against that request.

## Tokens and the conflict table

A lease holds **tokens**: a `heavy` request holds `{heavy}`, a `gui` request holds `{gui}`, a request with `network` in `exclusive` holds `{all}` (every token). Two requests conflict if they hold a common token, or if the table says so:

| | heavy | gui | network |
|---|---|---|---|
| **heavy** | conflict | conflict (default, see C5) | conflict |
| **gui** | conflict (default) | conflict | conflict |
| **network** | conflict | conflict | conflict |

The table lives in `config.json` (`conflicts`); the only entry intended to change is heavy↔gui, after calibration. A lease is **active** from the moment its file is written until the job reaches `done`, `cancelled` or `abandoned`, or the lease expires **unclaimed**; a claimed or running job keeps its lease even past its estimate. **Every real-lock holder visible in the owner files that is not the job of a lease or claim** (an unmanaged participant, an mdpro job; a fallback job holds a fallback claim and is treated as a claim) counts as an active **pseudo-lease** holding the tokens of its kind (`heavy` for the heavy lock, `gui` for the desktop lock) and the table applies to it exactly as to a lease; the broker cannot stop it but never issues a lease the table forbids against a holder it can see. **Identity matching:** an owner-file PID belongs to a lease or claim when it equals the claimant's wrapper PID or is its descendant in the process tree read with `ps` at tick time; an owner record whose PID is gone but whose `started` time is not earlier than a claim's `claimed_at` and for which no other holder is visible is counted as that claim's own (conservative: it is not double counted as a pseudo-lease); any other record is a pseudo-lease.

## Hard constraints

- **H1** The scheduler issues a lease only if no active lease conflicts with it, per the table. Together with "a lease is the only admission" this is the whole mutual-exclusion rule of the broker: at most one `heavy`, at most one `gui`, `network` alone, heavy and gui together only if the table allows it.
- **H2** Never issue a lease to a request whose `depends_on` is not `done`; a dependency that ends `cancelled` or `abandoned` cancels its dependents.
- **H3** Hold (issue nothing for that token) while the live facts show a problem: `kern.memorystatus_level` below `min_free_percent` (initial 25), `kern.memorystatus_vm_pressure_level` not normal, or one-minute load above `max_load_per_core` × cores (initial 2.0). These are the quantities `~/.mado/device/ram/with-ram.sh` already samples; the observed free percentage during Mado builds was 44–55%. An **unknown holder** is handled as a pseudo-lease (see above), reported to the owner and never touched.
- **H4** Never end, shorten or revoke a running job or an active lease. A lease ends by `done`, `cancel`, expiry unstarted, or `abandoned`.

## Choosing the next request (each tick, in this order)

1. **Eligible set.** Queued requests whose dependencies are done, whose `earliest` has passed, with no conflicting active lease, and for which H3 holds.
2. **Effective class (aging).** `effective_class = max(1, class − floor(waited / aging_unit))`, with `waited` from the original submission and `aging_unit = max(aging_floor_minutes, 3 × p90)` (initial floor 45). A class 3 request reaches class 1 after enough waiting, so nothing starves behind a continuing class 1 stream.
3. **Deadline.** A request whose `deadline` is within `2 × p90` of now gets `effective_class − 1` (floor 1) and is flagged; a deadline that cannot be met is flagged to both delegators and the owner, never met by breaking H1–H4.
4. **Fairness filter.** If one project has had `fairness_max_consecutive` (initial 2) consecutive heavy leases and the other project has an eligible heavy request whose `effective_class` is at most the best candidate's, the candidates are restricted to the other project for this slot (a filter before the ordering key, so shortest-first cannot override it).
5. **Ordering key** over the remaining candidates: `effective_class` ascending; among requests that have aged at least once, earliest `waited_since` first; otherwise smallest `p90` first (the calibrated value, C6); then earliest submission; then project name.
6. **Protect the next higher-class jobs.** Let `tops` be **every** queued request of higher effective class than the candidate that depends, **directly or through a chain of queued requests**, on a request that currently holds an active lease and whose only missing conditions are those dependencies. Its expected start is the active lease's expected end, `max(started_at + p90, now)` (an overrunning job counts as ending now), plus the `p90` of each queued request in the chain between them. A candidate that conflicts with any member of `tops` is issued a lease only if `now + its p90 <= expected start` of **each** conflicting member; otherwise it waits. If `tops` is empty, this step does nothing.

The first candidate that survives steps 1–6 gets the lease; at most one lease is issued per tick per token set, and the tick re-evaluates after each issue.

## C5 Heavy and GUI overlap

Off by default (`conflicts.heavy_gui: true`). It is a **pair predicate evaluated in both directions**, whichever request of the pair is being leased now (a GUI request while a heavy lease is active, or a heavy request while a GUI lease is active). When switched off after calibration, a pair may overlap only if the GUI request has `performance_sensitive: false` and the free memory headroom (`kern.memorystatus_level` converted to GB of the machine's RAM) exceeds the sum of both requests' remaining `ram_gb_peak` plus `reserve_gb`; the declared peaks, not only the current percentage, decide.

## C6 Calibration

Group by `(project, task_kind)`. The sample is the last 20 finished jobs of the group, newest finish first, `outcome` `passed` or `failed` only. With at least 5 samples, sort the actual minutes ascending as `a[1..N]`; the **lower median** is `a[ceil(N/2)]` and the 90th percentile is `a[ceil(0.9 × N)]` (nearest rank, no interpolation). The scheduler orders and plans with `p50 = max(declared p50, lower median)` and `p90 = max(declared p90, 90th percentile)` (never lower than declared, so understating cannot buy priority), keeps `p50 <= p90`, and says in `status.md` when it replaced a number. Below 5 samples it uses the declared values, and the `config.json` default for the kind if the declared ones are missing.

## Lease timing

`start_by = granted_at + grace_minutes` (initial 10); a lease **not claimed** by then expires and the request returns to the queue with its original submission time; a lease claimed by `broker-check` never expires (see SKILL.md, steps 3 and 7). `expires_at = granted_at + grace_minutes + p90` is the planned end; it never ends a running job (H4). A running job sends `extend` at 80% of its current `p90`; at 2 × `p90` the scheduler flags it to both delegators and the owner. The lease stays active until `done`, `cancel` or `abandoned`.

## Stall rule (the broker must not block people)

If the candidate set (step 1 without the H3 condition) is non-empty, no conflicting lease is active, the real locks are free per their owner files, and nothing has been issued for `stall_minutes` (initial 15) **because of the load-average or `min_free_percent` conditions of H3 alone**, the scheduler issues the lease to the head of the ordering key and flags why. The stall rule never bypasses `kern.memorystatus_vm_pressure_level` above normal (the 2026-10-29 out-of-memory crash was that situation; the requester fallback gives liveness instead), never bypasses an unknown holder of a token the request needs, and never bypasses H1, H2 or H4.

## What `status.md` shows every cycle

`updated_at`, scheduler PID and generation at the top; then the holders (heavy, gui) with PID and start time from the lock owner files named in `config.json` (the heavy lock records under `~/.mado/locks/` and mdpro's directory lock; the desktop lock directory `~/.cache/desktop-gui.lock/owner`; RClick uses the same files), the unmanaged participants seen, active leases with their remaining planned time, the ordered queue with rule ids and expected order (an estimate, not a promise), live facts, flags (overrun, abandoned, unknown holder, deadline at risk, stall) and questions. Facts older than 3 minutes are marked.

## Notices

`notices/<requester>.md` lines come from fixed templates filled with validated tokens only: a per-requester sequence number, request id, a code (`LEASED`, `EXPIRED`, `OVERRUN`, `ABANDONED`, `BLOCKED-BY-UNKNOWN-HOLDER`, `DEADLINE-AT-RISK`, `STALL`, `QUESTION`, `STALE-BROKER`), a number or a timestamp. No text taken from a request, event or owner file appears in a notice.

## Measurement (before any number is trusted)

The initial values are not measured for this scheduler. Before the pane is enabled: collect a week of `with-ram.sh` samples and the lock `owner` start and stop times to set `min_free_percent`, `max_load_per_core` and the per-kind default durations; record the result and date next to each number in `config.json`. Until then C5 stays off.

Delivery is best-effort and idempotent: every line carries its sequence number, delegators de-duplicate on it and read `notices/` and `status.md` directly, so a repeated or missed relay by the monitor (for example after its daily `/clear`) is harmless.
