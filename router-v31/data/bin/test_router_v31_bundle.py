#!/usr/bin/env python3
"""Fixture-only contract tests for the Router v3.1 bundle switcher."""
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import time
import unittest


BUILD = pathlib.Path('/tmp/claude-1000/router-build')
BIN = BUILD / 'data' / 'bin'
RETAINED = BUILD / '.router-v31-testing'
INSTALL = BIN / 'router-install.sh'
RESTORE = BIN / 'router-restore.sh'
ENTRIES = ('lane-refill.sh', 'lane-refill-v2.sh', 'closure-sweep.sh',
           'mkclose-template.sh', 'cloud-launch.sh', 'cloud-refill.sh',
           'cloud-pickup-netcup.sh', 'cloud-pickup-send.sh', 'go-slot.sh',
           'bosgame-plan-send.sh', 'bosgame-leaf-send.sh', 'route-reviewer.sh')


class BundleFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        RETAINED.mkdir(exist_ok=True)

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='bundle-', dir=RETAINED))
        self.home = self.root / 'fm-home'
        self.source = self.root / 'source'
        for root in (self.home, self.source):
            (root / 'data' / 'bin').mkdir(parents=True)
            (root / 'config').mkdir()
            (root / 'state').mkdir()
        (self.source / 'config' / 'fleet.yaml').write_text((BUILD / 'config' / 'fleet.yaml').read_text())
        for name in ENTRIES:
            body = '#!/usr/bin/env bash\nset -eu\nprintf "%s:%s\\n" "' + name + '" "${ROUTER_BUNDLE_ROOT:-missing}" >> "${BUNDLE_TRACE:?}"\n'
            if name == 'lane-refill-v2.sh':
                body += 'exec "$FM_HOME/data/bin/closure-sweep.sh"\n'
            (self.source / 'data' / 'bin' / name).write_text(body)
            (self.source / 'data' / 'bin' / name).chmod(0o755)
        for name in ('router-launch.sh', 'refill_lib_v2.py', 'router_state_v31.py'):
            source = BIN / name
            (self.source / 'data' / 'bin' / name).write_bytes(source.read_bytes())
        (self.source / 'data' / 'bin' / 'test_fleet_schema.py').write_bytes((BIN / 'test_fleet_schema.py').read_bytes())
        (self.source / 'data' / 'bin' / 'fleet.yaml.example').write_bytes((BIN / 'fleet.yaml.example').read_bytes())
        self.control_log = self.root / 'control.log'
        self.control = self.root / 'producer-control.sh'
        self.control.write_text('#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "$1" >> "' + str(self.control_log) + '"\n')
        self.control.chmod(0o755)
        self.trace = self.root / 'trace.log'

    def invoke(self, script, *args, extra=None):
        env = dict(os.environ, FM_HOME=str(self.home), ROUTER_PRODUCER_CONTROL=str(self.control),
                   BUNDLE_TRACE=str(self.trace), ROUTER_DRAIN_TIMEOUT='5')
        if extra:
            env.update(extra)
        return subprocess.run(['bash', str(script), *args], text=True, capture_output=True,
                              cwd=BUILD, env=env, timeout=15)

    def test_install_stages_atomic_pointer_and_pins_nested_wrappers(self):
        result = self.invoke(INSTALL, 'v1', str(self.source))
        self.assertEqual(result.returncode, 0, result.stderr)
        current = self.home / 'data' / 'router-current'
        self.assertTrue(current.is_symlink())
        bundle = current.resolve()
        self.assertEqual(bundle, self.home / 'data' / 'router-bundles' / 'v1')
        manifest = json.loads((bundle / 'manifest.json').read_text())
        self.assertIn('data/bin/lane-refill-v2.sh', manifest['files'])
        self.assertIn('config/fleet.yaml', manifest['files'])
        self.assertEqual(self.control_log.read_text().splitlines(), ['pause', 'drain', 'resume'])
        self.assertFalse((self.home / 'data' / 'router-off').exists())
        launched = subprocess.run(['bash', str(self.home / 'data' / 'bin' / 'lane-refill-v2.sh')],
                                  text=True, capture_output=True,
                                  cwd=BUILD, env=dict(os.environ, FM_HOME=str(self.home), BUNDLE_TRACE=str(self.trace)), timeout=10)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        roots = [line.rsplit(':', 1)[1] for line in self.trace.read_text().splitlines()]
        self.assertEqual(roots, [str(bundle), str(bundle)])
        self.assertTrue(any(p.name.startswith('router-off.bak-') for p in (self.home / 'data').iterdir()))

    def test_bundle_ships_real_planning_runner_beside_router_scripts(self):
        helpers = ('fm-planning-runner.sh', 'router_planning_runner_v31.py', 'router-planning.sh')
        for name in helpers:
            source = BIN / name
            self.assertTrue(source.is_file(), 'missing bundled planning helper: ' + name)
            target = self.source / 'data/bin' / name
            target.write_bytes(source.read_bytes())
            target.chmod(source.stat().st_mode & 0o777)
        result = self.invoke(INSTALL, 'planning-runner', str(self.source))
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = (self.home / 'data/router-current').resolve()
        manifest = json.loads((bundle / 'manifest.json').read_text())
        for name in helpers:
            self.assertIn('data/bin/' + name, manifest['files'])
            self.assertEqual((bundle / 'data/bin' / name).read_bytes(), (BIN / name).read_bytes())
        self.assertTrue(os.access(bundle / 'data/bin/fm-planning-runner.sh', os.X_OK))

    def test_smoke_failure_rolls_back_and_keeps_off(self):
        first = self.invoke(INSTALL, 'v1', str(self.source))
        self.assertEqual(first.returncode, 0, first.stderr)
        before = (self.home / 'data' / 'router-current').resolve()
        failed = self.invoke(INSTALL, 'v2', str(self.source), extra={'ROUTER_BUNDLE_FORCE_SMOKE_FAIL': '1'})
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual((self.home / 'data' / 'router-current').resolve(), before)
        self.assertTrue((self.home / 'data' / 'router-off').exists())
        self.assertEqual(self.control_log.read_text().splitlines(), ['pause', 'drain', 'resume', 'pause', 'drain'])

    def test_restore_previous_and_hook_failure_fail_closed(self):
        self.assertEqual(self.invoke(INSTALL, 'v1', str(self.source)).returncode, 0)
        self.assertEqual(self.invoke(INSTALL, 'v2', str(self.source)).returncode, 0)
        restored = self.invoke(RESTORE, 'previous')
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual((self.home / 'data' / 'router-current').resolve().name, 'v1')
        bad = self.root / 'bad-control.sh'
        bad.write_text('#!/usr/bin/env bash\nexit 7\n')
        bad.chmod(0o755)
        result = self.invoke(INSTALL, 'v3', str(self.source), extra={'ROUTER_PRODUCER_CONTROL': str(bad)})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.home / 'data' / 'router-off').exists())
        self.assertEqual((self.home / 'data' / 'router-current').resolve().name, 'v1')

    def test_resume_hook_failure_reenables_off(self):
        bad = self.root / 'resume-fail.sh'
        bad.write_text('#!/usr/bin/env bash\n[ "$1" = resume ] && exit 9\nexit 0\n')
        bad.chmod(0o755)
        result = self.invoke(INSTALL, 'v1', str(self.source), extra={'ROUTER_PRODUCER_CONTROL': str(bad)})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.home / 'data' / 'router-off').exists())

    def test_initial_failure_leaves_no_pointer_and_drain_precedes_wrapper_replacement(self):
        legacy = self.home / 'data' / 'bin' / 'lane-refill-v2.sh'
        legacy.write_text('#!/usr/bin/env bash\nexit 0\n')
        failure = self.invoke(INSTALL, 'v1', str(self.source), extra={'ROUTER_BUNDLE_FORCE_SMOKE_FAIL': '1'})
        self.assertNotEqual(failure.returncode, 0)
        current = self.home / 'data' / 'router-current'
        self.assertFalse(current.exists() or current.is_symlink())
        self.assertTrue((self.home / 'data' / 'router-off').exists())
        self.assertEqual(self.control_log.read_text().splitlines(), ['pause', 'drain'])
        self.assertTrue(any(p.name.startswith('lane-refill-v2.sh.bak-') for p in legacy.parent.iterdir()))

    def test_real_bad_shell_smoke_and_state_preservation(self):
        original = (self.source / 'data' / 'bin' / 'go-slot.sh').read_text()
        (self.source / 'data' / 'bin' / 'go-slot.sh').write_text(original + 'if then\n')
        state = self.home / 'state' / 'route-bench.json'
        state.write_text('{"preserve": true}\n')
        result = self.invoke(INSTALL, 'bad-shell', str(self.source))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state.read_text(), '{"preserve": true}\n')
        self.assertTrue((self.home / 'data' / 'router-off').exists())
        self.assertFalse((self.home / 'data' / 'router-current').exists())

    def test_exclusive_installer_waits_for_shared_wrapper_and_pointer_never_torn(self):
        self.assertEqual(self.invoke(INSTALL, 'v1', str(self.source)).returncode, 0)
        bundle = (self.home / 'data' / 'router-current').resolve()
        # A real shared wrapper lock represents a long invocation.  While it is
        # held, installer cannot call its drain hook or expose a partial pointer.
        lock = self.home / 'state' / 'router-dispatch.lock'
        holder = subprocess.Popen(['bash', '-c', 'exec 9>>"$1"; flock -s 9; sleep 0.6', '_', str(lock)])
        time.sleep(0.1)
        start = time.monotonic()
        result = self.invoke(INSTALL, 'v2', str(self.source))
        elapsed = time.monotonic() - start
        holder.wait(timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 0.4)
        self.assertEqual((self.home / 'data' / 'router-current').resolve().name, 'v2')
        self.assertEqual(bundle.name, 'v1')

    def test_background_worker_does_not_leak_shared_lock(self):
        self.assertEqual(self.invoke(INSTALL, 'v1', str(self.source)).returncode, 0)
        # The worker inherits no lock FD because the outer flock uses --close.
        # It therefore cannot block a later exclusive transition after its
        # launcher has returned.
        source = self.source / 'data' / 'bin' / 'route-reviewer.sh'
        worker_pid = self.root / 'worker.pid'
        source.write_text('#!/usr/bin/env bash\n(sleep 3 >/dev/null 2>&1) &\necho $! > "${BUNDLE_WORKER_PID:?}"\nexit 0\n')
        # A fresh staged v2 carries the changed helper; invoke its wrapper
        # after the swap and immediately request v3 while its worker lives.
        self.assertEqual(self.invoke(INSTALL, 'v2', str(self.source)).returncode, 0)
        started = subprocess.run(['bash', str(self.home / 'data' / 'bin' / 'route-reviewer.sh')],
                                 cwd=BUILD, text=True, capture_output=True,
                                 env=dict(os.environ, FM_HOME=str(self.home), BUNDLE_TRACE=str(self.trace),
                                          BUNDLE_WORKER_PID=str(worker_pid)), timeout=5)
        self.assertEqual(started.returncode, 0, started.stderr)
        pid = int(worker_pid.read_text())
        os.kill(pid, 0)  # the detached worker must still be alive for this proof
        exclusive = subprocess.run(['flock', '-xn', str(self.home / 'state' / 'router-dispatch.lock'), 'true'],
                                   text=True, capture_output=True, timeout=3)
        self.assertEqual(exclusive.returncode, 0, exclusive.stderr)
        begin = time.monotonic()
        third = self.invoke(INSTALL, 'v3', str(self.source))
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertLess(time.monotonic() - begin, 1.8)

    def test_mid_wrapper_replacement_restores_each_original_wrapper(self):
        original = {}
        for name in ENTRIES:
            path = self.home / 'data' / 'bin' / name
            original[name] = '#!/usr/bin/env bash\necho legacy-' + name + '\n'
            path.write_text(original[name])
            path.chmod(0o755)
        result = self.invoke(INSTALL, 'v1', str(self.source),
                             extra={'ROUTER_BUNDLE_FAIL_WRAPPER_AT': '2'})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.home / 'data' / 'router-off').exists())
        for name, contents in original.items():
            self.assertEqual((self.home / 'data' / 'bin' / name).read_text(), contents, name)


if __name__ == '__main__':
    unittest.main(verbosity=2)
