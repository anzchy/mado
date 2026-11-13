#!/usr/bin/env bash
# Run heavy jobs under picsee's flock, then mdpro's shared directory lock.
# Usage: scripts/heavy-lock.sh <command...>
# PICSEE_HEAVY_LOCK: persistent file (default ~/.picsee/locks/heavy.lock).
# PICSEE_MDPRO_LOCK: mdpro directory (default ~/.cache/mdpro-heavy.lock); off skips.
# PICSEE_HEAVY_LOCK_WAIT_SECS: acquisition timeout, default 1800; exits 75.
# PICSEE_HEAVY_LOCK_KILL_GRACE_SECS: TERM grace before KILL, default 10.
# PICSEE_HEAVY_LOCK_DRAIN_SECS: post-exit drain bound, default 30; then TERM/grace/KILL + up to 5s.
# MDPRO_HEAVY_LOCK_HELD=1: reverse nesting has no verified handoff; exit 70
# before lock acquisition or launch. Issue #665 will restore this path.
# picsee never reclaims shared directories. Retain if workers survive KILL;
# mdpro may reclaim a dead owner after holder SIGKILL or survivors beyond KILL.
# PICSEE_HEAVY_LOCK_HELD=1: nesting hint; a live parent control FD is required.
# Lock-age alert (#672): when a top-level holder passes its execution budget, the
# supervisor writes $PICSEE_HEAVY_ALERT_DIR/lock-alerts/<id>.json (default dir
# ~/.picsee/herdr/delegator; 0600; command, deadline, pid/pgid, survivor
# state/RSS, retained lock paths) and one attention.log line there. listen-notify.py
# status reports it until the file is moved to lock-alerts/acked/.
# The private status record carries drainExpired; consumers that opt in (Trash lane,
# swift-red receipts) reject a run whose leader exited with surviving descendants.
# The inherited descriptor owns the lock until its last close, including after
# this launcher is SIGKILLed. Never unlink/rename the persistent lock file.
set -euo pipefail
if [[ $# -eq 0 ]]; then
  echo "usage: $0 <command...>" >&2
  exit 64
fi
exec python3 "$(dirname "$0")/tdd/heavy-lock.py" "$@"
