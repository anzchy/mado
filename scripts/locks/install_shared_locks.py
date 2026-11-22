#!/usr/bin/env python3
"""Install lock-tool snapshots from a named Mado commit without taking locks.

Usage: python3 scripts/locks/install_shared_locks.py --commit <40-hex> [--repo <checkout>]
HOME selects the destination. Tests set it to a temporary directory; the delegator
performs the real install after coordinating with lock consumers.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


SOURCES = (
    "scripts/heavy-lock.sh",
    "scripts/tdd/heavy-lock.py",
    ".agents/skills/mado-delegator/scripts/gui-lock.sh",
)


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", "replace").strip() or "git read failed")
    return result.stdout


def digest(sources):
    checksum = hashlib.sha256()
    for name in SOURCES:
        checksum.update(name.encode() + b"\0" + sources[name] + b"\0")
    return checksum.hexdigest()


def launcher(source):
    # resolve() follows ~/.local/bin/<tool> -> .../current/<tool> to its version.
    return f'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
here = pathlib.Path(__file__).resolve().parent
manifest = json.loads((here / "manifest.json").read_text())
if sys.argv[1:] == ["--version"]:
    checksum = hashlib.sha256()
    for name in manifest["sources"]:
        checksum.update(name.encode() + b"\\0" + (here / name).read_bytes() + b"\\0")
    actual = checksum.hexdigest()
    if actual != manifest["sha256"]:
        sys.exit("shared-locks snapshot content hash mismatch")
    print(f'shared-locks {{manifest["version"]}} sha256={{actual}}')
else:
    target = here / {source!r}
    os.execv(str(target), [str(target), *sys.argv[1:]])
'''


def verify_existing(directory, commit, sources, expected):
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest != {"version": commit, "sha256": expected, "sources": list(SOURCES)}:
        raise ValueError(f"existing snapshot differs: {directory}")
    for name, data in sources.items():
        if (directory / name).read_bytes() != data:
            raise ValueError(f"existing snapshot differs: {name}")
    for name, source in (("heavy-lock", SOURCES[0]), ("gui-lock", SOURCES[2])):
        if (directory / name).read_text() != launcher(source):
            raise ValueError(f"existing snapshot differs: {name}")


def publish_link(link, target):
    if link.is_symlink() and os.readlink(link) == target:
        return None
    if link.exists() or link.is_symlink():
        raise ValueError(f"refusing to replace unmanaged path: {link}")
    temporary = link.with_name(f".{link.name}.{os.getpid()}.tmp")
    try:
        os.symlink(target, temporary)
        os.replace(temporary, link)
        return link.lstat().st_ino
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def install(repo, commit, home):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("--commit needs a full lowercase 40-hex commit SHA")
    if git(repo, "cat-file", "-t", commit).strip() != b"commit":
        raise ValueError("--commit must name a commit")
    sources = {name: git(repo, "show", f"{commit}:{name}") for name in SOURCES}
    expected = digest(sources)
    share = home / ".local/share/shared-locks"
    bin_dir = home / ".local/bin"
    share.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    current = share / "current"
    if ((current.exists() and not current.is_symlink()) or
            (current.is_symlink() and not re.fullmatch(r"[0-9a-f]{40}", os.readlink(current)))):
        raise ValueError(f"refusing to replace unmanaged version pointer: {current}")
    public_target = "../share/shared-locks/current/{name}"
    for name in ("heavy-lock", "gui-lock"):
        link = bin_dir / name
        if link.exists() or link.is_symlink():
            if not link.is_symlink() or os.readlink(link) != public_target.format(name=name):
                raise ValueError(f"refusing to replace unmanaged path: {link}")
    version_dir = share / commit
    if version_dir.exists() or version_dir.is_symlink():
        if not version_dir.is_dir() or version_dir.is_symlink():
            raise ValueError(f"invalid snapshot path: {version_dir}")
        verify_existing(version_dir, commit, sources, expected)
    else:
        stage = Path(tempfile.mkdtemp(prefix=f".stage-{commit[:8]}-", dir=share))
        try:
            for name, data in sources.items():
                target = stage / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(0o755 if name.endswith(".sh") else 0o644)
            for name, source in (("heavy-lock", SOURCES[0]), ("gui-lock", SOURCES[2])):
                target = stage / name
                target.write_text(launcher(source))
                target.chmod(0o755)
            (stage / "manifest.json").write_text(json.dumps(
                {"version": commit, "sha256": expected, "sources": list(SOURCES)}, sort_keys=True) + "\n")
            os.rename(stage, version_dir)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    created = []
    try:
        for name in ("heavy-lock", "gui-lock"):
            link = bin_dir / name
            inode = publish_link(link, public_target.format(name=name))
            if inode is not None:
                created.append((link, inode))
        next_link = share / f".current.{os.getpid()}.tmp"
        try:
            os.symlink(commit, next_link)
            os.replace(next_link, current)
        finally:
            if next_link.is_symlink():
                next_link.unlink()
    except Exception:
        for link, inode in reversed(created):
            if link.is_symlink() and link.lstat().st_ino == inode:
                link.unlink()
        raise
    print(f"installed shared-locks {commit} sha256={expected}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        install(args.repo, args.commit, Path.home())
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"install shared-locks: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
