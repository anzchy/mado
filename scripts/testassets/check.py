#!/usr/bin/env python3
"""Validate manifest coverage, dimensions, sizes, hashes and source/recipe metadata."""

import argparse
import base64
import hashlib
import json
import platform
import zlib
from inventory import inventory, inventory_digest
from pathlib import Path
import re
import struct
import subprocess
import sys
import generate
from catalog import PHOTOS, BULK_PARAMETERS

ROOT = Path(__file__).resolve().parents[2]


def check_environment(manifest):
    for name, key, runtime in [
        ("Python", "python", platform.python_version()),
        ("zlib", "zlib", zlib.ZLIB_RUNTIME_VERSION),
    ]:
        expected = manifest["generator_environment"][key]
        if expected != runtime:
            print(
                f"WARNING {name} version mismatch: manifest={expected}, runtime={runtime}; byte identity requires hash verification"
            )


def check_bulk(manifest, args):
    bulk = manifest["bulk"]
    specs = generate.bulk_specs()
    if (
        bulk["tier"],
        bulk["path"],
        bulk["generator"],
        bulk["recipe"],
        bulk["count"],
        bulk["license"],
    ) != (
        2,
        "S2/",
        "scripts/testassets/generate.py",
        "bulk_specs",
        len(specs),
        "CC0-1.0",
    ):
        raise ValueError("bulk recipe differs")
    if bulk["parameters"] != BULK_PARAMETERS:
        raise ValueError("bulk parameters differ")
    if not re.fullmatch("[0-9a-f]{64}", bulk["inventory_sha256"]):
        raise ValueError("invalid bulk inventory digest")
    if not args.external:
        return 0
    records = {
        "S2/" + p: sha for p, sha in inventory(args.generated_root / "S2").items()
    }
    expected = {s["path"] for s in specs}
    if set(records) != expected:
        raise ValueError(
            "bulk inventory paths differ: " + ", ".join(sorted(set(records) ^ expected))
        )
    if inventory_digest(records) != bulk["inventory_sha256"]:
        raise ValueError("bulk inventory sha256 mismatch")
    for spec in specs:
        if dimensions((args.generated_root / spec["path"]).read_bytes()) != [
            spec["width"],
            spec["height"],
        ]:
            raise ValueError("bulk header dimensions mismatch " + spec["path"])
    return len(records)


