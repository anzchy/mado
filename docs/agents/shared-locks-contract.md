# Shared locks contract (Mado, RClick, mdpro)

One page for every project that shares this Mac's locks (#738 WI-1; RClick's design: anzchy/RClick#21).

- **Sources**, checked 2026-11-21 at main `d91ae3c2`:
  - `scripts/heavy-lock.sh`
  - `scripts/tdd/heavy-lock.py`
  - `.agents/skills/mado-delegator/scripts/gui-lock.sh`
- **#768 is new behaviour.** Three things came with it:
  - Ordinary jobs no longer inherit the flock; nested supervisors receive it by `SCM_RIGHTS`.
  - The guardian record has new fields: `startedEpoch`, `budgetSeconds`, `child=`, `group=`.
  - There is a `status` subcommand.
- **`UNVERIFIED`** marks a statement not confirmed in code or by a probe.
- **Code wins over this page.** A mismatch is listed under Discrepancies.

Design background: [heavy-lock-contract.md](heavy-lock-contract.md).

## Locks and owner records

| Lock | Path | Kind | Held by |
|---|---|---|---|
| Heavy (machine) | `~/.mado/locks/heavy.lock`, the same file as `~/.picsee/locks/heavy.lock` | Persistent file, BSD `flock(LOCK_EX)` | The acquiring heavy-lock supervisor and its guardian process, not the job |
| Heavy (mdpro) | `~/.cache/mdpro-heavy.lock/` | Directory made by `mkdir`, with an `owner` file | The acquiring supervisor, after the flock |
| Desktop GUI | `~/.cache/desktop-gui.lock/` and the mutex `~/.cache/desktop-gui.mutex` | Directory with an `owner` file. Every acquire and release runs under `flock` on the mutex | The device run that printed the `acquisition_id` |

- **Path aliases.** On the dev machine, `~/.mado` is a symlink to `~/.picsee`; the directory could not be renamed (commit `159c53da`). Both spellings reach one inode, so either path excludes the other.
  - `MADO_HEAVY_LOCK` overrides the heavy path.
  - `MADO_MDPRO_LOCK` sets the mdpro path; `off` skips it.
  - The GUI paths are fixed.
- **Guardian record** (heavy flock): `<lock dir>/heavy.lock.guardian-<invocation>.owner`, mode 0600, one `key=value` per line:
  - `pid` (the guardian), `cmd`, `started`, `startedEpoch`, `budgetSeconds`
  - `supervisor` (the wrapper PID)
  - `job=argc=<n>`: the argument count only, never the command text
  - `child=<root pid>` and `group=<registered nested pgid>` lines

  Next to it, a `.log` holds guardian errors. The supervisor removes both after verified cleanup.
- **mdpro directory record**, as written by Mado's tool: `owner` with `pid`, `started`, `cwd` and `cmd=argc=<n>`. mdpro's own records carry more fields (`process_start`, `cmd=--keeper …`); `UNVERIFIED` beyond a read of mdpro's `scripts/heavy-lock.sh` header.
- **GUI owner record**: exactly eight lines, `project session batch start pid expected_minutes purpose acquisition_id` (uuid4), mode 0600, created with `O_EXCL|O_NOFOLLOW`.
  - Mado still writes `project=picsee`; RClick writes `project=rclick`.
  - A release is refused unless `project`, `batch` and `acquisition_id` all match.
- **Heavy status**: `/Users/jack/Documents/mac-app/picsee/scripts/heavy-lock.sh status` (or `--status`) prints JSON `{lock, holders[], processQuery}` and exits 0. It reads the guardian records and does not queue, lock or signal.
  - Each holder has `holderPid`, `wrapperPid`, `wrapperAlive`, `childPids`, `ageSeconds`, `budgetSeconds` and `orphanOverBudget`.
  - Use the absolute path: from another repo, `scripts/heavy-lock.sh` names that repo's file or nothing.
  - An argv of exactly `status` or `--status` always runs this diagnostic, never a command. To run your own program called `status`, give its path (`./status`).
  - With any extra argument it is **not** the diagnostic: `heavy-lock.sh status --json` queues and runs a command named `status` and fails (probed at `d91ae3c2`: exit 70, `No such file or directory: 'status'`). Call it with that one argument only.
  - An empty `holders` list does not prove the kernel lock is free, and it is not permission to start work beside the lock.
