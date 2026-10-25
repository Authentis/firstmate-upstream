#!/usr/bin/env python3
"""Locked Router v3.1 admission, reservation, receipt, and failure state."""
import datetime
import glob
import hashlib
import json
import math
import os
import re
import secrets
import sys


COMMANDS = {"route-admit", "route-check", "route-confirm", "route-ambiguous",
            "route-failure", "route-cancel", "route-classify"}
KINDS = {"plan", "resume", "closure", "cloud", "go", "priority", "start-first", "build"}
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,254}$")
EXHAUST_RE = re.compile(r"insufficient credits|usage limit|weekly limit|quota exceeded", re.I)


def _safe_id(value):
    return isinstance(value, str) and value not in (".", "..") and SAFE_ID.fullmatch(value) is not None


def _clean(value):
    return re.sub(r"[\t\r\n]+", " ", str(value or "")).strip()


def _day(epoch):
    return datetime.datetime.fromtimestamp(float(epoch), datetime.timezone.utc).strftime("%Y-%m-%d")


def _paths(R):
    home = os.environ.get("FM_HOME")
    if not home:
        return None
    home = os.path.realpath(home)
    inherited = R._route_paths()
    if not isinstance(inherited, dict):
        return {"home": home, "error": "router state paths unavailable"}
    for env_name, key in (("FLEET_YAML", "fleet"), ("QUOTA_JSON", "quota"),
                          ("BENCH_JSON", "bench")):
        # _route_paths deliberately represents an invalid explicit path as None.
        # Do not turn that fail-closed result back into the default path.
        if os.environ.get(env_name) is not None and inherited.get(key) is None:
            return {"home": home, "error": "invalid %s path" % env_name}
    if inherited.get("fleet") is None:
        return {"home": home, "error": "invalid fleet path"}
    if inherited.get("quota") is None:
        return {"home": home, "error": "invalid quota path"}
    if inherited.get("bench") is None:
        return {"home": home, "error": "invalid routing_state.bench path"}
    if inherited.get("lock") is None:
        return {"home": home, "error": "invalid ROUTE_LOCK path"}
    return {
        "home": home,
        "fleet": inherited["fleet"],
        "quota": inherited["quota"],
        "bench": inherited["bench"],
        "lock": inherited["lock"],
        "launches": R.fm_path("state/route-launches", home),
        "receipts": R.fm_path("state/route-launches/receipts.jsonl", home),
        "ledger": R.fm_path("data/cloud-workers.tsv", home),
    }


def _sidecar_path(paths, task):
    if not _safe_id(task):
        raise ValueError("invalid task id")
    return os.path.join(paths["launches"], task + ".json")


def _sidecar_valid(row, expected_task=None):
    if not isinstance(row, dict) or row.get("v") != 1:
        return False
    if (not _safe_id(row.get("task", "")) or
            (expected_task is not None and row.get("task") != expected_task) or
            row.get("kind") not in KINDS or not _safe_id(row.get("role", "")) or
            row.get("host") not in ("netcup", "bosgame") or
            not _safe_id(row.get("binding", "")) or
            not _safe_id(row.get("incarnation", ""))):
        return False
    for key in ("harness", "model", "provider", "effort"):
        value = row.get(key)
        if not isinstance(value, str) or not value or _clean(value) != value:
            return False
    admitted = row.get("admitted_at")
    if (isinstance(admitted, bool) or not isinstance(admitted, (int, float)) or
            not math.isfinite(admitted) or type(row.get("pending")) is not bool):
        return False
    state = row.get("state")
    pending_states = {"admitted", "ambiguous"}
    terminal_states = {"confirmed", "failed", "cancelled", "expired", "invalidated"}
    if state not in pending_states | terminal_states:
        return False
    if row["pending"] != (state in pending_states):
        return False
    if state in ("ambiguous", "confirmed") and not _safe_id(row.get("session", "")):
        return False
    if state == "confirmed":
        verified = row.get("verified_at")
        if (isinstance(verified, bool) or not isinstance(verified, (int, float)) or
                not math.isfinite(verified)):
            return False
    processed = row.get("processed_failure_events", [])
    return isinstance(processed, list) and all(isinstance(x, str) for x in processed)