def dimensions(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return list(struct.unpack(">II", data[16:24]))
    if data.startswith(b"II*\0"):
        offset = struct.unpack_from("<I", data, 4)[0]
        count = struct.unpack_from("<H", data, offset)[0]
        tags = {}
        for i in range(count):
            tag, kind, n, value = struct.unpack_from("<HHII", data, offset + 2 + i * 12)
            tags[tag] = value & 65535 if kind == 3 else value
        return [tags[256], tags[257]]
    return None


def check_manifest_schema(manifest):
    if manifest["schema"] != "picsee-testassets/v1":
        raise ValueError("unknown schema")
    if manifest["generator_version"] != generate.VERSION:
        raise ValueError("generator version mismatch")
    if (
        manifest["generator_sha256"]
        != hashlib.sha256(
            (ROOT / "scripts/testassets/generate.py").read_bytes()
        ).hexdigest()
    ):
        raise ValueError("generator source hash mismatch")
    specs = {(1, s["path"]): s for s in generate.small_specs()}
    specs.update({(2, s["path"]): s for s in generate.large_specs()})
    return specs


def check_asset_schema(asset, specs, seen, counts):
    tier, path = asset["tier"], asset["path"]
    relative = Path(path)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError("unsafe asset path " + path)
    key = (tier, path)
    if key in seen:
        raise ValueError("duplicate manifest path " + path)
    seen.add(key)
    counts[tier] += 1
    if (
        not re.fullmatch("[0-9a-f]{64}", asset["sha256"])
        or asset["byte_size"] <= 0
    ):
        raise ValueError("invalid hash/size " + path)
    if asset["license"] != "CC0-1.0":
        raise ValueError("unreviewed licence " + path)
    if tier in (1, 2):
        spec = specs[key]
        if asset["generator"] != "scripts/testassets/generate.py" or asset[
            "parameters"
        ] != {k: v for k, v in spec.items() if k != "path"}:
            raise ValueError("recipe differs " + path)
        if asset["pixel_size"] != [spec["width"], spec["height"]]:
            raise ValueError("recipe dimensions differ " + path)
    else:
        for field in ("url", "license_url", "source_url", "provenance_url"):
            if not asset[field].startswith("https://"):
                raise ValueError("missing HTTPS source " + path)
        if not asset["has_exif"]:
            raise ValueError("photo requires EXIF " + path)
    return tier, path, relative


def check_asset_bytes(asset, args, tier, path, relative):
    target = (
        args.small_root
        if tier == 1
        else args.generated_root if tier == 2 else args.external_root
    ) / relative
    data = target.read_bytes()
    if len(data) != asset["byte_size"]:
        raise ValueError("byte size mismatch " + path)
    if hashlib.sha256(data).hexdigest() != asset["sha256"]:
        raise ValueError("sha256 mismatch " + path)
    if tier in (1, 2):
        observed_dimensions = dimensions(data)
        expected_dimensions = asset["pixel_size"]
        if expected_dimensions == [None, None]:
            if observed_dimensions is not None:
                raise ValueError("non-image has image dimensions " + path)
        elif observed_dimensions != expected_dimensions:
            raise ValueError("header dimensions mismatch " + path)
    if tier == 3 and data.startswith(b"version https://git-lfs"):
        raise ValueError("download is a pointer, not image bytes")
    return target, data


def check_native(asset, target, tier, path, oriented_hashes):
    kind = asset["parameters"]["kind"] if tier == 1 else None
    if tier == 1 and asset["parameters"]["kind"] == "truncated":
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                str(ROOT / "scripts/testassets/inspect.js"),
                str(target),
                "truncated",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    if tier == 1 and kind in ("not-image", "unsupported-container", "corrupt"):
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                str(ROOT / "scripts/testassets/inspect.js"),
                str(target),
                "rejected",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return
    if not (
        tier == 3
        or (
            tier == 1
            and asset["parameters"]["kind"] not in ("corrupt", "truncated", "oversize")
        )
    ):
        return
    mode = (
        ["oriented-pixels"]
        if tier == 1 and asset["parameters"]["kind"] == "orientation"
        else []
    )
    observed = json.loads(
        subprocess.check_output(
            [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                str(ROOT / "scripts/testassets/inspect.js"),
                str(target),
                *mode,
            ],
            text=True,
        )
    )
    if [observed["width"], observed["height"]] != asset["pixel_size"]:
        raise ValueError("ImageIO dimensions mismatch " + path)
    if tier == 3 and not observed["hasExif"]:
        raise ValueError("ImageIO found no EXIF " + path)
    if (
        tier == 1
        and asset["parameters"]["kind"] == "orientation"
        and (
            observed["orientation"] != asset["parameters"]["orientation"]
            or not observed["hasExif"]
        )
    ):
        raise ValueError("ImageIO EXIF orientation mismatch " + path)
    if mode:
        if [observed["displayWidth"], observed["displayHeight"]] != asset[
            "display_size"
        ]:
            raise ValueError("oriented display size mismatch " + path)
        oriented_hashes.append(
            hashlib.sha256(base64.b64decode(observed["pixels"])).hexdigest()
        )
    if (
        tier == 1
        and asset["parameters"]["kind"] == "alpha"
        and not observed["hasAlpha"]
    ):
        raise ValueError("ImageIO found no alpha " + path)
    if tier == 1 and kind == "gradient-16bit" and observed["depth"] != 16:
        raise ValueError("ImageIO bit depth mismatch " + path)


def check_manifest_coverage(manifest, args, specs, seen, counts):
    if not set(specs).issubset(seen):
        raise ValueError("missing generated manifest entries")
    if counts != {
        1: len(generate.small_specs()),
        2: len(generate.large_specs()),
        3: len(PHOTOS),
    }:
        raise ValueError("tier counts differ")
    disk = {
        str(p.relative_to(args.small_root))
        for p in args.small_root.rglob("*")
        if p.is_file()
        and p.name != ".DS_Store"
        and str(p.relative_to(args.small_root)) not in ("README.md", "manifest.json")
    }
    if disk != {p for tier, p in seen if tier == 1}:
        raise ValueError(
            "unlisted or missing tier-1 files: "
            + ", ".join(sorted(disk ^ {p for tier, p in seen if tier == 1}))
        )


def check_native_summary(oriented_hashes, checked):
    if len(oriented_hashes) != 8 or len(set(oriented_hashes)) != 1:
        raise ValueError("orientations do not render identical upright pixels")
    print(
        "PASS independent ImageIO: dimensions, EXIF orientations 1–8 render identical upright 128x96 pixels, alpha, 16-bit depth, P1 non-images rejected; truncated: partial or failed, never a crash; "
        + ("photo EXIF verified" if checked[3] else "photo EXIF skipped (use --external)")
    )


def verify(args):
    manifest = json.loads(args.manifest.read_text())
    check_environment(manifest)
    specs = check_manifest_schema(manifest)
    bulk_checked = check_bulk(manifest, args)
    oriented_hashes = []
    seen = set()
    counts = {1: 0, 2: 0, 3: 0}
    checked = {1: 0, 2: 0, 3: 0}
    total_small = 0
    for asset in manifest["assets"]:
        tier, path, relative = check_asset_schema(asset, specs, seen, counts)
        if tier != 1 and not args.external:
            continue
        target, data = check_asset_bytes(asset, args, tier, path, relative)
        if args.native:
            check_native(asset, target, tier, path, oriented_hashes)
        checked[tier] += 1
        if tier == 1:
            total_small += len(data)
    check_manifest_coverage(manifest, args, specs, seen, counts)
    print(
        f"PASS manifest schema/recipes/licences: {sum(counts.values())} entries + {manifest['bulk']['count']} bulk files; verified tier1={checked[1]} tier2={checked[2]+bulk_checked} tier3={checked[3]}; tier1 bytes={total_small}"
    )
    if args.native:
        check_native_summary(oriented_hashes, checked)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", type=Path, help="optional directory for check output")
    p.add_argument("--manifest", type=Path, default=ROOT / "TestAssets/manifest.json")
    p.add_argument("--small-root", type=Path, default=ROOT / "TestAssets")
    p.add_argument(
        "--generated-root",
        type=Path,
        default=Path.home() / ".mado/testassets/generated",
    )
    p.add_argument(
        "--external-root", type=Path, default=Path.home() / ".mado/testassets"
    )
    p.add_argument("--external", action="store_true")
    p.add_argument("--native", action="store_true")
    try:
        args = p.parse_args()
        if args.output:
            import contextlib
            import io

            report = io.StringIO()
            try:
                with contextlib.redirect_stdout(report):
                    verify(args)
            finally:
                args.output.expanduser().mkdir(parents=True, exist_ok=True)
                (args.output.expanduser() / "check.txt").write_text(report.getvalue())
                print(report.getvalue(), end="")
        else:
            verify(args)
        return 0
    except Exception as e:
        print("FAIL manifest — " + str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
