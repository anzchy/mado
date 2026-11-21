# Shared locks contract (Mado, RClick, mdpro)

One page for every project that shares this Mac's locks (#738 WI-1; RClick's design: anzchy/RClick#21). It states what the tools do **after #768** (flock no longer inherited by ordinary jobs; `status` subcommand). Where #768 changes behaviour, the line says "after #768". Sources: `scripts/heavy-lock.sh`, `scripts/tdd/heavy-lock.py`, `.agents/skills/mado-delegator/scripts/gui-lock.sh`, checked 2026-11-21 at `888a28cd` and on the #768 branch head `97ce409d`. A statement marked `UNVERIFIED` was not confirmed in code or by a probe. Code wins over this page; a mismatch is listed under Discrepancies. Design background: [heavy-lock-contract.md](heavy-lock-contract.md).

## Locks and owner records

| Lock | Path | Kind | Held by |
|---|---|---|---|
| Heavy (machine) | `~/.mado/locks/heavy.lock`; the same file as `~/.picsee/locks/heavy.lock` (see below) | Persistent file, BSD `flock(LOCK_EX)` | The acquiring heavy-lock supervisor and its guardian process; after #768 not the job |
| Heavy (mdpro) | `~/.cache/mdpro-heavy.lock/` | Directory created by `mkdir`, with `owner` file | The acquiring heavy-lock supervisor, after the flock |
| Desktop GUI | `~/.cache/desktop-gui.lock/` + mutex `~/.cache/desktop-gui.mutex` | Directory with `owner` file; every acquire/release runs under `flock` on the mutex | The device run that printed the `acquisition_id` |

