#!/bin/zsh
# rebase-verify.sh <old-base> <old-head> <new-base> <new-head> — run after rebasing an audited branch.
# Compares commit messages and the full patch except the regenerated ledger md/html of
# old-base..old-head with new-base..new-head. An audit or device-smoke verdict covers a patch, so it only carries
# over when CODE is same. Exit 0: both same. 1: code differs (send the combination back for a quick audit check,
# then rerun gates and smoke). 2: messages differ (fix them before pushing; wins over 1, both lines still print).
# 3: usage or invalid ref. 4: empty comparison (no evidence to carry forward).
set -eu
set -o pipefail
(( $# == 4 )) || { echo "usage: rebase-verify.sh <old-base> <old-head> <new-base> <new-head>"; exit 3; }
for r in "$@"; do git rev-parse -q --verify "$r^{commit}" >/dev/null || { echo "unknown commit: $r"; exit 3; }; done
msgs() { git log --reverse --format='%s%n%b%n--' "$1..$2"; }
# Blob IDs and hunk offsets may change on a clean rebase. Retain hunk lengths,
# patch order, paths, modes, rename metadata, source lines and binary payloads.
code() {
  git diff --binary --full-index --no-ext-diff --no-textconv --no-color -M -U0 \
    --src-prefix=a/ --dst-prefix=b/ "$1" "$2" -- . \
    ':(top,exclude)docs/feature-ledger.md' ':(top,exclude)docs/feature-ledger.html' |
    LC_ALL=C sed -E '/^index /d; s/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@.*$/@@ -OLD\1 +NEW\2 @@/'
}
rc=0
if [[ "$(msgs $1 $2)" == "$(msgs $3 $4)" ]]; then echo "MESSAGES same"; else echo "MESSAGES differ"; rc=2; fi
old=$(code $1 $2) new=$(code $3 $4)
if [[ -z $old || -z $new ]]; then
  echo "CODE empty comparison: old=${#old} new=${#new}; cannot carry an audit across an empty patch" >&2
  exit 4
fi
a=$(print -r -- "$old" | shasum | cut -d' ' -f1)
b=$(print -r -- "$new" | shasum | cut -d' ' -f1)
if [[ $a == $b ]]; then echo "CODE same $a"; else echo "CODE differ $a -> $b"; if (( rc == 0 )); then rc=1; fi; fi
exit $rc
