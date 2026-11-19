#!/bin/zsh
set -eu
[[ $# == 0 || ( $# == 1 && $1 == --two-green ) ]] || { echo 'usage: main-ci-status.sh [--two-green]' >&2; exit 2; }
limit=1
[[ $# == 1 ]] && limit=20
runs=$(gh run list --branch main --workflow CI --event push --limit $limit --json databaseId,headSha,status,conclusion) || exit 2
python3 -c '
import json,sys
try: runs=json.loads(sys.argv[1])
except (ValueError,TypeError): sys.exit(2)
two=sys.argv[2]=="20"
if not runs:
 print("PENDING - -"); sys.exit(1)
unique=[]; ids=set()
for r in runs:
 run_id=r.get("databaseId")
 if run_id is None or run_id in ids: continue
 ids.add(run_id); unique.append(r)
completed=[r for r in unique if r.get("status")=="completed"]
latest=completed[0] if two and completed else runs[0]
def green(r): return r.get("status")=="completed" and r.get("conclusion")=="success"
if green(latest) and (not two or len(completed)>=2 and green(completed[1])): status="GREEN"
elif latest.get("status")!="completed" or two and len(completed)<2 and green(latest): status="PENDING"
else: status="RED"
print(status,latest.get("databaseId","-"),latest.get("headSha","-"))
sys.exit(0 if status=="GREEN" else 1)
' "$runs" "$limit"
