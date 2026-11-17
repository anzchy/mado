#!/bin/zsh
# rebase-ledger.sh [upstream=origin/main] — run inside a PR worktree. Rebases and resolves only generated/ledger
# conflicts: docs/feature-ledger.html is regenerated; docs/feature-ledger.md rows go through resolve_rows.py.
# Any other conflict (or a row that needs a manual merge) stops with the rebase left in progress for you.
# Never pipe this script's rebase; it checks exit codes itself. core.commentChar=';' keeps commit body lines that
# start with '#' (issue IDs such as "#123 P2-05"), which the default message cleanup on --continue would delete.
set -u
up=${1:-origin/main}; here=${0:A:h}
git fetch -q origin || exit 1
gd=$(git rev-parse --git-dir)
git -c core.commentChar=";" rebase "$up" > "$gd/rb.log" 2>&1 && { echo "DONE clean"; exit 0; }
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
  [[ -d $gd/rebase-merge ]] || { echo "DONE resolved"; node scripts/ledger/build.mjs --check && exit 0; exit 5; }
done
echo "STOP too many steps"; exit 6
