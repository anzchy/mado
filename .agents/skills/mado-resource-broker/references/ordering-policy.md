# Ordering policy

The scheduler script applies these steps in this order and writes the rule ids it used in `status.md`. Every number named here lives in `~/.mado/broker/config.json` with a note on how it was measured; the values below are **initial and conservative, to be calibrated** (see "Measurement" at the end). A case the rules do not cover is not guessed: it becomes a question in `status.md` against that request.

## Hard constraints (never traded for speed)

- **H1** One `heavy` job at a time on the whole Mac, across both projects, from its grant until `done` (or `abandoned`).
- **H2** `gui` is exclusive: one desktop run at a time. A GUI run does not overlap another GUI run, a job with `network`, or (by default, see C5) a heavy job.
- **H3** A job with `network` in `exclusive` runs alone: no other granted or running job of either project overlaps it.
- **H4** Never grant a job whose `depends_on` is not `done`; a dependency that ends `cancelled` or `abandoned` cancels its dependents.
- **H5** Hold (grant nothing for that resource) while the live facts show a problem: `kern.memorystatus_level` below `min_free_percent` (initial 25), `kern.memorystatus_vm_pressure_level` not normal, or one-minute load above `max_load_per_core` × cores (initial 2.0). These are the quantities `~/.mado/device/ram/with-ram.sh` already samples; observed free percentage during Mado builds was 44–55%. Hold only the resource the problem concerns and say which. An **unknown holder** of `heavy` holds `heavy` only and an unknown holder of `gui` holds `gui` only; neither is touched, both are reported to the owner.
- **H6** Never end, shorten or reorder a running job, and never replace a committed grant.

## Choosing the next job (per free resource, in this order)

1. **Eligible set.** Queued requests of that resource whose dependencies are done, whose `earliest` has passed, and for which H1–H5 hold.
2. **Effective class (aging).** `effective_class = max(1, class − floor(waited / aging_unit))`, with `waited` counted from the original submission and `aging_unit = max(aging_floor_minutes, 3 × p90)` (initial floor 45). A class 3 request therefore reaches class 1 after enough waiting, so nothing starves behind a continuing class 1 stream.
3. **Deadline.** A request whose `deadline` is within `2 × p90` of now gets `effective_class − 1` (floor 1) and is flagged; a deadline that cannot be met is flagged to both delegators and the owner, never met by breaking H1–H6.
4. **Fairness filter.** If one project has had `fairness_max_consecutive` (initial 2) consecutive heavy grants and the other project has an eligible heavy request whose `effective_class` is at most the best candidate's, the candidates are restricted to the other project for this slot. This is a filter applied before the ordering key, so shortest-first cannot override it.
5. **Ordering key** over the remaining candidates: `effective_class` ascending; among requests that have aged at least once, earliest `waited_since` first; otherwise smallest `p90` first (the calibrated value, C6); then earliest submission; then project name.
6. **Backfill reservation.** Let `top` be the best eligible request overall (any resource) that is blocked only because its resource is busy or its dependency is about to finish. A lower-class request may start only if its `p90` finishes before `top`'s expected start; otherwise it waits. This stops a class 3 job from taking `heavy` while a class 1 job (or a GUI run whose build is finishing) is next.

## C5 Heavy and GUI overlap

Off by default (`allow_gui_overlap: false`). When enabled after calibration, a GUI run with `performance_sensitive: false` may overlap a heavy job only if the free memory headroom (`kern.memorystatus_level` converted to GB of the machine's RAM) exceeds the sum of both requests' remaining `ram_gb_peak` plus `reserve_gb`; the declared peaks, not only the current percentage, decide.

## C6 Calibration

Group by `(project, task_kind)`. With at least 5 finished jobs in the last 20, the scheduler orders and plans with `p50 = max(declared p50, median of actuals)` and `p90 = max(declared p90, 90th percentile of actuals)` (never lower than declared, so understating cannot buy priority), keeps `p50 <= p90`, and says in `status.md` when it replaced a number. Below 5 samples it uses the declared values, and the `config.json` default for the kind if the declared ones are missing.

## Windows and overrun

`start_by = not_before + grace_minutes` (initial 10). A running job sends `extend` when elapsed reaches 80% of its current `p90`; at 2 × `p90` the scheduler flags it to both delegators and the owner; it never ends it. An `extend` that delays later granted-but-not-committed jobs makes the scheduler republish those grants with a higher `generation`; committed grants are not replaced (H6), and the affected requesters are told in `status.md`.

## Stall rule (the broker must not block people)

If the heavy lock is free, the eligible set is non-empty and no grant has been published for `stall_minutes` (initial 15) because of H5 conditions alone, the scheduler grants the head of the ordering key anyway and flags why, except for an unknown holder of that same resource, which is only reported.

## What `status.md` shows every cycle

`updated_at`, scheduler PID and generation at the top; then the holders (heavy, gui) with PID and start time from the lock owner files named in `config.json` (the heavy lock records under `~/.mado/locks/` and mdpro's directory lock; the desktop lock directory `~/.cache/desktop-gui.lock/owner`; RClick uses the same files), the unmanaged participants seen, the ordered queue with rule ids and expected start times, live facts, flags (overrun, abandoned, unknown holder, deadline at risk, stall) and questions. Facts older than 3 minutes are marked.

## Measurement (before any number is trusted)

The initial values are not measured for this scheduler. Before the pane is enabled: collect a week of `with-ram.sh` samples and the lock `owner` start and stop times to set `min_free_percent`, `max_load_per_core` and the per-kind default durations; record the result and date next to each number in `config.json`. Until then C5 stays off.
