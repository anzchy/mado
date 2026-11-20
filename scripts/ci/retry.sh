#!/bin/sh
# #788: bounded retry for package installs in CI (apt mirrors and browser downloads fail for minutes at a time).
# usage: retry.sh <tries 1-5> <first-wait-seconds 0-120> <command> [args...]
# Runs the command up to <tries> times, waiting <first-wait> seconds after the first failure and doubling the wait
# each time; exits 0 on the first success, else with the command's last exit code. Only install steps use it:
# scripts/ci/retry.test.mjs fails if a workflow wraps any other step, so a test or assertion is never retried.
usage() { echo 'usage: retry.sh <tries 1-5> <first-wait-seconds 0-120> <command> [args...]' >&2; exit 64; }
[ $# -ge 3 ] || usage
tries=$1 wait=$2
shift 2
case $tries in [1-5]) ;; *) usage ;; esac
case $wait in ''|*[!0-9]*) usage ;; esac
[ "$wait" -le 120 ] || usage
try=1
while :; do
  "$@"
  code=$?
  [ "$code" -eq 0 ] && exit 0
  if [ "$try" -ge "$tries" ]; then
    echo "retry: $1 failed $tries times; last exit $code" >&2
    exit "$code"
  fi
  echo "retry: try $try/$tries of $1 failed with exit $code; next try in $wait s" >&2
  sleep "$wait"
  try=$((try + 1))
  wait=$((wait * 2))
done
