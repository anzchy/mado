# -*- coding: utf-8 -*-
"""resolve_doc_rows.py <path> — #733: resolve a conflicted allowlisted doc (the states README status table) during a
rebase by merging its table rows per row key from index stages 1 (base), 2 (main) and 3 (the commit being replayed).

Exit 0 resolved (file written; the caller stages it). 2 the path is not in rebase-docs-allowlist.txt. 3 manual: a cell
changed on both sides, a deleted row, a duplicate key, the same new key with different text, rows reordered differently
on both sides, a stage missing, or lines outside the table changed on both sides; the conflict markers stay for a human.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from doc_rows import Manual, load_allowlist, merge  # noqa: E402


def stage(n, path):
    shown = subprocess.run(["git", "show", f":{n}:{path}"], capture_output=True)
    if shown.returncode:
        raise Manual(f"stage {n} missing (added or deleted on one side)")
    return shown.stdout.decode("utf-8")


def main(argv):
    if len(argv) != 1:
        print("usage: resolve_doc_rows.py <path>")
        return 2
    path = argv[0]
    headers = load_allowlist().get(path)
    if not headers:
        print(f"{path}: not in the allowlist ({Path(__file__).with_name('rebase-docs-allowlist.txt').name})")
        return 2
    try:
        merged = merge(stage(1, path), stage(2, path), stage(3, path), headers)
    except Manual as reason:
        print(f"manual {path}: {reason}")
        return 3
    with open(path, "w", encoding="utf-8", newline="") as out:
        out.write(merged)
    print(f"resolved {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
