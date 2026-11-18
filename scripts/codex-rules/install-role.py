#!/usr/bin/env python3
"""Install an explicit per-worktree role overlay before launching Codex."""
import argparse
import os
from pathlib import Path
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', type=Path, required=True)
    parser.add_argument('--role', choices=('delegator', 'implementor', 'auditor'), default='implementor')
    args = parser.parse_args()
    directory = args.worktree.resolve() / '.codex/rules'
    if not (directory / 'picsee.rules').is_file():
        parser.error('worktree must already contain the common picsee.rules')
    target = directory / 'picsee-role.rules'
    if target.is_symlink():
        parser.error('refusing a symlink role overlay')
    content = '# Local picsee role: ' + args.role + '\n'
    if args.role != 'delegator':
        content += Path(__file__).with_name('restricted-role.rules').read_text()
    else:
        content += '# PR ownership is granted; push only through the checked push-guard.py entry point.\n'
    fd, temp = tempfile.mkstemp(prefix='.role-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(temp, target)
    finally:
        Path(temp).unlink(missing_ok=True)
    print(f'{args.role}: {target}')


if __name__ == '__main__':
    main()
