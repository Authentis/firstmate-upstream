#!/usr/bin/env python3
"""One-pass planning launcher with conservative, durable token reservations.

Pi has no token-budget flag.  Reservations therefore charge 300k before launch;
the child records session usage when available and preserves any overrun verbatim.
"""
import argparse, fcntl, json, os, re, shutil, signal, subprocess, sys, time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

PASS_CAP, DAY_CAP, WALL_SECONDS = 300000, 1000000, 1800

def emit(ok, reason="", **extra):
    print(json.dumps(dict(ok=ok, reason=reason, **extra), sort_keys=True))

def today(): return datetime.now(timezone.utc).date().isoformat()
def pi_binary():
    bundled = Path(__file__).resolve().parent / "pi-codemode/pi"
    return os.environ.get("FM_PLANNING_PI") or (str(bundled) if bundled.is_file() else "") or shutil.which("pi") or ""
def ssh_binary(): return os.environ.get("FM_PLANNING_SSH") or shutil.which("ssh") or ""
def muse_sender(home): return os.environ.get("FM_PLANNING_BOSGAME_SEND") or str(Path(home) / "data/bin/bosgame-sm-send.sh")
def cli_model(model):
    """Map router's stable K3 identity to an installed Pi provider, offline."""
    if model != "kimi-code/k3": return model
    registry = Path(os.environ.get("FM_PLANNING_MODEL_REGISTRY", Path.home() / ".pi/agent/models-store.json"))
    if not registry.exists(): return model
    try: raw = json.loads(registry.read_text())
    except (OSError, json.JSONDecodeError): return None
    provider = raw.get("kimi-coding", {}) if isinstance(raw, dict) else {}
    models = provider.get("models", []) if isinstance(provider, dict) else []
    return "kimi-coding/k3" if any(isinstance(m, dict) and m.get("id") == "k3" for m in models) else None

@contextmanager
def locked(home):
    p = Path(home) / "state/planning-runner-v31.lock"; p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a") as f:
        fcntl.flock(f, fcntl.LOCK_EX); yield

def ledger_path(home): return Path(home) / "state/planning-runner-v31.json"
def load(home):
    p = ledger_path(home)
    return json.loads(p.read_text()) if p.exists() else {"v": 1, "passes": []}
def save(home, value):
    p = ledger_path(home); tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True)); os.replace(tmp, p)
def day_at(value): return datetime.fromtimestamp(value, timezone.utc).date().isoformat()
def charged(state):
    # An unfinished reservation remains charged across midnight. Finished work
    # is charged both to its reservation day and its completion day.
    return sum(int(x.get("charged_tokens", PASS_CAP)) for x in state["passes"]
               if x.get("remote_pending") or not x.get("finished_at") or x.get("day") == today() or day_at(x["finished_at"]) == today())
def budget_reason(state):
    if any(x.get("overrun") and (x.get("remote_pending") or not x.get("finished_at") or x.get("day") == today() or day_at(x["finished_at"]) == today())
           for x in state["passes"]): return "pass token budget exceeded"
    if charged(state) + PASS_CAP > DAY_CAP: return "daily token budget reached"
    return ""

def valid(a):
    if a.max_tokens != PASS_CAP: return "max tokens must be 300000"
    if a.host == "netcup" and a.harness == "pi" and a.model in ("openai-codex/gpt-6.1-sol", "kimi-code/k3"): return ""
    if a.host == "bosgame" and a.harness == "muse" and a.model == "muse-wonder": return ""
    return "unsupported planning route"

def check(a):
    reason = valid(a)
    if reason: return reason
    if a.harness == "pi" and not cli_model(a.model): return "installed Pi model unavailable"
    binary = ssh_binary() if a.harness == "muse" else pi_binary()
    if not binary or not os.path.isfile(binary) or not os.access(binary, os.X_OK): return "binary missing"
    with locked(a.home):
        reason = budget_reason(load(a.home))
        if reason: return reason
    return ""

