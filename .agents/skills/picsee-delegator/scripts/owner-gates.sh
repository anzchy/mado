#!/bin/zsh
# owner-gates.sh <worktree> <sha> <prefix> [base=origin/main] — the delegator's own rerun of every gate on an
# implementer's head; never trust a reported "all green". Writes <out>/<prefix>-summary.txt (out defaults to
# ~/.picsee/herdr/delegator, override with PICSEE_GATES_OUT) plus one log per gate:
#   head=<full sha> / swift= / lcov= (0 only at 100%) / lines a/b functions c/d [uncovered f:l…] / xcodegen= / xcodebuild= / node= / ledger= / diffcheck= / design=
#   / the Swift "Test run with N tests" line / DONE
# A summary without DONE means the run died; treat it as no evidence. Exit 2: bad worktree or head mismatch.
# The Swift, Xcode build and browser design jobs go through the worktree's scripts/heavy-lock.sh. Run it in the background.
# design:check needs npm ci --ignore-scripts and Playwright Chromium in the gated worktree;
# without either prerequisite it fails closed (design != 0).
set -u
here=${0:A:h}
(( $# >= 3 )) || { echo "usage: owner-gates.sh <worktree> <sha> <prefix> [base]"; exit 2; }
wt=$1 sha=$2 p=$3 base=${4:-origin/main} o=${PICSEE_GATES_OUT:-$HOME/.picsee/herdr/delegator}
mkdir -p $o
s=$o/$p-summary.txt
export PATH=$HOME/.picsee/tools/xcodegen/bin:/opt/homebrew/bin:$PATH
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd $wt 2>/dev/null || { echo "no worktree $wt" > $s; exit 2; }
[[ "$(git rev-parse HEAD 2>/dev/null)" == "$(git rev-parse "$sha" 2>/dev/null)" ]] || { echo "head mismatch" > $s; exit 2; }
hl=$wt/scripts/heavy-lock.sh
echo "head=$(git rev-parse HEAD)" > $s
$hl swift test --package-path Packages/PicseeKit --enable-code-coverage > $o/$p-swift.log 2>&1; echo "swift=$?" >> $s
# swift-lcov.sh only writes coverage/lcov.info; lcov-total.py sums it and fails below 100% (an uncovered line once
# passed as lcov=0). lcov= is that check's exit code; the next line holds the totals and any uncovered file:line.
sh scripts/tdd/swift-lcov.sh > $o/$p-lcov.log 2>&1 && python3 $here/lcov-total.py coverage/lcov.info >> $o/$p-lcov.log 2>&1
echo "lcov=$?" >> $s
grep -E '^(lines|uncovered|no report|empty report)' $o/$p-lcov.log | tr '\n' ' ' >> $s; echo >> $s
xcodegen generate > $o/$p-xcodegen.log 2>&1; echo "xcodegen=$?" >> $s
$hl xcodebuild build -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci \
  > $o/$p-xcodebuild.log 2>&1; echo "xcodebuild=$?" >> $s
node --test --test-reporter=spec scripts/agents/*.test.mjs scripts/tdd/*.test.mjs scripts/ledger/*.test.mjs > $o/$p-node.log 2>&1; echo "node=$?" >> $s
node scripts/ledger/build.mjs --check > /dev/null 2>&1; echo "ledger=$?" >> $s
git diff --check "$base"..HEAD > /dev/null 2>&1; echo "diffcheck=$?" >> $s
$hl npm run design:check > $o/$p-design.log 2>&1; echo "design=$?" >> $s
grep -E 'Test run with .* tests' $o/$p-swift.log | tail -1 >> $s
echo DONE >> $s
