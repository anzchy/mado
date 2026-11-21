#!/bin/bash
set -euo pipefail
run_dir=$1
payload=$2
exec 9>"$HOME/ci/.lock"
if ! flock -n 9; then echo busy >&2; exit 75; fi
trap 'rm -rf -- "$run_dir"' EXIT
trap 'exit 75' INT TERM HUP
export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin
deadline=$(printf '%s' "$payload" | base64 -d | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(String(JSON.parse(s).deadline)))')
[[ $deadline =~ ^[0-9]+$ ]] && (( deadline >= 1 && deadline <= 86400 )) || exit 75
deadline_at=$(($(date +%s) + deadline))
run_bounded() {
  local remaining=$((deadline_at - $(date +%s)))
  if (( remaining < 1 )); then echo 'whole run deadline reached' >&2; exit 124; fi
  timeout --kill-after=10 "$remaining" "$@"
}
run_bounded git clone -q "$run_dir/head.bundle" "$run_dir/pr-head"
run_bounded git -C "$run_dir/pr-head" fetch -q "$run_dir/head.bundle" 'refs/preflight/*:refs/preflight/*'
first_sha=$(printf '%s' "$payload" | base64 -d | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).heads[0]))')
run_bounded git -C "$run_dir/pr-head" checkout -q --detach "$first_sha"
if [[ $(git -C "$run_dir/pr-head" rev-parse HEAD) != "$first_sha" ]]; then echo 'checkout head mismatch' >&2; exit 75; fi
set +e
run_bounded /bin/bash "$run_dir/env-check.sh" >&2
check_status=$?
set -e
if (( check_status == 124 )); then exit 124; fi
if (( check_status != 0 )); then
  echo 'environment mismatch' >&2
  exit 75
fi
run_bounded node "$run_dir/repro.mjs" remote "$run_dir/pr-head" "$payload"