- **Path aliases.** On the dev machine `~/.mado` is a symlink to `~/.picsee` (the directory could not be renamed, commit `159c53da`). Both spellings reach one inode, so a job using either path excludes the other. `MADO_HEAVY_LOCK` overrides the heavy path. The mdpro path is `MADO_MDPRO_LOCK` (`off` skips it). The GUI paths are fixed.
- **Guardian record** (heavy flock): `<lock dir>/heavy.lock.guardian-<invocation>.owner`, 0600, `key=value` lines: `pid` (guardian), `cmd`, `started`, `startedEpoch`, `budgetSeconds` (after #768), `supervisor` (wrapper PID), `job=argc=<n>` (argument count only, never command text); after #768 also `child=<root pid>` and `group=<registered nested pgid>` lines. Beside it, a `.log` for guardian errors. Both are removed after verified cleanup.
- **mdpro directory record** (written by picsee's tool): `owner` with `pid`, `started`, `cwd`, `cmd=argc=<n>`. mdpro's own records carry more fields (`process_start`, `cmd=--keeper …`) — `UNVERIFIED` beyond a read of mdpro's `scripts/heavy-lock.sh` header.
- **GUI owner**: exactly eight lines `project session batch start pid expected_minutes purpose acquisition_id` (uuid4), 0600, `O_EXCL|O_NOFOLLOW`. Mado still writes `project=picsee`; RClick writes `project=rclick`. A release is refused unless `project`, `batch` and `acquisition_id` all match.
- **Status (heavy), after #768**: `scripts/heavy-lock.sh status` (or `--status`) prints JSON `{lock, holders[], processQuery}` from the guardian records without queueing, locking or signalling. Each holder: `holderPid`, `wrapperPid`, `wrapperAlive`, `childPids`, `ageSeconds`, `budgetSeconds`, `orphanOverBudget`. An empty list does not prove the kernel lock is free. **Before #768 merges, `status` is not a subcommand**: `heavy-lock.sh status` queues a command named `status` for the lock (observed 2026-11-21); read the guardian `.owner` files instead. **GUI**: `gui-lock.sh status` prints `FREE` or `HELD:` plus the owner lines.
- **Optional for consumers**: the lock-age alert (`$MADO_HEAVY_ALERT_DIR/lock-alerts/<id>.json` and `attention.log`, default `~/.mado/herdr/delegator`; without `MADO_HEAVY_ALERT_DIR` written only for the machine lock path) and the private status record (`MADO_HEAVY_STATUS_PATH` / `MADO_HEAVY_ATTEST_FD`). A consumer may ignore both.

## Environment

| Name | Meaning | Default |
|---|---|---|
| `MADO_HEAVY_LOCK` | Heavy flock path | `~/.mado/locks/heavy.lock` |
| `MADO_MDPRO_LOCK` | mdpro directory path; `off` skips it | `~/.cache/mdpro-heavy.lock` |
| `MADO_HEAVY_LOCK_WAIT_SECS` | Acquisition wait, shared by both waits | 1800 |
| `MADO_HEAVY_LOCK_EXEC_SECS` | Run cap after launch (finite, > 0) | by command: 300 list/discovery, 600 filtered `swift test`, 1200 full `swift test`, 1800 coverage and anything else |
| `MADO_HEAVY_LOCK_KILL_GRACE_SECS` | TERM→KILL grace | 10 |
| `MADO_HEAVY_LOCK_DRAIN_SECS` | Post-exit drain bound before TERM | 30 |
| `MADO_HEAVY_ALERT_DIR` | Lock-age alert directory | `~/.mado/herdr/delegator` (machine lock only) |
| `MADO_HEAVY_LOCK_HELD` | Set to `1` for the job; a nesting hint, never proof | set by the supervisor |
| `MADO_HEAVY_CONTROL_FD` | Registration socket passed to the job | set by the supervisor |
| `MADO_HEAVY_FLOCK_EXPECTED` | After #768: `1` when the parent holds a local flock; the nested supervisor then requires the FD by `SCM_RIGHTS` | set by the supervisor |
| `MADO_HEAVY_FLOCK_FD` | Before #768: the inherited flock FD. After #768: removed from the job's environment | — |
| `MDPRO_HEAVY_LOCK_HELD` | Set to `1` for the job only when picsee's tool took the mdpro directory. Set by any caller other than a registered Mado parent, it means reverse nesting under mdpro: refused with 70 before locking (#665) | — |
| `PICSEE_HEAVY*`, `PICSEE_MDPRO*` | Former names. `heavy-lock.sh` copies each to its `MADO_*` name when that is unset; a `MADO_*` value wins. Removed together with the `~/.picsee` path (#556) | — |

`MADO_HEAVY_CI_TOP_LEVEL`, `MADO_HEAVY_STATUS_*`, `MADO_HEAVY_ATTEST_FD`, `MADO_HEAVY_GUARDIAN_*` and `MADO_HEAVY_FAULT_*` are internal (CI, private status, tests). Consumers do not set them. `gui-lock.sh` reads no environment except its test hooks (`MADO_GUI_LOCK_TEST`, `…_WAIT_SECONDS`, `…_PRE_MUTEX_FILE`; RClick's copy uses `RCLICK_*`).

## Exit codes

| Tool | Code | Meaning |
|---|---|---|
| heavy-lock | the command's own code | Normal run with verified cleanup; a signal-killed command is re-raised as that signal |
| heavy-lock | 64 | No command (usage) |
| heavy-lock | 75 | Acquisition wait ran out (flock or mdpro directory); nothing was launched |
| heavy-lock | 124 | Run cap reached and cleanup verified |
| heavy-lock | 70 | Refused or unsafe: bad env value, `HELD=1` without a parent, reverse mdpro nesting, unverified/unknown cleanup, status publication failure, supervisor exception |
| gui-lock | 0 / 75 | `acquire`/`wait` succeeded / busy (`acquire`) or wait timed out (`wait`) |
| gui-lock | 1 | `REFUSED:` (usage, bad id, not this acquisition) or `FAIL:` (I/O) |

Probed 2026-11-21 with temporary lock paths: 64, 7→7, 124, 70 (`HELD=1`, reverse nesting, `WAIT_SECS=inf`), 75 (busy flock, also through `PICSEE_HEAVY_LOCK_WAIT_SECS`); gui-lock `status` 0, usage 1, bad id 1.

## Nesting rule

- One lock per command: wrap only the heavy command, one command per call, never a bare shell, REPL or idle session. A chain of commands takes the lock per command (#738 notes the fairness cost).
- A heavy-lock call **inside** a heavy-lock job does not wait on its own lock. It registers with the live parent through `MADO_HEAVY_CONTROL_FD`; after #768 it receives a duplicate flock FD by `SCM_RIGHTS`, and the parent's deadline bounds it. Its job's exit code comes back to the caller.
- The nested call must run below a script or shell of the job (for example `gates.sh` calling `heavy-lock.sh swift test`). Wrapping `heavy-lock.sh` directly in `heavy-lock.sh` exits 70 (see Discrepancies).
- `MADO_HEAVY_LOCK_HELD=1` without a live parent control FD exits 70: a copied environment cannot borrow a lock.
- GUI lock: take it before the first GUI action, hold it across relaunches, release after the app quits (also on failure). It does not nest; a second `acquire` of a held lock is 75 even from the same run.

## Who may unlink or rename what

- **Nobody** unlinks, renames or `LOCK_UN`s the persistent files `heavy.lock` and `desktop-gui.mutex`.
- The mdpro directory is removed only by its acquirer's release (picsee's tool removes it only when its own PID is in `owner`), and only after verified cleanup; on incomplete cleanup it is retained. Picsee's tool never reclaims it. mdpro's tool reclaims a directory whose owner PID is dead (`UNVERIFIED` beyond its header; mdpro stopped 2026-11-11).
- The GUI directory is removed only by `release` with the matching `acquisition_id`.
- **Never another project's lock or process.** A lock that looks stale is reported to its owner (and the user), not removed. Never take a lock from a running job: do not unlink its file or directory, do not kill its holder, do not run a job "beside" it. Never kill an unrelated `nohup`/background job to free a lock; the owner decides.
- Guardian `.owner`/`.log` files are the supervisor's to remove; a leftover one with a dead `pid` is reported, not deleted by another project.

## No private forks

One source: Mado's repo copy (`scripts/heavy-lock.sh` + `scripts/tdd/heavy-lock.py`; `gui-lock.sh` follows mdpro's reference protocol). Another project calls it or installs a pinned snapshot (#738 WI-2); it does not edit a copy. Today RClick calls Mado's `scripts/heavy-lock.sh` by path, and RClick's `gui-lock.sh` is a protocol-identical port (only `project`, default session and test variable names differ). Nothing yet proves the GUI copies agree (#738 WI-3).

## Consumer guarantees (confirmed with RClick)

- Waiting is bounded by `MADO_HEAVY_LOCK_WAIT_SECS` (default 1800 s), then 75. Waiters poll (`LOCK_NB` every 50 ms; the mdpro directory every 5 s): there is **no first-come order** among waiters.
- 64 for usage, 75 for wait timeout; otherwise the command's own exit code passes through, except 124 (run cap) and 70 (unsafe).
- Run cap: 1800 s for any command not recognised as `swift test`/`xcodebuild -list`; override with `MADO_HEAVY_LOCK_EXEC_SECS` before launch.
- Both `~/.mado/locks/heavy.lock` and `~/.picsee/locks/heavy.lock` name the same lock; no lock state path moves without all three projects agreeing in a quiet window.
- `status`, alerts and status records are optional diagnostics for consumers.

## Discrepancies

- DISCREPANCY: on a 75 for the mdpro directory, `heavy-lock.py` prints "then remove the directory …", and `heavy-lock.md` describes manual deletion after checking the owner PID. This page's rule is report, not remove. Resolve in WI-2 or a docs change.
- DISCREPANCY: `heavy-lock.sh` and `heavy-lock.md` call it "the `~/.picsee` symlink"; on the dev machine the symlink is `~/.mado → .picsee` (state directory still named `.picsee`).
- DISCREPANCY: the resource-broker skill says the locks give mutual exclusion "in arrival order"; the code polls, so order among waiters is not guaranteed.
- DISCREPANCY: direct nesting `heavy-lock.sh heavy-lock.sh <cmd>` exits 70 (`nested admission refused: Operation not permitted`) on `888a28cd` and on #768's head: the immediate child is a session leader and cannot `setpgid`. Nesting one level down works. No doc mentions this.
- `UNVERIFIED`: that RClick has no remaining caller that relies on the inherited flock FD (`MADO_HEAVY_FLOCK_FD`) removed by #768.
