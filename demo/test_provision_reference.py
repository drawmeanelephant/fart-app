"""Offline failure injection for #58; real cold/warm demos are separate."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("provision_reference.py")
REPO = SCRIPT.parent.parent
spec = importlib.util.spec_from_file_location("provision_reference", SCRIPT)
provisioner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provisioner)
REAL_GIT = shutil.which("git")

STUB = r'''
import json, os, pathlib, socket, subprocess, sys, time
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_CALLS"], "a") as f:
    f.write(json.dumps([tool] + args) + "\n")
if tool == "git":
    if args[-2:] == ["rev-parse", "HEAD"] and os.environ.get("TEST_ACTUAL_SHA"):
        print(os.environ["TEST_ACTUAL_SHA"])
        sys.exit(0)
    network = "ls-remote" in args or "fetch" in args
    if network:
        counter = pathlib.Path(os.environ["TEST_COUNTER"])
        n = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(n))
        mode = os.environ.get("TEST_NETWORK", "")
        if mode == "timeout":
            time.sleep(10)
        if mode == "persistent" or (mode == "once" and n == 1):
            print("fatal: Could not resolve host: github.com")
            sys.exit(128)
        if mode == "permanent":
            print("fatal: repository not found")
            sys.exit(128)
        if "ls-remote" in args:
            if mode == "empty":
                sys.exit(0)
            print(os.environ["TEST_SHA"] + "\trefs/heads/main")
            sys.exit(0)
        args = [
            os.environ["TEST_REFERENCE"] if a == "https://github.com/drawmeanelephant/ninjam" else a
            for a in args
        ]
    sys.exit(subprocess.call([os.environ["TEST_REAL_GIT"]] + args))
if tool == "cmake":
    if args == ["--version"]:
        print("cmake version fixture")
        sys.exit(0)
    if os.environ.get("TEST_COMPILE_FAIL"):
        print("injected compile failure")
        sys.exit(57)
    if args[0] == "-S":
        pathlib.Path(args[args.index("-B") + 1]).mkdir(parents=True, exist_ok=True)
    else:
        build = pathlib.Path(args[1])
        for name in ("libninjam_core.a", "libninjam_net.a",
                     "_deps/vorbis-build/lib/libvorbisenc.a",
                     "_deps/vorbis-build/lib/libvorbis.a",
                     "_deps/ogg-build/libogg.a"):
            path = build / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture library\n")
        server = build / "bin/ninjamsrv"
        server.parent.mkdir(parents=True, exist_ok=True)
        server.write_text("#!/bin/sh\nexit 0\n")
        if os.environ.get("TEST_RUN_DEMO"):
            server.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(60)\n")
        server.chmod(0o755)
elif tool in ("clang", "clang++"):
    if args == ["--version"]:
        print("clang fixture")
    else:
        path = pathlib.Path(args[args.index("-o") + 1])
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
elif tool == "xcrun":
    print("fixture SDK")
elif tool == "lsof":
    if os.environ.get("TEST_RUN_DEMO"):
        path = pathlib.Path(os.environ["TEST_CALLS"] + ".lsof")
        n = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(n))
        sys.exit(1 if n == 1 else 0)
    sys.exit(1)
elif tool == "zig":
    if os.environ.get("TEST_ZIG_FAIL"):
        sys.exit(42)
'''


class ProvisioningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Clone the existing repository offline; no new commits or overridden
        # author identity are needed to manufacture a fetchable reference.
        cls.reference_tmp = tempfile.TemporaryDirectory()
        cls.reference = Path(cls.reference_tmp.name) / "reference.git"
        subprocess.run(
            [REAL_GIT, "clone", "--bare", "--no-hardlinks", "--quiet", str(REPO), str(cls.reference)],
            check=True,
        )
        cls.sha = subprocess.check_output(
            [REAL_GIT, "-C", str(REPO), "rev-parse", "HEAD"], text=True,
        ).strip()
        subprocess.run(
            [REAL_GIT, "-C", str(cls.reference), "update-ref", "refs/heads/main", cls.sha],
            check=True,
        )
        subprocess.run(
            [REAL_GIT, "-C", str(cls.reference), "symbolic-ref", "HEAD", "refs/heads/main"],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.reference_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("git", "cmake", "clang", "clang++", "xcrun", "lsof", "zig"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + STUB)
            path.chmod(0o755)
        self.calls = self.root / "calls.jsonl"
        self.calls.touch()
        self.environment = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "TEST_CALLS": str(self.calls),
            "TEST_COUNTER": str(self.root / "counter"),
            "TEST_REAL_GIT": REAL_GIT,
            "TEST_REFERENCE": str(self.reference),
            "TEST_SHA": self.sha,
        }
        for name in ("GITHUB_OUTPUT", "NINJAM_REF_SHA", "KUJ_EVIDENCE_INITIALIZED"):
            self.environment.pop(name, None)
        self.patch = mock.patch.dict(os.environ, self.environment, clear=True)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        # No wall-clock sleeps in injected retry tests; retry counts/timeout
        # values and receipts remain real assertions.
        self.sleep = mock.patch.object(provisioner.time, "sleep")
        self.sleep.start()
        self.addCleanup(self.sleep.stop)
        self.runtime = self.root / "runtime"
        self.evidence = self.root / "evidence"
        self.invoke("init")

    def invoke(self, command, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return provisioner.main([
                command, "--evidence", str(self.evidence), *map(str, args),
            ])

    def provision(self, *args):
        return self.invoke("provision", "--runtime", self.runtime, "--sha", self.sha, *args)

    def receipt(self):
        return json.loads((self.evidence / "receipt.json").read_text())

    def reference_result(self):
        return json.loads((self.evidence / "reference.json").read_text())

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def fresh_run(self):
        self.evidence = self.root / f"evidence-{time.monotonic_ns()}"
        self.invoke("init")
        self.calls.write_text("")

    def test_cold_then_clean_warm_skips_compilation(self):
        self.assertEqual(0, self.provision("--cache-outcome", "success", "--cache-hit", "false"))
        first = self.reference_result()
        self.assertEqual("built-and-verified", self.receipt()["cache_validation"])
        self.assertEqual(self.sha, self.receipt()["actual_sha"])
        self.fresh_run()
        self.assertEqual(0, self.provision("--cache-outcome", "success", "--cache-hit", "true"))
        self.assertEqual(first["root"], self.reference_result()["root"])
        self.assertEqual("skipped", self.receipt()["compilation"])
        self.assertFalse(any(c[0] == "cmake" and c[1] != "--version" for c in self.commands()))
        self.assertFalse(any(c[0] == "clang++" and c[1] != "--version" for c in self.commands()))

    def test_static_dependency_config_keeps_pkgconfig_macros_available(self):
        self.assertEqual(0, self.provision())
        configs = [c for c in self.commands() if c[0] == "cmake" and c[1] == "-S"]
        self.assertEqual(2, len(configs))
        for c in configs:
            self.assertTrue(any(a.startswith("-DPKG_CONFIG_EXECUTABLE:FILEPATH=/") for a in c))
            self.assertTrue(any(a.startswith("-DCMAKE_C_COMPILER:FILEPATH=/") for a in c))
            self.assertTrue(any(a.startswith("-DCMAKE_CXX_COMPILER:FILEPATH=/") for a in c))
            self.assertNotIn("-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON", c)

    def test_build_environment_changes_invalidate_warm_snapshot(self):
        cache = self.root / "cache"
        self.assertEqual(0, self.provision("--cache-directory", cache))
        os.environ["CFLAGS"] = "-DFIXTURE_CHANGED"
        self.fresh_run()
        self.assertEqual(1, self.provision("--cache-directory", cache))
        self.assertIn("manifest inputs/reference", self.receipt()["error"])

    def test_restore_failure_is_recorded_separately_from_absent_key(self):
        self.assertEqual(0, self.provision("--cache-outcome", "failure", "--cache-hit", ""))
        self.assertEqual("failure", self.receipt()["cache_restore"])
        self.assertEqual("", self.receipt()["cache_hit"])
        other = self.root / "absent-runtime"
        self.fresh_run()
        self.assertEqual(0, self.invoke(
            "provision", "--runtime", other, "--sha", self.sha,
            "--cache-outcome", "success", "--cache-hit", "false",
        ))
        self.assertEqual("success", self.receipt()["cache_restore"])
        self.assertEqual("false", self.receipt()["cache_hit"])

    def test_warm_snapshot_in_clean_job_skips_compilation(self):
        cache = self.root / "cache"
        self.assertEqual(0, self.provision("--cache-directory", cache))
        self.assertTrue((cache / "manifest.json").exists())
        self.fresh_run()
        runtime = self.root / "clean-job"
        self.assertEqual(0, self.invoke(
            "provision", "--runtime", runtime, "--sha", self.sha,
            "--cache-directory", cache, "--cache-outcome", "success", "--cache-hit", "true",
        ))
        self.assertEqual(str(cache), self.reference_result()["root"])
        self.assertEqual("skipped", self.receipt()["compilation"])
        self.assertFalse(any(c[0] == "cmake" and c[1] != "--version" for c in self.commands()))

    def test_partial_failed_restore_is_preserved_but_never_executed(self):
        cache = self.root / "partial-restore"
        cache.mkdir()
        marker = cache / "refpeer"
        marker.write_text("unusable partial artifact")
        self.assertEqual(0, self.provision(
            "--cache-directory", cache, "--cache-outcome", "failure", "--cache-hit", "",
        ))
        self.assertEqual("unusable partial artifact", marker.read_text())
        self.assertNotEqual(str(cache), self.reference_result()["root"])
        self.assertEqual("skipped-existing-restore", self.receipt()["cache_save"])
        self.assertFalse(any(c[0] == "refpeer" for c in self.commands()))
        self.assertEqual(0, self.provision())  # the demo re-verifies recorded recovery

    def test_first_transient_fetch_failure_recovers(self):
        os.environ["TEST_NETWORK"] = "once"
        self.assertEqual(0, self.provision())
        fetches = [c for c in self.commands() if c[0] == "git" and "fetch" in c]
        self.assertEqual(2, len(fetches))
        self.assertEqual(2, self.receipt()["network_attempt"])

    def test_persistent_outage_is_capped_and_has_no_demo_pass(self):
        os.environ["TEST_NETWORK"] = "persistent"
        historical = self.root / "historical"
        historical.mkdir()
        (historical / "DEMO-PASS.txt").write_text("DEMO PASS\n")
        self.assertEqual(1, self.provision())
        receipt = self.receipt()
        self.assertEqual(("provisioning", "failed", "not-run"), (
            receipt["phase"], receipt["status"], receipt["demo"],
        ))
        self.assertEqual(3, receipt["network_attempt"])
        self.assertFalse((self.evidence / "reference.json").exists())
        self.assertFalse(any("DEMO PASS" in p.read_text() for p in self.evidence.iterdir()))
        self.assertEqual([], list((self.runtime / "references").iterdir()))

    def test_permanent_failure_does_not_get_network_retries(self):
        os.environ["TEST_NETWORK"] = "permanent"
        self.assertEqual(1, self.provision())
        self.assertEqual(1, self.receipt()["network_attempt"])

    def test_network_process_deadline_is_enforced(self):
        os.environ["TEST_NETWORK"] = "timeout"
        with mock.patch.object(provisioner, "NETWORK_TIMEOUT", 0.1):
            start = time.monotonic()
            self.assertEqual(1, self.provision())
            self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(3, self.receipt()["network_attempt"])

    def test_empty_or_invalid_reference_is_red(self):
        os.environ["TEST_NETWORK"] = "empty"
        self.assertEqual(1, self.invoke("resolve"))
        self.assertIsNone(self.receipt()["expected_sha"])
        self.fresh_run()
        self.assertEqual(1, self.invoke("resolve", "--sha", "not-a-sha"))
        self.assertEqual("failed", self.receipt()["status"])

    def test_resolved_sha_is_checked_out_even_if_main_moves(self):
        self.assertEqual(0, self.invoke("resolve"))
        resolved = self.receipt()["expected_sha"]
        # The advertised branch changes after resolution; the real fetch must
        # still request/check out the original commit. Works with CI's depth-1
        # checkout too, without synthesizing commits or overriding Git identity.
        os.environ["TEST_SHA"] = "0" * 40
        self.assertEqual(0, self.provision())
        self.assertEqual(resolved, self.receipt()["actual_sha"])

    def test_cached_revision_mismatch_is_rejected_before_execution(self):
        self.assertEqual(0, self.provision())
        root = Path(self.reference_result()["root"])
        manifest = root / "manifest.json"
        data = json.loads(manifest.read_text())
        data["expected_sha"] = "0" * 40
        manifest.write_text(json.dumps(data))
        self.fresh_run()
        self.assertEqual(1, self.provision("--cache-outcome", "success", "--cache-hit", "true"))
        self.assertIn("rejected before execution", self.receipt()["error"])
        self.assertFalse(any(c[0] in ("ninjamsrv", "refpeer") for c in self.commands()))
        self.assertTrue(root.exists())  # no broad deletion of restored state

    def test_cached_binary_changes_are_rejected(self):
        self.assertEqual(0, self.provision())
        result = self.reference_result()
        Path(result["refpeer"]).write_text("corrupted cache\n")
        self.fresh_run()
        self.assertEqual(1, self.provision())
        self.assertIn("checksum mismatch", self.receipt()["error"])

    def test_cached_source_revision_and_dirty_tree_are_rejected(self):
        self.assertEqual(0, self.provision())
        source = Path(self.reference_result()["source"])
        os.environ["TEST_ACTUAL_SHA"] = "0" * 40
        self.fresh_run()
        self.assertEqual(1, self.provision())
        self.assertIn("identity mismatch", self.receipt()["error"])
        del os.environ["TEST_ACTUAL_SHA"]
        (source / "README.md").write_text("modified cached source")
        self.fresh_run()
        self.assertEqual(1, self.provision())
        self.assertIn("checkout is modified", self.receipt()["error"])

    def test_external_checkout_mismatch_is_untouched(self):
        external = self.root / "external"
        subprocess.run([REAL_GIT, "clone", "--quiet", str(self.reference), str(external)], check=True)
        marker = external / "user-file"
        marker.write_text("keep this")
        self.assertEqual(1, self.provision("--source", external))
        self.assertEqual("keep this", marker.read_text())

    def test_compile_failure_is_not_retried_and_remains_compilation_failed(self):
        os.environ["TEST_COMPILE_FAIL"] = "1"
        self.assertEqual(1, self.provision())
        builds = [c for c in self.commands() if c[0] == "cmake" and c[1] != "--version"]
        self.assertEqual(1, len(builds))
        self.assertEqual("compilation", self.receipt()["phase"])
        self.assertEqual("failed", self.receipt()["status"])
        self.assertEqual("not-run", self.receipt()["demo"])
        self.invoke("phase", "--phase", "provisioning", "--status", "failed")
        self.assertEqual("compilation", self.receipt()["phase"])

    def test_existing_evidence_cannot_be_reinitialized(self):
        sentinel = self.evidence / "old"
        sentinel.write_text("old evidence")
        with self.assertRaises(FileExistsError):
            self.invoke("init")
        self.assertEqual("old evidence", sentinel.read_text())

    def test_demo_failure_receipt_stays_red(self):
        self.assertEqual(0, self.provision())
        self.invoke("phase", "--phase", "demo", "--status", "running")
        self.invoke("phase", "--phase", "demo", "--status", "failed")
        self.assertEqual("failed", self.receipt()["demo"])
        self.assertEqual("failed", self.receipt()["status"])
        self.assertEqual(1, self.provision())
        self.assertEqual(1, self.invoke("phase", "--phase", "demo", "--status", "passed"))
        self.assertEqual("failed", self.receipt()["demo"])

    def test_completed_demo_requires_fresh_run_evidence(self):
        self.assertEqual(0, self.provision())
        self.assertEqual(0, self.invoke("phase", "--phase", "demo", "--status", "passed"))
        self.assertEqual(1, self.provision())
        self.assertEqual("passed", self.receipt()["demo"])

    def test_demo_assertion_failure_is_not_retried(self):
        # Execute the actual shell entrypoint against fixture tools. Both join
        # commands exit zero, but the first real demo assertion rejects ok=false.
        app = self.root / "app"
        (app / "demo").mkdir(parents=True)
        for name in ("run_demo.sh", "provision_reference.py", "refpeer.cpp"):
            shutil.copyfile(REPO / "demo" / name, app / "demo" / name)
        binary = app / "zig-out/bin/kujamba"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\necho 'RESULT ok=false'\nexit 0\n")
        binary.chmod(0o755)
        evidence = self.root / "shell-evidence"
        env = dict(os.environ, TEST_RUN_DEMO="1", NINJAM_REF_SHA=self.sha,
                   KUJ_RUNTIME=str(self.runtime), KUJ_EVIDENCE_DIR=str(evidence))
        run = subprocess.run(
            ["/bin/bash", str(app / "demo/run_demo.sh")], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
        )
        self.assertNotEqual(0, run.returncode, run.stdout)
        self.assertIn("scenario A: session not ok", run.stdout)
        self.assertNotIn("DEMO PASS", run.stdout)
        receipt = json.loads((evidence / "receipt.json").read_text())
        self.assertEqual(("demo", "failed"), (receipt["phase"], receipt["demo"]))
        self.assertEqual(1, run.stdout.count("== scenario A:"))
        self.assertEqual(1, run.stdout.count("== scenario B:"))

    def test_warm_verification_does_not_erase_restore_receipt(self):
        self.assertEqual(0, self.provision("--cache-outcome", "failure", "--cache-hit", ""))
        self.assertEqual(0, self.provision())
        self.assertEqual("failure", self.receipt()["cache_restore"])
        self.assertEqual("", self.receipt()["cache_hit"])
        self.assertTrue(any(e.get("compilation") == "passed" for e in self.receipt()["events"]))


if __name__ == "__main__":
    unittest.main()
