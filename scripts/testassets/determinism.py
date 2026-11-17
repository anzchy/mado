#!/usr/bin/env python3
"""Generate twice independently; compare system shasum inventories, not encoder claims."""

import argparse
import hashlib
import json
from inventory import inventory, inventory_text
from check import check_environment
from pathlib import Path
import subprocess
import sys
import tempfile
import generate

ROOT = Path(__file__).resolve().parents[2]


def compare_manifest(records, manifest):
    expected = {a["path"]: a["sha256"] for a in manifest["assets"] if a["tier"] == 1}
    actual = {
        path: sha for path, sha in records.items() if path.startswith("synthetic/")
    }
    if actual != expected:
        changed = sorted(
            path
            for path in expected.keys() | actual.keys()
            if expected.get(path) != actual.get(path)
        )
        raise ValueError(
            "regenerated tier 1 differs from committed manifest: " + ", ".join(changed)
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tier", choices=["small", "all"], default="small")
    parser.add_argument(
        "--output", type=Path, default=Path.home() / ".mado/testassets"
    )
    parser.add_argument(
        "--manifest", type=Path, default=ROOT / "TestAssets/manifest.json"
    )
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    check_environment(manifest)
    base = args.output.expanduser()
    base.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="determinism-", dir=base))
    records = []
    for name in ["a", "b"]:
        folder = run / name
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/testassets/generate.py"),
                "--tier",
                args.tier,
                "--output",
                str(folder),
            ],
            check=True,
        )
        hashes = inventory(folder)
        records.append(hashes)
        compare_manifest(hashes, manifest)
        (run / (name + ".sha256")).write_text(inventory_text(hashes))
    if records[0] != records[1]:
        raise ValueError("different file sets or SHA-256 values")
    for path, sha in sorted(records[0].items()):
        if path.startswith("synthetic/"):
            print(sha + "  " + path)
    digest = hashlib.sha256((run / "a.sha256").read_bytes()).hexdigest()
    print("PASS regenerated tier 1 matches committed manifest hashes")
    print(
        f"PASS determinism: {len(records[0])} files; two independent directories; shasum -a 256 inventories identical"
    )
    print("PASS inventory sha256=" + digest)
    print("Evidence: " + str(run))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        sys.exit("FAIL determinism — " + str(e))
