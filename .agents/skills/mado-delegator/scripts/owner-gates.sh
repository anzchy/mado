#!/bin/zsh
# owner-gates.sh <worktree> <sha> <prefix> [base=origin/main] — the delegator's own rerun of every gate on an
# implementer's head; run this branch's own copy, never a stale checkout. Writes <out>/<prefix>-summary.txt (out defaults to
# ~/.mado/herdr/delegator, override with MADO_GATES_OUT) plus one log per gate. The summary includes
# swift/lcov (or native-input skip), xcodegen, xcodebuild, apptests-retained=<exit> <run>/<fail>,
# apptests-hosted (default skip; OWNER_GATES_HOSTED=1 runs it), apptests compatibility, scoped node
# suite skips, node, ledger, diffcheck, design, failure facts, and DONE after every selected lane finishes.
# Exit 1: one or more lanes failed; every lane still runs and the completed summary prints to stdout.
# A summary without DONE means the run died; treat it as no evidence. Exit 2: bad worktree, head mismatch, tracked
# changes, or a rebase/merge/cherry-pick/revert in progress (summary says "refused: …" and has no DONE).
# The Swift, xcodegen, Xcode build, App test and browser design jobs go through the worktree's scripts/heavy-lock.sh.
# Preflight checks npm and Playwright prerequisites before any lane, and refuses with exit 2.
set -u
here=${0:A:h}
(( $# >= 3 )) || { echo "usage: owner-gates.sh <worktree> <sha> <prefix> [base]"; exit 2; }
wt=$1 sha=$2 p=$3 base=${4:-origin/main} o=${MADO_GATES_OUT:-$HOME/.mado/herdr/delegator}
s=$o/$p-summary.txt
summary_error() { echo "owner-gates: cannot write summary $s" >&2; exit 1; }
mkdir -p "$o" || summary_error
: > "$s" || summary_error
# OWNER_GATES_TOOL_PATH replaces the tool directories put in front of PATH (tests point it at their fakes).
export PATH=${OWNER_GATES_TOOL_PATH:-$HOME/.mado/tools/xcodegen/bin:/opt/homebrew/bin}:$PATH
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
export MADO_HEAVY_LOCK_WAIT_SECS=${MADO_HEAVY_LOCK_WAIT_SECS:-3600}
mb=$(git merge-base "$base" HEAD 2>/dev/null) || refuse "cannot compute merge-base of $base and HEAD"
diff_file=$o/$p-diff.txt
git diff --name-only --no-renames "$mb" HEAD > "$diff_file" || refuse "cannot list gated diff"
selection=$(node "$here/owner-gates-tools.mjs" select "$diff_file") || refuse "cannot classify gated diff"
selection_lines=("${(@f)selection}")
(( ${#selection_lines} == 3 )) && [[ $selection_lines[1] == native=[01] ]] &&
  [[ $selection_lines[2] == agents=[01] ]] && [[ $selection_lines[3] == tdd=[01] ]] ||
  refuse "invalid suite selection; expected native/agents/tdd each exactly 0 or 1"
native=${${(M)${(f)selection}:#native=*}#native=}
agents=${${(M)${(f)selection}:#agents=*}#agents=}
tdd=${${(M)${(f)selection}:#tdd=*}#tdd=}
preflight=$(node "$here/owner-gates-tools.mjs" preflight "$wt" "$0")
if (( $? != 0 )); then
  echo "refused: $preflight" > "$s" || summary_error
  exit 2
fi
failed=0
lane_result() {
  local lane=$1 code=$2 detail=${3:-}
  echo "$lane=$code${detail:+ $detail}" >> $s || summary_error
  if (( code != 0 )); then
    failed=1
    local log=$o/$p-$lane.log
    [[ -f "$log" ]] && node "$here/owner-gates-tools.mjs" fact "$lane" "$code" "$log" "$diff_file" >> "$s" || true
  fi
}
echo "head=$(git rev-parse HEAD)" > $s || summary_error
print -r -- "$preflight" | grep -E '^preflight: stale-owner-records=[0-9]+$' >> "$s" || true
if (( native )); then
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
else
  echo "swift=skipped (no native inputs)" >> "$s"
  echo "lcov=skipped (no native inputs)" >> "$s"
fi
if (( native )); then
grep -E '^(coverage failed after|Package:|Coverage gate:|Invalid coverage evidence:|- shard=|Uncovered locations:)' $o/$p-lcov.log | tr '\n' ' ' >> $s || summary_error
awk '/^Uncovered locations:/{section=1;next} /^Large LLVM counters/{section=0} section && /^- /{print}' $o/$p-lcov.log | tr '\n' ' ' >> $s || summary_error
echo >> $s || summary_error
fi
$hl xcodegen generate > $o/$p-xcodegen.log 2>&1; lane_result xcodegen $?
app_facing='^(App/|AppTests/|project\.yml$|Packages/MadoKit/Sources/MadoMacUI/)'
if grep -Eq "$app_facing" "$diff_file"; then
  $hl xcodebuild build-for-testing -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath .build/dd-ci > "$o/$p-xcodebuild.log" 2>&1
  build_code=$?
  lane_result xcodebuild $build_code
  echo "xcodebuild: build-for-testing exit=$build_code" >> "$s"
  if (( build_code == 0 )); then
    env -u MADO_APP_FILTER $hl node scripts/tdd/app-lane.mjs '^MadoAppTests\.' > "$o/$p-apptests-retained.log" 2>&1
    retained_code=$?
  else
    echo "retained: build-for-testing failed (exit $build_code)" > "$o/$p-apptests-retained.log"
    retained_code=$build_code
  fi
  if (( retained_code == 0 )) && ! grep -Eq '^Tests run: [1-9][0-9]*, Failures: 0' "$o/$p-apptests-retained.log"; then
    echo 'apptests-retained: missing positive passing count' >> "$o/$p-apptests-retained.log"
    retained_code=1
  fi
  retained_counts=$(sed -nE 's/^Tests run: ([0-9]+), Failures: ([0-9]+).*/\1\/\2/p' "$o/$p-apptests-retained.log" | tail -1)
  lane_result apptests-retained $retained_code "${retained_counts:-0/0}"
  if [[ ${OWNER_GATES_HOSTED:-0} == 1 ]]; then
    if (( build_code == 0 )); then
      env -u MADO_APP_FILTER $hl node scripts/tdd/app-lane.mjs '^MadoHostedFocusTests\.' > "$o/$p-apptests-hosted.log" 2>&1
      hosted_code=$?
      if (( hosted_code == 0 )) && ! grep -Eq '^Tests run: [1-9][0-9]*, Failures: 0' "$o/$p-apptests-hosted.log"; then
        echo 'apptests-hosted: missing positive passing count' >> "$o/$p-apptests-hosted.log"
        hosted_code=1
      fi
    else
      echo "hosted: build-for-testing failed (exit $build_code)" > "$o/$p-apptests-hosted.log"
      hosted_code=$build_code
    fi
    lane_result apptests-hosted $hosted_code
    grep -E '^Tests run: [0-9]+' "$o/$p-apptests-hosted.log" | tail -1 | sed 's/^/apptests-hosted: /' >> "$s" || true
    if (( retained_code != 0 )); then lane_result apptests $retained_code; else lane_result apptests $hosted_code; fi
  else
    echo 'apptests-hosted=skipped (OWNER_GATES_HOSTED=0; hosted CI binding)' >> "$s"
    lane_result apptests $retained_code
  fi
else
  $hl xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci \
    > "$o/$p-xcodebuild.log" 2>&1
  lane_result xcodebuild $?
  echo 'apptests-retained=skipped (no App-facing change)' >> "$s"
  echo 'apptests-hosted=skipped (no App-facing change)' >> "$s"
  echo 'apptests=skip (no App-facing change)' >> "$s"
fi
node_suites=(scripts/ledger/*.test.mjs scripts/name-checks/*.test.mjs scripts/ci/name-checks-ci.test.mjs .agents/skills/mado-delegator/scripts/*.test.mjs)
if (( agents )); then
  node_suites+=(scripts/agents/*.test.mjs)
else
  echo 'node-agents=skipped (reviewed native-only diff)' >> "$s"
fi
if (( tdd )); then
  node_suites+=(scripts/tdd/*.test.mjs)
else
  echo 'node-tdd=skipped (reviewed native-only diff)' >> "$s"
fi
node --test --test-reporter=spec "${(@)node_suites}" > "$o/$p-node.log" 2>&1; lane_result node $?
node scripts/ledger/build.mjs --check > /dev/null 2>&1; lane_result ledger $?
git diff --check "$base"..HEAD > /dev/null 2>&1; lane_result diffcheck $?
if [[ ! -d node_modules ]]; then
  echo "design: missing node_modules in $wt; run npm ci --ignore-scripts in this worktree" > $o/$p-design.log
  lane_result design 1
else
  $hl npm run design:check > $o/$p-design.log 2>&1; lane_result design $?
fi
if (( native )); then grep -E 'Test run with .* tests' $o/$p-swift.log | tail -1 >> $s || true; fi
echo DONE >> $s || summary_error
cat "$s" || summary_error
exit $failed