def _load_sidecar(R, path, expected_task=None):
    if not os.path.exists(path):
        return None, None
    row = R._load_json(path, None)
    if not _sidecar_valid(row, expected_task):
        return None, "launch sidecar malformed"
    return row, None


def _validate_sidecars(R, paths):
    for path in glob.glob(os.path.join(paths["launches"], "*.json")):
        row, error = _load_sidecar(R, path, os.path.basename(path)[:-5])
        if error:
            return error
    return None


def _load_bench(R, path):
    default = {"models": {}, "bindings": {}, "cursor": {}}
    if not os.path.exists(path):
        return default, None
    bench = R._load_json(path, None)
    if not isinstance(bench, dict):
        return None, "route bench malformed"
    for key in ("models", "bindings", "cursor"):
        if key in bench and not isinstance(bench[key], dict):
            return None, "route bench malformed"
    return bench, None


def _binding_info(cfg, binding):
    row = (cfg.get("bindings") or {}).get(binding, {}) if isinstance(cfg, dict) else {}
    model = (cfg.get("models") or {}).get(row.get("model"), {}) if isinstance(row, dict) else {}
    return row if isinstance(row, dict) else {}, model if isinstance(model, dict) else {}


def _is_claude(cfg, binding):
    row, model = _binding_info(cfg, binding)
    return (str(model.get("family", "")).lower() == "claude" or
            str(row.get("harness", "")).lower() == "claude" or
            str(row.get("provider", "")).lower() in ("anthropic", "claude"))


def _role_bindings(cfg, role):
    row = (cfg.get("roles") or {}).get(role) if isinstance(cfg, dict) else None
    if isinstance(row, list):
        return [x for x in row if isinstance(x, str)]
    if not isinstance(row, dict):
        return []
    result = []
    for key in ("free", "flat", "models", "metered"):
        result.extend(x for x in row.get(key, []) if isinstance(x, str))
    return result


def _candidate_flag_reason(paths, cfg, role, binding):
    row, model = _binding_info(cfg, binding)
    family = str(model.get("family", "")).lower()
    actual = str(model.get("id", row.get("model", ""))).lower()
    if role == "cloud" and row.get("cloud_capable") is not True:
        return "binding is not cloud-capable"
    if os.path.exists(os.path.join(paths["home"], "data", "codex-review-only")):
        if family == "codex" or "codex" in actual or "gpt-6.1-sol" in actual:
            return "data/codex-review-only"
    if role == "plan" and os.path.exists(os.path.join(paths["home"], "data", "plan-grok.off")):
        if family == "grok" or "grok" in actual:
            return "data/plan-grok.off"
    if (os.path.exists(os.path.join(paths["home"], "data", "claude-off")) or
            os.environ.get("FM_CLAUDE_OFF") == "1") and _is_claude(cfg, binding):
        return "data/claude-off"
    return None


def _catalogs(R, cfg, now, paths):
    if hasattr(R, "_load_route_catalogs"):
        return R._load_route_catalogs(cfg, paths["home"])
    result = {}
    for host, spec in (cfg.get("catalogs") or {}).items():
        if not isinstance(spec, dict) or not isinstance(spec.get("path"), str):
            continue
        snap = R._load_json(R.fm_path(spec["path"], paths["home"]), None)
        if isinstance(snap, dict):
            snap = dict(snap)
            snap.setdefault("max_age_seconds", spec.get("max_age_seconds", 86400))
            result[host] = snap
    return result


def _failure_reason(R, status, message):
    if R.route_funds_stall(status, message):
        return "funds"
    if str(status).strip() == "429" or re.search(r"(?:^|\D)429(?:\D|$)", str(message)):
        return "429"
    if EXHAUST_RE.search(str(message)):
        return "exhaustion"
    return "failure"


def _event_key(incarnation, event):
    return hashlib.sha256((str(incarnation) + "\0" + str(event)).encode("utf-8", "replace")).hexdigest()


