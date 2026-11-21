#!/bin/sh
# Shadow check for an audited PR; this script never merges or blocks.
set -eu
case "${1:-}" in ''|*[!0-9]*) echo 'usage: merge-gate.sh <pr-number> [--audited <sha>]' >&2; exit 2;; esac
case "$#" in 1) audited='' ;; 3) [ "$2" = --audited ] || { echo 'usage: merge-gate.sh <pr-number> [--audited <sha>]' >&2; exit 2; }; audited=$3 ;; *) echo 'usage: merge-gate.sh <pr-number> [--audited <sha>]' >&2; exit 2;; esac
exec python3 - "$1" "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" "$audited" <<'PY'
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

pr, scripts, audited = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]


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



# #789: "CODE same, DOCS differ" (#733) carries the audited verdicts over only under rebase-verify's own conditions.
# merge-gate runs rebase-verify.sh from its own (delegator main checkout) directory, never the PR head's copy, parses
# its CODE line exactly, binds both patch hashes to its own recomputation, re-checks the DIFF paths against main's
# allowlist, and requires a PR body that shows no known Critical/High open (the classification never waives one).
REFUSALS = ('UPSTREAM OVERLAP ', 'DOCS ', 'acceptance text ', 'CODE differ')
VERDICTS = {
    'same': re.compile(r'CODE same ([0-9a-f]{40}) \(exact replayed tree match; candidate patch ([0-9a-f]{40})\)'),
    'docs': re.compile(r'CODE same, DOCS differ ([0-9a-f]{40}) \(only allowlisted doc rows differ; per-row merge keeps '
                       r'both sides; candidate patch ([0-9a-f]{40})\)'),
}
SEVERITY = re.compile(r'\b(critical|high)s?\b', re.I)  # whole words; "High-DPI" still matches (fails closed)


def patch_hash(worktree, base, tip):
    """rebase-verify.sh's code() digest: the canonical patch, blob IDs and hunk offsets normalized, shasum'd."""
    args = ['git', 'diff', '--binary', '--full-index', '--no-ext-diff', '--no-textconv', '--no-color', '-M', '-U3',
            '--src-prefix=a/', '--dst-prefix=b/', base, tip, '--', '.', ':(top,exclude)docs/feature-ledger.md',
            ':(top,exclude)docs/feature-ledger.html']
    try:
        result = subprocess.run(args, cwd=worktree, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LookupFailed(f'git diff {base} {tip}: {error}') from error
    if result.returncode:
        raise LookupFailed(f'git diff {base} {tip} failed: {result.stderr.decode(errors="replace").strip()}')
    patch = re.sub(rb'(?m)^index [^\n]*(\n|$)', b'', result.stdout)
    patch = re.sub(rb'(?m)^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@', rb'@@ -OLD\1 +NEW\2 @@', patch)
    return hashlib.sha1(patch.rstrip(b'\n') + b'\n').hexdigest()


def rebase_verdict(verify, hashes):
    """'same' or 'docs' for exactly one CODE line in rebase-verify's grammar whose hashes are `hashes`; else refuse."""
    lines = [line for line in verify.stdout.splitlines() if line.startswith('CODE ')]
    matched = {kind: pattern.fullmatch(lines[0]) for kind, pattern in VERDICTS.items()} if len(lines) == 1 else {}
    kind = next((kind for kind, match in matched.items() if match), None)
    if verify.returncode or kind is None:
        raise ConditionFailed('rebase-verify CODE same required for audited head to PR head: ' +
                              (verify.stdout.strip() or verify.stderr.strip()))
    if matched[kind].groups() != hashes:
        raise ConditionFailed(f'rebase-verify CODE line does not name the audited and PR-head patches {hashes}: '
                              + lines[0])
    return kind


def docs_differ(output, new_base, worktree, body):
    lines = output.splitlines()
    bad = [line for line in lines if line.startswith(REFUSALS)]
    if bad:
        raise ConditionFailed('rebase-verify DOCS differ with a refusal: ' + '; '.join(bad))
    sys.path.insert(0, str(scripts))
    try:
        from doc_rows import ALLOWLIST_REPO_PATH, load_allowlist
    except ImportError as error:
        raise LookupFailed(f'doc_rows import from {scripts}: {error}') from error
    try:
        shown = subprocess.run(['git', 'show', f'{new_base}:{ALLOWLIST_REPO_PATH}'], cwd=worktree, text=True,
                               capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LookupFailed(f'git show {new_base}:{ALLOWLIST_REPO_PATH}: {error}') from error
    if shown.returncode:
        raise ConditionFailed(f'rebase-verify DOCS differ but main has no {ALLOWLIST_REPO_PATH}')
    allowed = load_allowlist(text=shown.stdout)
    paths = [line[5:] for line in lines if line.startswith('DIFF ')]
    outside = [path for path in paths if path not in allowed]
    if not paths or outside:
        raise ConditionFailed('rebase-verify DOCS differ needs every DIFF path in main\'s allowlist: ' +
                              (', '.join(outside) if outside else 'no DIFF path'))
    known_high(body)


def headings(body):
    """(index, level, title) of every ATX heading outside fenced code; fenced lines stay in their section."""
    out, fence = [], None
    for index, line in enumerate(body.splitlines()):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})', line)
        if fence:
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence) and \
                    not line.strip()[len(marker.group(1)):]:
                fence = None
        elif marker:
            fence = marker.group(1)
        elif (heading := re.match(r'^(#{1,6})\s+(.*?)\s*#*\s*$', line)):
            out.append((index, len(heading.group(1)), heading.group(2)))
    return out


def section(body, at, level):
    """The lines after heading line `at` up to the next heading of the same or a higher level."""
    lines = body.splitlines()
    end = next((index for index, depth, _ in headings(body) if index > at and depth <= level), len(lines))
    return lines[at + 1:end]


