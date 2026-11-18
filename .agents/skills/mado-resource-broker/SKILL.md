---
name: mado-resource-broker
description: Schedule the shared Mac between Mado and RClick. Delegators submit a request (task, duration, resources) before any heavy or GUI job; the broker pane (Haiku) orders the queue and writes grants. Use when submitting, waiting for or ordering heavy-lock and GUI-lock work, or when running the broker pane. Not for holding locks, killing processes, or running tests.
---

# mado-resource-broker

One Mac, two projects (Mado and RClick), two delegators, one heavy lock and one desktop. Today the locks give mutual exclusion in arrival order (`scripts/heavy-lock.sh`, `.agents/skills/mado-delegator/scripts/gui-lock.sh`); nobody knows what is coming, how long it takes, or whether a short job is stuck behind a long one. The broker adds the missing piece: **order and admission**, decided from declared requests and measured load.

## What the broker is, and is not

- It **recommends and grants** an order by writing files under `~/.mado/broker/`. Requesters wait for their grant before they take a lock.
- It **never holds, releases, reclaims or removes a lock, never kills a process, never edits a repository, never runs a build or test.** Mutual exclusion stays in the lock tools. A lock that looks stale is reported to the owner in `status.md`, never touched (AGENTS.md, `docs/agents/heavy-lock.md`).
- It is **cooperative**: a delegator who skips the broker still takes the locks the old way and the locks still protect everyone; the broker only cannot order them. When the broker is down or silent for more than 5 minutes, requesters fall back to plain lock arrival order and say so in their handoff.

## Roles

| Role | Who | Does |
|---|---|---|
| Requester | `mado-delegator`, `rclick-delegator` (implementers go through their delegator) | submits, waits for the grant, runs the job under the real lock, reports the outcome |
| Broker | herdr pane `resource-broker`, `claude --agent mado-resource-broker`, model Haiku | reads requests and load, orders the queue, writes grants and `status.md`, calibrates estimates |
| Owner | the human | decides stale locks, priorities in dispute, and anything the broker flags |

## Data directory `~/.mado/broker/` (mode 0700, outside every repository, shared by both projects)

```
requests/<id>.json   written by the requester            (schema: references/request-format.md)
grants/<id>.json     written by the broker only
status.md            written by the broker: current holders, queue with reasons, flags, last decision time
history.jsonl        append-only: one line per finished job (estimated vs actual minutes, peak RAM seen)
events.log           append-only: submit, grant, start, done, extend, expire, cancel, flag
```

No secrets, tokens, personal data or file contents in any of these files; task text is one neutral line.

## Lifecycle

`submitted → queued → granted → running → done | cancelled | expired`

1. **Submit** before any heavy job (`swift test`, `xcodebuild`, `xcodegen`, node lanes, owner-gates, mado-verify, signed builds) and any GUI run (device smoke, GUI-driving tests, anything that needs the desktop or the network down). One request per job; a GUI run that follows a build is a second request with `depends_on`.
2. **Grant.** The broker writes `grants/<id>.json` with a window (`not_before`, `valid_until`) and the reason it is next. Until then the requester does not call the lock script.
3. **Run.** Inside the window the requester takes the real lock (`scripts/heavy-lock.sh <cmd>`, `gui-lock.sh acquire <run-id> …`) and writes `running` with the PID of its wrapper. If the real lock is still held by someone outside the broker's order, wait up to 5 minutes, then report `blocked` (the broker flags it); never barge in and never touch the holder.
4. **Overrun.** At 80% of the estimate the requester sends `extend` with a new estimate. A job at 2× its estimate is flagged to both delegators and the owner; the broker never ends it.
5. **Done.** The requester reports `done` with actual minutes and outcome (`passed`, `failed`, `cancelled`); the broker appends to `history.jsonl`. A grant that is not used by `valid_until` expires and the job is re-queued behind later arrivals.

## Ordering

`references/ordering-policy.md` is the rule set; the broker must quote the rule that decided each placement in `status.md`. Hard constraints (one heavy job at a time, the desktop exclusive, "network off" exclusive of everything) are never traded away for speed. Anything the broker cannot decide from the request and the rules is **not guessed**: it writes a question in `status.md` and the requester answers by amending the request.

## Broker pane rules

- Tools: Read, Grep, Glob and Bash. Bash is limited to the broker scripts, read-only status commands (`uptime`, `vm_stat`, `memory_pressure`, `ps`, `ls`, `cat`, `date`) and writing inside `~/.mado/broker/grants/`, `status.md`, `events.log`, `history.jsonl`. It never runs `scripts/heavy-lock.sh`, `gui-lock.sh acquire|release`, `kill`, `rm` on locks, `git`, or anything outside the data directory.
- Loop: every 60 s, and immediately on a new request, read `requests/`, run `scripts/broker-status.sh` (load average, memory free and pressure, lock owners, the running job's age), order, write grants, refresh `status.md`. `/clear` once a day; state lives in the files, not in the conversation.
- If a request file is malformed the broker moves nothing: it writes the parse problem into `status.md` against that id and leaves the file alone.

## Not built yet (this skill is the contract; implementation is a later ticket, test-first)

`scripts/broker-submit.sh`, `broker-status.sh`, a request/grant validator and offline tests; RClick adopts the same files (its delegator needs the same skill or a pointer to this one; RClick's own repository is not edited from here); the relation to #738 (shared lock tools installed outside every repository) is to be settled there: this skill must keep working when the lock scripts move.
