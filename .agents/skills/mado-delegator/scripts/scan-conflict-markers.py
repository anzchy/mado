#!/usr/bin/env python3
"""Reject paired Git conflict markers in tracked text at each commit in a range."""
import subprocess
import sys


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True).stdout


def main():
    if len(sys.argv) != 2:
        print('usage: scan-conflict-markers.py <base>..<head>', file=sys.stderr)
        return 2
    commits = git('rev-list', '--reverse', sys.argv[1]).decode().splitlines()
    for commit in commits:
        matches = subprocess.run(['git', 'grep', '-I', '-n', '-E',
                                  r'^(<<<<<<<|>>>>>>>)( |$)', commit, '--'],
                                 capture_output=True)
        if matches.returncode not in (0, 1):
            print(matches.stderr.decode(errors='replace'), file=sys.stderr)
            return 2
        by_path = {}
        for line in matches.stdout.splitlines():
            rest = line[len(commit) + 1:]
            path, _, marker = rest.rsplit(b':', 2)
            by_path.setdefault(path, set()).add(marker[:7])
        for raw_path, markers in by_path.items():
            if markers == {b'<<<<<<<', b'>>>>>>>'}:
                path = raw_path.decode('utf-8', 'surrogateescape')
                print(f'conflict markers: {commit} {path}')
                return 8
    return 0


if __name__ == '__main__':
    sys.exit(main())
