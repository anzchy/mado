#!/usr/bin/env python3
"""Verify an audited patch's resulting locations in an isolated Git index."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    repo, old_base, old_head, new_base, new_head = sys.argv[1:]
    paths = ["--", ".", ":(top,exclude)docs/feature-ledger.md",
             ":(top,exclude)docs/feature-ledger.html"]
    with tempfile.TemporaryDirectory(prefix="picsee-rebase-verify-") as temp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(temp) / "index")}

        def git(*args):
            return subprocess.run(["git", "-C", repo, *args], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)

        patch = git("diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
                    "--no-color", "-M", "--src-prefix=a/", "--dst-prefix=b/",
                    old_base, old_head, *paths).stdout
        git("read-tree", new_base)
        # Full blob IDs let Git merge from the original pre-image, preserving which
        # repeated block was edited. A conflict is evidence against carry-forward.
        applied = subprocess.run(["git", "-C", repo, "apply", "--cached", "--3way"],
                                 input=patch, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if applied.returncode:
            print("rebase-verify: audited patch cannot replay cleanly on new base", file=sys.stderr)
            return 1
        expected = git("write-tree").stdout.decode().strip()
        # The only ignored files are regenerated ledger files, just as in the patch check.
        return subprocess.run(["git", "-C", repo, "diff", "--quiet", "--no-ext-diff",
                               "--no-textconv", expected, new_head, *paths], env=env).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b"git command failed").decode(errors="replace").strip().splitlines()[0]
        print(f"rebase-verify: {detail}", file=sys.stderr)
        sys.exit(1)
    except OSError as error:
        print(f"rebase-verify: {error}", file=sys.stderr)
        sys.exit(1)
