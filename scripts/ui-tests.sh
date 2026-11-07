#!/bin/bash
# Local/manual XCUITests only. Never add this command to required PR checks.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-flows}
repetitions=${2:-1}
case "$mode" in
  all|flows|audit|smoke) ;;
  *) echo "Usage: scripts/ui-tests.sh [all|flows|audit|smoke] [repetitions=1]" >&2; exit 64 ;;
esac
if [[ $# -gt 2 || ! "$repetitions" =~ ^([1-9]|10)$ ]]; then
  echo "repetitions must be 1..10" >&2; exit 64
fi
repo="$PWD"
run_id="i145-$(date +%Y%m%d-%H%M%S)-$$"
output="$HOME/.picsee/ui-tests/$run_id"
mkdir -p "$output"
derived="$HOME/.picsee/ui-tests/dd"
ram="$HOME/.picsee/device/ram/with-ram.sh"
lock="$repo/.agents/skills/picsee-delegator/scripts/gui-lock.sh"
selectors=(-only-testing:MadoUITests)
expected=4
case "$mode" in
  flows)
    selectors=(-only-testing:MadoUITests/MadoFixtureGridUITests/testKeyboardLoopRestoresCurrentItemSelectionAndFocus
      -only-testing:MadoUITests/MadoFixtureGridUITests/testMenuStatesFollowGridAndViewer)
    expected=2 ;;
  audit)
    selectors=(-only-testing:MadoUITests/MadoFixtureGridUITests/testAccessibilityAuditGridAndViewer)
    expected=1 ;;
  smoke)
    selectors=(-only-testing:MadoUITests/MadoFixtureGridUITests/testContainerFixtureOpensThreeImageGrid)
    expected=1 ;;
esac
run_heavy() { "$ram" i145 "$repo/scripts/heavy-lock.sh" "$@"; }
release() {
  [[ -n "$acquisition_id" ]] || return 0
  # A signal may finish the outer RAM wrapper before heavy-lock's isolated
  # process group drains. Do not give another run the desktop in that window.
  if python3 - "$derived" <<'DRAIN'
import os, subprocess, sys, time
root = sys.argv[1]
deadline = time.monotonic() + 330
while True:
    lines = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True).splitlines()
    live = [line for line in lines if root in line and int(line.split()[0]) != os.getpid()]
    if not live:
        sys.exit(0)
    if time.monotonic() >= deadline:
        print('GUI lock retained: test processes still present:', *live, sep='\n', file=sys.stderr)
        sys.exit(1)
    time.sleep(1)
DRAIN
  then
    "$lock" release "$run_id" --acquisition-id "$acquisition_id"
  else
    echo "After confirming test processes are gone, release with:" >&2
    echo "$lock release $run_id --acquisition-id $acquisition_id" >&2
    return 1
  fi
}
finish() {
  task_rc=$?
  trap - EXIT
  if [[ -n "$monitor" ]]; then
    touch "$stop"
    wait "$monitor" || true
  fi
  if ! release; then
    [[ $task_rc -ne 0 ]] || task_rc=70
  else
    # XCTest termination can bypass the App hook; test-host sandbox cleanup may fail.
    # Only after owned processes drain, remove UUID fixtures proved by this run's log.
    if ! python3 "$repo/scripts/ui-test-runtime.py" cleanup-app-fixtures "$output"; then
      [[ $task_rc -ne 0 ]] || task_rc=70
    fi
  fi
  if ! python3 "$repo/scripts/ui-test-runtime.py" cleanup "$output"; then
    [[ $task_rc -ne 0 ]] || task_rc=70
  fi
  exit "$task_rc"
}
acquisition_id=""
monitor=""
stop=""
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "UI test evidence: $output"
python3 "$repo/scripts/ui-test-runtime.py" stage "$output" "$repo/TestAssets/synthetic"
# Build before acquiring the desktop, so queued builds do not reserve it.
run_heavy xcodegen generate > "$output/generate.log" 2>&1 || { rc=$?; cat "$output/generate.log"; exit "$rc"; }
if run_heavy xcodebuild build-for-testing -scheme MadoFixtureUI -destination 'platform=macOS' \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PICSEE_UI_TEST_FIXTURE' \
    -derivedDataPath "$derived" > "$output/build.log" 2>&1; then
  echo 'BUILD-FOR-TESTING PASSED'
else
  rc=$?; tail -80 "$output/build.log"; exit "$rc"
