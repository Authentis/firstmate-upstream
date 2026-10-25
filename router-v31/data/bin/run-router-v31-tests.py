#!/usr/bin/env python3
"""Run Router v3.1's offline test set in a retained build-local sandbox."""
import os
import pathlib
import subprocess
import sys
import tempfile


BUILD = pathlib.Path("/tmp/claude-1000/router-build")
BIN = BUILD / "data" / "bin"
TEST_ROOT = BUILD / ".router-v31-testing"
HISTORICAL_TESTS = (
    "test_refill_v2.py",
    "test_router_v3.py",
    "test_bosgame_binding.py",
    "test_vcand.py",
)


def test_paths(selected=()):
    """New v3.1 tests first, followed by schema and recovered regression suites."""
    paths = sorted(BIN.glob("test_router_v31*.py"))
    paths.append(BIN / "test_fleet_schema.py")
    paths.extend(BIN / name for name in HISTORICAL_TESTS)
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError("missing Router v3.1 test files: " + ", ".join(missing))
    if selected:
        known = {path.name: path for path in paths}
        invalid = [name for name in selected if pathlib.Path(name).name != name or name not in known]
        if invalid:
            raise ValueError("unknown Router v3.1 test basename(s): " + ", ".join(invalid))
        return [known[name] for name in selected]
    return paths