def _status_evidence(paths, task):
    path = os.path.join(paths["home"], "state", task + ".status")
    try:
        text = open(path).read()[-8192:]
    except (OSError, UnicodeError):
        text = ""
    digest = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest() if text else ""
    return digest, text


def _apply_failure(R, cfg, quota, bench, sidecar, incarnation, event, status, message, now):
    if sidecar.get("incarnation") != incarnation:
        return quota, bench, False
    key = _event_key(incarnation, event)
    processed = sidecar.get("processed_failure_events")
    processed = processed if isinstance(processed, list) else []
    if key in processed:
        return quota, bench, False
    reason = _failure_reason(R, status, message)
    apply_reason = {"funds": "insufficient balance", "exhaustion": "quota exceeded"}.get(
        reason, reason)
    bench, quota, _ = R.route_bench_apply(sidecar.get("binding"), apply_reason, now, cfg, quota, bench)
    sidecar["pending"] = False
    sidecar["state"] = "failed"
    sidecar["last_failure_event"] = {"id": str(event), "incarnation": incarnation}
    sidecar["last_failure_reason"] = reason
    # Incarnations are bounded by one launch attempt. Retain every event identity
    # for that attempt so an old event can never become replayable after a window.
    sidecar["processed_failure_events"] = processed + [key]
    return quota, bench, True


def _observe_failures(R, cfg, quota, bench, paths, now):
    changed = False
    os.makedirs(paths["launches"], exist_ok=True)
    for path in sorted(glob.glob(os.path.join(paths["launches"], "*.json"))):
        sidecar = R._load_json(path, None)
        if (not isinstance(sidecar, dict) or
                (not sidecar.get("pending") and sidecar.get("state") != "confirmed")):
            continue
        task, incarnation = sidecar.get("task"), sidecar.get("incarnation")
        if not _safe_id(task) or not _safe_id(incarnation):
            continue
        had_queued = "queued_events" in sidecar
        events = sidecar.pop("queued_events", [])
        if not isinstance(events, list):
            events = []
        status_digest, status_text = _status_evidence(paths, task)
        prior_digest = sidecar.get("status_fingerprint", sidecar.get("status_baseline", ""))
        status_code = "402" if re.search(r"(?:^|\D)402(?:\D|$)", status_text) else (
            "429" if re.search(r"(?:^|\D)429(?:\D|$)", status_text) else "")
        if (status_text and status_digest != prior_digest and
                _failure_reason(R, status_code or None, status_text) != "failure"):
            events.append({"id": "status:" + status_digest,
                           "status": status_code, "message": status_text})
        local_change = had_queued
        for item in events:
            if not isinstance(item, dict):
                continue
            event = item.get("id") or hashlib.sha256(json.dumps(item, sort_keys=True).encode()).hexdigest()
            quota, bench, applied = _apply_failure(
                R, cfg, quota, bench, sidecar, incarnation, event,
                item.get("status"), item.get("message", ""), now)
            local_change = local_change or applied
        if status_digest != prior_digest:
            sidecar["status_fingerprint"] = status_digest
            local_change = True
        if local_change:
            R._atomic_json(path, sidecar)
            changed = True
    return quota, bench, changed


def _read_receipts(paths):
    result = []
    if not os.path.exists(paths["receipts"]):
        return result, None
    try:
        with open(paths["receipts"]) as f:
            for line in f:
                if not line.strip():
                    continue
                row = json.loads(line)
                numeric = (row.get("admitted_at"), row.get("verified_at")) if isinstance(row, dict) else ()
                if (not isinstance(row, dict) or row.get("v") != 1 or
                        not _safe_id(row.get("task", "")) or row.get("kind") not in KINDS or
                        not _safe_id(row.get("binding", "")) or
                        row.get("host") not in ("netcup", "bosgame") or
                        not _safe_id(row.get("incarnation", "")) or
                        not _safe_id(row.get("session", "")) or
                        len(numeric) != 2 or any(isinstance(x, bool) or
                        not isinstance(x, (int, float)) or not math.isfinite(x) for x in numeric)):
                    raise ValueError
                result.append(row)
    except (OSError, ValueError, TypeError, UnicodeError):
        return [], "route receipt ledger malformed"
    return result, None


