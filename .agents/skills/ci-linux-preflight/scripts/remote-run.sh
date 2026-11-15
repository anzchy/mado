#!/bin/bash
set -euo pipefail
run_dir=$1
head_sha=$2
job=$3
workflow_hash=$4
step_timeout=$5
deadline=$6
deadline_at=$(($(date +%s) + deadline))

run_bounded() {
  local remaining=$((deadline_at - $(date +%s)))
  if (( remaining < 1 )); then
    echo 'whole run deadline reached' >&2
    exit 124
  fi
  timeout --kill-after=10 "$remaining" "$@"
}

exec 9>"$HOME/ci/.lock"
if ! flock -n 9; then
  echo busy >&2
  exit 75
fi
trap 'rm -rf -- "$run_dir"' EXIT
trap 'exit 75' INT TERM HUP

run_bounded git clone -q "$run_dir/head.bundle" "$run_dir/pr-head"
run_bounded git -C "$run_dir/pr-head" fetch -q "$run_dir/head.bundle" "refs/preflight/$head_sha"
run_bounded git -C "$run_dir/pr-head" checkout -q --detach "$head_sha"
actual=$(git -C "$run_dir/pr-head" rev-parse HEAD)
if [[ "$actual" != "$head_sha" ]]; then
  echo "checkout head mismatch" >&2
  exit 75
fi

export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin
set +e
run_bounded /bin/bash "$run_dir/pr-head/.agents/skills/ci-linux-preflight/scripts/env-check.sh" >&2
check_status=$?
set -e
if (( check_status == 124 )); then exit 124; fi
if (( check_status != 0 )); then
  echo "environment mismatch" >&2
  exit 75
fi
remaining=$((deadline_at - $(date +%s)))
if (( remaining < 1 )); then echo 'whole run deadline reached' >&2; exit 124; fi
node "$run_dir/pr-head/.agents/skills/ci-linux-preflight/scripts/preflight.mjs" remote "$run_dir/pr-head" "$head_sha" "$job" "$workflow_hash" "$step_timeout" "$remaining"
