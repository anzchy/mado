#!/bin/zsh
# Reset a herdr Codex pane to a fresh conversation (picsee fresh-context rule).
# usage: reset.sh <agent-name> <pane-id>
# Verified 2026-10-22 on Codex 0.163.0: `/new` opens a "Where should the new conversation run?"
# chooser (option 1 = current worktree, preselected), so two Enters are needed, sent with
# `herdr pane send-keys` (agent send-keys does not submit). Require a fresh Codex
# title over an empty transcript above the footer in one expanded recent read, or a pane session id change.
# Use the last unfenced title; ignore older scrollback. A nonleading title also needs cwd metadata
# below it, so a bare title echoed by an old reply cannot re-prove freshness. Allow one placeholder
# followed only by blanks or known footer hints before the bottom-most footer.
# herdr may retain the old id until the first turn; an unchanged id is not a veto.
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
# Parse one screen only: the last unfenced title and bottom-most eligible footer win.
# A chooser is a boundary, but its footer still belongs to the pre-start UI.
footer() {
  python3 -c '
import re, sys
proved = sys.argv[1] == "1"
seen = started = proved
clean = metadata = False
ctx = fence = ""
# Slash commands are single /words; cwd metadata must be an unspaced home path
# or a multi-component absolute path, never arbitrary slash-prefixed prose.
def is_cwd(line):
    return bool(re.fullmatch(r"(?:~/\S+|/(?:[^/\s]+/)+[^/\s]*)", line))

title = r">_ OpenAI Codex \(v[0-9][^)]*\)"
lines = list(sys.stdin)
last_title = None
for index, raw in enumerate(lines):
    line = raw.strip()
    if line.startswith(("```", "~~~")):
        mark = line[:3]
        fence = "" if fence == mark else fence or mark
    elif not fence and re.fullmatch(title, line):
        last_title = index
fence = ""
title_proof = False
if last_title is not None:
    prefix = [line.strip() for line in lines[:last_title] if line.strip()]
    body = [line.strip() for line in lines[last_title + 1:] if line.strip()]
    # A fresh header after scrollback includes cwd metadata. Without it, an old
    # reply ending in an exact title would erase transcript evidence (#434).
    title_proof = (not prefix or
                   (len(prefix) == 1 and is_cwd(prefix[0])) or
                   bool(body and is_cwd(body[0])))
    lines = lines[last_title:]
placeholder = False
footer_hints = {"? for shortcuts", "? for help", "? for commands"}
welcome = footer_hints | {"Tip: Use /help to see available commands."}
for raw in lines:
    line = raw.strip()
    if line.startswith(("```", "~~~")):
        mark = line[:3]
        fence = "" if fence == mark else fence or mark
        clean = metadata = False
        seen = proved
        continue
    if fence:
        continue
    if re.fullmatch(title, line):
        ctx = ""
        seen = started = clean = proved or title_proof
        metadata = True
        continue
    if line.startswith("Where should the new conversation run"):
        ctx = ""
        started = clean = metadata = False
        continue
    if re.fullmatch(r"(?:(?:>|❯|›) )?/new", line) or re.match(r"Starting MCP servers(?:\s|$)", line):
        ctx = ""
        started = proved
        clean = metadata = False
        continue
    match = re.fullmatch(r"Context [0-9]+% used", line) or re.fullmatch(
        r"(?:GPT-|gpt-)\S+\s+[\w-]+\s+·\s+Context [0-9]+% used(?:\s+·.*)?", line)
    if match:
        # Always replace ctx: a dirty transcript before the bottom-most footer
        # revokes the header even when an earlier clean footer was visible.
        ctx = re.search(r"Context [0-9]+% used", line).group() if started and (proved or clean) else ""
        metadata = False
        continue
    if not line:
        continue
    # The worktree line immediately under the saved title is header metadata.
    if metadata and is_cwd(line):
        metadata = False
        continue
    metadata = False
    # One input placeholder; only blanks and known footer hints may follow it.
    # Tips, logo-like output, and duplicate placeholders remain transcript evidence.
    if line == "› Ask Codex to do anything" and not placeholder:
        placeholder = True
        continue
    if placeholder and line not in footer_hints:
        clean = False
        seen = proved
        continue
    if line in welcome or all(c.isspace() or "\u2500" <= c <= "\u259f" or "\u2800" <= c <= "\u28ff" for c in line):
        continue
    clean = False
    seen = proved
print(f"{int(seen or bool(ctx))}:{ctx}")
' "${1:-0}"
}
# Decode the documented nested field; unrelated JSON "value" fields are not identities.
# Missing/malformed/unavailable pane metadata falls back to visible screen evidence.
pane_session() {
  herdr pane get "$pane" 2>/dev/null | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)["result"]["pane"]["agent_session"]["value"]
    if isinstance(value, str) and value.strip():
        print(value)
except (ValueError, KeyError, TypeError):
    pass
'
}
st=$(herdr agent get $name 2>&1 | grep -oE '"agent_status":"[a-z]+"' | cut -d'"' -f4)
case $st in idle|done) ;; *) echo "FAIL reset $name: status $st, not idle"; exit 1;; esac
old=$(herdr agent get $name 2>&1 | grep -oE '"value":"[^"]+"' | head -1 | cut -d'"' -f4)
old_pane_session=$(pane_session)
[[ -z $old_pane_session ]] || old=$old_pane_session
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
  current_session=$(pane_session)
  session_proof=0
  if [[ -n $old_pane_session && -n $current_session && $current_session != "$old_pane_session" ]]; then
    session_proof=1
  fi
  parsed=$(herdr pane read $pane --source recent-unwrapped --lines 2000 2>&1 | footer $session_proof)
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
