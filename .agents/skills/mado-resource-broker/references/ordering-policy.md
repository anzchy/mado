# Ordering policy

The broker applies these rules in this order and quotes the rule id in `status.md`. If two rules conflict the lower number wins; if a case is not covered the broker asks (a note against the request in `status.md`), it does not improvise.

## Hard constraints (never traded for speed)

- **H1** One `heavy` job at a time on the whole Mac, across both projects. A job holds heavy from its grant window start until `done`.
- **H2** `gui` is exclusive: one desktop run at a time, across both projects. A GUI window is also exclusive of any other job that drives the desktop or needs the network (see H3).
- **H3** A job with `network` in `exclusive` runs alone: no other granted or running job of either project overlaps it, because it takes the Mac offline for everyone (agents, CI polling, downloads).
- **H4** Never grant a job whose `depends_on` is not `done`.
- **H5** Never grant when the live facts show a problem: free memory below 20% or memory pressure above normal, 1-minute load average above 2× the core count, or a lock owner file that does not match the broker's records (an unknown holder). Wait and write the reason; an unknown holder is reported to the owner, never touched.
- **H6** Never end, shorten or reorder a running job.

## Choosing the next job (when heavy or gui is free)

1. **C1 Class first.** Class 1 before 2 before 3. A class 1 request needs a `why`; without one it is treated as class 2 and the broker says so.
2. **C2 Shortest first inside a class.** Smaller `p90` first (it frees the machine soonest), after estimates are calibrated (C6).
3. **C3 Aging.** A request that has waited longer than 3 × its `p90` or 45 minutes (whichever is smaller) moves up one class once; no job is starved.
4. **C4 Project fairness.** Do not give the same project more than two consecutive heavy slots while the other project has a ready request of the same or a higher class.
5. **C5 Batch the desktop.** Group GUI requests so the desktop is taken once for a related run (build, launch, steps, cleanup); do not split a device run across other GUI windows. A GUI window may overlap a heavy job only if `gui.performance_sensitive` is false and the live facts satisfy H5 with at least 40% free memory; otherwise it waits for the heavy job.
6. **C6 Calibrate.** From `history.jsonl`, per task kind (same command family): if two or more finished jobs ran longer than 1.5 × their `p50`, use the historical median × 1.2 as `p50` and the historical 90th percentile as `p90`. Say in `status.md` when a request's numbers were replaced.
7. **C7 Deadlines.** A deadline moves a request up only within its class; if the deadline cannot be met the broker flags it to both delegators and the owner instead of breaking H1–H6.
8. **C8 Ties** by submission time, then by project name.

## Window length and overrun

`valid_until = not_before + p90 + 10 min`. A running job at 80% of its estimate must send `extend`; at 2 × `p50` the broker flags it (status.md plus both delegators); it is never ended. An `extend` that pushes the next granted job is re-ordered by C1–C8, and the affected requesters are told in `status.md`.

## What the broker reports in `status.md` every cycle

Current holders (heavy, gui) with PID and start time from the lock owner files, the ordered queue with rule ids and expected start times, live facts (load, free memory, pressure), flags (overrun, unknown holder, deadline at risk, broker questions), and the time of the last decision. If the facts are older than 3 minutes the file says so at the top.
