# Request and grant format

One JSON file per job, `~/.mado/broker/requests/<id>.json`, mode 0600. `<id>` is `<project>-<requester>-<YYYYMMDDTHHMMSS>-<seq>`, unique, `[a-z0-9-]+`. The requester may amend a request that is still `queued` (the broker re-reads it); a granted or running request is changed only by `extend`, `done`, `cancel`.

```json
{
  "id": "mado-mado-delegator-20261117T214500-1",
  "project": "mado",
  "requester": "mado-delegator",
  "task": "mado-verify swift lane for #688 at ba466467",
  "kind": "heavy",
  "exclusive": ["heavy"],
  "wall_minutes": { "p50": 22, "p90": 35 },
  "resources": { "ram_gb_peak": 12, "cpu_cores_busy": 8, "disk_gb": 3 },
  "gui": null,
  "priority": { "class": 1, "why": "blocks PR #748 merge (CI fix)" },
  "earliest": null,
  "deadline": null,
  "depends_on": [],
  "state": "submitted"
}
```

## Fields

| Field | Meaning |
|---|---|
| `project` | `mado` or `rclick` |
| `requester` | the delegator that owns the request |
| `task` | one neutral line: what runs, for which ticket; no secrets, paths of private files, or personal data |
| `kind` | `heavy` (needs `heavy.lock`), `gui` (needs `~/.cache/desktop-gui.lock`), or `heavy+gui` only if one command needs both; otherwise two requests |
| `exclusive` | resources the job cannot share: any of `heavy`, `gui`, `network` (the run takes the Mac offline) |
| `wall_minutes` | the requester's honest estimate: `p50` typical, `p90` worst plausible; both required; the broker calibrates them from `history.jsonl` |
| `resources` | measured or best-known peak RAM in GB, busy cores, scratch disk GB; unknown = `null` (the broker then uses the history median for that task kind, or asks) |
| `gui` | for `gui` jobs: `{ "performance_sensitive": true\|false, "needs_input": true\|false }`; `null` otherwise |
| `priority.class` | 1 blocks a merge, a CI fix or the other project's critical path; 2 normal; 3 background (research, tallies, cleanup); `why` is required for class 1 |
| `earliest` / `deadline` | ISO-8601 local time or `null`; a deadline is a request, not a guarantee; the broker flags a deadline it cannot meet |
| `depends_on` | ids that must be `done` first (a GUI run after its build) |
| `state` | `submitted`, `queued`, `granted`, `running`, `done`, `cancelled`, `expired`, `blocked` |

## Grant `~/.mado/broker/grants/<id>.json` (broker only)

```json
{ "id": "…", "not_before": "2026-11-17T21:50:00-08:00", "valid_until": "2026-11-17T22:25:00-08:00",
  "position_reason": "rule C2: class 1 before class 2; shortest p90 first",
  "decided_at": "2026-11-17T21:46:10-08:00", "revision": 1 }
```

`valid_until` = `not_before` + `p90` + 10 minutes grace; a requester that cannot start inside the window says so (`cancel` or `extend`) instead of letting it lapse. A new `revision` replaces an older one; the requester always obeys the highest revision.

## Reports from the requester (appended as events, state change in the request)

`running` (wrapper PID, start time), `extend` (new p50/p90, reason), `blocked` (who holds the real lock, from its owner file), `done` (actual minutes, outcome `passed|failed|cancelled`, peak RAM if measured), `cancel`.
