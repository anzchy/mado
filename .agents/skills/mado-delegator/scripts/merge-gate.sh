#!/bin/sh
# The delegator's checked entry point for merging an audited PR.
set -eu
case "${1:-}" in ''|*[!0-9]*) echo 'usage: merge-gate.sh <pr-number>' >&2; exit 2;; esac
[ "$#" -eq 1 ] || { echo 'usage: merge-gate.sh <pr-number>' >&2; exit 2; }
exec python3 - "$1" "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

pr, scripts = sys.argv[1], pathlib.Path(sys.argv[2])


def fail(message):
    print('merge-gate: ' + message, file=sys.stderr)
    sys.exit(1)


def run(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        fail(f'{" ".join(map(str, args))} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result.stdout


status = subprocess.run([str(scripts / 'main-ci-status.sh')], text=True, capture_output=True)
if status.returncode or not status.stdout.startswith('GREEN '):
    fail('main CI is not GREEN: ' + status.stdout.strip())
candidate = json.loads(run(['gh', 'pr', 'view', pr, '--json', 'headRefOid,isDraft,body,createdAt']))
head = candidate['headRefOid']
if candidate['isDraft']:
    fail('PR is a draft')


def checks(number):
    rows = json.loads(run(['gh', 'pr', 'checks', str(number), '--json', 'name,state']))
    return bool(rows) and all(row['state'] in ('SUCCESS', 'SKIPPED', 'NEUTRAL') for row in rows)


if not checks(pr):
    fail('PR checks are not all passing')
for other in json.loads(run(['gh', 'pr', 'list', '--state', 'open', '--json', 'number,createdAt,isDraft'])):
    if int(other['number']) != int(pr) and not other['isDraft'] and other['createdAt'] < candidate['createdAt']:
        if checks(other['number']):
            fail(f'older ready PR #{other["number"]} must merge first')

worktrees = run(['git', 'worktree', 'list', '--porcelain']).splitlines()
for line in worktrees:
    if not line.startswith('worktree '):
        continue
    path = pathlib.Path(line[9:])
    tip = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=path, text=True, capture_output=True)
    if tip.returncode == 0 and tip.stdout.strip() == head:
        record = path / '.build/mado-verify' / f'{head}.json'
        if record.is_file():
            break
else:
    fail(f'no worktree at PR head {head} with a mado-verify record')
try:
    issue = json.loads(record.read_text())['issue']
except (ValueError, KeyError):
    fail('invalid mado-verify record')
run(['node', str(path / '.agents/skills/mado-verify/scripts/evidence.mjs'), 'check',
     '--head', head, '--issue', str(issue), '--worktree', str(path)], cwd=path)
with tempfile.TemporaryDirectory(prefix='mado-merge-body-') as temporary:
    body = pathlib.Path(temporary) / 'body.md'
    body.write_text(candidate['body'] or '')
    run(['node', str(path / 'scripts/agents/local-pr-lint.mjs'), '--body-file', str(body),
         '--base', 'origin/main', '--expect', head], cwd=path)
print(f'merge-gate: checks, PR body and evidence passed for #{pr} @ {head}')
run(['gh', 'pr', 'merge', '--rebase', pr], cwd=path)
PY
