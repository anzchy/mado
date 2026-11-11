#!/bin/zsh
# owner-gates.sh <worktree> <sha> <prefix> [base=origin/main] — the delegator's own rerun of every gate on an
# implementer's head; run this branch's own copy, never a stale checkout. Writes <out>/<prefix>-summary.txt (out defaults to
# ~/.picsee/herdr/delegator, override with PICSEE_GATES_OUT) plus one log per gate:
#   head=<full sha> / swift= / lcov= (0 only at 100% eligible) / Package raw and eligible counts [uncovered f:l…] / xcodegen= / xcodebuild= / node= / ledger= / diffcheck= / design=
#   / the Swift "Test run with N tests" line / DONE
# Exit 1: one or more lanes failed; every lane still runs and the completed summary prints to stdout.
# A summary without DONE means the run died; treat it as no evidence. Exit 2: bad worktree or head mismatch.
# The Swift, Xcode build and browser design jobs go through the worktree's scripts/heavy-lock.sh. Run it in the background.
# design:check needs npm ci --ignore-scripts and Playwright Chromium in the gated worktree;
# without either prerequisite it fails closed (design != 0).
set -u
here=${0:A:h}
(( $# >= 3 )) || { echo "usage: owner-gates.sh <worktree> <sha> <prefix> [base]"; exit 2; }
wt=$1 sha=$2 p=$3 base=${4:-origin/main} o=${PICSEE_GATES_OUT:-$HOME/.picsee/herdr/delegator}
s=$o/$p-summary.txt
summary_error() { echo "owner-gates: cannot write summary $s" >&2; exit 1; }
mkdir -p "$o" || summary_error
: > "$s" || summary_error
export PATH=$HOME/.picsee/tools/xcodegen/bin:/opt/homebrew/bin:$PATH
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd $wt 2>/dev/null || { echo "no worktree $wt" > $s || summary_error; exit 2; }
[[ "$(git rev-parse HEAD 2>/dev/null)" == "$(git rev-parse "$sha" 2>/dev/null)" ]] || { echo "head mismatch" > $s || summary_error; exit 2; }
hl=$wt/scripts/heavy-lock.sh
failed=0
lane_result() {
  local lane=$1 code=$2
  echo "$lane=$code" >> $s || summary_error
  (( code == 0 )) || failed=1
}
echo "head=$(git rev-parse HEAD)" > $s || summary_error
node scripts/tdd/unit-lane.mjs > $o/$p-swift.log 2>&1
swift_code=$?
lane_result swift $swift_code
# Re-evaluate the fresh local unit artifact with the same strict evaluator as CI.
# lcov= is that check's exit code; the next line holds raw and eligible totals.
if (( swift_code == 0 )); then
  node scripts/ci/package-coverage-local.mjs --reuse > $o/$p-lcov.log 2>&1
  lane_result lcov $?
else
  echo "coverage skipped: Swift run failed (exit $swift_code); prior coverage is not current evidence" > $o/$p-lcov.log
  lane_result lcov 1
fi
grep -E '^(Package:|Coverage gate:|Uncovered locations:|- Packages/)' $o/$p-lcov.log | tr '\n' ' ' >> $s || summary_error
echo >> $s || summary_error
xcodegen generate > $o/$p-xcodegen.log 2>&1; lane_result xcodegen $?
$hl xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci \
  > $o/$p-xcodebuild.log 2>&1; lane_result xcodebuild $?
node --test --test-reporter=spec scripts/agents/*.test.mjs scripts/tdd/*.test.mjs scripts/ledger/*.test.mjs > $o/$p-node.log 2>&1; lane_result node $?
node scripts/ledger/build.mjs --check > /dev/null 2>&1; lane_result ledger $?
git diff --check "$base"..HEAD > /dev/null 2>&1; lane_result diffcheck $?
if [[ ! -d node_modules ]]; then
  echo "design: missing node_modules in $wt; run npm ci --ignore-scripts in this worktree" > $o/$p-design.log
  lane_result design 1
else
  $hl npm run design:check > $o/$p-design.log 2>&1; lane_result design $?
fi
grep -E 'Test run with .* tests' $o/$p-swift.log | tail -1 >> $s || summary_error
echo DONE >> $s || summary_error
cat "$s" || summary_error
exit $failed
