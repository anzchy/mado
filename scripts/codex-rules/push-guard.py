#!/usr/bin/env python3
"""Push the current picsee topic branch through a checked delegator entry point."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


# The repository is renamed anzchy/picsee -> anzchy/mado (#554); both names stay approved.
APPROVED_PUSH_URLS = tuple(url for repo in ('picsee', 'mado')
                           for url in (f'https://github.com/anzchy/{repo}.git', f'git@github.com:anzchy/{repo}.git'))


def git(*args):
    return subprocess.run(['git', *args], check=True, text=True, capture_output=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--expected-remote-oid', metavar='OID', help='exact remote tip for a lease-protected rebase push')
    args = parser.parse_args()

    script_root = Path(__file__).resolve().parents[2]
    try:
        worktree = Path(git('rev-parse', '--show-toplevel')).resolve()
        branch = git('symbolic-ref', '--quiet', '--short', 'HEAD')
        push_urls = git('remote', 'get-url', '--push', '--all', 'origin').splitlines()
    except subprocess.CalledProcessError as error:
        parser.error(f'cannot identify worktree, branch or origin: {error}')
    if worktree != script_root:
        parser.error('run the script from its own picsee worktree')
    overlay = worktree / '.codex/rules/picsee-role.rules'
    if overlay.is_symlink() or not overlay.is_file() or not overlay.read_text().startswith('# Local picsee role: delegator\n'):
        parser.error('only the explicitly provisioned delegator worktree may push')
    if branch in ('main', 'HEAD') or branch.startswith('-'):
        parser.error('push only the current topic branch, never main or a detached HEAD')
    if len(push_urls) != 1 or push_urls[0] not in APPROVED_PUSH_URLS:
        parser.error('origin must have exactly one anzchy/picsee or anzchy/mado push URL')

    ref = f'refs/heads/{branch}'
    command = ['git', 'push']
    if args.dry_run:
        command.append('--dry-run')
    if args.expected_remote_oid:
        if not re.fullmatch(r'(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})', args.expected_remote_oid):
            parser.error('expected remote OID must be a full 40- or 64-digit hex value')
        command.append(f'--force-with-lease={ref}:{args.expected_remote_oid.lower()}')
    command.extend([push_urls[0], f'HEAD:{ref}'])
    return subprocess.run(command, check=False).returncode


if __name__ == '__main__':
    sys.exit(main())
