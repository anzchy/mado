#!/usr/bin/env python3
"""Stage local UI-test fixtures outside macOS protected user folders."""

import argparse
import json
from pathlib import Path
import sys


FILENAMES = ("landscape-3x2.png", "portrait-2x3.png", "orientation-1.tiff")
MARKER = ".picsee-ui-fixtures.json"


def _no_symlinks(path: Path) -> None:
    for candidate in (*reversed(path.parents), path):
        if candidate.is_symlink():
            raise ValueError(f"refusing symlink in runtime path: {candidate}")


def _run_directory(run_root: Path, runtime_root: Path) -> Path:
    run = Path(run_root).expanduser().absolute()
    root = Path(runtime_root).expanduser().absolute()
    if ".." in run.parts or ".." in root.parts:
        raise ValueError("runtime paths must not contain parent traversal")
    _no_symlinks(root)
    _no_symlinks(run)
    run, root = run.resolve(), root.resolve()
    if run == root or not run.is_relative_to(root):
        raise ValueError(f"run directory must be strictly beneath {root}")
    for folder in ("Documents", "Desktop", "Downloads"):
        protected = (Path.home() / folder).resolve()
        if run == protected or run.is_relative_to(protected):
            raise ValueError(f"runtime output must not be in protected folder: {protected}")
    if run.exists() and not run.is_dir():
        raise ValueError(f"run path is not a directory: {run}")
    return run


def _ownership(run: Path) -> dict:
    return {"version": 1, "run_root": str(run), "filenames": list(FILENAMES)}


def stage(run_root: Path, source_dir: Path, runtime_root: Path) -> Path:
    """Copy the three pinned images; explicit runtime_root supports isolated real-I/O tests."""
    run = _run_directory(run_root, runtime_root)
    fixtures, marker = run / "fixtures", run / MARKER
    if fixtures.exists() or fixtures.is_symlink() or marker.exists() or marker.is_symlink():
        raise ValueError(f"refusing existing fixture output or ownership marker: {run}")
    source = Path(source_dir)
    if source.is_symlink() or not source.is_dir():
        raise ValueError(f"fixture source must be a non-symlink directory: {source}")
    # Read all inputs before creating output, so a missing/unsafe source cannot leave a partial run.
    images = {}
    for name in FILENAMES:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or symlinked pinned image: {path}")
        images[name] = path.read_bytes()
    run.mkdir(parents=True, exist_ok=True)
    fixtures.mkdir()
    created = []
    try:
        for name, data in images.items():
            path = fixtures / name
            with path.open("xb") as stream:
                created.append(path)
                stream.write(data)
        with marker.open("x", encoding="utf-8") as stream:
            json.dump(_ownership(run), stream)
    except Exception:
        # Roll back only the exact files created here, never the run directory or its logs.
        for path in created:
            path.unlink()
        fixtures.rmdir()
        raise
    return fixtures


def cleanup(run_root: Path, runtime_root: Path) -> None:
    """Remove only an owned three-image fixture, preserving the run directory and evidence."""
    run = _run_directory(run_root, runtime_root)
    fixtures, marker = run / "fixtures", run / MARKER
    if fixtures.is_symlink() or marker.is_symlink():
        raise ValueError(f"refusing symlinked fixture or marker: {run}")
    if not fixtures.exists() and not marker.exists():
        return
    if not marker.is_file():
        raise ValueError(f"refusing fixture without its ownership marker: {run}")
    try:
        ownership = json.loads(marker.read_text(encoding="utf-8"))
    except (ValueError, OSError) as error:
        raise ValueError(f"unreadable fixture ownership marker: {marker}") from error
    if ownership != _ownership(run):
        raise ValueError(f"fixture ownership marker does not match this run: {run}")
    if fixtures.exists():
        if not fixtures.is_dir() or {path.name for path in fixtures.iterdir()} != set(FILENAMES):
            raise ValueError(f"refusing unexpected fixture contents: {fixtures}")
        paths = [fixtures / name for name in FILENAMES]
        if any(path.is_symlink() or not path.is_file() for path in paths):
            raise ValueError(f"refusing nonregular or symlinked fixture files: {fixtures}")
        # Validate everything before deleting anything.
        for path in paths:
            path.unlink()
        fixtures.rmdir()
    marker.unlink()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    staging = commands.add_parser("stage")
    staging.add_argument("run_root", type=Path)
    staging.add_argument("source_dir", type=Path)
    cleaning = commands.add_parser("cleanup")
    cleaning.add_argument("run_root", type=Path)
    args = parser.parse_args(argv)
    # Deliberately no environment override: CLI output is confined to this home-owned root.
    runtime_root = Path.home() / ".picsee" / "ui-tests"
    try:
        if args.command == "stage":
            fixtures = stage(args.run_root, args.source_dir, runtime_root)
            print(json.dumps({"fixtures": str(fixtures)}))
        else:
            cleanup(args.run_root, runtime_root)
            print(json.dumps({"cleaned": str(args.run_root.absolute())}))
    except (ValueError, OSError) as error:
        print(f"ui-test-runtime: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
