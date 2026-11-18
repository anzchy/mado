# Ordering policy

The scheduler script applies these steps in this order and writes the rule ids it used in `status.md`. Every number named here lives in `~/.mado/broker/config.json` with a note on how it was measured; the values below are **initial and conservative, to be calibrated** (see "Measurement" at the end). A case the rules do not cover is not guessed: it becomes a question in `status.md` against that request.

## Hard constraints (never traded for speed)

- **H1** One `heavy` job at a time on the whole Mac, across both projects, from its grant until `done` (or `abandoned`).
- **H2** `gui` is exclusive: one desktop run at a time. A GUI run does not overlap another GUI run, a job with `network`, or (by default, see C5) a heavy job.
- **H3** A job with `network` in `exclusive` runs alone: no other granted or running job of either project overlaps it.
- **H4** Never grant a job whose `depends_on` is not `done`; a dependency that ends `cancelled` or `abandoned` cancels its dependents.
- **H5** Hold (grant nothing for that resource) while the live facts show a problem: `kern.memorystatus_level` below `min_free_percent` (initial 25), `kern.memorystatus_vm_pressure_level` not normal, or one-minute load above `max_load_per_core` × cores (initial 2.0). These are the quantities `~/.mado/device/ram/with-ram.sh` already samples; observed free percentage during Mado builds was 44–55%. Hold only the resource the problem concerns and say which. An **unknown holder** of `heavy` holds `heavy` only and an unknown holder of `gui` holds `gui` only; neither is touched, both are reported to the owner.
- **H6** Never end, shorten or reorder a running job. A published grant is a **plan, not a reservation**: it may be republished (higher `generation`) while its request has not started, for example when a predecessor overruns; admission is decided only by `broker-check` (see "Using a grant" below).

## Choosing the next job (per free resource, in this order)

1. **Candidate set** (before H5): queued requests of that resource whose `earliest` has passed and that are not excluded by H3/H4 ordering. **Eligible set**: the candidates for which dependencies are done and H1, H2, H3, H5 hold now. The ordering key picks from the eligible set; the stall rule and the backfill reservation use the candidate set.
2. **Effective class (aging).** `effective_class = max(1, class − floor(waited / aging_unit))`, with `waited` counted from the original submission and `aging_unit = max(aging_floor_minutes, 3 × p90)` (initial floor 45). A class 3 request therefore reaches class 1 after enough waiting, so nothing starves behind a continuing class 1 stream.
3. **Deadline.** A request whose `deadline` is within `2 × p90` of now gets `effective_class − 1` (floor 1) and is flagged; a deadline that cannot be met is flagged to both delegators and the owner, never met by breaking H1–H6.
4. **Fairness filter.** If one project has had `fairness_max_consecutive` (initial 2) consecutive heavy grants and the other project has an eligible heavy request whose `effective_class` is at most the best candidate's, the candidates are restricted to the other project for this slot. This is a filter applied before the ordering key, so shortest-first cannot override it.
5. **Ordering key** over the remaining candidates: `effective_class` ascending; among requests that have aged at least once, earliest `waited_since` first; otherwise smallest `p90` first (the calibrated value, C6); then earliest submission; then project name.
6. **Backfill reservation.** Let `top` be the best request by the ordering key among the **candidate set of every resource** that satisfies everything except that its resource is busy or a dependency is not yet `done`. `expected_start(top) = max(expected end of the current holder of top's resource, expected end of each unfinished dependency)`, where a running job's expected end is `max(started_at + p90, now)` (an overrunning job counts as ending now, so a reservation never waits on an invented time) and a queued dependency's expected end is its own planned `not_before` + `p90`. A lower-class request may start only if `now + its p90 <= expected_start(top)`; if `expected_start(top)` cannot be computed, no backfill happens and the lower-class request waits. This stops a class 3 job from taking `heavy` while a class 1 job (or a GUI run whose build is finishing) is next.

## C5 Heavy and GUI overlap

Off by default (`allow_gui_overlap: false`). When enabled after calibration, a GUI run with `performance_sensitive: false` may overlap a heavy job only if the free memory headroom (`kern.memorystatus_level` converted to GB of the machine's RAM) exceeds the sum of both requests' remaining `ram_gb_peak` plus `reserve_gb`; the declared peaks, not only the current percentage, decide.

## C6 Calibration

Group by `(project, task_kind)`. The sample is the last 20 finished jobs of the group, newest finish first, `outcome` `passed` or `failed` only (not `cancelled`). With at least 5 samples, sort the actual minutes ascending as `a[1..N]`; the median is `a[ceil(N/2)]` and the 90th percentile is `a[ceil(0.9 × N)]` (nearest rank, no interpolation). The scheduler orders and plans with `p50 = max(declared p50, median)` and `p90 = max(declared p90, 90th percentile)` (never lower than declared, so understating cannot buy priority), keeps `p50 <= p90`, and says in `status.md` when it replaced a number. Below 5 samples it uses the declared values, and the `config.json` default for the kind if the declared ones are missing.

## Windows and overrun

A grant has `not_before` (the planned start) and becomes **usable** at `usable_at = max(not_before, the moment every conflicting predecessor is done or abandoned)`; `start_by = usable_at + grace_minutes` (initial 10), so waiting for an overrunning predecessor never expires a grant. A running job sends `extend` when elapsed reaches 80% of its current `p90`; at 2 × `p90` the scheduler flags it to both delegators and the owner; it never ends it. When a predecessor overruns or extends, the scheduler republishes the grants of requests that have not started with a higher `generation` and a new `not_before`, and says so in a notice and in `status.md`.

## Using a grant (admission)

`broker-check <id>` under the directory lock returns `GO` only if the grant file is the same generation the requester read, `start_by` has not passed, and **every conflicting predecessor in `state/` is `done`, `abandoned` or `cancelled`**: the previous job on the same resource, any running `gui` job for a `gui` request or `network` job (H2, H3), and any running job at all for a `network` request. Otherwise it returns `WAIT <new not_before>` or `INVALID` (expired or replaced: read the new grant). The requester never starts the real lock on `WAIT`. A `running` event for an expired or replaced grant is rejected, so a requester that waited inside `heavy-lock.sh` past `start_by` must re-check.

## Stall rule (the broker must not block people)

If the real lock of the resource is free, the **candidate set** is non-empty and no grant has been published for `stall_minutes` (initial 15) **because of the load-average or `min_free_percent` conditions of H5 alone**, the scheduler grants the head of the ordering key and flags why. The stall rule never bypasses `kern.memorystatus_vm_pressure_level` above normal (the 2026-10-29 out-of-memory crash was exactly that situation; the requester fallback below gives liveness instead), never bypasses an unknown holder of the same resource (reported only), and never bypasses H1–H4.

## What `status.md` shows every cycle

`updated_at`, scheduler PID and generation at the top; then the holders (heavy, gui) with PID and start time from the lock owner files named in `config.json` (the heavy lock records under `~/.mado/locks/` and mdpro's directory lock; the desktop lock directory `~/.cache/desktop-gui.lock/owner`; RClick uses the same files), the unmanaged participants seen, the ordered queue with rule ids and expected start times, live facts, flags (overrun, abandoned, unknown holder, deadline at risk, stall) and questions. Facts older than 3 minutes are marked.

## Measurement (before any number is trusted)

The initial values are not measured for this scheduler. Before the pane is enabled: collect a week of `with-ram.sh` samples and the lock `owner` start and stop times to set `min_free_percent`, `max_load_per_core` and the per-kind default durations; record the result and date next to each number in `config.json`. Until then C5 stays off.