def known_high(body):
    def refuse(why):
        raise ConditionFailed('DOCS differ never waives a known High: ' + why)

    gates = [(index, level) for index, level, title in headings(body) if re.fullmatch(r'gates\b.*', title, re.I)]
    rows = [index for index, line in enumerate(body.splitlines()) if re.match(r'^\s*\|\s*audit\s*\|', line, re.I)]
    if len(gates) != 1 or len(rows) != 1:
        refuse(f'the PR body needs one Gates section with one audit row ({len(gates)} Gates, {len(rows)} audit rows)')
    if rows[0] - gates[0][0] - 1 not in range(len(section(body, *gates[0]))):
        refuse('the audit row is outside the Gates section')
    audit = [cell.strip() for cell in body.splitlines()[rows[0]].strip().strip('|').split('|')]
    phrase = re.compile(r'\bno Critical/High\b', re.I)
    if len(audit) != 4 or audit[1] != 'PASS' or not phrase.search(audit[3]) or SEVERITY.search(phrase.sub('', audit[3])):
        refuse('the audit row needs PASS and a Source naming Critical/High only as "no Critical/High": ' +
               ' | '.join(audit))
    labels = [index for index, line in enumerate(body.splitlines())
              if re.match(r'^\s*(?:#+\s*|[-*_>]+\s*)?still open\b', line, re.I)]
    still = [(index, level) for index, level, title in headings(body) if re.match(r'still open\b', title, re.I)]
    if len(labels) != 1 or len(still) != 1 or still[0][0] != labels[0] or still[0][1] not in (2, 3):
        refuse('the PR body needs exactly one "## Still open" or "### Still open" heading')
    named = [line.strip() for line in section(body, *still[0]) if SEVERITY.search(line)]
    if named:
        refuse('Still open names ' + '; '.join(named))


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
    for other in json.loads(run(['gh', 'pr', 'list', '--state', 'open', '--limit', '200', '--json', 'number,createdAt,isDraft'])):
        if int(other['number']) != int(pr) and not other['isDraft'] and other['createdAt'] < candidate['createdAt']:
            if checks(other['number']):
                raise ConditionFailed(f'older ready PR #{other["number"]} must merge first')

    worktrees = [pathlib.Path(line[9:]) for line in run(['git', 'worktree', 'list', '--porcelain']).splitlines()
                 if line.startswith('worktree ')]
    head_worktree = next((path for path in worktrees
                          if subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=path, text=True,
                                            capture_output=True).stdout.strip() == head), None)
    if head_worktree is None:
        raise ConditionFailed(f'no worktree at PR head {head}')
    if not audited:
        if not (head_worktree / '.build/mado-verify' / f'{head}.json').is_file():
            raise ConditionFailed('--audited <sha> required when PR head has no mado-verify record')
        audited = head
    record_worktree = next((path for path in worktrees
                            if (path / '.build/mado-verify' / f'{audited}.json').is_file()), None)
    if record_worktree is None:
        raise ConditionFailed(f'no mado-verify record for audited head {audited}')
    record = record_worktree / '.build/mado-verify' / f'{audited}.json'
    try:
        record_data = json.loads(record.read_text())
        issue = record_data['issue']
    except (ValueError, KeyError):
        raise ConditionFailed('invalid mado-verify record')
    if record_data.get('link'):
        link = record_data['link']
        if not isinstance(link, dict) or record_data.get('head') != audited or link.get('newHead') != audited or \
                record_data.get('base') != link.get('newBase'):
            raise ConditionFailed('invalid linked mado-verify head/base')
        # evidence.mjs check recomputes CODE, allow-list, fingerprints, old record and lane provenance.
    evidence = subprocess.run(['node', str(record_worktree / '.agents/skills/mado-verify/scripts/evidence.mjs'), 'check',
                               '--head', audited, '--issue', str(issue), '--worktree', str(record_worktree)], cwd=record_worktree,
                              text=True, capture_output=True)
    if evidence.returncode:
        raise ConditionFailed('mado-verify evidence failed: ' + (evidence.stderr.strip() or evidence.stdout.strip()))
    if audited != head:
        old_base = run(['git', 'merge-base', 'origin/main', audited], cwd=head_worktree).strip()
        new_base = run(['git', 'merge-base', 'origin/main', head], cwd=head_worktree).strip()
        try:
            verify = subprocess.run(['zsh', str(scripts / 'rebase-verify.sh'), old_base, audited, new_base, head],
                                    cwd=head_worktree, text=True, capture_output=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise LookupFailed(f'rebase-verify.sh: {error}') from error
        hashes = (patch_hash(head_worktree, old_base, audited), patch_hash(head_worktree, new_base, head))
        if rebase_verdict(verify, hashes) == 'docs':
            docs_differ(verify.stdout, new_base, head_worktree, candidate['body'] or '')
    with tempfile.TemporaryDirectory(prefix='mado-merge-body-') as temporary:
        body = pathlib.Path(temporary) / 'body.md'
        body.write_text(candidate['body'] or '')
        lint = subprocess.run(['node', str(head_worktree / 'scripts/agents/local-pr-lint.mjs'), '--body-file', str(body),
                               '--base', 'origin/main', '--expect', head], cwd=head_worktree, text=True, capture_output=True)
        if lint.returncode:
            raise ConditionFailed('PR body lint failed: ' + (lint.stderr.strip() or lint.stdout.strip()))
    verdict = 'would-allow'
except ConditionFailed as error:
    verdict = 'would-refuse condition-failed: ' + str(error)
except (LookupFailed, ValueError, KeyError, TypeError, OSError, ImportError) as error:
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
