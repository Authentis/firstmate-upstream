#!/usr/bin/env python3
"""Fail-closed, fixture-testable Router v3.1 bundle pointer management.

This utility makes no network or provider calls.  It is deliberately inert
until a caller supplies both an absolute FM_HOME and an external producer
control command.  The command is responsible for the local service topology;
this code only invokes its pause/drain/resume contract.
"""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time


ENTRIES = (
    'lane-refill.sh', 'lane-refill-v2.sh', 'closure-sweep.sh',
    'mkclose-template.sh', 'cloud-launch.sh', 'cloud-refill.sh',
    'cloud-pickup-netcup.sh', 'cloud-pickup-send.sh', 'go-slot.sh',
    'bosgame-plan-send.sh', 'bosgame-leaf-send.sh', 'route-reviewer.sh',
)
MUTABLE_BIN_FILES = {
    'priority-lanes.txt', 't1-priority.txt', 'ds-route-next', 'go-reservations.tsv',
}


class BundleError(RuntimeError):
    pass


def stamp():
    return '%d-%d' % (time.time_ns(), os.getpid())


def absolute_dir(value, label):
    path = pathlib.Path(value)
    if not path.is_absolute():
        raise BundleError('%s must be absolute' % label)
    return path.resolve()


def safe_version(version):
    if not version or any(ch not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for ch in version):
        raise BundleError('version must contain only letters, digits, dot, underscore, or dash')
    return version


def under(path, parent):
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def off_path(home):
    return home / 'data' / 'router-off'


def enable_off(home):
    path = off_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text('router bundle transition %s\n' % stamp())


def archive(path):
    if path.exists() or path.is_symlink():
        target = path.with_name(path.name + '.bak-' + stamp())
        os.replace(path, target)
        return target
    return None


def remove_off_by_archive(home):
    archive(off_path(home))


def control_path(value):
    path = pathlib.Path(value)
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise BundleError('ROUTER_PRODUCER_CONTROL must name an absolute executable')
    return path


def invoke_control(control, action, home, timeout):
    try:
        result = subprocess.run([str(control), action, str(home)], text=True,
                                capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise BundleError('producer control %s timed out' % action) from error
    if result.returncode:
        raise BundleError('producer control %s failed (%s): %s' %
                          (action, result.returncode, result.stderr.strip()))


def locked_dispatch(home, timeout):
    """Yield the exclusive dispatch lock after active shared wrappers drain."""
    import contextlib
    @contextlib.contextmanager
    def holder():
        state = home / 'state'
        state.mkdir(parents=True, exist_ok=True)
        path = state / 'router-dispatch.lock'
        with path.open('a+') as lock:
            end = time.monotonic() + timeout
            while True:
                try:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= end:
                        raise BundleError('timed out draining router dispatch lock')
                    time.sleep(0.05)
            try:
                yield
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return holder()


def source_files(source):
    root = source / 'data' / 'bin'
    if not root.is_dir() or not (source / 'config' / 'fleet.yaml').is_file():
        raise BundleError('source must contain data/bin and config/fleet.yaml')
    result = []
    for item in root.rglob('*'):
        if not item.is_file() or item.is_symlink():
            continue
        rel = item.relative_to(root)
        if (item.name.startswith('test_') and item.name != 'test_fleet_schema.py') or \
                '.bak-' in item.name or item.name in MUTABLE_BIN_FILES or \
                item.name.endswith(('.pyc', '.diff', '.new')) or '__pycache__' in item.parts:
            continue
        result.append(item)
    missing = [name for name in ENTRIES if not (root / name).is_file()]
    if missing:
        raise BundleError('source lacks entrypoint(s): ' + ', '.join(missing))
    for needed in ('router-launch.sh', 'refill_lib_v2.py', 'router_state_v31.py'):
        if not (root / needed).is_file():
            raise BundleError('source lacks required router helper ' + needed)
    return sorted(result)


def stage_bundle(home, source, version):
    destination = home / 'data' / 'router-bundles' / version
    if destination.exists() or destination.is_symlink():
        raise BundleError('bundle version already exists: ' + version)
    files = source_files(source)
    destination.mkdir(parents=True)
    manifest = {'version': version, 'files': {}}
    for item in files:
        rel = pathlib.Path('data/bin') / item.relative_to(source / 'data' / 'bin')
        target = destination / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
        target.chmod(item.stat().st_mode & 0o777)
        manifest['files'][rel.as_posix()] = hashlib.sha256(target.read_bytes()).hexdigest()
    fleet = destination / 'config' / 'fleet.yaml'
    fleet.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / 'config' / 'fleet.yaml', fleet)
    manifest['files']['config/fleet.yaml'] = hashlib.sha256(fleet.read_bytes()).hexdigest()
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return destination


