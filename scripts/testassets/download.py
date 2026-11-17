#!/usr/bin/env python3
"""Fetch tier-3 bytes over HTTPS and publish only after size/SHA-256 validation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


class HTTPSOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise ValueError("HTTPS redirect required: " + newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_https(request, timeout):
    return urllib.request.build_opener(HTTPSOnlyRedirect()).open(
        request, timeout=timeout
    )


def load_manifest():
    return json.loads((ROOT / "TestAssets/manifest.json").read_text())


def download(root):
    root = root.expanduser().resolve()
    if root == ROOT or ROOT in root.parents:
        raise ValueError("photos must stay outside the repository")
    manifest = load_manifest()
    for asset in manifest["assets"]:
        if asset["tier"] != 3:
            continue
        relative = Path(asset["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe photo path")
        destination = (root / relative).resolve()
        if root not in destination.parents:
            raise ValueError("photo path escapes external root")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            data = destination.read_bytes()
            if (
                len(data) != asset["byte_size"]
                or hashlib.sha256(data).hexdigest() != asset["sha256"]
            ):
                raise ValueError("existing file differs: " + asset["path"])
            print("PASS cached " + asset["path"] + " sha256=" + asset["sha256"])
            continue
        if not asset["url"].startswith("https://"):
            raise ValueError("HTTPS source required")
        temporary = None
        try:
            digest = hashlib.sha256()
            size = 0
            request = urllib.request.Request(
                asset["url"], headers={"User-Agent": "picsee-testassets/1"}
            )
            with open_https(
                request, timeout=60
            ) as response, tempfile.NamedTemporaryFile(
                dir=destination.parent, delete=False
            ) as output:
                temporary = Path(output.name)
                if not response.geturl().startswith("https://"):
                    raise ValueError("insecure redirect")
                while True:
                    data = response.read(1024 * 1024)
                    if not data:
                        break
                    size += len(data)
                    if size > asset["byte_size"]:
                        raise ValueError("download exceeds expected size")
                    digest.update(data)
                    output.write(data)
            if size != asset["byte_size"] or digest.hexdigest() != asset["sha256"]:
                raise ValueError("download size/sha256 mismatch")
            os.replace(temporary, destination)
            print("PASS downloaded " + asset["path"] + " sha256=" + asset["sha256"])
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path.home() / ".mado/testassets"
    )
    try:
        download(parser.parse_args().output)
    except Exception as e:
        parser.exit(1, "FAIL download — " + str(e) + "\n")
