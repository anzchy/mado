#!/usr/bin/env python3
"""Conformance probe for either Mado-compatible lock executable, using only temporary state.

Usage: python3 scripts/locks/conformance.py --kind heavy|gui --executable <path>
Checks only verified behaviour in docs/agents/shared-locks-contract.md. The GUI
lock has no drain operation; the heavy lock has no explicit release/id command.
"""
import argparse
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid


class Failure(Exception):
    pass


def require(condition, description):
    if not condition:
        raise Failure(description)


def run(executable, args, env, timeout=20):
    try:
        return subprocess.run([str(executable), *args], env=env, capture_output=True,
                              text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f"command did not complete: {error}") from error


def wait_for(path, process, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            raise Failure(f"holder exited before {path.name}: {process.returncode}")
        time.sleep(0.05)
    raise Failure(f"holder did not publish {path.name}")


def keys(path):
    result = {}
    for line in path.read_text().splitlines():
        require("=" in line, f"malformed owner line: {line}")
        key, value = line.split("=", 1)
        require(key not in result and bool(value), f"duplicate or empty owner field: {key}")
        result[key] = value
    return result


def gui_contract(executable, base):
    home = base / "home"
    home.mkdir()
    env = {name: value for name, value in os.environ.items()
           if not name.startswith(("MADO_GUI_LOCK_", "RCLICK_GUI_LOCK_"))}
    env.update(HOME=str(home), MADO_GUI_LOCK_TEST="1", MADO_GUI_LOCK_WAIT_SECONDS="0",
               RCLICK_GUI_LOCK_TEST="1", RCLICK_GUI_LOCK_WAIT_SECONDS="0")
    batch = "conformance-batch"
    status = run(executable, ["status"], env)
    require(status.returncode == 0 and status.stdout.strip() == "FREE", "GUI status must start FREE")
    first = run(executable, ["acquire", batch, "1", "conformance"], env)
    require(first.returncode == 0, f"GUI acquire failed: {first.stderr.strip()}")
    matched = re.search(r"acquisition_id=([0-9a-f-]{36})", first.stdout)
    require(matched is not None, "GUI acquire omitted acquisition_id")
    owner = home / ".cache/desktop-gui.lock/owner"
    require(owner.is_file(), "GUI owner record absent")
    owner_before = owner.read_text()
    fields = keys(owner)
    require(set(fields) == {"project", "session", "batch", "start", "pid",
                            "expected_minutes", "purpose", "acquisition_id"}, "GUI owner field set differs")
    require(fields["batch"] == batch and fields["acquisition_id"] == matched.group(1),
            "GUI owner identity differs")
    require(stat.S_IMODE(owner.stat().st_mode) == 0o600, "GUI owner mode is not 0600")
    require(uuid.UUID(fields["acquisition_id"]).version == 4, "GUI acquisition id is not UUID4")
    busy = run(executable, ["acquire", "other-batch", "1", "conformance"], env)
    require(busy.returncode == 75, f"GUI busy acquire must exit 75, got {busy.returncode}")
    waited = run(executable, ["wait", "other-batch", "1", "conformance", "conformance", "1"], env)
    require(waited.returncode == 75, f"GUI wait timeout must exit 75, got {waited.returncode}")
    for command, args in (("acquire", [batch, "1", "conformance"]),
                          ("wait", [batch, "1", "conformance", "conformance", "1"])):
        result = run(executable, [command, *args], env)
        require(result.returncode == 75 and owner.read_text() == owner_before,
                f"GUI same-batch {command} must exit 75 without changing owner")
    wrong = run(executable, ["release", batch, "--acquisition-id", str(uuid.uuid4())], env)
    require(wrong.returncode == 1 and owner.exists(), "GUI wrong-id release was not refused")
    wrong_batch = run(executable, ["release", "other-batch", "--acquisition-id", matched.group(1)], env)
    require(wrong_batch.returncode == 1 and owner.read_text() == owner_before,
            "GUI wrong-batch release was not refused")
    foreign_project = "mado" if fields["project"] == "rclick" else "rclick"
    foreign_owner = owner_before.replace(f"project={fields['project']}", f"project={foreign_project}", 1)
    require(foreign_owner != owner_before, "GUI owner project was unexpected")
    owner.write_text(foreign_owner)
    foreign = run(executable, ["release", batch, "--acquisition-id", matched.group(1)], env)
    require(foreign.returncode == 1 and owner.read_text() == foreign_owner,
            "GUI foreign-project release was not refused")
    owner.write_text(owner_before)
    released = run(executable, ["release", batch, "--acquisition-id", matched.group(1)], env)
    require(released.returncode == 0 and not owner.exists(), "GUI matching release failed")
    require(run(executable, ["status"], env).stdout.strip() == "FREE", "GUI status not FREE after release")
    return "acquire,busy,wait-timeout,wrong-id,wrong-batch,foreign-project,nesting-refused,owner,release"


def heavy_env(base):
    env = dict(os.environ)
    # A conformance run may itself be inside a test's private heavy-lock. Its
    # candidate uses a different temporary lock and cannot borrow that parent.
    for name in list(env):
        if name.startswith(("MADO_HEAVY_", "PICSEE_HEAVY_")) or name in (
                "MADO_MDPRO_LOCK", "PICSEE_MDPRO_LOCK", "MDPRO_HEAVY_LOCK_HELD"):
            env.pop(name)
    env.update(HOME=str(base / "home"), MADO_HEAVY_LOCK=str(base / "heavy.lock"),
               MADO_MDPRO_LOCK="off", MADO_HEAVY_LOCK_WAIT_SECS="0.3",
               MADO_HEAVY_LOCK_EXEC_SECS="60", MADO_HEAVY_LOCK_DRAIN_SECS="10",
               MADO_HEAVY_ALERT_DIR=str(base / "alerts"))
    Path(env["HOME"]).mkdir()
    return env


def finish_own_holder(process, release):
    release.touch(exist_ok=True)
    try:
        process.communicate(timeout=12)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)


