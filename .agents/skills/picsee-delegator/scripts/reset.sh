#!/bin/zsh
# Reset a herdr Codex pane to a fresh conversation (picsee fresh-context rule).
# usage: reset.sh <agent-name> <pane-id>
# Verified 2026-10-22 on Codex 0.163.0: `/new` opens a "Where should the new conversation run?"
# chooser (option 1 = current worktree, preselected), so two Enters are needed, sent with
# `herdr pane send-keys` (agent send-keys does not submit). herdr reports the new session id
# only after the next turn, so the caller checks the id after the request starts.
set -eu
name=$1 pane=$2
context_secs=${PICSEE_RESET_CONTEXT_SECS-30}
poll_secs=${PICSEE_RESET_POLL_SECS-0.25}
# Validate literal decimal text before any pane input or shell arithmetic.
for timer in PICSEE_RESET_CONTEXT_SECS PICSEE_RESET_POLL_SECS; do
  if [[ $timer == PICSEE_RESET_CONTEXT_SECS ]]; then value=$context_secs; else value=$poll_secs; fi
  if ! [[ $value =~ '^[0-9]+([.][0-9]+)?$' ]] ||
     ! LC_ALL=C awk -v n="$value" 'BEGIN { exit !(n + 0 > 0 && n + 0 <= 300) }'; then
    echo "FAIL reset $name: invalid $timer=$value"; exit 1
  fi
done
# Exclude transcript quotations and anything before the last reset/startup marker.
footer() {
  awk -v mode="${1:-context}" '
    /^[[:space:]]*```/ { if (fence == "`") fence = ""; else if (!fence) fence = "`"; next }
    /^[[:space:]]*~~~/ { if (fence == "~") fence = ""; else if (!fence) fence = "~"; next }
    fence { next }
    /Where should the new conversation run/ || /^[[:space:]]*([>❯›] )?\/new[[:space:]]*$/ || /Starting MCP servers/ { ctx = ""; seen = 1; next }
    /^[[:space:]]*Context [0-9]+% used[[:space:]]*$/ {
      ctx = $0; sub(/^[[:space:]]*/, "", ctx); sub(/[[:space:]]*$/, "", ctx)
    }
    END { if (mode == "boundary") print seen + 0; else print ctx }
  '
}
st=$(herdr agent get $name 2>&1 | grep -oE '"agent_status":"[a-z]+"' | cut -d'"' -f4)
case $st in idle|done) ;; *) echo "FAIL reset $name: status $st, not idle"; exit 1;; esac
old=$(herdr agent get $name 2>&1 | grep -oE '"value":"[^"]+"' | head -1 | cut -d'"' -f4)
old_ctx=$(herdr pane read $pane 2>&1 | footer)
herdr pane send-text $pane '/new' >/dev/null
# The first Enter can be swallowed by the slash-command popup; press until the chooser shows.
for i in 1 2 3; do
  herdr pane send-keys $pane enter >/dev/null; sleep 3
  herdr pane read $pane 2>&1 | grep -q 'Where should the new conversation run' && break
done
herdr pane read $pane 2>&1 | grep -q 'Where should the new conversation run' || { echo "FAIL reset $name: chooser never appeared"; exit 1; }
herdr pane send-keys $pane enter >/dev/null
# MCP startup can delay the context footer; wait for it before judging the reset.
typeset -F SECONDS
deadline=$((SECONDS + context_secs))
fresh=0
while true; do
  screen=$(herdr pane read $pane 2>&1)
  ctx=$(print -r -- "$screen" | footer)
  # An unchanged markerless footer is not evidence of a new session. Require
  # a reset boundary, or the old footer to disappear/change before accepting it.
  if [[ $ctx != "$old_ctx" || $(print -r -- "$screen" | footer boundary) == 1 ]]; then
    fresh=1
  fi
  (( fresh )) || ctx=""
  [[ -n $ctx ]] && break
  if (( SECONDS >= deadline )); then
    echo "FAIL reset $name: no context line after ${context_secs}s"; exit 1
  fi
  sleep $poll_secs
done
case $ctx in "Context 0% used") ;; *) echo "FAIL reset $name: $ctx after /new"; exit 1;; esac
echo "reset $name old_session=$old $ctx (verify the session id changes after the next turn)"
