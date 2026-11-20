#!/usr/bin/env python3
"""Verify an audited patch's resulting locations in an isolated Git index.

Exit 0: the replayed patch matches new-head exactly (CODE same). 5 (#733): only rows of tables listed in
rebase-docs-allowlist.txt differ, the per-row three-way merge keeps both sides, no ledger acceptance text changed and
upstream did not touch any other path the branch touched (CODE same, DOCS differ). 1: anything else (CODE differ).
Every differing path prints as `DIFF <path>`; a refused docs result prints why (`UPSTREAM OVERLAP <path>`, ...).
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent))

LEDGER = ("docs/feature-ledger.md", "docs/feature-ledger.html")
ACCEPT_COLUMN, LIMIT = "怎么确认", "限制："


def acceptance(text):
    """{row ID: the 怎么确认 text before 「限制：」} for every ledger table that has the column."""
    rows, column = {}, None
    for line in (text or "").split("\n"):
        if not line.startswith("|"):
            column = None
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if ACCEPT_COLUMN in cells:
            column = cells.index(ACCEPT_COLUMN)
        elif column is not None and len(cells) > column and not set(cells[0]) <= set("-: "):
            rows[cells[0]] = cells[column].split(LIMIT, 1)[0].strip()
    return rows


class Conflict(Exception):
    pass


def three_way(base, ours, theirs):
    if ours == theirs or theirs == base:
        return ours
    if ours == base:
        return theirs
    raise Conflict("changed on both sides")


def main():
    repo, old_base, old_head, new_base, new_head = sys.argv[1:]
    ledger_out = [f":(top,exclude){p}" for p in LEDGER]
    with tempfile.TemporaryDirectory(prefix="picsee-rebase-verify-") as temp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(temp) / "index")}

        def git(*args, check=True, data=None):
            return subprocess.run(["git", "-C", repo, *args], env=env, input=data,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

        def patch(*paths, renames=True):
            return git("diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color",
                       "-M" if renames else "--no-renames", "--src-prefix=a/", "--dst-prefix=b/",
                       old_base, old_head, "--", *paths).stdout

        def names(a, b, excludes):
            out = git("diff", "--name-only", "--no-renames", "-z", a, b, "--", ".", *excludes).stdout
            return [p for p in out.decode().split("\0") if p]

        def blob(ref, path):
            shown = git("show", f"{ref}:{path}", check=False)
            return shown.stdout if shown.returncode == 0 else None

        def replay(excludes):
            git("read-tree", new_base)
            # Full blob IDs let Git merge from the original pre-image, preserving which
            # repeated block was edited. A conflict is evidence against carry-forward.
            if git("apply", "--cached", "--3way", check=False, data=patch(".", *excludes)).returncode == 0:
                return git("write-tree").stdout.decode().strip(), []
            git("read-tree", new_base)
            failed = [p for p in names(old_base, old_head, excludes)
                      if git("apply", "--cached", "--3way", check=False, data=patch(p, renames=False)).returncode]
            for p in failed:
                # A failed --3way apply leaves unmerged stages; the path keeps new-base and is named as differing.
                git("reset", "-q", new_base, "--", p)
            return git("write-tree").stdout.decode().strip(), failed

        expected, failed = replay(ledger_out)
        if not failed and git("diff", "--quiet", "--no-ext-diff", "--no-textconv", expected, new_head,
                              "--", ".", *ledger_out, check=False).returncode == 0:
            return 0
        # The exact decision above needs nothing else; the docs path fails closed (CODE differ) without doc_rows.py.
        from doc_rows import Manual, load_allowlist, merge
        allow = load_allowlist()
        docs_out = ledger_out + [f":(top,exclude){p}" for p in allow]
        # Name the differing paths: outside the allowlist from a replay without the allowlisted files, the
        # allowlisted files from a plain three-way replay of each.
        expected, failed = replay(docs_out)
        code_diff = sorted(set(failed) | set(names(expected, new_head, docs_out)))
        doc_diff = []
        for path in allow:
            b, o, t, h = (blob(ref, path) for ref in (old_base, new_base, old_head, new_head))
            try:
                replayed = three_way(b, o, t)
            except Conflict:
                replayed = None
                if None not in (b, o, t):
                    with tempfile.TemporaryDirectory() as m:
                        files = [Path(m) / n for n in ("ours", "base", "theirs")]
                        for f, data in zip(files, (o, b, t)):
                            f.write_bytes(data)
                        merged = git("merge-file", "-p", *map(str, files), check=False)
                        replayed = merged.stdout if merged.returncode == 0 else None
            if replayed is None or replayed != h:
                doc_diff.append(path)
        for path in sorted(set(code_diff) | set(doc_diff)):
            print(f"DIFF {path}")
        if code_diff:
            print("CODE differ: paths outside rebase-docs-allowlist.txt differ")
            return 1
        if not doc_diff:
            print("CODE differ: the replay failed without a differing path")
            return 1
        refused = []
        for path in doc_diff:
            versions = [blob(ref, path) for ref in (old_base, new_base, old_head, new_head)]
            if None in versions:
                refused.append(f"DOCS {path}: missing in one version")
                continue
            b, o, t, h = (v.decode("utf-8") for v in versions)
            try:
                if merge(b, o, t, allow[path]) != h:
                    refused.append(f"DOCS {path}: the per-row merge of both sides does not equal the rebased file")
            except Manual as reason:
                refused.append(f"DOCS {path}: {reason}")
        sides = [acceptance((blob(ref, LEDGER[0]) or b"").decode("utf-8"))
                 for ref in (old_base, new_base, old_head, new_head)]
        for key in sorted(set().union(*sides)):
            b, o, t, h = (side.get(key) for side in sides)
            try:
                if three_way(b, o, t) != h:
                    refused.append(f"acceptance text of {key} changed in the rebase")
            except Conflict:
                refused.append(f"acceptance text of {key} changed on both sides")
        upstream = set(names(old_base, new_base, docs_out)) & set(names(old_base, old_head, docs_out))
        refused += [f"UPSTREAM OVERLAP {p} (upstream changed it too: two-auditor combination check)"
                    for p in sorted(upstream)]
        for line in refused:
            print(line)
        return 1 if refused else 5


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b"git command failed").decode(errors="replace").strip().splitlines()[0]
        print(f"rebase-verify: {detail}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, UnicodeDecodeError, ImportError) as error:
        print(f"rebase-verify: {error}", file=sys.stderr)
        sys.exit(1)
