---
name: mado-resource-broker
description: Schedule the shared Mac between Mado and RClick. Delegators submit a request (task, duration, resources) before any heavy or GUI job; a deterministic scheduler script orders the queue and writes grants, and a Haiku monitor pane runs it, explains it and raises flags. Use when submitting, waiting for or ordering heavy-lock and GUI-lock work, or when running the broker pane. Not for holding locks, killing processes, or running tests.
---

# mado-resource-broker

One Mac, two projects (Mado and RClick), two delegators, one heavy lock and one desktop. Today the locks give mutual exclusion in arrival order (`scripts/heavy-lock.sh`, `.agents/skills/mado-delegator/scripts/gui-lock.sh`); nobody knows what is coming, how long it takes, or whether a short job is stuck behind a long one. The broker adds **order and admission**, decided from declared requests and measured load.

## Design in one paragraph

**The scheduling decision is made by a deterministic script (`scripts/broker-tick.mjs`), not by the model.** The script validates requests, applies `references/ordering-policy.md`, does all the arithmetic (aging, windows, calibration, expiry), and writes grants and `status.md` atomically. The Haiku pane (`mado-resource-broker`) **runs that one script each cycle, reads its output, explains it, and raises flags** (overruns, unknown holders, questions to a requester). The model never ingests request text as instructions and cannot choose a different order than the script computed. This keeps the cheap model on a job it can do and keeps the safety boundary in code, not in prose.

## What the broker is, and is not