def _cloud_ledger(paths):
    running, finished, daily = set(), set(), []
    if not os.path.exists(paths["ledger"]):
        return running, finished, daily, None
    try:
        with open(paths["ledger"]) as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) != 4 or not _safe_id(cols[2]) or cols[3] not in ("running", "finished"):
                    raise ValueError
                epoch = float(cols[0])
                if not math.isfinite(epoch):
                    raise ValueError
                daily.append((epoch, cols[2]))
                if cols[3] == "running":
                    running.add(cols[2])
                    finished.discard(cols[2])
                else:
                    finished.add(cols[2])
                    running.discard(cols[2])
    except (OSError, ValueError, TypeError, UnicodeError):
        return set(), set(), [], "cloud worker ledger malformed"
    return running, finished, daily, None


def _cloud_usage(R, paths, now, bench=None):
    receipts, error = _read_receipts(paths)
    if error:
        return None, None, error
    running, finished, ledger_daily, error = _cloud_ledger(paths)
    if error:
        return None, None, error
    simultaneous = set(running)
    today = _day(now)
    daily = {session for epoch, session in ledger_daily if _day(epoch) == today}
    counter = bench.get("cloud_daily") if isinstance(bench, dict) else None
    if counter is not None:
        if (not isinstance(counter, dict) or not isinstance(counter.get("day"), str) or
                not isinstance(counter.get("sessions"), list) or
                not all(_safe_id(x) for x in counter["sessions"])):
            return None, None, "cloud daily counter malformed"
        if counter["day"] == today:
            daily.update(counter["sessions"])
    for receipt in receipts:
        if receipt.get("kind") == "cloud" and _day(receipt.get("verified_at", -1)) == today:
            daily.add(receipt["session"])
    for path in glob.glob(os.path.join(paths["launches"], "*.json")):
        sidecar, sidecar_error = _load_sidecar(R, path, os.path.basename(path)[:-5])
        if sidecar_error:
            return None, None, sidecar_error
        if sidecar.get("kind") != "cloud":
            continue
        state = sidecar.get("state")
        if sidecar.get("pending"):
            key = "pending:" + str(sidecar.get("incarnation"))
            simultaneous.add(key)
            if _day(sidecar.get("admitted_at", -1)) == today:
                daily.add(key)
        elif (state == "confirmed" and _safe_id(sidecar.get("session", "")) and
              sidecar["session"] not in finished):
            simultaneous.add(sidecar["session"])
    return simultaneous, daily, None


def _expire_pending(R, cfg, paths, now):
    """Release stale reservations; explicit ambiguous transport state never auto-expires."""
    try:
        ttl = int((cfg.get("routing_state") or {}).get("pending_reservation_seconds", 900))
    except (TypeError, ValueError):
        return "pending reservation TTL invalid"
    if ttl <= 0:
        return "pending reservation TTL invalid"
    for path in glob.glob(os.path.join(paths["launches"], "*.json")):
        sidecar = R._load_json(path, None)
        if not isinstance(sidecar, dict) or not sidecar.get("pending") or sidecar.get("state") == "ambiguous":
            continue
        try:
            expired = float(now) - float(sidecar["admitted_at"]) >= ttl
        except (KeyError, TypeError, ValueError):
            continue
        if expired:
            sidecar["pending"] = False
            sidecar["state"] = "expired"
            R._atomic_json(path, sidecar)
    return None


def _charge_cloud_counter(R, paths, bench, session, verified_at):
    day = _day(verified_at)
    current = bench.get("cloud_daily") if isinstance(bench, dict) else None
    if current is not None and (not isinstance(current, dict) or
                                not isinstance(current.get("sessions"), list)):
        return False
    sessions = list(current.get("sessions", [])) if current and current.get("day") == day else []
    if not all(_safe_id(x) for x in sessions):
        return False
    if session not in sessions:
        sessions.append(session)
    bench["cloud_daily"] = {"day": day, "sessions": sessions}
    R._atomic_json(paths["bench"], bench)
    return True


