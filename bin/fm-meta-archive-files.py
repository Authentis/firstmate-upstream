#!/usr/bin/env python3
"""Private file operations for fm-meta-archive.sh; the shell owns evidence/locks.

Snapshots reject symlinks, hardlinks and special files recursively. Each batch
has a fsynced manifest before movement. Fresh exclusive directories prevent
archive collisions; every source is fingerprinted again before its move.
Restore reads only a validated manifest under this state's archive, refuses
conflicts and restores a partial batch as well as a completed one.
"""
import ctypes
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time


def safe_dir(path):
    if path.is_symlink() or not path.is_dir() or path.resolve() != path:
        raise ValueError(f"unsafe directory: {path}")


def fingerprint(path):
    info = path.lstat()
    if stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
        with path.open("rb") as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(65536), b""):
                digest.update(block)
        content = digest.hexdigest()
        kind = "file"
    elif stat.S_ISDIR(info.st_mode):
        content = {p.name: fingerprint(p) for p in sorted(path.iterdir())}
        kind = "directory"
    else:
        raise ValueError(f"unsafe file: {path}")
    result = dict(kind=kind, dev=info.st_dev, inode=info.st_ino,
                  mode=info.st_mode, size=info.st_size, mtime_ns=info.st_mtime_ns,
                  content=content)
    after = path.lstat()
    if any(getattr(after, field) != getattr(info, field) for field in
           ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")):
        raise ValueError(f"file changed while reading: {path}")
    return result


def snapshot(state, task):
    result = {p.name: fingerprint(p) for p in sorted(state.glob(task + ".*"))}
    if task + ".meta" not in result:
        raise ValueError("metadata disappeared")
    return result


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def rename_exclusive(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        directory_fd, flags = -2, 4  # AT_FDCWD, RENAME_EXCL
    elif sys.platform.startswith("linux"):
        rename = libc.renameat2
        directory_fd, flags = -100, 1  # AT_FDCWD, RENAME_NOREPLACE
    else:
        raise ValueError("exclusive rename is unsupported on this platform")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                       ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(directory_fd, os.fsencode(source), directory_fd,
              os.fsencode(destination), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def write_manifest(batch, manifest):
    with (batch / "manifest.json").open("x", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    sync_dir(batch)


def read_manifest(state, batch):
    archive = state / "meta-archive"
    safe_dir(archive)
    safe_dir(batch)
    if batch.parent != archive:
        raise ValueError("batch is outside this state's archive")
    manifest_path = batch / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("unsafe manifest")
    manifest = json.loads(manifest_path.read_text())
    task = manifest["task"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task):
        raise ValueError("invalid task")
    if manifest["schema"] != "fm-meta-archive.v1" or manifest["state"] != str(state):
        raise ValueError("wrong manifest scope")
    entries = manifest["entries"]
    names = set()
    for entry in entries:
        name = entry["name"]
        if (Path(name).name != name or not name.startswith(task + ".")
                or name in names or entry["original"] != str(state / name)
                or entry["archived"] != str(batch / "files" / name)):
            raise ValueError("invalid manifest entry")
        names.add(name)
    if task + ".meta" not in names:
        raise ValueError("missing meta entry")
    safe_dir(batch / "files")
    return manifest


def main():
    action = sys.argv[1]
    if action == "github-response":
        # gh-axi API shapes the caller-selected four scalar fields as TOON.
        # Parse only that exact schema; unknown/nested/truncated output refuses.
        fields = {}
        for line in sys.stdin.read().splitlines():
            key, separator, value = line.partition(": ")
            if not separator or key not in ("url", "state", "merged", "closed_at") or key in fields:
                raise ValueError("unreadable GitHub response")
            if value.startswith('"') or value in ("true", "false", "null"):
                fields[key] = json.loads(value)
            elif key == "state" and value in ("open", "closed"):
                fields[key] = value
            else:
                raise ValueError("unexpected GitHub scalar")
        if (set(fields) != {"url", "state", "merged", "closed_at"}
                or fields["url"] != sys.argv[2] or fields["state"] != "closed"
                or not isinstance(fields["merged"], bool)
                or not isinstance(fields["closed_at"], str)):
            raise ValueError("no trustworthy terminal GitHub evidence")
        datetime.strptime(fields["closed_at"], "%Y-%m-%dT%H:%M:%SZ")
        print(json.dumps(fields, sort_keys=True))
        return
    state = Path(sys.argv[2])
    safe_dir(state)
    if action in ("restore", "restore-check", "task-id"):
        batch = Path(sys.argv[3])
        manifest = read_manifest(state, batch)
        if action == "task-id":
            print(manifest["task"])
            return
        moved = []
        for entry in manifest["entries"]:
            source = Path(entry["archived"])
            destination = Path(entry["original"])
            if not os.path.lexists(source):
                continue
            if os.path.lexists(destination):
                raise ValueError(f"restore conflict: {destination}")
            if fingerprint(source) != entry["fingerprint"]:
                raise ValueError(f"archived file changed: {source}")
            moved.append((source, destination, entry["fingerprint"]))
        if action == "restore-check":
            print(f"would restore {len(moved)} entries from {batch}")
            return
        for source, destination, expected in moved:
            if os.path.lexists(destination) or fingerprint(source) != expected:
                raise ValueError("restore changed during revalidation")
            # Exclusive rename preserves the original file/directory inode and
            # cannot clobber a destination created after our preflight.
            rename_exclusive(source, destination)
            sync_dir(state)
            sync_dir(batch / "files")
        print(f"restored {len(moved)} entries from {batch}")
        return
    task = sys.argv[3]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task):
        raise ValueError("invalid task")
    if action == "snapshot":
        print(json.dumps(snapshot(state, task), sort_keys=True))
        return
    expected = json.load(sys.stdin)
    if snapshot(state, task) != expected:
        raise ValueError("sidecars changed since snapshot")
    if action == "prepare":
        archive = state / "meta-archive"
        if not os.path.lexists(archive):
            archive.mkdir(mode=0o700)
        safe_dir(archive)
        batch = Path(tempfile.mkdtemp(prefix=task + "-", dir=archive))
        (batch / "files").mkdir(mode=0o700)
        manifest = dict(schema="fm-meta-archive.v1", task=task, state=str(state),
                        reason=sys.argv[4], evidence=json.loads(sys.argv[5]),
                        created_epoch=int(time.time()),
                        restore_command=["env", "FM_STATE_OVERRIDE=" + str(state),
                                         "bash", sys.argv[6], "--apply", "--restore", str(batch)],
                        entries=[dict(name=name, original=str(state / name),
                                      archived=str(batch / "files" / name),
                                      fingerprint=fp)
                                 for name, fp in expected.items()])
        write_manifest(batch, manifest)
        sync_dir(archive)
        sync_dir(state)
        print(batch)
        return
    if action != "move":
        raise ValueError("invalid action")
    batch = Path(sys.argv[4])
    manifest = read_manifest(state, batch)
    if manifest["task"] != task or {e["name"]: e["fingerprint"] for e in manifest["entries"]} != expected:
        raise ValueError("manifest does not match snapshot")
    # Retain the final authoritative observation separately without rewriting
    # the manifest that already authorizes every original/archive path.
    with (batch / "revalidated.json").open("x") as stream:
        json.dump(dict(reason=sys.argv[5], evidence=json.loads(sys.argv[6])), stream)
        stream.flush()
        os.fsync(stream.fileno())
    sync_dir(batch)
    names = sorted(expected, key=lambda name: (name == task + ".meta", name))
    for name in names:
        source = state / name
        destination = batch / "files" / name
        if os.path.lexists(destination) or fingerprint(source) != expected[name]:
            raise ValueError("source changed or destination exists")
        # Atomic no-replace rename leaves either the original or its archived
        # path intact at every interruption point, for files and directories.
        rename_exclusive(source, destination)
        sync_dir(batch / "files")
        sync_dir(state)
    print(f"moved {len(names)} entries")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
