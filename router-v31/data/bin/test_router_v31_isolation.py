#!/usr/bin/env python3
"""Offline invariants for the Router v3.1 build fixture.

The public seam is importing ``refill_lib_v2`` with ``FM_HOME`` set to a
fixture.  The guard process refuses any attempt to open the live Firstmate
home, so this test proves that import-time state discovery is fixture-bound.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


BUILD = "/tmp/claude-1000/router-build"
HERE = os.path.join(BUILD, "data", "bin")
BASELINE = os.path.join(BUILD, ".router-v31-baseline")
TEST_ROOT = os.path.join(BUILD, ".router-v31-testing")
LIVE_HOME = "/home/holu/fm-secondmate-upstream-20260907"


def retained_dir(prefix):
    os.makedirs(TEST_ROOT, exist_ok=True)
    return tempfile.mkdtemp(prefix=prefix, dir=TEST_ROOT)


class BaselineIntegrity(unittest.TestCase):
    def test_baseline_manifest_hashes_the_pristine_snapshot(self):
        manifest_path = os.path.join(BASELINE, "sha256.json")
        with open(manifest_path) as f:
            manifest = json.load(f)
        self.assertGreaterEqual(len(manifest), 518)
        for rel, expected in manifest.items():
            path = os.path.join(BASELINE, rel)
            self.assertTrue(os.path.isfile(path), rel)
            with open(path, "rb") as f:
                actual = hashlib.sha256(f.read()).hexdigest()
            self.assertEqual(actual, expected, rel)

    def test_cred_re_is_identical_to_the_pristine_baseline(self):
        def cred_re(path):
            with open(path) as f:
                found = re.search(r"^CRED_RE\s*=.*$", f.read(), re.M)
            self.assertIsNotNone(found, path)
            return found.group(0)
        self.assertEqual(
            cred_re(os.path.join(HERE, "refill_lib_v2.py")),
            cred_re(os.path.join(BASELINE, "data", "bin", "refill_lib_v2.py")),
        )


class FixtureHomeIsolation(unittest.TestCase):
    def test_refill_library_import_never_opens_the_live_home(self):
        root = retained_dir("isolation-")
        home = os.path.join(root, "fm-home")
        guard = os.path.join(root, "guard")
        os.makedirs(os.path.join(home, "data"))
        os.makedirs(guard)
        with open(os.path.join(guard, "sitecustomize.py"), "w") as f:
            f.write(textwrap.dedent("""\
                import builtins
                import os
                LIVE = {live!r}
                real_open = builtins.open
                def guarded_open(file, *args, **kwargs):
                    if os.path.abspath(os.fspath(file)).startswith(LIVE + os.sep):
                        raise RuntimeError("live-home open blocked: " + os.fspath(file))
                    return real_open(file, *args, **kwargs)
                builtins.open = guarded_open
            """).format(live=LIVE_HOME))
        env = dict(os.environ, FM_HOME=home,
                   PYTHONPATH=guard + os.pathsep + HERE,
                   PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run(
            [sys.executable, "-c", "import refill_lib_v2; print('fixture-import-ok')"],
            text=True, capture_output=True, env=env, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "fixture-import-ok")


if __name__ == "__main__":
    unittest.main()
