#!/bin/zsh
# owner-gates.sh <worktree> <sha> <prefix> [base=origin/main] — the delegator's own rerun of every gate on an
# implementer's head; run this branch's own copy, never a stale checkout. Writes <out>/<prefix>-summary.txt (out defaults to
# ~/.picsee/herdr/delegator, override with PICSEE_GATES_OUT) plus one log per gate:
#   head=<full sha> / swift= / lcov= (0 only at 100% eligible) / Package raw and eligible counts [uncovered f:l…] / xcodegen= / xcodebuild=
#   / apptests= (xcodebuild build-for-testing + scripts/tdd/app-lane.mjs, no filter, when the merge-base diff touches App/,
#   AppTests/, project.yml or Packages/MadoKit/Sources/MadoMacUI/; else "apptests=skip (no App-facing change)") plus
#   "apptests: Tests run: N, Failures: F, …" / node= / ledger= / diffcheck= / design= / the Swift "Test run with N tests" line / DONE
# Exit 1: one or more lanes failed; every lane still runs and the completed summary prints to stdout.
# A summary without DONE means the run died; treat it as no evidence. Exit 2: bad worktree, head mismatch, tracked
# changes, or a rebase/merge/cherry-pick/revert in progress (summary says "refused: …" and has no DONE).
# The Swift, Xcode build, App test and browser design jobs go through the worktree's scripts/heavy-lock.sh. Run it in the background.
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
# Gates read the working tree, so refuse anything that is not exactly the committed head (#687a run i687b
# gated a conflict marker mid-rebase). Untracked files (.build, node_modules) are allowed.
refuse() { echo "owner-gates: refused: $1" > $s || summary_error; echo "owner-gates: refused: $1" >&2; exit 2; }
for op in rebase-merge:rebase rebase-apply:rebase MERGE_HEAD:merge CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert; do
  [[ -e "$(git rev-parse --git-path ${op%%:*} 2>/dev/null)" ]] && refuse "${op#*:} in progress in $wt; finish or abort it and rerun on the committed head"
done
[[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] || refuse "tracked changes in $wt; commit or stash them and rerun in a clean worktree at the head"
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
if (( swift_code == 65 )); then
  lane_result swift 0
else
  lane_result swift $swift_code
fi
# Re-evaluate the fresh local unit artifact with the same strict evaluator as CI.
# lcov= is that check's exit code; the next line holds raw and eligible totals.
if (( swift_code == 65 )); then
  echo 'coverage failed after Swift tests passed; reevaluating retained evidence' > $o/$p-lcov.log
  node scripts/ci/package-coverage-local.mjs --reuse >> $o/$p-lcov.log 2>&1
  lane_result lcov 1
elif (( swift_code == 0 )); then
  node scripts/ci/package-coverage-local.mjs --reuse > $o/$p-lcov.log 2>&1
  lane_result lcov $?
else
  echo "coverage skipped: Swift run failed (exit $swift_code); prior coverage is not current evidence" > $o/$p-lcov.log
  lane_result lcov 1
fi
grep -E '^(coverage failed after|Package:|Coverage gate:|Invalid coverage evidence:|- shard=|Uncovered locations:)' $o/$p-lcov.log | tr '\n' ' ' >> $s || summary_error
awk '/^Uncovered locations:/{section=1;next} /^Large LLVM counters/{section=0} section && /^- /{print}' $o/$p-lcov.log | tr '\n' ' ' >> $s || summary_error
echo >> $s || summary_error
xcodegen generate > $o/$p-xcodegen.log 2>&1; lane_result xcodegen $?
$hl xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci \
  > $o/$p-xcodebuild.log 2>&1; lane_result xcodebuild $?
# App tests: the full App lane as CI runs it, when the diff from the merge-base is App-facing (#702, #701).
# Plain `xcodebuild test` hangs on the mini (bundle instance / runner connection, exit 65), so: build-for-testing,
# then scripts/tdd/app-lane.mjs with no filter (retained MadoAppTests group + MadoHostedFocusTests group; exit 0/1/70).
app_facing='^(App/|AppTests/|project\.yml$|Packages/MadoKit/Sources/MadoMacUI/)'
if ! mb=$(git merge-base "$base" HEAD 2>/dev/null) || [[ -z "$mb" ]]; then
  echo "apptests: cannot compute merge-base of $base and HEAD" > $o/$p-apptests.log
  lane_result apptests 1
elif ! git diff --name-only "$mb" HEAD | grep -Eq "$app_facing"; then
  echo "apptests=skip (no App-facing change)" >> $s || summary_error
else
  $hl xcodebuild build-for-testing -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath .build/dd-ci > $o/$p-apptests.log 2>&1
  app_code=$?
  if (( app_code != 0 )); then
    echo "apptests: build-for-testing failed (exit $app_code); App lane not run" >> $o/$p-apptests.log
  else
    env -u PICSEE_APP_FILTER $hl node scripts/tdd/app-lane.mjs >> $o/$p-apptests.log 2>&1
    app_code=$?
    if (( app_code == 0 )) && ! grep -Eq '^Tests run: [1-9][0-9]*, Failures: 0' $o/$p-apptests.log; then
      echo "apptests: exit 0 but no 'Tests run: N' line with N > 0 and no failures; treated as failure" >> $o/$p-apptests.log
      app_code=1
    fi
  fi
  lane_result apptests $app_code
  grep -E '^Tests run: [0-9]+' $o/$p-apptests.log | tail -1 | sed 's/^/apptests: /' >> $s || summary_error
fi
node --test --test-reporter=spec scripts/agents/*.test.mjs scripts/tdd/*.test.mjs scripts/ledger/*.test.mjs scripts/name-checks/*.test.mjs scripts/ci/name-checks-ci.test.mjs > $o/$p-node.log 2>&1; lane_result node $?
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
