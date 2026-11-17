#!/bin/zsh
# poll-idle.sh <agent> [interval=60] [max_minutes=600]
# Exits 0 with "<agent> idle|question <time>".
# - Codex panes: herdr status sticks at "working" and the narrow screen may hide "esc to interrupt", so a turn
#   is done when the last lines above the composer show Codex's end-of-turn "Worked for …" line.
# - A sub-agent question ("? 1 question … to answer") blocks the turn: report it at once.
# - Claude panes: herdr's agent_status is reliable.
a=$1; iv=${2:-60}; max=${3:-600}; hits=0; start=$(date +%s)
sleep $iv
while :; do
  out=$(herdr agent read "$a" --source visible 2>&1)
  if print -r -- "$out" | grep -q -e 'to answer' -e 'enter submit'; then echo "$a question $(date +%H:%M:%S)"; exit 0; fi
  info=$(herdr agent get "$a" 2>/dev/null)
  if [[ -z ${out//[[:space:]]/} ]]; then
    # An empty visible screen (pane too small) tells nothing: fall back to herdr's status.
    [[ $info == *'"agent_status":"working"'* ]] && busy=1 || busy=0
  elif [[ $info == *'"agent":"claude"'* ]]; then
    [[ $info == *'"agent_status":"working"'* ]] && busy=1 || busy=0
  else
    tail_lines=$(print -r -- "$out" | grep -v '^[[:space:]]*$' | sed -n '/^› /q;p' | tail -6)
    if print -r -- "$out" | grep -q 'esc to interrupt'; then busy=1
    elif print -r -- "$(print -r -- "$out" | grep -v '^[[:space:]]*$' | tail -8)" | grep -q 'Worked for'; then busy=0
    else busy=1; fi
  fi
  if (( busy )); then hits=0; else hits=$((hits+1)); fi
  [ $hits -ge 2 ] && { echo "$a idle $(date +%H:%M:%S)"; exit 0; }
  [ $(( $(date +%s) - start )) -gt $((max*60)) ] && { echo "$a timeout"; exit 1; }
  sleep $iv
done
