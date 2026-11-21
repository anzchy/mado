#!/bin/bash
set -euo pipefail
run_dir=$1
payload=$2
exec 9>"$HOME/ci/.lock"
if ! flock -n 9; then echo busy >&2; exit 75; fi
trap 'rm -rf -- "$run_dir"' EXIT
trap 'exit 75' INT TERM HUP
git clone -q "$run_dir/head.bundle" "$run_dir/pr-head"
export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin
git -C "$run_dir/pr-head" fetch -q "$run_dir/head.bundle" 'refs/preflight/*:refs/preflight/*'
first_sha=$(printf '%s' "$payload" | base64 -d | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).heads[0]))')
git -C "$run_dir/pr-head" checkout -q --detach "$first_sha"
if [[ $(git -C "$run_dir/pr-head" rev-parse HEAD) != "$first_sha" ]]; then echo 'checkout head mismatch' >&2; exit 75; fi
if ! /bin/bash "$run_dir/env-check.sh" >&2; then
  echo 'environment mismatch' >&2
  exit 75
fi
node "$run_dir/repro.mjs" remote "$run_dir/pr-head" "$payload"
