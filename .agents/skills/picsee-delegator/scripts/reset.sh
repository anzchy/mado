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
# Parse one screen only: the last boundary and bottom-most eligible footer win.
# A chooser is a boundary, but its footer still belongs to the pre-start UI.
footer() {
  LC_ALL=C awk '
    /^[[:space:]]*```/ { if (fence == "`") fence = ""; else if (!fence) fence = "`"; next }
    /^[[:space:]]*~~~/ { if (fence == "~") fence = ""; else if (!fence) fence = "~"; next }
    fence { next }
    /^[[:space:]]*Where should the new conversation run/ { ctx = ""; seen = 1; started = 0; next }
    /^[[:space:]]*((>|❯|›) )?\/new[[:space:]]*$/ || /^[[:space:]]*Starting MCP servers([[:space:]]|$)/ {
      ctx = ""; seen = 1; started = 1; next
    }
    started && /^[[:space:]]*Context [0-9]+% used[[:space:]]*$/ {
      ctx = $0; sub(/^[[:space:]]*/, "", ctx); sub(/[[:space:]]*$/, "", ctx)
    }
    END { printf "%d:%s\n", seen, ctx }
  '
}
st=$(herdr agent get $name 2>&1 | grep -oE '"agent_status":"[a-z]+"' | cut -d'"' -f4)
case $st in idle|done) ;; *) echo "FAIL reset $name: status $st, not idle"; exit 1;; esac
old=$(herdr agent get $name 2>&1 | grep -oE '"value":"[^"]+"' | head -1 | cut -d'"' -f4)
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
boundary_seen=0
while true; do
  parsed=$(herdr pane read $pane 2>&1 | footer)
  [[ ${parsed%%:*} == 1 ]] && boundary_seen=1
  ctx=${parsed#*:}
  [[ -n $ctx ]] && break
  if (( SECONDS >= deadline )); then
    if (( ! boundary_seen )); then
      echo "FAIL reset $name: no new-session boundary seen within ${context_secs}s; check the pane"
    else
      echo "FAIL reset $name: no context line after ${context_secs}s"
    fi
    exit 1
  fi
  sleep $poll_secs
done
case $ctx in "Context 0% used") ;; *) echo "FAIL reset $name: $ctx after /new"; exit 1;; esac
echo "reset $name old_session=$old $ctx (verify the session id changes after the next turn)"