def main():
    TEST_ROOT.mkdir(exist_ok=True)
    run_root = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=TEST_ROOT))
    tmpdir = run_root / "tmp"
    stubs = run_root / "offline-bin"
    guard = run_root / "guard"
    tmpdir.mkdir()
    stubs.mkdir()
    guard.mkdir()
    (guard / "sitecustomize.py").write_text(
        "import builtins, io, os, pathlib, shutil, socket, tempfile, time\n"
        "_ROOT = os.environ['ROUTER_TEST_TMPDIR']\n"
        "_BUILD = os.environ['ROUTER_TEST_BUILD']\n"
        "_LIVE = '/home/holu/fm-secondmate-upstream-20260907'\n"
        "_OPEN = builtins.open\n"
        "_IO_OPEN = io.open\n"
        "def guard_path(file, mode='r'):\n"
        "    if isinstance(file, int):\n"
        "        return\n"
        "    path = os.path.abspath(os.fspath(file))\n"
        "    if path == _LIVE or path.startswith(_LIVE + os.sep):\n"
        "        raise RuntimeError('live-home open blocked: ' + path)\n"
        "    if any(flag in mode for flag in ('w', 'a', 'x', '+')) and not (path == _BUILD or path.startswith(_BUILD + os.sep)):\n"
        "        raise RuntimeError('test write escaped build: ' + path)\n"
        "def guarded_open(file, *args, **kwargs):\n"
        "    guard_path(file, kwargs.get('mode', args[0] if args else 'r'))\n"
        "    return _OPEN(file, *args, **kwargs)\n"
        "def guarded_io_open(file, *args, **kwargs):\n"
        "    guard_path(file, kwargs.get('mode', args[0] if args else 'r'))\n"
        "    return _IO_OPEN(file, *args, **kwargs)\n"
        "builtins.open = guarded_open\n"
        "io.open = guarded_io_open\n"
        "def archive(path, *args, **kwargs):\n"
        "    target = os.path.abspath(os.fspath(path))\n"
        "    if not (target == _BUILD or target.startswith(_BUILD + os.sep)):\n"
        "        raise RuntimeError('test deletion escaped build: ' + target)\n"
        "    if not os.path.lexists(target):\n"
        "        raise FileNotFoundError(target)\n"
        "    base = target + '.bak-' + str(time.time_ns())\n"
        "    backup = base\n"
        "    index = 0\n"
        "    while os.path.lexists(backup):\n"
        "        index += 1\n"
        "        backup = base + '-' + str(index)\n"
        "    os.rename(target, backup)\n"
        "os.unlink = archive\n"
        "os.remove = archive\n"
        "os.rmdir = archive\n"
        "def retained_rmtree(path, ignore_errors=False, *args, **kwargs):\n"
        "    try:\n"
        "        archive(path)\n"
        "    except FileNotFoundError:\n"
        "        if not ignore_errors:\n"
        "            raise\n"
        "shutil.rmtree = retained_rmtree\n"
        "_ORIGINAL = tempfile.TemporaryDirectory\n"
        "class RetainedTemporaryDirectory(_ORIGINAL):\n"
        "    def __init__(self, *args, **kwargs):\n"
        "        if kwargs.get('dir') == '/tmp/claude-1000':\n"
        "            kwargs['dir'] = _ROOT\n"
        "        super().__init__(*args, **kwargs)\n"
        "        self._finalizer.detach()\n"
        "    def cleanup(self):\n"
        "        pass\n"
        "tempfile.TemporaryDirectory = RetainedTemporaryDirectory\n"
        "def blocked(*args, **kwargs):\n"
        "    raise RuntimeError('network disabled by Router v3.1 test runner')\n"
        "socket.socket.connect = blocked\n"
        "socket.create_connection = blocked\n"
    )
    for name in ("ssh", "curl", "wget", "gh", "gh-axi", "fm-spawn.sh", "model", "pi",
                 "claude", "codex", "kimi", "opencode", "droid", "script"):
        path = stubs / name
        path.write_text("#!/usr/bin/env bash\necho 'offline stub: %s' >&2\nexit 91\n" % name)
        path.chmod(0o755)
    git = stubs / "git"
    git.write_text(
        "#!/usr/bin/env bash\n"
        "for arg in \"$@\"; do\n"
        "  case \"$arg\" in fetch|pull|push|clone|ls-remote) echo 'offline git blocked: ' \"$arg\" >&2; exit 91;; esac\n"
        "done\n"
        "exec /usr/bin/git \"$@\"\n"
    )
    git.chmod(0o755)
    rm = stubs / "rm"
    rm.write_text(
        "#!/usr/bin/env bash\n"
        "set -u\n"
        "force=0\n"
        "for target in \"$@\"; do\n"
        "  case \"$target\" in -f|--force) force=1; continue;; --) continue;; -*) continue;; esac\n"
        "  case \"$target\" in \"$ROUTER_TEST_BUILD\"|\"$ROUTER_TEST_BUILD\"/*) ;; *) echo 'test rm escaped build: ' \"$target\" >&2; exit 91;; esac\n"
        "  if [ ! -e \"$target\" ] && [ ! -L \"$target\" ]; then [ \"$force\" = 1 ] && continue; exit 1; fi\n"
        "  stamp=$(date +%s%N 2>/dev/null || date +%s)-$$-$RANDOM\n"
        "  mv -- \"$target\" \"$target.bak-$stamp\"\n"
        "done\n"
    )
    rm.chmod(0o755)
    env = dict(os.environ)
    env.update({
        "FM_HOME": str(BUILD),
        "TMPDIR": str(tmpdir),
        "TEMP": str(tmpdir),
        "TMP": str(tmpdir),
        "ROUTER_TEST_TMPDIR": str(tmpdir),
        "ROUTER_TEST_BUILD": str(BUILD),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": str(guard) + os.pathsep + env.get("PYTHONPATH", ""),
        "PATH": str(stubs) + os.pathsep + env.get("PATH", ""),
    })
    try:
        paths = test_paths(sys.argv[1:])
    except (FileNotFoundError, ValueError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 2
    for path in paths:
        command = [sys.executable, str(path)]
        print("+ " + " ".join(command), flush=True)
        result = subprocess.run(command, cwd=BUILD, env=env)
        if result.returncode:
            return result.returncode
    print("PASS: Router v3.1 offline test set; retained fixture root " + str(run_root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