def usage(session):
    total = 0; found = False; malformed = False
    for p in Path(session).rglob("*.jsonl") if Path(session).exists() else []:
        for line in p.read_text(errors="ignore").splitlines():
            try:
                event = json.loads(line)
                u = event.get("usage", event.get("message", {}).get("usage"))
            except json.JSONDecodeError: continue
            if u is None: continue
            if not isinstance(u, dict): malformed = True; continue
            values = [u.get(k) for k in ("input", "output", "cacheRead", "cacheWrite") if k in u]
            reasoning = u.get("reasoning")
            token_total = u.get("totalTokens")
            if (not isinstance(token_total, int) or token_total < 0 or
                any(not isinstance(v, int) or v < 0 for v in values) or
                (reasoning is not None and (not isinstance(reasoning, int) or reasoning < 0)) or
                (values and token_total < sum(values))): malformed = True; continue
            total += token_total; found = True
    return max(total, PASS_CAP) if malformed else (total if found else PASS_CAP)

def child(a, endpoint, session):
    request = Path(a.request).read_text()
    request_data = json.loads(request)
    prompt = ("Run one tracker-only planning pass. Work only on this immutable JSON request, "
              "publish the normal planning PR, and create a verifiable landed commit before claiming completion. "
              "Its commit message must include the exact trailer 'Planning-task: " + a.task + "'. "
              "In the disposable worktree, create branch fm/" + a.task + "; rebuild the worktree-local "
              "tracker with `br sync --import-only --rebuild`, verify the isolated tracker before using br, "
              "and commit only .beads/issues.jsonl. Do not use child models or edit unrelated files. REQUEST=" + request)
    workdir = a.project
    if a.harness == "pi":
        worktree = Path(a.home) / "data" / a.task / "worktree"
        if worktree.exists():
            _finish_unavailable(a, endpoint, "worktree path already exists; refusing stale reuse")
            return
        baseline = request_data.get("baseline", "origin/main")
        made = subprocess.run(["git", "-C", a.project, "worktree", "add", "--detach", str(worktree), baseline],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if made.returncode:
            _finish_unavailable(a, endpoint, "worktree unavailable: " + made.stdout.strip())
            return
        if isinstance(baseline, str) and len(baseline) >= 40:
            head = subprocess.run(["git", "-C", str(worktree), "rev-parse", "HEAD"], text=True, capture_output=True)
            if head.returncode or head.stdout.strip() != baseline:
                _finish_unavailable(a, endpoint, "worktree baseline mismatch")
                return
        tracker = worktree / ".beads"; tracker.mkdir(exist_ok=True)
        (tracker / "isolated-tracker").write_text(str(tracker.resolve()) + "\n")
        workdir = str(worktree)
    if a.harness == "muse":
        # bosgame-sm is a forced-command endpoint: stdin is the sole supported
        # launch transport, never an arbitrary remote shell.
        cmd = [ssh_binary(), "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "bosgame-sm"]
        prompt = ("[netcup SM] Run exactly one bosgame-only Muse Wonder high planning pass for " + a.task +
                  " in a local disposable task worktree. Use no other model and no child model. "
                  "Enforce a 300000 token budget and 1800 second limit. " + prompt)
    else:
        cmd = [pi_binary(), "--print", "--mode", "json", "--model", cli_model(a.model), "--thinking", a.effort, "--session-dir", session, prompt]
    started = time.time(); rc = 125; error = ""; output = ""
    try:
        launch_env = dict(os.environ, FM_PI_HARNESS="pi")
        process = subprocess.Popen(cmd, cwd=workdir, env=launch_env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        output, _ = process.communicate(prompt if a.harness == "muse" else None, timeout=WALL_SECONDS); rc = process.returncode
        if a.harness == "muse" and (not re.search(r"^(replied|sent)", output, re.M | re.I) or re.search(r"\b(error|fail(?:ed|ure)?|quota|429|402)\b", output, re.I)):
            rc, error = 125, "bosgame delivery not acknowledged"
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try: output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); output, _ = process.communicate()
        rc, error = 124, "timeout"
    except OSError as e: rc, error = 127, str(e)
    actual = usage(session) if a.harness == "pi" else PASS_CAP
    with locked(a.home):
        state = load(a.home)
        row = next(x for x in state["passes"] if x["task"] == a.task and x["endpoint"] == endpoint)
        row.update(finished_at=time.time(), exit_code=rc, actual_tokens=actual, error=error,
                   charged_tokens=max(PASS_CAP, actual))
        if actual > PASS_CAP:
            row["overrun"] = True
            with (Path(a.home) / "state/planning-blocked.alert").open("a") as alert:
                alert.write(f"{datetime.now(timezone.utc).isoformat()} planning blocked: pass token budget exceeded actual={actual} cap={PASS_CAP}\n")
            blocked_path = Path(a.home) / "data" / a.task / "planning-blocked.json"
            blocked_path.write_text(json.dumps({"v":1,"task":a.task,"incarnation":a.incarnation,"model":a.model,"reason":"pass token budget exceeded"}))
        save(a.home, state)
    # Controller completion requires a locally verified landed commit. Usage is
    # deliberately separate so an async runner never creates an invalid result.
    usage_path = Path(a.home) / "data" / a.task / "planning-usage.json"
    usage_path.parent.mkdir(parents=True, exist_ok=True)
    usage_path.write_text(json.dumps({"v": 1, "task": a.task, "incarnation": a.incarnation,
        "model": a.model, "token_cap": PASS_CAP, "tokens": actual, "runner_exit": rc, "endpoint": endpoint}))
    # A remote ssh timeout/disconnect cannot prove the remote Muse process did
    # not continue.  Keep that reservation ambiguous rather than falsely
    # advancing the model chain and double-spending the pass.
    def blocked(reason):
        pending = Path(a.home) / "data" / a.task / "planning-blocked.json"
        pending.parent.mkdir(parents=True, exist_ok=True)
        pending.write_text(json.dumps({"v":1,"task":a.task,"incarnation":a.incarnation,"model":a.model,"reason":reason}))
    if a.harness == "muse" and rc == 0:
        with locked(a.home):
            state = load(a.home)
            next(x for x in state["passes"] if x["task"] == a.task and x["endpoint"] == endpoint)["remote_pending"] = True
            save(a.home, state)
        status = Path(a.home) / "state" / (a.task + ".planning-runner.json")
        status.write_text(json.dumps({"endpoint": endpoint, "remote_pending": True}))
        blocked("bosgame accepted remote Muse launch; remote completion pending")
        with (Path(a.home) / "state/planning-blocked.alert").open("a") as alert:
            alert.write(f"{datetime.now(timezone.utc).isoformat()} planning remote-pending: bosgame Muse accepted task={a.task}\n")
    # SSH transport ambiguity, including 255, cannot establish that remote Muse
    # stopped. Retain its reservation; only an explicit quota/refusal response
    # proves this attempt can hand off to K3.
    definitive_muse = a.harness != "muse" or (rc != 0 and re.search(r"\b(quota|refus(?:e|ed|al)|429|402)\b", output, re.I))
    if a.harness == "muse" and rc and not definitive_muse:
        blocked("bosgame transport ambiguous; remote Muse may still be running")
    if rc and definitive_muse:
        # A completed CLI failure is definitive only after the child has exited.
        # It lets the controller charge this attempt and move to the next model.
        reason = "quota stop" if any(x in output.lower() for x in ("quota", "rate limit", "429", "402")) else (error or "runner exit " + str(rc))
        failed = Path(a.home) / "data" / a.task / "planning-failure.json"
        tmp = failed.with_suffix(".tmp")
        tmp.write_text(json.dumps({"v":1,"task":a.task,"incarnation":a.incarnation,"model":a.model,
                                   "tokens":actual,"reason":reason,"definitive":True}))
        os.replace(tmp, failed)

def _finish_unavailable(a, endpoint, reason):
    with locked(a.home):
        state = load(a.home)
        row = next(x for x in state["passes"] if x["task"] == a.task and x["endpoint"] == endpoint)
        row.update(finished_at=time.time(), exit_code=127, actual_tokens=PASS_CAP, error=reason)
        save(a.home, state)
    failed = Path(a.home) / "data" / a.task / "planning-failure.json"; failed.parent.mkdir(parents=True, exist_ok=True)
    failed.write_text(json.dumps({"v":1,"task":a.task,"incarnation":a.incarnation,"model":a.model,
                                  "tokens":PASS_CAP,"reason":reason,"definitive":True}))

def proc_start(pid):
    try: return Path(f"/proc/{pid}/stat").read_text().split()[21]
    except (OSError, IndexError): return ""

def alive(task):
    home = os.environ.get("FM_PLANNING_HOME") or os.environ.get("FM_HOME")
    if not home: return 75
    path = Path(home) / "state" / (task + ".planning-runner.json")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,180}", task): return 75
    try: row = json.loads(path.read_text()); pid = int(row["pid"])
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        try:
            row = json.loads(path.read_text())
            if row.get("remote_pending") is True: print("alive"); return 0
        except (OSError, json.JSONDecodeError): pass
        return 75
    try: state = Path(f"/proc/{pid}/stat").read_text().split()[2]
    except (OSError, IndexError): return 75
    if state == "Z" or row.get("start") != proc_start(pid): return 75
    print("alive"); return 0

def start(a):
    reason = check(a)
    if reason: emit(False, reason); return 75
    if (Path(a.home) / "data/router-off").exists(): emit(False, "router off"); return 75
    endpoint = "planning-" + a.task
    session = str(Path(a.home) / "data" / a.task / "pi-session")
    with locked(a.home):
        state = load(a.home)
        reason = budget_reason(state)
        if reason: emit(False, reason); return 75
        if any(x["task"] == a.task for x in state["passes"]): emit(False, "duplicate task"); return 75
        # Reserve the entire pass up-front: unknown usage never becomes free spend.
        state["passes"].append(dict(task=a.task, endpoint=endpoint, day=today(), reserved_at=time.time(),
            reserved_tokens=PASS_CAP, charged_tokens=PASS_CAP, host=a.host, harness=a.harness, model=a.model))
        save(a.home, state)
    meta = Path(a.home) / "state" / (a.task + ".meta"); meta.parent.mkdir(parents=True, exist_ok=True)
    meta.write_text("window=" + endpoint + "\n")
    proc = [sys.executable, str(Path(__file__).resolve()), "--child", *sys.argv[2:]]
    if os.environ.get("FM_PLANNING_FOREGROUND") == "1":
        subprocess.run(proc, check=False)
    else:
        try:
            child_proc = subprocess.Popen(proc, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            _finish_unavailable(a, endpoint, "runner spawn failed: " + str(e))
            with (Path(a.home) / "state/planning-blocked.alert").open("a") as alert:
                alert.write(f"{datetime.now(timezone.utc).isoformat()} planning blocked: runner spawn failed {e}\n")
            emit(False, "runner spawn failed"); return 75
        status = Path(a.home) / "state" / (a.task + ".planning-runner.json")
        status.write_text(json.dumps({"pid": child_proc.pid, "start": proc_start(child_proc.pid), "endpoint": endpoint}))
    print("spawned endpoint=" + endpoint)
    return 0

def parser():
    p = argparse.ArgumentParser(); p.add_argument("alive_task", nargs="?"); p.add_argument("--capabilities", action="store_true"); p.add_argument("--check", action="store_true"); p.add_argument("--start", action="store_true"); p.add_argument("--child", action="store_true")
    p.add_argument("--home"); p.add_argument("--task"); p.add_argument("--project"); p.add_argument("--host"); p.add_argument("--request"); p.add_argument("--max-tokens", type=int); p.add_argument("--result"); p.add_argument("--incarnation"); p.add_argument("--harness"); p.add_argument("--model"); p.add_argument("--effort")
    return p
def main():
    a = parser().parse_args()
    if a.alive_task: return alive(a.alive_task)
    if a.capabilities:
        print(json.dumps({"v":1,"hosts":["netcup","bosgame"],"hard_token_cap":False,"budget_enforcement":"wall-clock+accounting"})); return 0
    if not all((a.home,a.host,a.harness,a.model,a.effort,a.max_tokens)):
        emit(False, "missing required runner arguments"); return 75
    if a.check:
        reason=check(a); emit(not bool(reason), reason); return 0 if not reason else 75
    if a.child:
        child(a, "planning-" + a.task, str(Path(a.home) / "data" / a.task / "pi-session")); return 0
    if a.start:
        if not a.task or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,180}", a.task): emit(False, "invalid task"); return 75
        return start(a)
    emit(False, "select --capabilities, --check, or --start"); return 75
if __name__ == "__main__": raise SystemExit(main())
