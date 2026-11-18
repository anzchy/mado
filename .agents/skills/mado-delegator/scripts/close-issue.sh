#!/bin/sh
# Close a CI/test-fix ticket only after two completed green main CI runs.
set -eu
case "${1:-}" in ''|*[!0-9]*) echo 'usage: close-issue.sh <issue-number>' >&2; exit 2;; esac
[ "$#" -eq 1 ] || { echo 'usage: close-issue.sh <issue-number>' >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! status=$("$here/main-ci-status.sh" --two-green); then
  echo "close-issue: main CI needs two completed green runs: $status" >&2
  exit 7
fi
echo "close-issue: $status"
gh issue close "$1"
