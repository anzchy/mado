#!/bin/zsh
# Reset a herdr Codex pane to a fresh conversation (picsee fresh-context rule).
# usage: reset.sh <agent-name> <pane-id>
# Verified 2026-10-22 on Codex 0.163.0: `/new` opens a "Where should the new conversation run?"
# chooser (option 1 = current worktree, preselected), so two Enters are needed, sent with
# `herdr pane send-keys` (agent send-keys does not submit). herdr reports the new session id
# only after the next turn, so the caller checks the id after the request starts.
set -eu
name=$1 pane=$2
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
context_secs=${PICSEE_RESET_CONTEXT_SECS:-30}
poll_secs=${PICSEE_RESET_POLL_SECS:-0.25}
typeset -F SECONDS
deadline=$((SECONDS + context_secs))
while true; do
  ctx=$(herdr pane read $pane 2>&1 | grep -oE 'Context [0-9]+% used' | tail -1)
  [[ -n $ctx ]] && break
  if (( SECONDS >= deadline )); then
    echo "FAIL reset $name: no context line after ${context_secs}s"; exit 1
  fi
  sleep $poll_secs
done
case $ctx in "Context 0% used") ;; *) echo "FAIL reset $name: $ctx after /new"; exit 1;; esac
echo "reset $name old_session=$old $ctx (verify the session id changes after the next turn)"
