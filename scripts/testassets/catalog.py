#!/usr/bin/env python3
"""Rebuild the manifest after explicit review of generator/source changes."""

import argparse
import hashlib
import json
import platform
import zlib
from inventory import inventory, inventory_digest
from pathlib import Path
import generate

ROOT = Path(__file__).resolve().parents[2]
COMMIT = "df0d5df406ad0dbe2124d6f2a3700fe73dd3ead7"
UPSTREAM = "https://github.com/aaron-rust/hdr-sample-images"
PHOTOS = [
    (
        "5B_JPEG_SDR.jpg",
        10500045,
        "b4d013555225a431fb744d44863db529c9b34ba90843842a4b7aa450857bd6c9",
    ),
    (
        "3B_HEIC_SDR.heic",
        4479456,
        "0e366a983db397b1c1fbcb638e51ecbb6f2163f03f1e652f62ec8e192d96ce6e",
    ),
]

BULK_PARAMETERS = dict(
    count=5000,
    groups=50,
    files_per_group=100,
    nested_cycle=5,
    basename="image-{i%100:03d}",
    format="PNG for even i, TIFF for odd i",
    width="64+(i%3)*16",
    height="48+(i%3)*12",
    seed="i for i in range(count)",
)


def generated_record(spec, tier, root):
    path = root / spec["path"]
    data = path.read_bytes()
    result = dict(
        tier=tier,
        path=spec["path"],
        pixel_size=[spec["width"], spec["height"]],
        byte_size=len(data),
        sha256=hashlib.sha256(data).hexdigest(),
        generator="scripts/testassets/generate.py",
        parameters={k: v for k, v in spec.items() if k != "path"},
        license="CC0-1.0",
    )
    if spec["kind"] == "orientation":
        result["display_size"] = [128, 96]
    if spec["kind"] in (
        "corrupt",
        "truncated",
        "oversize",
        "not-image",
        "unsupported-container",
    ):
        result["expected"] = (
            "decode failure; oversize dimensions must be rejected before pixel allocation"
            if spec["kind"] == "oversize"
            else (
                "partial or failed, never a crash"
                if spec["kind"] == "truncated"
                else (
                    "unsupported non-image ZIP container; ImageIO rejection"
                    if spec["kind"] == "unsupported-container"
                    else "decode failure"
                )
            )
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--generated-root",
        type=Path,
        default=Path.home() / ".mado/testassets/generated",
    )
    parser.add_argument(
        "--photo-root", type=Path, default=Path.home() / ".mado/testassets/photos"
    )
    args = parser.parse_args()
    assets = [
        generated_record(s, 1, ROOT / "TestAssets") for s in generate.small_specs()
    ]
    assets += [
        generated_record(s, 2, args.generated_root) for s in generate.large_specs()
    ]
    for name, size, digest in PHOTOS:
        data = (args.photo_root / name).read_bytes()
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("unverified source " + name)
        source_path = "different_file_formats_in_sdr_and_hdr/" + name
        assets.append(
            dict(
                tier=3,
                path="photos/" + name,
                pixel_size=[8256, 5504],
                byte_size=size,
                sha256=digest,
                url=f"https://media.githubusercontent.com/media/aaron-rust/hdr-sample-images/{COMMIT}/{source_path}",
                source_url=f"{UPSTREAM}/blob/{COMMIT}/{source_path}",
                license="CC0-1.0",
                license_url=f"{UPSTREAM}/blob/{COMMIT}/LICENSE",
                provenance_url=f"{UPSTREAM}/blob/{COMMIT}/README.md",
                has_exif=True,
                content="real photograph; Nikon Z8, upstream developed SDR",
            )
        )
    metadata = dict(
        schema="picsee-testassets/v1",
        generator_version=generate.VERSION,
        generator_environment={
            "python": platform.python_version(),
            "zlib": zlib.ZLIB_RUNTIME_VERSION,
        },
        bulk=dict(
            tier=2,
            path="S2/",
            generator="scripts/testassets/generate.py",
            recipe="bulk_specs",
            parameters=BULK_PARAMETERS,
            count=len(generate.bulk_specs()),
            license="CC0-1.0",
            inventory_format="sorted sha256  relative-path\n; paths relative to generated root",
            inventory_sha256=inventory_digest(
                {"S2/" + p: h for p, h in inventory(args.generated_root / "S2").items()}
            ),
        ),
        generator_sha256=hashlib.sha256(
            (ROOT / "scripts/testassets/generate.py").read_bytes()
        ).hexdigest(),
        roots={
            "1": "TestAssets/",
            "2": "~/.mado/testassets/generated/",
            "3": "~/.mado/testassets/",
        },
        performance_rule="Flat synthetic images must never feed performance numbers. All generated fixtures here are correctness/stress data, not a photo performance baseline.",
        gaps=[
            "S1 recommended 50-file 1–12MP mixed photo corpus is not complete; selected real photos are 45.4MP.",
            "S4 RAW/GIF/PDF sources are deferred; no unsupported licence or format claim.",
            "S5 replacement/symlink/permissions/unmount and S6 multiwindow/pins require runtime setup, not static files.",
        ],
    )
    # S2 is represented by its deterministic recipe and canonical inventory digest.
    header = json.dumps(metadata, indent=2)[:-2]
    output = (
        header
        + ',\n  "assets": [\n'
        + ",\n".join(
            "    " + json.dumps(a, sort_keys=True, separators=(",", ":"))
            for a in assets
        )
        + "\n  ]\n}\n"
    )
    (ROOT / "TestAssets/manifest.json").write_text(output)
    print(
        f"PASS catalogued {len(assets)} individual assets and {len(generate.bulk_specs())} bulk files"
    )


if __name__ == "__main__":
    main()
