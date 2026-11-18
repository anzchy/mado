#!/bin/sh
# The delegator's checked entry point for merging an audited PR.
set -eu
case "${1:-}" in ''|*[!0-9]*) echo 'usage: merge-gate.sh <pr-number>' >&2; exit 2;; esac
[ "$#" -eq 1 ] || { echo 'usage: merge-gate.sh <pr-number>' >&2; exit 2; }
exec python3 - "$1" "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" <<'PY'
import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile

pr, scripts = sys.argv[1], pathlib.Path(sys.argv[2])


class ConditionFailed(Exception): pass
class LookupFailed(Exception): pass


def run(args, cwd=None):
    try:
        result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LookupFailed(f'{" ".join(map(str, args))}: {error}') from error
    if result.returncode:
        raise LookupFailed(f'{" ".join(map(str, args))} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result.stdout

head = 'unknown'
try:
    candidate = json.loads(run(['gh', 'pr', 'view', pr, '--json', 'headRefOid,isDraft,body,createdAt']))
    head = candidate['headRefOid']
    status_result = subprocess.run([str(scripts / 'main-ci-status.sh')], text=True, capture_output=True)
    status = status_result.stdout
    if status.startswith(('RED ', 'PENDING ')):
        raise ConditionFailed('main CI is not GREEN: ' + status.strip())
    if status_result.returncode or not status.startswith('GREEN '):
        raise LookupFailed('main CI status lookup failed: ' + (status_result.stderr.strip() or status.strip()))
    if candidate['isDraft']:
        raise ConditionFailed('PR is a draft')

    def checks(number):
        rows = json.loads(run(['gh', 'pr', 'checks', str(number), '--json', 'name,state']))
        return bool(rows) and all(row['state'] in ('SUCCESS', 'SKIPPED', 'NEUTRAL') for row in rows)

    if not checks(pr):
        raise ConditionFailed('PR checks are not all passing')
    for other in json.loads(run(['gh', 'pr', 'list', '--state', 'open', '--json', 'number,createdAt,isDraft'])):
        if int(other['number']) != int(pr) and not other['isDraft'] and other['createdAt'] < candidate['createdAt']:
            if checks(other['number']):
                raise ConditionFailed(f'older ready PR #{other["number"]} must merge first')

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
        raise ConditionFailed(f'no worktree at PR head {head} with a mado-verify record')
    try:
        issue = json.loads(record.read_text())['issue']
    except (ValueError, KeyError):
        raise ConditionFailed('invalid mado-verify record')
    evidence = subprocess.run(['node', str(path / '.agents/skills/mado-verify/scripts/evidence.mjs'), 'check',
                               '--head', head, '--issue', str(issue), '--worktree', str(path)], cwd=path,
                              text=True, capture_output=True)
    if evidence.returncode:
        raise ConditionFailed('mado-verify evidence failed: ' + (evidence.stderr.strip() or evidence.stdout.strip()))
    with tempfile.TemporaryDirectory(prefix='mado-merge-body-') as temporary:
        body = pathlib.Path(temporary) / 'body.md'
        body.write_text(candidate['body'] or '')
        lint = subprocess.run(['node', str(path / 'scripts/agents/local-pr-lint.mjs'), '--body-file', str(body),
                               '--base', 'origin/main', '--expect', head], cwd=path, text=True, capture_output=True)
        if lint.returncode:
            raise ConditionFailed('PR body lint failed: ' + (lint.stderr.strip() or lint.stdout.strip()))
    verdict = 'would-allow'
except ConditionFailed as error:
    verdict = 'would-refuse condition-failed: ' + str(error)
except (LookupFailed, ValueError, KeyError, TypeError) as error:
    verdict = 'would-refuse lookup-failed: ' + str(error) + '; retry or use the override'
print(f'merge-gate: {verdict} PR #{pr} @ {head} (SHADOW; no merge performed)')
reason = os.environ.get('MADO_MERGE_GATE_OVERRIDE')
if reason is not None:
    if not reason.strip():
        print('merge-gate: override reason must be nonempty', file=sys.stderr)
        sys.exit(2)
    log = pathlib.Path.home() / '.mado/handoff/merge-gate-overrides.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('a') as stream:
        stream.write(f'{datetime.datetime.now(datetime.timezone.utc).isoformat()} PR #{pr} head={head} reason={reason}\n')
    comment = f'Merge-gate shadow override for PR #{pr} at {head}: {reason}. Verdict: {verdict}'
    run(['gh', 'pr', 'comment', pr, '--body', comment])
    print('merge-gate: override recorded and PR comment posted')
PY