def heavy_contract(executable, base):
    env = heavy_env(base)
    usage = run(executable, [], env)
    require(usage.returncode == 64, f"heavy usage must exit 64, got {usage.returncode}")
    passthrough = run(executable, [sys.executable, "-c", "import sys; sys.exit(7)"], env)
    require(passthrough.returncode == 7, f"heavy command exit 7 was not passed through: {passthrough.returncode}")

    ready, release = base / "holder-ready", base / "holder-release"
    holder_code = "from pathlib import Path; import sys,time; Path(sys.argv[1]).touch(); r=Path(sys.argv[2]);\nwhile not r.exists(): time.sleep(.05)"
    holder = subprocess.Popen([str(executable), sys.executable, "-c", holder_code,
                               str(ready), str(release)], env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    try:
        wait_for(ready, holder)
        deadline = time.monotonic() + 8
        records = []
        while time.monotonic() < deadline and not records:
            records = list(base.glob("heavy.lock.guardian-*.owner"))
            if not records:
                time.sleep(0.05)
        require(len(records) == 1, "heavy guardian owner record absent or ambiguous")
        fields = keys(records[0])
        require({"pid", "cmd", "started", "startedEpoch", "budgetSeconds", "supervisor", "job"} <= set(fields),
                "heavy guardian owner record missing required fields")
        require(fields["job"].startswith("argc="), "heavy owner job leaks command text")
        require(stat.S_IMODE(records[0].stat().st_mode) == 0o600, "heavy owner mode is not 0600")
        contender_marker = base / "contender-ran"
        contender = run(executable, [sys.executable, "-c",
                                     f"from pathlib import Path; Path({str(contender_marker)!r}).touch()"], env)
        require(contender.returncode == 75 and not contender_marker.exists(),
                f"heavy busy/wait timeout must exit 75 before launch, got {contender.returncode}")
    finally:
        finish_own_holder(holder, release)
    require(holder.returncode == 0, f"heavy holder did not release: {holder.returncode}")

    nested = base / "nested.py"
    nested.write_text("import os,subprocess,sys\nfd=int(os.environ['MADO_HEAVY_CONTROL_FD'])\nr=subprocess.run([sys.argv[1],sys.executable,'-c','import sys;sys.exit(7)'],pass_fds=(fd,))\nsys.exit(r.returncode)\n")
    result = run(executable, [sys.executable, str(nested), str(executable)], env, timeout=30)
    require(result.returncode == 7, f"heavy registered nesting did not pass exit 7: {result.returncode} {result.stderr.strip()}")

    child_ready, drain_release = base / "child-ready", base / "drain-release"
    child = base / "surviving-child.py"
    child.write_text("from pathlib import Path\nimport sys,time\nPath(sys.argv[1]).touch()\nr=Path(sys.argv[2])\nwhile not r.exists(): time.sleep(.05)\n")
    parent = base / "short-leader.py"
    parent.write_text("import subprocess,sys\nsubprocess.Popen([sys.executable,*sys.argv[1:]])\n")
    drainer = subprocess.Popen([str(executable), sys.executable, str(parent), str(child),
                               str(child_ready), str(drain_release)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(child_ready, drainer)
        require(drainer.poll() is None, "heavy lock released while descendant survived")
        contender = run(executable, [sys.executable, "-c", "pass"], env)
        require(contender.returncode == 75, "heavy lock did not exclude while descendant survived")
    finally:
        finish_own_holder(drainer, drain_release)
    require(drainer.returncode == 0, f"heavy drain did not finish cleanly: {drainer.returncode}")
    require(run(executable, [sys.executable, "-c", "pass"], env).returncode == 0,
            "heavy lock did not admit after descendant drained")
    cap_env = {**env, "MADO_HEAVY_LOCK_EXEC_SECS": "1"}
    capped = run(executable, [sys.executable, "-c", "import time; time.sleep(2)"], cap_env, timeout=12)
    require(capped.returncode == 124 and "[heavy-lock]" in capped.stderr,
            f"heavy run cap must exit 124 with tool diagnostic, got {capped.returncode}")
    unsafe_marker = base / "unsafe-ran"
    unsafe_env = {**env, "MADO_HEAVY_LOCK_HELD": "1"}
    unsafe = run(executable, [sys.executable, "-c",
                              f"from pathlib import Path; Path({str(unsafe_marker)!r}).touch()"], unsafe_env)
    require(unsafe.returncode == 70 and "[heavy-lock]" in unsafe.stderr and not unsafe_marker.exists(),
            f"heavy copied nesting hint must exit 70 before launch, got {unsafe.returncode}")
    require((base / "heavy.lock").is_file(), "heavy persistent lock file was removed")
    require(not list(base.glob("heavy.lock.guardian-*.owner")), "heavy guardian owner record remained after release")
    return "usage,acquire,busy,wait-timeout,nesting,drain,owner,release,cap-124,unsafe-70,persistent-file"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kind", choices=("heavy", "gui"), required=True)
    parser.add_argument("--executable", type=Path, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve()
    if not executable.is_file():
        print("CONFORMANCE FAIL: executable not found", file=sys.stderr)
        return 1
    try:
        with tempfile.TemporaryDirectory(prefix="shared-lock-conformance-") as directory:
            base = Path(directory)
            checks = gui_contract(executable, base) if args.kind == "gui" else heavy_contract(executable, base)
    except (Failure, OSError, ValueError) as error:
        print(f"CONFORMANCE FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS kind={args.kind} checks={checks}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
