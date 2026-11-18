#!/bin/zsh
# rebase-ledger.sh [upstream=origin/main] — run inside a PR worktree. Rebases and resolves only generated/ledger
# conflicts: docs/feature-ledger.html is regenerated; docs/feature-ledger.md rows go through resolve_rows.py.
# Any other conflict (or a row that needs a manual merge) stops with the rebase left in progress for you.
# Never pipe this script's rebase; it checks exit codes itself. core.commentChar=';' keeps commit body lines that
# start with '#' (issue IDs such as "#123 P2-05"), which the default message cleanup on --continue would delete.
set -u
here=${0:A:h}; up=origin/main; allow_red=0
for arg in "$@"; do
  case "$arg" in
    --allow-red-main) allow_red=1;;
    -*) echo "unknown option: $arg" >&2; exit 2;;
    *) up=$arg;;
  esac
done
ci=$("$here/main-ci-status.sh" 2>&1); ci_rc=$?
echo "$ci"
if [[ $ci == RED\ * && $allow_red == 0 ]]; then
  run=${${=ci}[2]}
  echo "main CI is red (run $run); fix main first or pass --allow-red-main"
  exit 7
fi
git fetch -q origin || exit 1
gd=$(git rev-parse --git-dir)
git -c core.commentChar=";" rebase "$up" > "$gd/rb.log" 2>&1 && {
  echo "DONE clean"
  python3 "$here/scan-conflict-markers.py" "$up..HEAD" || exit 8
  exit 0
}
for i in $(seq 1 50); do
  c=$(git diff --name-only --diff-filter=U)
  for f in ${=c}; do
    case $f in docs/feature-ledger.md|docs/feature-ledger.html) ;;
      *) echo "STOP other conflict: $f (rebase left in progress)"; exit 2;; esac
  done
  if [[ $c == *feature-ledger.md* ]]; then python3 "$here/resolve_rows.py" || { echo "STOP manual ledger row (rebase left in progress)"; exit 3; }; fi
  node scripts/ledger/build.mjs >/dev/null || exit 4
  git add docs/feature-ledger.md docs/feature-ledger.html
  GIT_EDITOR=true git -c core.commentChar=";" rebase --continue > "$gd/rb.log" 2>&1
  [[ -d $gd/rebase-merge ]] || {
    echo "DONE resolved"
    node scripts/ledger/build.mjs --check || exit 5
    python3 "$here/scan-conflict-markers.py" "$up..HEAD" || exit 8
    exit 0
  }
done
echo "STOP too many steps"; exit 6
