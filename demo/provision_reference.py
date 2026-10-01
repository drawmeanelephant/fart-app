#!/usr/bin/env python3
"""Pinned reference provisioning and current-run receipts for the demo (#58).

No compilation/demo retries. Network resolution/fetch gets three attempts,
each capped at 45 seconds, with 1/3 second backoff. Never delete a restored
cache or an external checkout: builds are published from task-owned staging.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

REFERENCE_URL = "https://github.com/drawmeanelephant/ninjam"
NETWORK_TIMEOUT = 45
NETWORK_BACKOFF = (1, 3)
BUILD_TIMEOUT = 300
PROVISION_TIMEOUT = 600
SCHEMA = 1
SHA = re.compile(r"[0-9a-f]{40}")
TRANSIENT = re.compile(
    r"could not resolve|temporary failure|failed to connect|"
    r"connection (?:reset|timed out|refused)|timed out|network is unreachable|"
    r"remote end hung up|HTTP[^\n]*(?:429|500|502|503|504)",
    re.IGNORECASE,
)


class Failure(Exception):
    pass


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def atomic_json(path, data):
    path = Path(path)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


class Receipt:
    def __init__(self, evidence):
        self.evidence = Path(evidence).resolve()
        self.path = self.evidence / "receipt.json"
        try:
            self.data = json.loads(self.path.read_text())
        except (OSError, ValueError) as e:
            raise Failure(f"initialize a fresh evidence directory first: {e}") from e

    def update(self, **fields):
        now = time.time()
        self.data.setdefault("events", []).append(dict(fields, at=now))
        self.data.update(fields, updated_at=now)
        atomic_json(self.path, self.data)


class Runner:
    def __init__(self, receipt):
        self.receipt = receipt
        self.log = receipt.evidence / "provision.log"
        self.deadline = time.monotonic() + PROVISION_TIMEOUT

    def run(self, args, timeout=BUILD_TIMEOUT):
        # A process group makes the deadline cover subprocesses (git helpers,
        # CMake's child compiler, etc.), not merely their parent shell/process.
        timeout = min(timeout, self.deadline - time.monotonic())
        if timeout <= 0:
            raise Failure("reference provisioning exceeded its 10-minute budget")
        with tempfile.TemporaryFile() as output:
            proc = subprocess.Popen(
                [str(a) for a in args], stdout=output, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            timed_out = False
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            output.seek(0)
            text = output.read().decode("utf-8", errors="replace")
        with self.log.open("a") as log:
            log.write(f"$ {' '.join(str(a) for a in args)}\n{text}\n")
        return proc.returncode, text, timed_out

    def once(self, args):
        rc, text, expired = self.run(args)
        if rc:
            raise Failure(f"command {'timed out' if expired else 'failed'}: {args[0]} (exit {rc}); see provision.log")
        return text.strip()

    def network(self, args, operation):
        for attempt in range(1, 4):
            self.receipt.update(network_operation=operation, network_attempt=attempt)
            rc, text, expired = self.run(args, timeout=NETWORK_TIMEOUT)
            if rc == 0:
                return text.strip()
            if attempt == 3 or not (expired or TRANSIENT.search(text)):
                raise Failure(f"{operation} failed on attempt {attempt} (exit {rc}); see provision.log")
            time.sleep(NETWORK_BACKOFF[attempt - 1])
        raise AssertionError("unreachable")


def validate_sha(value):
    if not SHA.fullmatch(value):
        raise Failure(f"expected a nonempty 40-character reference SHA, got {value!r}")
    return value


def resolve(runner, requested):
    if requested:
        return validate_sha(requested)
    text = runner.network(
        ["git", "ls-remote", REFERENCE_URL, "refs/heads/main"], "resolve",
    )
    rows = [line.split() for line in text.splitlines()]
    if len(rows) != 1 or len(rows[0]) != 2 or rows[0][1] != "refs/heads/main":
        raise Failure("reference resolution did not return exactly refs/heads/main")
    return validate_sha(rows[0][0])


def source_identity(runner, source, expected):
    actual = runner.once(["git", "-C", source, "rev-parse", "HEAD"])
    runner.receipt.update(actual_sha=actual)
    if actual != expected:
        raise Failure(f"reference identity mismatch: expected {expected}, actual {actual}")
    if runner.once(["git", "-C", source, "status", "--porcelain", "--untracked-files=all"]):
        raise Failure("reference checkout is modified; refusing cached tools")


def inputs(runner, refpeer):
    system = platform.system()
    if system not in ("Darwin", "Linux"):
        raise Failure("reference demo supports macOS/Linux; Windows is deferred")
    result = {
        "schema": SCHEMA,
        "refpeer_sha256": digest(refpeer),
        "provisioner_sha256": digest(__file__),
        "system": system,
        "machine": platform.machine(),
        "cmake": runner.once(["cmake", "--version"]).splitlines()[0],
        "c_compiler": runner.once(["clang", "--version"]),
        "compiler": runner.once(["clang++", "--version"]),
        # Fingerprint build-affecting environment without putting its raw
        # values into the receipt/manifest. Explicit CMake compiler options
        # below make these versions the compilers actually used on both OSes.
        "build_environment_sha256": hashlib.sha256(json.dumps({
            key: os.environ.get(key, "") for key in (
                "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "SDKROOT",
                "MACOSX_DEPLOYMENT_TARGET", "CMAKE_GENERATOR", "CMAKE_TOOLCHAIN_FILE",
            )
        }, sort_keys=True).encode()).hexdigest(),
        "build_type": "Release",
        "client": False,
        "tests": False,
        "dependencies": "upstream-static-ogg-vorbis",
    }
    if system == "Darwin":
        result["sdk"] = runner.once(["xcrun", "--show-sdk-version"])
    return result


def cache_paths(root):
    return {
        "source": root / "ninjam-src",
        "server": root / "srv-build/bin/ninjamsrv",
        "core": root / "core-build/libninjam_core.a",
        "net": root / "core-build/libninjam_net.a",
        "vorbisenc": root / "core-build/_deps/vorbis-build/lib/libvorbisenc.a",
        "vorbis": root / "core-build/_deps/vorbis-build/lib/libvorbis.a",
        "ogg": root / "core-build/_deps/ogg-build/libogg.a",
        "refpeer": root / "refpeer",
    }


def verify_cache(runner, root, expected, identity):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest["expected_sha"] != expected or manifest["inputs"] != identity:
        raise Failure("cache manifest inputs/reference do not match this run")
    paths = cache_paths(root)
    source_identity(runner, paths["source"], expected)
    for name, path in paths.items():
        if name != "source" and digest(path) != manifest["artifacts"][name]:
            raise Failure(f"cached {name} checksum mismatch")
    if not os.access(paths["server"], os.X_OK) or not os.access(paths["refpeer"], os.X_OK):
        raise Failure("cached tools are not executable")
    return paths


def build_reference(runner, stage, expected, refpeer, external):
    source = stage / "ninjam-src"
    if external:
        # Never reset/delete a user-supplied checkout. Validate it, then copy
        # only committed files via a local clone into task-owned staging.
        source_identity(runner, external, expected)
        runner.once(["git", "clone", "--no-hardlinks", external, source])
    else:
        runner.once(["git", "init", source])
        runner.network(
            ["git", "-C", source, "fetch", "--depth", "1", REFERENCE_URL, expected],
            "fetch",
        )
    runner.once(["git", "-C", source, "checkout", "--detach", expected])
    source_identity(runner, source, expected)

    runner.receipt.update(phase="compilation", status="running")
    for build in ("srv-build", "core-build"):
        # Force upstream's pinned in-tree Ogg/Vorbis path, but keep the
        # FindPkgConfig module enabled: Vorbis calls its pkg_check_modules
        # macro even when discovery fails. Disabling the module breaks cold
        # builds with "Unknown CMake command".
        runner.once([
            "cmake", "-S", source, "-B", stage / build,
            "-DCMAKE_BUILD_TYPE=Release", "-DNINJAM_BUILD_CLIENT=OFF",
            "-DNINJAM_BUILD_TESTS=OFF",
            f"-DCMAKE_C_COMPILER:FILEPATH={shutil.which('clang')}",
            f"-DCMAKE_CXX_COMPILER:FILEPATH={shutil.which('clang++')}",
            f"-DPKG_CONFIG_EXECUTABLE:FILEPATH={shutil.which('false')}",
        ])
        runner.once(["cmake", "--build", stage / build, "-j", "4"])
    core = stage / "core-build"
    args = [
        "clang++", "-std=c++17", "-O2", refpeer, f"-I{source}",
        f"-I{core}/_deps/ogg-src/include", f"-I{core}/_deps/vorbis-src/include",
        f"-I{core}/_deps/vorbis-src/lib", core / "libninjam_core.a",
        core / "libninjam_net.a",
        core / "_deps/vorbis-build/lib/libvorbisenc.a",
        core / "_deps/vorbis-build/lib/libvorbis.a",
        core / "_deps/ogg-build/libogg.a",
    ]
    if platform.system() == "Darwin":
        args += ["-framework", "CoreFoundation", "-framework", "CoreServices"]
    else:
        args += ["-pthread", "-ldl", "-lm"]
    runner.once(args + ["-o", stage / "refpeer"])
    source_identity(runner, source, expected)


def provision(runner, runtime, expected, refpeer, external, cache_directory=None, restore_failed=False):
    identity = inputs(runner, refpeer)
    key_hash = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    root = runtime / "references" / f"{expected}-{key_hash}"
    runner.receipt.update(phase="provisioning", status="running", expected_sha=expected)
    if restore_failed:
        # A partial extraction is preserved but never read/executed. Builds
        # publish elsewhere; only the snapshot below is eligible for saving.
        runner.receipt.update(cache_validation="restore-failed-cold-recovery")
    elif cache_directory and cache_directory.exists():
        root = cache_directory
    if root.exists():
        try:
            paths = verify_cache(runner, root, expected, identity)
        except (Failure, OSError, KeyError, ValueError, TypeError) as e:
            # An invalid cache is never executed or silently reused. Keeping it
            # untouched also prevents deleting restored or external user work.
            runner.receipt.update(cache_validation="rejected")
            raise Failure(f"cached reference rejected before execution: {e}") from e
        runner.receipt.update(cache_validation="verified", compilation="skipped")
        return root, paths

    root.parent.mkdir(parents=True, exist_ok=True)
    # Only this fresh staging directory is eligible for cleanup on failure.
    with tempfile.TemporaryDirectory(prefix=".reference-stage-", dir=root.parent) as tmp:
        stage = Path(tmp)
        build_reference(runner, stage, expected, refpeer, external)
        paths = cache_paths(stage)
        artifacts = {name: digest(path) for name, path in paths.items() if name != "source"}
        atomic_json(stage / "manifest.json", {
            "expected_sha": expected, "inputs": identity, "artifacts": artifacts,
        })
        verify_cache(runner, stage, expected, identity)
        stage.rename(root)
    runner.receipt.update(cache_validation="built-and-verified", compilation="passed")
    return root, cache_paths(root)


def publish_cache(runner, root, destination, expected, refpeer):
    if destination.exists():
        # Existing/partial restore state is not task-owned staging. Preserve
        # it and skip saving, rather than overwriting it with a fresh build.
        runner.receipt.update(cache_save="skipped-existing-restore")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".cache-stage-", dir=destination.parent) as tmp:
        copy = Path(tmp) / "reference"
        shutil.copytree(root, copy, symlinks=True)
        verify_cache(runner, copy, expected, inputs(runner, refpeer))
        copy.rename(destination)
    runner.receipt.update(cache_save="verified-snapshot")
    append_output("cache-ready", "true")


def append_output(name, value):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"{name}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("init", "resolve", "provision", "phase"))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--sha", default=os.environ.get("NINJAM_REF_SHA", ""))
    parser.add_argument("--refpeer", type=Path, default=Path(__file__).with_name("refpeer.cpp"))
    parser.add_argument("--source", type=Path)
    parser.add_argument("--cache-directory", type=Path)
    parser.add_argument("--cache-outcome")
    parser.add_argument("--cache-hit")
    parser.add_argument("--phase", default="")
    parser.add_argument("--status", default="")
    args = parser.parse_args(argv)
    if args.command == "init":
        args.evidence.mkdir(parents=True, exist_ok=False)
        atomic_json(args.evidence / "receipt.json", {
            "schema": SCHEMA, "phase": "provisioning", "status": "not-started",
            "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
            "demo": "not-run", "expected_sha": None, "actual_sha": None,
            "cache_restore": "local", "cache_hit": "unknown",
        })
        return 0

    receipt = Receipt(args.evidence)
    if args.command == "phase":
        if not args.phase or not args.status:
            parser.error("phase requires --phase and --status")
        if receipt.data["status"] == "failed":
            if args.status == "failed":
                return 0  # preserve the helper's more specific phase/error
            print("failed run cannot resume; initialize fresh evidence", file=sys.stderr)
            return 1
        receipt.update(phase=args.phase, status=args.status)
        if args.phase == "demo":
            receipt.update(demo=args.status)
        return 0

    if receipt.data["status"] == "failed" or receipt.data["demo"] != "not-run":
        print("run already failed/completed; initialize fresh evidence", file=sys.stderr)
        return 1

    runner = Runner(receipt)
    fields = {"phase": "provisioning", "status": "running"}
    if args.cache_outcome is not None:
        fields["cache_restore"] = args.cache_outcome
    if args.cache_hit is not None:
        fields["cache_hit"] = args.cache_hit
    receipt.update(**fields)
    try:
        expected = resolve(runner, args.sha)
        receipt.update(expected_sha=expected)
        if args.command == "resolve":
            identity = inputs(runner, args.refpeer.resolve())
            key_hash = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
            append_output("sha", expected)
            append_output("key", f"ninjam-ref-v2-{expected}-{key_hash}")
            print(expected)
            return 0
        if args.runtime is None:
            raise Failure("provision requires --runtime")
        runtime = args.runtime.resolve()
        cache_directory = args.cache_directory.resolve() if args.cache_directory else None
        # CI provisions once before the demo entrypoint. Re-verify the exact
        # recorded root there, including a cold recovery from a partial restore,
        # instead of re-resolving main or rediscovering the rejected cache.
        result_path = receipt.evidence / "reference.json"
        if result_path.exists():
            previous = json.loads(result_path.read_text())
            if previous["expected_sha"] != expected:
                raise Failure("this run's resolved reference SHA changed")
            root = Path(previous["root"])
            paths = verify_cache(runner, root, expected, inputs(runner, args.refpeer.resolve()))
            receipt.update(cache_validation="verified", compilation="skipped")
        else:
            root, paths = provision(
                runner, runtime, expected, args.refpeer.resolve(),
                args.source.resolve() if args.source else None,
                cache_directory=cache_directory,
                restore_failed=args.cache_outcome == "failure",
            )
        if cache_directory and root != cache_directory:
            publish_cache(runner, root, cache_directory, expected, args.refpeer.resolve())
        result = {name: str(path) for name, path in paths.items()}
        result.update(root=str(root), expected_sha=expected)
        atomic_json(receipt.evidence / "reference.json", result)
        receipt.update(phase="provisioning", status="passed", error=None)
        append_output("root", root)
        print(f"reference {expected}: {receipt.data['cache_validation']}")
        return 0
    except (Failure, OSError, ValueError, KeyError, TypeError, IndexError) as e:
        phase = receipt.data["phase"]
        receipt.update(status="failed", error=str(e), demo="not-run")
        print(f"{phase.upper()} FAILED: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
