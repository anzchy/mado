#!/bin/zsh -f
emulate -R zsh
set -e
if (( $# < 1 )); then
  print -u2 -- 'usage: preflight.sh <commit-sha> [--step-timeout seconds] [--deadline seconds]'
  exit 2
fi
script_dir=${0:A:h}
exec node "$script_dir/preflight.mjs" run "$@"