def current_target(home):
    current = home / 'data' / 'router-current'
    if not current.is_symlink():
        return None
    target = current.resolve()
    bundles = home / 'data' / 'router-bundles'
    if not under(target, bundles):
        raise BundleError('router-current points outside router-bundles')
    return target


def set_current(home, target):
    bundles = home / 'data' / 'router-bundles'
    if not under(target, bundles):
        raise BundleError('refusing pointer outside router-bundles')
    current = home / 'data' / 'router-current'
    # Retain a symlink to the former target before the atomic swap.  Copying
    # that link does not create a pointer gap and never removes a rollback
    # artifact.
    if current.is_symlink():
        prior = current.with_name(current.name + '.previous-' + stamp())
        os.symlink(os.readlink(current), prior)
    temporary = current.with_name('.router-current-' + stamp())
    os.symlink(str(target), temporary)
    os.replace(temporary, current)


def restore_pointer(home, previous):
    current = home / 'data' / 'router-current'
    if previous is None:
        archive(current)  # initial install failure: preserve the bad pointer, leave none active
    else:
        set_current(home, previous)


def history(home, version, previous):
    root = home / 'state' / 'router-bundle-history'
    root.mkdir(parents=True, exist_ok=True)
    record = {'new': version, 'previous': previous.name if previous else None, 'at': time.time()}
    (root / (stamp() + '.json')).write_text(json.dumps(record, sort_keys=True) + '\n')


def install_wrappers(home, wrapper, backups):
    dest = home / 'data' / 'bin'
    dest.mkdir(parents=True, exist_ok=True)
    for index, name in enumerate(ENTRIES, 1):
        target = dest / name
        backups[name] = archive(target)
        if os.environ.get('ROUTER_BUNDLE_FAIL_WRAPPER_AT') == str(index):
            raise BundleError('wrapper replacement failure requested at ' + name)
        shutil.copy2(wrapper, target)
        target.chmod(0o755)


def restore_wrappers(home, backups):
    dest = home / 'data' / 'bin'
    for name, backup in backups.items():
        target = dest / name
        archive(target)
        if backup is not None:
            os.replace(backup, target)


def smoke(bundle, home):
    if os.environ.get('ROUTER_BUNDLE_FORCE_SMOKE_FAIL') == '1':
        raise BundleError('smoke failure requested')
    manifest = json.loads((bundle / 'manifest.json').read_text())
    if 'config/fleet.yaml' not in manifest.get('files', {}):
        raise BundleError('manifest lacks fleet configuration')
    for rel, digest in manifest['files'].items():
        path = bundle / rel
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise BundleError('bundle manifest mismatch: ' + rel)
    for path in bundle.rglob('*.sh'):
        result = subprocess.run(['bash', '-n', str(path)], text=True, capture_output=True)
        if result.returncode:
            raise BundleError('bash syntax failed: %s' % path)
    schema = bundle / 'data' / 'bin' / 'test_fleet_schema.py'
    if schema.is_file():
        result = subprocess.run([sys.executable, str(schema)], text=True, capture_output=True,
                                env=dict(os.environ, FM_HOME=str(home), FLEET_YAML=str(bundle / 'config' / 'fleet.yaml')))
        if result.returncode:
            raise BundleError('bundled fleet schema failed: ' + result.stderr.strip())
    # route-check is deliberately readonly.  A missing fixture catalog may
    # yield WAIT (75), which is a valid smoke result; mutation is never used to
    # turn it into a success.
    for role in ('build', 'plan', 'closure', 'cloud'):
        env = dict(os.environ, FM_HOME=str(home), FLEET_YAML=str(bundle / 'config' / 'fleet.yaml'),
                   ROUTER_BUNDLE_ROOT=str(bundle), ROUTER_BIN=str(bundle / 'data' / 'bin'))
        result = subprocess.run([sys.executable, str(bundle / 'data' / 'bin' / 'refill_lib_v2.py'),
                                 'route-check', 'bundle-smoke-' + role, 'build', role, 'netcup', 'no'],
                                text=True, capture_output=True, env=env)
        if result.returncode not in (0, 75):
            raise BundleError('readonly route-check failed for %s: %s' % (role, result.stderr.strip()))


