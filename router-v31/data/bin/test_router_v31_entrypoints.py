#!/usr/bin/env python3
"""Runtime proof that every Router v3.1 producer honors ``data/router-off``.

These are intentionally black-box checks.  Each real entrypoint runs against a
retained, empty FM_HOME with the kill switch present.  The fixture tree is
snapshotted around every invocation and PATH contains fail-closed transport
stubs, so an early write, prompt, model call, remote send, or launch is visible
without contacting any external service.
"""
import hashlib
import os
import pathlib
import subprocess
import tempfile
import unittest


BUILD = pathlib.Path("/tmp/claude-1000/router-build")
BIN = BUILD / "data" / "bin"
RETAINED = BUILD / ".router-v31-testing"
ENTRYPOINTS = (
    "lane-refill.sh",
    "lane-refill-v2.sh",
    "closure-sweep.sh",
    "mkclose-template.sh",
    "cloud-launch.sh",
    "cloud-refill.sh",
    "cloud-pickup-netcup.sh",
    "cloud-pickup-send.sh",
    "go-slot.sh",
    "bosgame-plan-send.sh",
    "bosgame-leaf-send.sh",
    "route-reviewer.sh",
)
TRANSPORTS = (
    "ssh", "curl", "wget", "nc", "socat", "script", "claude", "codex",
    "pi", "kimi", "opencode", "droid", "model", "fm-spawn.sh", "fm-control.sh",
    "bosgame-sm-send", "gh", "gh-axi",
)


def tree_snapshot(root):
    """Return a stable representation including directories and file bytes."""
    result = []
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode & 0o7777
        if path.is_symlink():
            result.append(("link", rel, mode, os.readlink(path)))
        elif path.is_dir():
            result.append(("dir", rel, mode))
        elif path.is_file():
            result.append(("file", rel, mode, hashlib.sha256(path.read_bytes()).hexdigest()))
        else:
            result.append(("other", rel, mode))
    return result


class RouterOffEntrypoints(unittest.TestCase):
    def test_service_shim_anchors_home_and_pins_child(self):
        # Check before adding the legacy shim to runtime coverage: the old
        # executable hard-coded the live home and must never be executed here.
        text = (BIN / "lane-refill.sh").read_text()
        self.assertIn('H=${FM_HOME:-', text)
        self.assertIn('data/router-off', text)
        self.assertIn('"$B/lane-refill-v2.sh"', text)

    @classmethod
    def setUpClass(cls):
        RETAINED.mkdir(exist_ok=True)
        cls.root = pathlib.Path(tempfile.mkdtemp(prefix="entrypoints-off-", dir=RETAINED))
        cls.home = cls.root / "fm-home"
        (cls.home / "data").mkdir(parents=True)
        (cls.home / "data" / "router-off").write_text("offline test kill switch\n")
        # Some legacy paths invoke helpers by an absolute FM_HOME/bin path,
        # bypassing PATH.  Put the same fail-closed witness there before the
        # snapshot so this test catches either form of accidental execution.
        home_bin = cls.home / "bin"
        home_bin.mkdir()
        for command in ("fm-spawn.sh", "fm-control.sh", "fm-tasks-axi.sh", "fm-crew-state.sh"):
            stub = home_bin / command
            stub.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$0 $*\" >> \"${ROUTER_TEST_TRANSPORT_HITS:?}\"\n"
                "echo 'unexpected FM_HOME helper: $0' >&2\n"
                "exit 91\n"
            )
            stub.chmod(0o755)
        cls.stub_bin = cls.root / "offline-bin"
        cls.stub_bin.mkdir()
        cls.hits = cls.root / "transport-hits.log"
        for command in TRANSPORTS:
            stub = cls.stub_bin / command
            stub.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$0 $*\" >> \"${ROUTER_TEST_TRANSPORT_HITS:?}\"\n"
                "echo 'unexpected transport: $0' >&2\n"
                "exit 91\n"
            )
            stub.chmod(0o755)

    def run_case(self, entrypoint, live, arguments):
        before = tree_snapshot(self.home)
        env = dict(os.environ)
        env.update({
            "FM_HOME": str(self.home),
            "ROUTER_BIN": str(BIN),
            "FLEET_YAML": str(BUILD / "config" / "fleet.yaml"),
            "ROUTER_LIVE": live,
            "ROUTER_TEST_TRANSPORT_HITS": str(self.hits),
            "PATH": str(self.stub_bin) + os.pathsep + env.get("PATH", ""),
            "PS1": "",
        })
        proc = subprocess.run(
            ["bash", str(BIN / entrypoint), *arguments],
            cwd=BUILD,
            env=env,
            capture_output=True,
            text=True,
            timeout=12,
        )
        output = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, "%s %s: %s" % (entrypoint, arguments, output))
        self.assertIn("router-off", output, "%s %s: %s" % (entrypoint, arguments, output))
        self.assertEqual(before, tree_snapshot(self.home), "%s wrote below FM_HOME" % entrypoint)

    def test_all_entrypoints_stop_before_argument_parsing_or_side_effects(self):
        # The scripts intentionally receive insufficient positional arguments:
        # the kill switch must win over their parser for live, legacy, and dry
        # invocations alike.
        for entrypoint in ENTRYPOINTS:
            for live in ("1", "0"):
                for arguments in ((), ("--dry-run",)):
                    with self.subTest(entrypoint=entrypoint, live=live, arguments=arguments):
                        self.run_case(entrypoint, live, arguments)
        self.assertFalse(self.hits.exists(), self.hits.read_text() if self.hits.exists() else "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