- **GUI status**: `gui-lock.sh status` prints `FREE`, or `HELD:` followed by the owner lines.
- **Optional diagnostics.** A consumer may ignore both:
  - The lock-age alert: `$MADO_HEAVY_ALERT_DIR/lock-alerts/<id>.json` plus `attention.log`, default directory `~/.mado/herdr/delegator`. Without `MADO_HEAVY_ALERT_DIR`, it is written only for the machine lock path.
  - The status JSON above.

## Environment

| Name | Meaning | Default |
|---|---|---|
| `MADO_HEAVY_LOCK` | Heavy flock path | `~/.mado/locks/heavy.lock` |
| `MADO_MDPRO_LOCK` | mdpro directory path; `off` skips it | `~/.cache/mdpro-heavy.lock` |
| `MADO_HEAVY_LOCK_WAIT_SECS` | Acquisition wait, shared by both waits | 1800 |
| `MADO_HEAVY_LOCK_EXEC_SECS` | Run cap after launch (finite, > 0) | By command: 300 for list/discovery, 600 for filtered `swift test`, 1200 for full `swift test`, 1800 for coverage and anything else |
| `MADO_HEAVY_LOCK_KILL_GRACE_SECS` | Grace between TERM and KILL | 10 |
| `MADO_HEAVY_LOCK_DRAIN_SECS` | How long to wait after exit before sending TERM | 30 |
| `MADO_HEAVY_ALERT_DIR` | Lock-age alert directory | `~/.mado/herdr/delegator` (machine lock only) |
| `MADO_HEAVY_LOCK_HELD` | Set to `1` for the job: a nesting hint, never proof | Set by the supervisor |
| `MADO_HEAVY_CONTROL_FD` | Registration socket passed to the job | Set by the supervisor |
| `MADO_HEAVY_FLOCK_EXPECTED` | `1` when the parent holds a local flock; the nested supervisor then requires the FD by `SCM_RIGHTS` | Set by the supervisor |
| `MADO_HEAVY_FLOCK_FD` | Removed from every job's environment; the job holds no flock FD | — |
| `MDPRO_HEAVY_LOCK_HELD` | Set to `1` for the job only when Mado's tool took the mdpro directory. Set by any caller other than a registered Mado parent, it means reverse nesting under mdpro and is refused with 70 before locking (#665) | — |
| `PICSEE_HEAVY*`, `PICSEE_MDPRO*` | Former names. `heavy-lock.sh` copies each to its `MADO_*` name when that is unset; a `MADO_*` value wins. Removed with the `~/.picsee` path (#556) | — |

**Internal, do not set:** `MADO_HEAVY_CI_TOP_LEVEL`, `MADO_HEAVY_CI_TEST`, `MADO_HEAVY_STATUS_PATH`, `MADO_HEAVY_STATUS_DIR`, `MADO_HEAVY_ATTEST_FD`, `MADO_HEAVY_GUARDIAN_*` and `MADO_HEAVY_FAULT_*`. They serve CI, Mado's private status records for its own lanes, and tests. `gui-lock.sh` reads no environment except its test hooks (`MADO_GUI_LOCK_TEST`, `…_WAIT_SECONDS`, `…_PRE_MUTEX_FILE`); RClick's copy uses `RCLICK_*`.

## Exit codes

| Tool | Code | Meaning |
|---|---|---|
| heavy-lock | The command's own code | Normal run with verified cleanup. A command killed by a signal is re-raised as that signal, except SIGKILL and SIGSTOP, which return 137 and 145 |
| heavy-lock | 0 | Also the result of `status` / `--status` (see above) |
| heavy-lock | 64 | No command (usage) |
| heavy-lock | 75 | Acquisition failed and nothing was launched. Either the wait ran out (flock or mdpro directory), or, immediately, the mdpro path exists but is not a directory |
| heavy-lock | 124 | Run cap reached, cleanup verified |
| heavy-lock | 70 | Refused or unsafe: bad environment value, `HELD=1` without a parent, reverse mdpro nesting, nested admission refused, cleanup unverified or unknown, status publication failure, supervisor exception |
| gui-lock | 0 / 75 | `acquire` or `wait` succeeded / busy (`acquire`) or the wait timed out (`wait`) |
| gui-lock | 1 | `REFUSED:` (usage, bad id, not this acquisition) or `FAIL:` (I/O) |

A command that passes through can itself exit 64, 70, 75 or 124. Those codes prove the tool's meaning only when stderr shows the matching `[heavy-lock]` line.

Probed with temporary lock paths:
- 2026-11-21 at `888a28cd`: heavy-lock 64, 7 → 7, 124, 70 (`HELD=1`, reverse nesting, `WAIT_SECS=inf`), and 75 (busy flock, also through `PICSEE_HEAVY_LOCK_WAIT_SECS`); gui-lock `status` 0, usage 1, bad id 1.
- At `d91ae3c2`: `status` and `--status` both exit 0 and print JSON; nesting as below.

## Nesting rule

- **One lock per command.** Wrap only the heavy command, one command per call, never a bare shell, REPL or idle session. A chain of commands takes the lock once per command (#738 notes the fairness cost).
- **A call inside a job does not wait on its own lock.** It registers with the live parent through `MADO_HEAVY_CONTROL_FD`, receives a duplicate flock FD by `SCM_RIGHTS`, and is bounded by the parent's deadline. Its job's exit code comes back to the caller.
- **The nested call must not be the process the job execs**, or it exits 70: the job's first process is a session leader and cannot `setpgid`. That rules out:
  - wrapping `heavy-lock.sh` directly in `heavy-lock.sh`;
  - a single-command `sh -c` / `bash -c`, because the shell execs it.

  It must be a child of a script or shell that keeps running, for example `gates.sh` calling `heavy-lock.sh swift test`, or `bash -c "true; heavy-lock.sh …"`. Probed at `d91ae3c2`: `heavy-lock.sh bash -c "heavy-lock.sh sh -c 'exit 3'"` gives 70; with `true;` first it gives 3.
- **A copied environment cannot borrow a lock.** `MADO_HEAVY_LOCK_HELD=1` without a live parent control FD exits 70.
- **The GUI lock does not nest.** Take it before the first GUI action, hold it across relaunches, and release it after the app quits, also on failure. A second `acquire` of a held lock gives 75, even from the same run.

## Holder loss (known limit)

The guardian ignores INT, TERM and HUP, so those signals alone do not release the heavy lock. If the supervisor **and** the guardian are both SIGKILLed (`pkill -9`, jetsam), a job that is still running loses flock protection, and another job can enter beside it. Exclusion is therefore not guaranteed after both holders die. Neither an empty `status` list nor a missing record is permission to start a job while the old job's processes are alive. Source: `docs/agents/heavy-lock.md`, line 7.

## Owner recovery

Another project only reports a stuck heavy lock; it never recovers it. The owning project identifies its own guardian from the record's `cmd` line, which names the guardian's `heavy-lock.py` path and so its worktree. It may SIGKILL that one guardian PID, and only after `status` shows all three of these for that holder:

- `wrapperAlive=false`;
- no `childPids`;
- `ageSeconds` over `budgetSeconds`.

It never touches the lock file.

## Who may unlink or rename what

- **Nobody** unlinks or renames the persistent files `heavy.lock` and `desktop-gui.mutex`.
  - Nobody calls `LOCK_UN` on the heavy lock: its open-file description is shared with the guardian and nested supervisors.
  - The GUI mutex is different. It is flocked only around each check-and-mutate, and the same `gui-lock.sh` call unlocks it on its own descriptor.
- **The mdpro directory** is removed only by its acquirer's release. Mado's tool removes it only when its own PID is in `owner`. When cleanup is known to be incomplete, the directory is retained (one exception under Discrepancies).
  - Mado's tool never reclaims the directory.
  - mdpro's tool reclaims a directory whose owner PID is dead; `UNVERIFIED` beyond its header, and mdpro stopped 2026-11-11.
- **The GUI directory** is removed only by `release` with the matching `acquisition_id`.
- **Never another project's lock or process.**
  - A lock that looks stale is reported to its owner and to the user, not removed.
  - Never take a lock from a running job: do not unlink its file or directory, do not kill its holder, and do not run a job beside it.
  - Never kill an unrelated `nohup` or background job to free a lock; the owner decides.
- **Guardian `.owner` and `.log` files** are the supervisor's to remove. A leftover one with a dead `pid` is reported, not deleted by another project.

## No private forks

There is one source: Mado's repo copy, `scripts/heavy-lock.sh` plus `scripts/tdd/heavy-lock.py`. `gui-lock.sh` follows mdpro's reference protocol. Another project calls it or installs a pinned snapshot (#738 WI-2); it does not edit a copy.

- **heavy-lock:** rclick-delegator's message of 2026-11-21 says RClick calls `/Users/jack/Documents/mac-app/picsee/scripts/heavy-lock.sh`. No such path appears in RClick main's tree (`git grep`), so this rests on the message alone.
- **gui-lock:** checked 2026-11-21: RClick main `435790d` `.agents/skills/macos-device-test/scripts/gui-lock.sh` diffed against Mado's has no code differences. Only `project`, the default session, the test variable names and comments differ. mdpro's copy was not compared.
- **Open:** nothing keeps the GUI copies in agreement automatically (#738 WI-3).

## RClick's constraints (reviewed by the RClick delegator on 2026-11-21)

These are the interface points rclick-delegator listed on 2026-11-21; it also gave an OK on the #768 diff. It reviewed this page at `b47fd1ed` on 2026-11-21 (verdict: OK to merge with six edits, all applied here).

- **No first-come order among waiters.** Whoever polls first after a release wins; a long waiter can lose to a newcomer.
- **Waiting** is bounded by `MADO_HEAVY_LOCK_WAIT_SECS` (default 1800 s), then exit 75. Waiters poll: `LOCK_NB` every 50 ms on the flock, every 5 s on the mdpro directory.
- **Exit codes:** 64 for usage and 75 for a wait timeout. Otherwise the command's own exit code passes through, with three exceptions:
  - 124 (run cap);
  - 70 (unsafe);
  - the argv `status` / `--status`, which is never run as a command.
- **Run cap:** 1800 s for any command not recognised as `swift test` or `xcodebuild -list`. Override it with `MADO_HEAVY_LOCK_EXEC_SECS` before launch. A ladder that runs longer than the cap exits 124, which looks like a test failure, so set `MADO_HEAVY_LOCK_EXEC_SECS` explicitly for such a command.
- **Lock paths:** `~/.mado/locks/heavy.lock` and `~/.picsee/locks/heavy.lock` name the same lock. No lock state path moves unless all three projects agree, in a quiet window.
- **Exclusion** holds while either the supervisor or the guardian is alive (see Holder loss).
- **Optional for consumers:** `status`, alerts and status records.

## Discrepancies

- DISCREPANCY: three places tell the reader to delete the mdpro directory by hand after a 75. This page's rule is report, not remove. Resolve in WI-2 or a docs change.
  - `heavy-lock.py` prints "then remove the directory …".
  - `heavy-lock.md` describes manual deletion after checking the owner PID.
  - `.agents/skills/macos-device-test/references/device-runbook.md` (line ~414) says to "check the owner's `cmd` with `pgrep -f`, … then manually remove the directory". That check cannot work: the owner `cmd` is `argc=<n>`, so `pgrep -f` matches nothing and the directory looks stale.
- DISCREPANCY: `heavy-lock.sh` (line 31) calls it "the `~/.picsee` symlink". On the dev machine the symlink is `~/.mado → .picsee`; the state directory is still named `.picsee`.
- DISCREPANCY: the resource-broker skill says the locks give mutual exclusion "in arrival order". The code polls, so order among waiters is not guaranteed.
- DISCREPANCY: a nested call that is the job's exec'd process exits 70 (`nested admission refused: Operation not permitted`). This covers both the direct `heavy-lock.sh heavy-lock.sh <cmd>` and a single-command `bash -c "heavy-lock.sh …"`. Nesting from a child of a running shell works. No other doc mentions this.
- DISCREPANCY: "on incomplete cleanup the mdpro directory is retained" does not hold after `--mark-host-unknown`. `heavy-lock.py` (~999–1002) sets `retain_shared` from the known cleanup before the unknown-host mark turns `cleanup` into `incomplete`, so `finally` (~1066) releases the directory while the run exits 70 incomplete. Known limitation; no code change here.
- Checked 2026-11-21: `git grep` for `MADO_HEAVY_FLOCK_FD` and `MADO_HEAVY` in RClick main `435790d` tracked files finds nothing, so no tracked RClick caller relies on the inherited flock FD that #768 removed. Untracked RClick briefs are not covered.
