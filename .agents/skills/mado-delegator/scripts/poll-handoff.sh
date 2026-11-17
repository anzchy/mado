#!/bin/zsh
# poll-handoff.sh <agent> <handoff-file> [max_minutes=120] [grep-marker]
# For agents whose herdr status is reliable (Kimi, Claude): exits when the handoff file exists (and, if a marker is
# given, contains it) AND herdr reports the agent idle/done. Prints "<agent> done|blocked|timeout <time>".
# Don't grep Kimi's screen for words like "permission": that produced a false "question" once.
a=$1; f=$2; max=${3:-120}; marker=${4:-}
for i in $(seq 1 $max); do
  st=$(herdr agent get "$a" 2>&1 | grep -oE '"agent_status":"[a-z]+"' | cut -d'"' -f4)
  if [[ -f $f ]] && { [[ -z $marker ]] || grep -q -- "$marker" "$f"; } && [[ $st == idle || $st == done ]]; then
    echo "$a done $(date +%H:%M:%S)"; exit 0; fi
  [[ $st == blocked ]] && { echo "$a blocked $(date +%H:%M:%S)"; exit 0; }
  sleep 60
done
echo "$a timeout status=$st"
