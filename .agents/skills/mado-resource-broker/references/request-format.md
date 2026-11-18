# Request, event and grant format

All files are JSON, never edited in place. Directory `~/.mado/broker/`, mode 0700, files 0600. Creation of `requests/` and `events/` files is **atomic and exclusive**: write a tmp file, then `link(tmp, final)` (fails if `final` exists), then unlink the tmp. `grants/`, `state/`, `status.md` and `notices/` are replaced with `rename(2)` by the single scheduler (overwrite is intended there). Every free-text field below (`task`, `priority.why`, `extend.reason`, `blocked.holder`) is limited to 120 characters of `[A-Za-z0-9 #._:/+-]` and treated as data everywhere; the same limit applies to any owner-file text copied into `status.md`, and a malformed-request note never echoes raw content (id and the rule it broke only).

## Ids

`<project>-<requester>-<uuid4>` with `project` in `mado|rclick`, `requester` `[a-z0-9-]+`. The requester creates `requests/<id>.json` with exclusive create (`O_EXCL`); the file name, the `id` field and the `project` field must match or the request is rejected. A restart or a second submitter cannot collide because the uuid is random and the create is exclusive.

## Request `requests/<id>.json` (immutable)

```json
{
  "id": "mado-mado-delegator-3f2c9a40-…",
  "project": "mado",
  "requester": "mado-delegator",
  "task": "mado-verify swift lane #688 at ba466467",
  "task_kind": "swift-test",
  "kind": "heavy",
  "exclusive": ["heavy"],
  "wall_minutes": { "p50": 22, "p90": 35 },
  "resources": { "ram_gb_peak": 12, "cpu_cores_busy": 8, "disk_gb": 3 },
  "gui": null,
  "priority": { "class": 1, "why": "blocks PR #748 merge (CI fix)" },
  "submitted_at": "2026-11-17T21:45:00-08:00",
  "earliest": null,
  "deadline": null,
  "depends_on": [],
  "supersedes": null
}
```

| Field | Meaning |
|---|---|
| `task` | one neutral line, at most 120 characters of `[A-Za-z0-9 #._:/+-]`; data only, no secrets, private paths or personal data |
| `task_kind` | required, from the closed list in `config.json` (`swift-test`, `xcodebuild`, `xcodegen`, `node-lane`, `owner-gates`, `mado-verify`, `device-gui`, `signed-build`, `other`); calibration groups by `(project, task_kind)` |
| `kind` | `heavy` or `gui`; one resource per request; a job that needs both is two requests with `depends_on` |
| `exclusive` | any of `heavy`, `gui`, `network` (the run takes the Mac offline) |
| `wall_minutes` | the requester's honest estimate, both required, `0 < p50 <= p90` |
| `resources` | peak RAM in GB, busy cores, scratch disk GB; unknown is `null`, then the scheduler uses the history median for `(project, task_kind)`, or the `config.json` default for that kind |
| `gui` | for `gui`: `{ "performance_sensitive": bool, "needs_input": bool }`, else `null` |
| `priority.class` | 1 blocks a merge, a CI fix or the other project's critical path (`why` required); 2 normal; 3 background |
| `submitted_at`, `earliest`, `deadline` | ISO-8601 **with offset**; `earliest` and `deadline` may be `null`; a deadline is a request, never a guarantee |
| `depends_on` | ids that must be `done` first |
| `supersedes` | id of a still-queued request this one replaces (an amendment is a new request and the old one becomes `cancelled`); a granted or running request cannot be superseded, only `extend`ed or `cancel`led |

## Events `events/<id>.<n>.json` (requester writes, `n` = 1, 2, … per request, exclusive create)

`running` (`pid`, `pid_started_at`), `extend` (new `p50`/`p90`, reason), `blocked` (`holder` taken from its owner file), `done` (`actual_minutes`, `outcome` = `passed|failed|cancelled`, `peak_ram_gb` or `null`), `cancel`. Only the requester writes events; only the scheduler writes everything else. The requester picks `n` as one more than the highest existing file for that id and creates with `link`; on `EEXIST` it re-reads and takes the next number (two writers, for example a cancellation and a completion, therefore get different numbers). **The first terminal event (`done` or `cancel`) by `n` wins**; later events are logged in `events.log` and ignored.

## Grant `grants/<id>.json` (scheduler only)

```json
{ "id": "…", "generation": 41, "not_before": "2026-11-17T21:50:00-08:00",
  "start_by": "2026-11-17T22:00:00-08:00", "rule": "C1,C2", "decided_at": "2026-11-17T21:46:10-08:00" }
```

`not_before` is the planned start; the grant becomes **usable** at `usable_at` = `not_before` or later, when every conflicting predecessor is done (see "Using a grant" in `ordering-policy.md`), and `start_by` = `usable_at` + `grace_minutes` (config). `generation` is a counter written into each grant file that increases when that request's grant is republished; `broker-check` compares the generation in the file with the one the requester read, under the directory lock, right before the requester takes the real lock, so a replaced grant cannot be used. A grant is a plan, not a reservation: only `broker-check` returning `GO` admits a start.

## State `state/<id>.json` (scheduler only)

`state` (`submitted, queued, granted, running, done, cancelled, expired, abandoned, blocked`), `waited_since` (original submission time, kept through re-queues), `effective_class`, `last_event`.