def install(args):
    home = absolute_dir(args.home, 'FM_HOME')
    source = absolute_dir(args.source, 'source')
    version = safe_version(args.version)
    control = control_path(args.control)
    wrapper = pathlib.Path(args.wrapper).resolve()
    if not wrapper.is_file():
        raise BundleError('wrapper template is missing')
    timeout = float(os.environ.get('ROUTER_DRAIN_TIMEOUT', '30'))
    enable_off(home)
    invoke_control(control, 'pause', home, timeout)
    with locked_dispatch(home, timeout):
        invoke_control(control, 'drain', home, timeout)
        previous = current_target(home)
        backups = {}
        try:
            bundle = stage_bundle(home, source, version)
            set_current(home, bundle)
            install_wrappers(home, wrapper, backups)
            smoke(bundle, home)
        except Exception:
            restore_pointer(home, previous)
            restore_wrappers(home, backups)
            raise
        history(home, version, previous)
    remove_off_by_archive(home)
    try:
        invoke_control(control, 'resume', home, timeout)
    except Exception:
        enable_off(home)
        raise


def previous_target(home):
    active = current_target(home)
    root = home / 'state' / 'router-bundle-history'
    if not active or not root.is_dir():
        raise BundleError('no previous bundle is recorded')
    for item in sorted(root.glob('*.json'), reverse=True):
        record = json.loads(item.read_text())
        if record.get('new') == active.name and record.get('previous'):
            target = home / 'data' / 'router-bundles' / record['previous']
            if target.is_dir():
                return target
    raise BundleError('no previous bundle is recorded')


def restore(args):
    home = absolute_dir(args.home, 'FM_HOME')
    control = control_path(args.control)
    timeout = float(os.environ.get('ROUTER_DRAIN_TIMEOUT', '30'))
    enable_off(home)
    invoke_control(control, 'pause', home, timeout)
    with locked_dispatch(home, timeout):
        invoke_control(control, 'drain', home, timeout)
        target = previous_target(home) if args.version == 'previous' else home / 'data' / 'router-bundles' / safe_version(args.version)
        if not target.is_dir():
            raise BundleError('restore bundle does not exist: ' + str(target))
        old = current_target(home)
        try:
            set_current(home, target)
            smoke(target, home)
        except Exception:
            restore_pointer(home, old)
            raise
        history(home, target.name, old)
    remove_off_by_archive(home)
    try:
        invoke_control(control, 'resume', home, timeout)
    except Exception:
        enable_off(home)
        raise


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('install', 'restore'):
        command = sub.add_parser(name)
        command.add_argument('--home', required=True)
        command.add_argument('--control', required=True)
    install_parser = sub.choices['install']
    install_parser.add_argument('--source', required=True)
    install_parser.add_argument('--wrapper', required=True)
    install_parser.add_argument('version')
    sub.choices['restore'].add_argument('version')
    args = parser.parse_args()
    try:
        (install if args.command == 'install' else restore)(args)
    except (BundleError, OSError, ValueError, json.JSONDecodeError) as error:
        print('router bundle: ' + str(error), file=sys.stderr)
        return 75
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