def _wait(reason, exhaustion=None):
    print("\t".join(["WAIT", _clean(reason), "", "", "", "", "",
                      json.dumps(exhaustion or [], separators=(",", ":"), sort_keys=True)]))
    return 0


def _pick(R, paths, cfg, quota, bench, catalogs, role, host, live, only, now):
    bindings = _role_bindings(cfg, role)
    if only is not None and only not in bindings:
        return None, "%s: binding is not configured for role %s" % (only, role), []

    def attempt(binding):
        blocked = _candidate_flag_reason(paths, cfg, role, binding)
        if blocked:
            return None, "%s: %s" % (binding, blocked)
        return R.route_pick(role, host, "", live, now, cfg, quota, bench,
                            catalogs=catalogs, only_binding=binding, advance_cursor=False)

    exhaustion = []
    if role == "cloud":
        nonclaude = [b for b in bindings if not _is_claude(cfg, b)]
        for binding in nonclaude:
            picked, why = attempt(binding)
            if picked:
                if only is not None and only != binding:
                    return None, "Claude is last resort; %s remains eligible" % binding, []
                return picked, why, []
            exhaustion.append({"binding": binding, "reason": _clean(why)})
        targets = [only] if only else [b for b in bindings if _is_claude(cfg, b)]
        if not nonclaude and not bool((cfg.get("routing_state") or {}).get("cloud_claude_exception")):
            return None, "Claude cloud exception is not configured", []
        for binding in targets:
            if not binding or not _is_claude(cfg, binding):
                continue
            picked, why = attempt(binding)
            if picked:
                return picked, why, exhaustion
            exhaustion.append({"binding": binding, "reason": _clean(why)})
        return None, "; ".join(x["reason"] for x in exhaustion) or "nothing eligible", exhaustion
    if only:
        picked, why = attempt(only)
        return picked, why, []
    for binding in bindings:
        picked, why = attempt(binding)
        if picked:
            return picked, why, []
        exhaustion.append({"binding": binding, "reason": _clean(why)})
    return None, "; ".join(x["reason"] for x in exhaustion) or "nothing eligible", exhaustion


