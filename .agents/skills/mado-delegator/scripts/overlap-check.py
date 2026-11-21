#!/usr/bin/env python3
"""overlap-check.py — find combination risk between in-flight branches and main, before the PR-time rebase.

  overlap-check.py [--json] [--upstream origin/main] trial [<branch>…]
      After every merge to main (run `git fetch` first). For each in-flight branch: an in-memory trial merge
      (`git merge-tree`; no worktree is touched) plus the files both the branch and main changed since they split.
        CLEAN    nothing shared
        LEDGER   only docs/feature-ledger.* conflicts; rebase-ledger.sh handles them, so this is not urgent
        OVERLAP  no textual conflict, but both sides changed the same code file (the #134 x #108 shape)
        CODE     textual conflict in code
        MERGED   every commit is already on main (also after gh's rebase merge)
        EMPTY    no commits of its own yet; "uncommitted": true means its worktree has edits the trial cannot see
      OVERLAP or CODE: rebase that branch now, while it is small, then a quick combination check (guide 5.6).
      Exit 0 clean or ledger only, 1 overlap, 2 code conflict, 3 usage.

  overlap-check.py [--json] [--upstream origin/main] claim [--branches <b>…] -- <path>…
      Before dispatch: which in-flight branches already change the files a new brief's "You own" line names
      (a path ending in / matches a directory). A shared hotspot prints HOTSPOT and refuses: sequence the items.
      Ledger paths print HOTSPOT-LEDGER as a warning and do not refuse, because the row-level ledger merge
      handles them. Other shared paths retain the SHARED refusal. Exit 0 clear or ledger-only, 1 refused, 3 usage.

Without branch names it checks every branch checked out in a worktree, except main.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

LEDGER = {"docs/feature-ledger.md", "docs/feature-ledger.html"}
HOTSPOTS = frozenset(line.strip() for line in Path(__file__).with_name("hotspots.txt").read_text().splitlines()
                     if line.strip() and not line.startswith("#"))


class UsageError(Exception):
    pass


def git(*args, ok=(0,)):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode not in ok:
        raise UsageError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result


def resolve(ref):
    if git("rev-parse", "-q", "--verify", f"{ref}^{{commit}}", ok=(0, 1)).returncode:
        raise UsageError(f"unknown branch or commit: {ref}")


def worktree_branches():
    """{branch: worktree path} for every branch checked out in a worktree, except main."""
    found, path = {}, None
    for line in git("worktree", "list", "--porcelain").stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/") and line != "branch refs/heads/main":
            found[line[len("branch refs/heads/"):]] = path
    return found


def uncommitted(path):
    return bool(git("-C", path, "status", "--porcelain", "--untracked-files=no").stdout.strip())


def merged(upstream, branch):
    return not any(line.startswith("+") for line in git("cherry", upstream, branch).stdout.splitlines())


def changed(a, b):
    return set(git("diff", "--name-only", a, b).stdout.split())


def trial(upstream, branch, path=None):
    resolve(branch)
    report = {"branch": branch, "conflicts": [], "overlap": []}
    if path:
        report["uncommitted"] = uncommitted(path)
    if git("rev-list", "--count", f"{upstream}..{branch}").stdout.strip() == "0":
        return {**report, "status": "EMPTY"}
    if merged(upstream, branch):
        return {**report, "status": "MERGED"}
    result = git("merge-tree", "--write-tree", "--name-only", "--no-messages", upstream, branch, ok=(0, 1))
    conflicts = sorted(set(result.stdout.split()[1:])) if result.returncode else []
    base = git("merge-base", upstream, branch).stdout.strip()
    overlap = sorted((changed(base, branch) & changed(base, upstream)) - LEDGER)
    if any(f not in LEDGER for f in conflicts):
        status = "CODE"
    elif overlap:
        status = "OVERLAP"
    else:
        status = "LEDGER" if conflicts else "CLEAN"
    return {**report, "status": status, "conflicts": conflicts, "overlap": overlap}


def claim(upstream, branches, paths):
    def wanted(f):
        return any(f == p or (p.endswith("/") and f.startswith(p)) for p in paths)

    found = []
    worktrees = worktree_branches()
    for branch in branches:
        resolve(branch)
        worktree = worktrees.get(branch)
        pending = set()
        if worktree:
            pending = set(git("-C", worktree, "diff", "--name-only", "HEAD").stdout.splitlines())
            pending.update(git("-C", worktree, "ls-files", "--others", "--exclude-standard").stdout.splitlines())
        if merged(upstream, branch) and not pending:
            continue
        base = git("merge-base", upstream, branch).stdout.strip()
        shared = sorted(f for f in changed(base, branch) | pending if wanted(f))
        if shared:
            report = {"branch": branch, "shared": shared}
            hotspots = sorted(set(shared) & (HOTSPOTS - LEDGER))
            ledger = sorted(set(shared) & LEDGER)
            if hotspots:
                report["hotspots"] = hotspots
            if ledger:
                report["ledger"] = ledger
            found.append(report)
    return found


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--upstream", default="origin/main")
    sub = parser.add_subparsers(dest="mode", required=True)
    t = sub.add_parser("trial")
    t.add_argument("branches", nargs="*")
    c = sub.add_parser("claim")
    c.add_argument("--branches", nargs="*")
    c.add_argument("paths", nargs="+")
    args = parser.parse_args(argv)
    try:
        resolve(args.upstream)
        if args.mode == "trial":
            trees = worktree_branches()
            report = [trial(args.upstream, b, trees.get(b)) for b in (args.branches or trees)]
            statuses = {r["status"] for r in report}
            rc = 2 if "CODE" in statuses else 1 if "OVERLAP" in statuses else 0
            lines = [f"{r['status']:8} {r['branch']}" + (f"  conflicts={','.join(r['conflicts'])}" if r["conflicts"] else "")
                     + (f"  overlap={','.join(r['overlap'])}" if r["overlap"] else "")
                     + ("  UNCOMMITTED work not checked" if r.get("uncommitted") else "") for r in report]
        else:
            report = claim(args.upstream, args.branches or list(worktree_branches()),
                           args.paths)
            rc = 1 if any(set(r["shared"]) - LEDGER for r in report) else 0
            lines = []
            for r in report:
                if r.get("hotspots"):
                    lines.append(f"HOTSPOT  {r['branch']}  {','.join(r['hotspots'])}; sequence the items")
                if r.get("ledger"):
                    lines.append(f"HOTSPOT-LEDGER  {r['branch']}  {','.join(r['ledger'])}; row-level merge applies")
                ordinary = sorted(set(r["shared"]) - HOTSPOTS)
                if ordinary:
                    lines.append(f"SHARED   {r['branch']}  {','.join(ordinary)}")
            lines = lines or ["NONE SHARED"]
    except UsageError as e:
        print(e, file=sys.stderr)
        return 3
    print(json.dumps(report) if args.json else "\n".join(lines))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
