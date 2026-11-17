#!/usr/bin/env python3
"""Exercise device/build.sh with a fake build command and the real kernel lock."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--output", type=Path, default=Path.home() / ".mado/testassets/lock-check"
)
scratch = parser.parse_args().output.expanduser()
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="probe-", dir=scratch) as directory:
    folder = Path(directory)
    shim = folder / "python3"
    shim.write_text("#!" + sys.executable + """\nimport fcntl,os,sys
if sys.argv[1].endswith('heavy-lock.py'):
    os.execv(sys.executable,[sys.executable,*sys.argv[1:]])
assert sys.argv[1].endswith('device.py'), sys.argv
assert os.environ.get('MADO_HEAVY_LOCK_HELD')=='1', 'build did not enter heavy-lock'
with open(os.environ['MADO_HEAVY_LOCK'],'a') as lock:
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: print('PASS device build is inside heavy-lock; independent lock acquisition refused')
    else: sys.exit('FAIL heavy lock is not held')
""")
    shim.chmod(0o755)
    result = subprocess.run(
        [str(root / "scripts/device/build.sh"), str(folder / "run")],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env={
            **os.environ,
            "PATH": str(folder) + os.pathsep + os.environ["PATH"],
            "MADO_HEAVY_LOCK": str(folder / "heavy.lock"),
            "MADO_HEAVY_LOCK_HELD": "",
            "MADO_MDPRO_LOCK": str(folder / "mdpro.lock"),
            "MDPRO_HEAVY_LOCK_HELD": "",
        },
    )
    print(result.stdout, end="")
    sys.exit(result.returncode)