fi
# Freeze a run-local plan with paths and fixture inputs outside protected folders.
plan="$output/Fixture.xctestrun"
python3 - "$derived" "$plan" "$output" <<'PLAN'
from pathlib import Path
import plistlib, sys
products = Path(sys.argv[1]) / 'Build/Products'
plans = list(products.glob('MadoFixtureUI_*.xctestrun'))
if len(plans) != 1:
    raise SystemExit('Expected exactly one generated MadoFixtureUI test plan')
def expand(value):
    if isinstance(value, str): return value.replace('__TESTROOT__', str(products))
    if isinstance(value, list): return [expand(v) for v in value]
    if isinstance(value, dict): return {k: expand(v) for k, v in value.items()}
    return value
plan = expand(plistlib.load(plans[0].open('rb')))
target = plan['MadoUITests']
target.setdefault('EnvironmentVariables', {}).update(
    PICSEE_UI_FIXTURE_DIR=str(Path(sys.argv[3]) / 'fixtures'),
    PICSEE_UI_RUN_ID=Path(sys.argv[3]).name, PWD=sys.argv[3])
target.setdefault('UITargetAppEnvironmentVariables', {})['PWD'] = sys.argv[3]
plistlib.dump(plan, open(sys.argv[2], 'wb'))
PLAN
if acquisition=$("$lock" acquire "$run_id" 20 '#145 XCUITest'); then
  :
else
  rc=$?
  [[ $rc -eq 75 ]] || exit "$rc"
  acquisition=$("$lock" wait "$run_id" 20 '#145 XCUITest')
fi
echo "$acquisition"
acquisition_id=${acquisition##*acquisition_id=}
for ((iteration=1; iteration<=repetitions; iteration++)); do
  result="$output/run-$iteration.xcresult"
  log="$output/run-$iteration.log"
  python3 "$repo/scripts/ui-test-prompts.py" check | tee "$output/prompts-before-$iteration.json"
  stop="$output/monitor-stop-$iteration"
  prompt="$output/prompt-$iteration.json"
  ready="$output/monitor-ready-$iteration"
  python3 "$repo/scripts/ui-test-prompts.py" watch "$result" "$derived" "$stop" "$prompt" "$ready" > "$output/monitor-$iteration.log" 2>&1 &
  monitor=$!
  for ((attempt=0; attempt<50; attempt++)); do
    [[ ! -f "$ready" ]] || break
    kill -0 "$monitor" 2>/dev/null || break
    sleep 0.1
  done
  [[ -f "$ready" && ! -f "$prompt" ]] || { cat "$output/monitor-$iteration.log" >&2; exit 78; }
  kill -0 "$monitor" 2>/dev/null || { cat "$output/monitor-$iteration.log" >&2; exit 78; }
  rc=0
  summary_rc=0
  (cd "$output"; run_heavy xcodebuild test-without-building -xctestrun "$plan" -destination 'platform=macOS' \
    -derivedDataPath "$derived" -parallel-testing-enabled NO \
    -resultBundlePath "$result" "${selectors[@]}" > "$log" 2>&1) || rc=$?
  touch "$stop"
  monitor_rc=0
  wait "$monitor" || monitor_rc=$?
  monitor=""
  if [[ $monitor_rc -ne 0 || -f "$prompt" ]]; then
    cat "$output/monitor-$iteration.log" >&2
    [[ ! -f "$prompt" ]] || cat "$prompt" >&2
    exit 78
  fi
  xcrun xcresulttool get test-results summary --path "$result" > "$output/run-$iteration.json" || {
    tail -80 "$log"; exit 70;
  }
  # Fail closed on skipped, expected-failure, zero-test or incomplete runs.
  python3 - "$output/run-$iteration.json" "$expected" <<'CHECK' || summary_rc=$?
import json, sys
s = json.load(open(sys.argv[1]))
print("UI result:", s['result'], "passed=", s['passedTests'], "failed=", s['failedTests'],
      "skipped=", s['skippedTests'], "expectedFailures=", s['expectedFailures'])
ok = (s['result'] == 'Passed' and s['passedTests'] == int(sys.argv[2])
      and s['totalTestCount'] == int(sys.argv[2]) and s['failedTests'] == 0
      and s['skippedTests'] == 0 and s['expectedFailures'] == 0)
sys.exit(0 if ok else 1)
CHECK
  if [[ $rc -ne 0 || $summary_rc -ne 0 ]]; then
    tail -80 "$log"
    [[ $rc -ne 0 ]] && exit "$rc"
    exit "$summary_rc"
  fi
  echo "PASS $iteration/$repetitions $mode (no skips, expected failures or retries)" | tee -a "$output/passes.log"
done