def _admit(a, R, paths):
    if len(a) not in (6, 7) or a[4] not in ("netcup", "bosgame") or a[5].lower() not in ("yes", "no"):
        return 2
    task, kind, role, host, live = a[1], a[2], a[3], a[4], a[5].lower() == "yes"
    only = a[6] if len(a) == 7 else None
    if not _safe_id(task) or kind not in KINDS or not _safe_id(role) or (only is not None and not _safe_id(only)):
        return 2
    now = R._route_now()
    os.makedirs(paths["launches"], exist_ok=True)
    with R._route_lock(paths["lock"]):
        cfg = R._load_fleet(paths["fleet"])
        if not isinstance(cfg, dict):
            return _wait("fleet config missing or invalid")
        if os.path.exists(os.path.join(paths["home"], "data", "router-off")):
            return _wait("router-off")
        sidecar_error = _validate_sidecars(R, paths)
        if sidecar_error:
            return _wait(sidecar_error)
        ttl_error = _expire_pending(R, cfg, paths, now)
        if ttl_error:
            return _wait(ttl_error)
        quota = R._load_json(paths["quota"], {})
        bench, bench_error = _load_bench(R, paths["bench"])
        if bench_error:
            return _wait(bench_error)
        quota, bench, observed = _observe_failures(R, cfg, quota, bench, paths, now)
        if observed:
            R._atomic_json(paths["bench"], bench)
            R._atomic_json(paths["quota"], quota)
        prior, prior_error = _load_sidecar(R, _sidecar_path(paths, task), task)
        if prior_error:
            return _wait(prior_error)
        if isinstance(prior, dict) and prior.get("state") == "confirmed":
            return _wait("task already has a verified launch; cancel it before a new admission")
        if isinstance(prior, dict) and prior.get("state") == "ambiguous":
            return _wait("task has an ambiguous launch; explicit resolution required")
        if role == "cloud" or kind == "cloud":
            simultaneous, daily, error = _cloud_usage(R, paths, now, bench)
            if error:
                return _wait(error)
            if isinstance(prior, dict) and prior.get("pending"):
                simultaneous.discard("pending:" + str(prior.get("incarnation")))
                daily.discard("pending:" + str(prior.get("incarnation")))
            state = cfg.get("routing_state") or {}
            try:
                max_sim = int(state.get("cloud_simultaneous_max", 5))
                max_day = int(state.get("claude_cloud_per_day", 3))
            except (TypeError, ValueError):
                return _wait("cloud limits invalid")
            if len(simultaneous) >= max_sim:
                return _wait("cloud simultaneous limit %d reached" % max_sim)
            if len(daily) >= max_day:
                return _wait("cloud UTC daily verified/reserved limit %d reached" % max_day)
        catalogs = _catalogs(R, cfg, now, paths)
        picked, why, exhaustion = _pick(R, paths, cfg, quota, bench, catalogs,
                                        role, host, live, only, now)
        if not picked:
            if isinstance(prior, dict) and prior.get("pending"):
                prior["pending"] = False
                prior["state"] = "invalidated"
                R._atomic_json(_sidecar_path(paths, task), prior)
            return _wait(why, exhaustion)
        lane, error = R._binding_lane_fields(cfg, picked)
        if lane is None:
            return _wait("%s: %s" % (picked, error), exhaustion)
        if (isinstance(prior, dict) and prior.get("pending") and prior.get("state") == "admitted" and
                prior.get("kind") == kind and prior.get("role") == role and prior.get("host") == host and
                prior.get("binding") == picked and tuple(prior.get(key, "") for key in
                ("harness", "model", "provider", "effort")) == tuple(lane)):
            print("\t".join([picked, _clean(why), *lane, prior["incarnation"],
                              json.dumps(exhaustion, separators=(",", ":"), sort_keys=True)]))
            return 0
        incarnation = secrets.token_hex(16)
        status_baseline, _ = _status_evidence(paths, task)
        sidecar = {
            "v": 1, "task": task, "kind": kind, "role": role, "host": host,
            "binding": picked, "harness": lane[0], "model": lane[1],
            "provider": lane[2], "effort": lane[3], "incarnation": incarnation,
            "admitted_at": now, "pending": True, "state": "admitted",
            "processed_failure_events": [], "exhausted": exhaustion,
            "admission_reason": _clean(why),
            "status_baseline": status_baseline,
        }
        R._atomic_json(_sidecar_path(paths, task), sidecar)
        R._atomic_json(paths["bench"], bench)
        print("\t".join([picked, _clean(why), *lane, incarnation,
                          json.dumps(exhaustion, separators=(",", ":"), sort_keys=True)]))
    return 0


def _check(a, R, paths):
    """Read-only admission check for live GO and dry runs; CHECK is not an incarnation."""
    if len(a) not in (6, 7) or a[4] not in ("netcup", "bosgame") or a[5].lower() not in ("yes", "no"):
        return 2
    task, kind, role, host, live = a[1], a[2], a[3], a[4], a[5].lower() == "yes"
    only = a[6] if len(a) == 7 else None
    if not _safe_id(task) or kind not in KINDS or not _safe_id(role) or (only is not None and not _safe_id(only)):
        return 2
    if os.path.exists(os.path.join(paths["home"], "data", "router-off")):
        return _wait("router-off")
    now = R._route_now()
    cfg = R._load_fleet(paths["fleet"])
    if not isinstance(cfg, dict):
        return _wait("fleet config missing or invalid")
    quota = R._load_json(paths["quota"], {})
    bench, bench_error = _load_bench(R, paths["bench"])
    if bench_error:
        return _wait(bench_error)
    if role == "cloud" or kind == "cloud":
        simultaneous, daily, error = _cloud_usage(R, paths, now, bench)
        if error:
            return _wait(error)
        state = cfg.get("routing_state") or {}
        try:
            max_sim = int(state.get("cloud_simultaneous_max", 5))
            max_day = int(state.get("claude_cloud_per_day", 3))
        except (TypeError, ValueError):
            return _wait("cloud limits invalid")
        if len(simultaneous) >= max_sim:
            return _wait("cloud simultaneous limit %d reached" % max_sim)
        if len(daily) >= max_day:
            return _wait("cloud UTC daily verified/reserved limit %d reached" % max_day)
    picked, why, exhaustion = _pick(R, paths, cfg, quota, bench, _catalogs(R, cfg, now, paths),
                                    role, host, live, only, now)
    if not picked:
        return _wait(why, exhaustion)
    lane, error = R._binding_lane_fields(cfg, picked)
    if lane is None:
        return _wait("%s: %s" % (picked, error), exhaustion)
    print("\t".join([picked, _clean(why), *lane, "CHECK",
                      json.dumps(exhaustion, separators=(",", ":"), sort_keys=True)]))
    return 0