- It **orders and grants** by writing files under `~/.mado/broker/`. Requesters wait for their grant before they take a lock.
- It **never holds, releases, reclaims or removes a lock, never kills a process, never edits a repository, never runs a build or test.** Mutual exclusion stays in the lock tools. A lock that looks stale is reported to the owner in `status.md`, never touched (AGENTS.md, `docs/agents/heavy-lock.md`).
- It is **cooperative**: the real locks protect everyone whether or not the broker is used; the broker can only order requesters who submit. Not enforced by anything: `network` exclusivity (nothing locks the network), and participants who do not submit (mdpro, an implementer's own lane, CI polling). `status.md` says which participants are unmanaged.

## Roles

| Role | Who | Does |
|---|---|---|
| Requester | `mado-delegator`, `rclick-delegator` (implementers go through their delegator) | submits, waits for the grant, checks it again right before the real lock, runs the job under the real lock, reports |
| Scheduler | `scripts/broker-tick.mjs` | the only writer of grants, `status.md`, `state/`, `history.jsonl` |
| Monitor | herdr pane `resource-broker`, `claude --agent mado-resource-broker`, model Haiku | runs the tick, reads `status.md`, relays the scheduler's notices to the named delegators, flags anomalies to the human in its pane, never decides order |
| Owner | the human | stale locks, disputes, deadline conflicts, anything flagged |

## Data directory `~/.mado/broker/` (mode 0700, outside every repository, shared by both projects)

```
config.json            thresholds and timings (every number in the policy lives here, with its measurement note)
requests/<id>.json     written once by the requester, immutable (references/request-format.md)
events/<id>.<n>.json   requester reports (running, extend, blocked, done, cancel), one file per event, created exclusively and atomically (`link`)
notices/<requester>.md  append-only, written only by the scheduler from validated fields: grants, waits, flags, questions for that requester (delegators read it on every poll; the monitor relays unsent lines)
.lock                  the directory lock: the scheduler holds it for a whole read-decide-write, `broker-check` takes it for the check
grants/<id>.json       written only by the scheduler (rename), with a per-request generation that rises when the grant is republished
state/<id>.json        derived lifecycle state, written only by the scheduler
status.md              written only by the scheduler: holders, queue with rule ids, live facts, flags, questions, heartbeat
history.jsonl          append-only, scheduler: one line per finished job
events.log             append-only, scheduler
```

All writes are tmp-file + atomic rename; ids are created with exclusive create (`O_EXCL`), so two submitters cannot collide. No secrets, tokens, personal data or file contents in any of these files; the `task` text is one neutral line of at most 120 characters of `[A-Za-z0-9 #._:/+-]`, validated and treated as data everywhere (never shown to the model as an instruction; the model sees an escaped, quoted copy).

## Lifecycle

`submitted → queued → granted → running → done | cancelled | expired | abandoned | blocked`

1. **Submit** one request per **top-level wrapper job**: one `owner-gates.sh` run, one `scripts/tdd/*-lane.mjs` call that takes the lock itself, one `swift test`/`xcodebuild`/`xcodegen` via `scripts/heavy-lock.sh`, one signed build, one device run (GUI). A request covers every nested heavy-lock acquisition inside that wrapper. A GUI run that follows a build is its own request with `depends_on`.
2. **Grant.** The scheduler writes `grants/<id>.json`: `not_before` (the plan), `generation`, and the rule used; the grant becomes usable only when its conflicting predecessors are done (`usable_at`), and `start_by` = `usable_at` + grace. A grant is a plan, not a reservation. Until it exists the requester does not call the lock script.
3. **Check, then run.** Immediately before taking the real lock the requester runs `scripts/broker-check.mjs <id>`, which under the directory lock returns `GO` only if the grant is the generation the requester read, unexpired, **and every conflicting predecessor is `done`, `abandoned` or `cancelled`** (the previous job on the resource; a running GUI job for a GUI request; any running job for a `network` request); otherwise `WAIT <new not_before>` or `INVALID`. Only on `GO` it takes the real lock (`scripts/heavy-lock.sh <cmd>`, `gui-lock.sh acquire …`) and writes the `running` event with its wrapper PID and start time. If the real lock is held by someone outside the order, the requester waits at most `wait_for_foreign_holder_minutes` and writes `blocked` naming the holder from its owner file; it never barges in and never touches the holder.
4. **Overrun.** At 80% of `p90` the requester sends `extend` with a new `p50`/`p90`; at 2 × `p90` the scheduler flags it to both delegators and the owner; it never ends the job.
5. **Done.** The requester reports `done` (actual minutes, outcome `passed|failed|cancelled`, peak RAM if measured); the scheduler appends `history.jsonl`.
6. **Dead requester.** The scheduler checks the PID and start time of every `running` job each cycle. If the wrapper is gone and the real lock is free or held by a different start time, the job becomes `abandoned` (not killed, nothing removed), dependents are cancelled with a note, the flag goes to the owner. If the real lock is still held by that wrapper's process tree, the job stays `running`.
7. **Unused grant.** A grant not started by `start_by` (counted from when it became usable, so waiting for an overrunning predecessor does not expire it) expires; the request is re-queued with its original submission time (it keeps its aging). A `running` event for an expired or replaced grant is rejected, so a requester that waited inside `heavy-lock.sh` past `start_by` must check again.

## Fallback and liveness

- `status.md` carries `updated_at`, the scheduler's PID and a `generation`. **If `updated_at` is older than `stale_after_minutes`, or a queued request has no grant within `grant_wait_minutes` while no conflicting holder exists on `heavy`, `gui` or `network` (judged from the lock owner files and `state/`, not from the heavy lock alone),** a requester may proceed the old way (plain lock arrival order) and must say so in its handoff. The broker is advisory: a stalled or wrong broker can slow people down, never block them forever or override a lock.
- When a `network` job runs, nothing the broker pane does needs the network except the model call: the scheduler script keeps running (no network needed); the Haiku pane may be deaf for that window. The requester of a `network` job states the expected minutes and tells the other delegator through the request; the Mac coming back online is reported by `done`.
- **Exactly one runner** executes the tick, configured in `config.json` as `runner: pane` or `runner: launchd`; the tick takes the directory lock non-blocking for its whole read-decide-write and exits at once if another instance holds it, so two ticks can never publish interleaved grants. With `runner: launchd` scheduling does not depend on the model or on the network; the pane then only monitors.

## Broker pane rules (the safety boundary is in the configuration, not in this prose)

- The agent definition allows exactly: Read, Grep, Glob, and Bash limited to the three commands `node scripts/broker-tick.mjs`, `node scripts/broker-check.mjs`, and `node scripts/broker-status.mjs` (read-only facts), plus read-only inspection (`cat`, `ls`, `date`) inside `~/.mado/broker/`. Everything else is denied by the pane's permission configuration, including `git`, `kill`, `rm`, any call of `heavy-lock.sh` or `gui-lock.sh`, and any path outside `~/.mado/broker/`; the denied list also names `~/.mado/locks`, `~/.cache/desktop-gui.lock`, `~/.cache/desktop-gui.mutex`, `~/.cache/mdpro-heavy.lock` and `~/.mado/herdr/delegator/lock-alerts/`. A conformance test (a pane given a hostile `task` string and a direct request to run `rm` and `kill`) must pass before the pane is used; whether the agent frontmatter can express the command restriction itself is **to be verified**, the fallback is a pane-specific settings file passed at launch.
- Loop: the pane is started with a 60-second schedule (`/loop 1m …`; whether that is the right mechanism is to be verified with the permission configuration): run the tick when `runner: pane`, read `status.md` and `notices/`, relay each unsent notice line **verbatim** with `SendMessage` to the delegator it names (only `mado-delegator` and `rclick-delegator`, no other recipient), act on nothing else. `/clear` once a day; all state is in the files.
- A malformed request is moved nowhere: the scheduler writes the problem against its id in `status.md` and leaves the file.

## Not built yet (this skill is the contract; implementation is a later ticket, test-first)

`scripts/broker-tick.mjs`, `broker-check.mjs`, `broker-status.mjs`, `broker-submit.mjs` (id allocation and validation), the request/grant/event validators, `config.json` with the measured thresholds, offline tests for the policy (starvation, backfill, fairness, window arithmetic, abandoned jobs, hostile text), the pane conformance test; RClick adopts the same files (its delegator needs this skill or a pointer; RClick's repository is not edited from here); the relation to #738 (lock tools outside every repository) is to be settled there: owner-file locations are read from `config.json`, so moving the lock scripts does not change the contract.