def _confirm(a, R, paths):
    if len(a) != 4 or not all(_safe_id(x) for x in a[1:]):
        return 2
    task, incarnation, session = a[1:]
    now = R._route_now()
    with R._route_lock(paths["lock"]):
        path = _sidecar_path(paths, task)
        sidecar, sidecar_error = _load_sidecar(R, path, task)
        bench, bench_error = _load_bench(R, paths["bench"])
        if sidecar_error or bench_error or not isinstance(sidecar, dict) or sidecar.get("incarnation") != incarnation:
            return 2
        if sidecar.get("state") == "confirmed":
            return 0 if sidecar.get("session") == session else 2
        if not sidecar.get("pending"):
            return 2
        receipts, error = _read_receipts(paths)
        if error:
            return 2
        existing = [row for row in receipts
                    if row.get("task") == task and row.get("incarnation") == incarnation]
        if existing:
            if any(row.get("session") != session for row in existing):
                return 2
            sidecar.update({"pending": False, "state": "confirmed",
                            "verified_at": existing[0].get("verified_at"), "session": session})
            if sidecar.get("kind") == "cloud" and not _charge_cloud_counter(
                    R, paths, bench, session, existing[0].get("verified_at")):
                return 2
            R._atomic_json(path, sidecar)
            return 0
        if sidecar.get("kind") == "cloud":
            _, daily, error = _cloud_usage(R, paths, now, bench)
            if error:
                return 2
            cfg = R._load_fleet(paths["fleet"])
            if not isinstance(cfg, dict):
                return 2
            try:
                limit = int((cfg.get("routing_state") or {}).get("claude_cloud_per_day", 3))
            except (TypeError, ValueError):
                return 2
            own_key = "pending:" + incarnation
            others = set(daily) - {own_key}
            if len(others) >= limit:
                return 2
        receipt = {key: sidecar[key] for key in ("task", "kind", "binding", "host", "incarnation", "admitted_at")}
        receipt.update({"v": 1, "verified_at": now, "session": session})
        os.makedirs(paths["launches"], exist_ok=True)
        line = json.dumps(receipt, separators=(",", ":"), sort_keys=True) + "\n"
        fd = os.open(paths["receipts"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, line.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        if sidecar.get("kind") == "cloud" and not _charge_cloud_counter(
                R, paths, bench, session, now):
            return 2
        sidecar.update({"pending": False, "state": "confirmed", "verified_at": now, "session": session})
        R._atomic_json(path, sidecar)
    return 0


def _failure(a, R, paths):
    if len(a) < 6 or not all(_safe_id(x) for x in a[1:4]):
        return 2
    task, incarnation, event, status = a[1:5]
    message = " ".join(a[5:])
    with R._route_lock(paths["lock"]):
        path = _sidecar_path(paths, task)
        sidecar, sidecar_error = _load_sidecar(R, path, task)
        if sidecar_error or not isinstance(sidecar, dict) or sidecar.get("incarnation") != incarnation:
            return 0
        cfg = R._load_fleet(paths["fleet"])
        quota = R._load_json(paths["quota"], {})
        bench, bench_error = _load_bench(R, paths["bench"])
        if bench_error:
            return 2
        quota, bench, changed = _apply_failure(
            R, cfg, quota, bench, sidecar, incarnation, event, status, message, R._route_now())
        if changed:
            R._atomic_json(paths["bench"], bench)
            R._atomic_json(paths["quota"], quota)
            R._atomic_json(path, sidecar)
    return 0


def _ambiguous(a, R, paths):
    """Persist a maybe-live launch when verification/accounting cannot complete."""
    if len(a) != 4 or not all(_safe_id(x) for x in a[1:]):
        return 2
    task, incarnation, session = a[1:]
    with R._route_lock(paths["lock"]):
        path = _sidecar_path(paths, task)
        sidecar, sidecar_error = _load_sidecar(R, path, task)
        if sidecar_error or not isinstance(sidecar, dict) or sidecar.get("incarnation") != incarnation:
            return 2
        if sidecar.get("state") == "confirmed":
            return 0 if sidecar.get("session") == session else 2
        if sidecar.get("state") == "ambiguous":
            return 0 if sidecar.get("session") == session else 2
        if not sidecar.get("pending") or sidecar.get("state") != "admitted":
            return 2
        sidecar.update({"pending": True, "state": "ambiguous", "session": session})
        R._atomic_json(path, sidecar)
    return 0


def _cancel(a, R, paths):
    if len(a) != 3 or not all(_safe_id(x) for x in a[1:]):
        return 2
    with R._route_lock(paths["lock"]):
        path = _sidecar_path(paths, a[1])
        sidecar, sidecar_error = _load_sidecar(R, path, a[1])
        if sidecar_error or not isinstance(sidecar, dict) or sidecar.get("incarnation") != a[2]:
            return 0
        sidecar["pending"] = False
        sidecar["state"] = "cancelled"
        R._atomic_json(path, sidecar)
    return 0


def cli(a, R):
    if not a or a[0] not in COMMANDS:
        return 2
    if a[0] == "route-classify":
        labels, task_text = [], ""
        if len(a) == 3 and a[1] == "--task-json":
            try:
                task = json.loads(a[2])
            except (ValueError, TypeError):
                task = None
            if isinstance(task, dict) and isinstance(task.get("labels", []), list):
                labels = task.get("labels", [])
                task_text = task.get("text", "")
        elif len(a) == 5 and a[1] == "--labels-json" and a[3] == "--text":
            try:
                labels = json.loads(a[2])
            except (ValueError, TypeError):
                labels = None
            task_text = a[4]
        elif len(a) >= 2:
            task_text = " ".join(a[1:])
            try:
                task = json.loads(task_text)
            except (ValueError, TypeError):
                task = None
            if isinstance(task, dict):
                labels = task.get("labels", [])
                task_text = task.get("text", "")
        if (not isinstance(labels, list) or not isinstance(task_text, str) or
                not task_text.strip()):
            print("WAIT\tcredential classification requires task text")
            return 2
        # Raw-text compatibility may contain serialized labels. Remove both yes/no
        # label spellings before applying CRED_RE so credentials:no is not prose.
        prose = re.sub(r"\bcredentials\s*:\s*(?:yes|no)\b", " ", task_text, flags=re.I)
        print("yes" if R.cred_label(labels) or R.cred_match(prose) else "no")
        return 0
    paths = _paths(R)
    if paths is None:
        return 2
    if paths.get("error"):
        if a[0] in ("route-admit", "route-check"):
            return _wait(paths["error"])
        return 2
    if a[0] == "route-admit":
        return _admit(a, R, paths)
    if a[0] == "route-check":
        return _check(a, R, paths)
    if a[0] == "route-confirm":
        return _confirm(a, R, paths)
    if a[0] == "route-ambiguous":
        return _ambiguous(a, R, paths)
    if a[0] == "route-failure":
        return _failure(a, R, paths)
    return _cancel(a, R, paths)


if __name__ == "__main__":
    import refill_lib_v2 as _R
    sys.exit(cli(sys.argv[1:], _R))
