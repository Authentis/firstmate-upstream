#!/usr/bin/env bash
# Go-slot admission (chief 2239/2244/2259, SO-16, captain approved 10-07): the one check every OpenCode Go DeepSeek dispatch on netcup goes
# through - new starts, resumes, relaunches and GO sends to a live waiting worker. Go is capped at GO_CAP (default 2) WORKING lanes; a full Go
# routes a new dispatch to OpenScale (deepseek/deepseek-v4.1-flash, $10/day cap via openscale-spend.py --enforce). A running lane is never killed.
#   go-slot.sh count                    working Go lanes + open reservations (see below)
#   go-slot.sh route                    read-only: go | openscale | none for one dispatch (dry runs)
#   go-slot.sh take <task-id> [new|same]   under the lock: if a Go slot is free, reserve it and print go, else openscale | none.
#                                       new = a new agent incarnation will start (spawn/relaunch); same = the live agent resumes (GO send)
#   go-slot.sh release <task-id>        drop <task-id>'s reservation (launch proven failed or skipped)
#   go-slot.sh spawn <task-id> <fm-spawn args...>              take new + bin/fm-spawn.sh with that route's --harness/--model appended
#   go-slot.sh relaunch <task-id> <fm-control relaunch args...> same for bin/fm-control.sh <task-id> relaunch
# Working Go lane (chief 2259 #2/#5): state/<id>.meta model opencode-go/*, judged by refill_lib.py's own predicates - an AGENT process (not a
# leftover shell) at or below the worktree, and is_working() on the last status line, so a 'resolved' answer to a decision keeps counting.
# Reservations (data/go-slot.res/<task-id>: "<epoch> <new|same> <agent pids at reserve time>") retire when that lane counts as working with an
# agent the reservation did not already see (new) or at all (same), so an old agent of a relaunched id never retires the replacement's slot
# (chief 2259 #3). release (proven launch failure) or 30 min with no new agent also retire it (logged). An fm-control relaunch that failed only
# on confirmation keeps its reservation (chief 2259 #4). The lock (data/.go-slot.lock) is held only around prune+count+reserve.
# Round 3 (chief 2337): count/route are read-only (a retirable reservation is simply not counted); reservation files are written or deleted
# only under the lock (take, release, prune). A counting error is an error (exit 3, route prints none), never 0. take <id> same is
# idempotent: an existing reservation for <id> or <id> already counted as a working lane is reused, no second slot is taken.
# Round 4 (chief 2340): an unreadable or malformed reservation counts as taken and is never deleted (only a file that vanished
# concurrently is gone); take same prunes under the lock FIRST, then reuses only a still-valid reservation or a counted working lane.
# Bosgame Go lanes are not visible from here (netcup processes only).
set -u
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}; export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}; export FLEET_YAML
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
. "$ROUTER_BIN/router-launch.sh"
LOCK=$H/data/.go-slot.lock; RES=$H/data/go-slot.res
GO_CAP=${GO_CAP:-$(cat "$H/data/go-cap" 2>/dev/null || echo 2)}   # chief 2395: data/go-cap overrides (0 = no Go)
mkdir -p "$RES"
gs(){ python3 - "$H" "$RES" "$@" <<'PY'
import glob, os, re, sys, time
H, RES, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
MUT = cmd == 'prune'   # chief 2337 P1: only prune (called under the lock) deletes reservation files
sys.path.insert(0, os.environ["ROUTER_BIN"])
import refill_lib as rl
procs = []
for p in os.listdir('/proc'):
    if not p.isdigit():
        continue
    try:
        cwd = os.readlink('/proc/%s/cwd' % p)
        comm = open('/proc/%s/comm' % p).read().strip()
        cl = open('/proc/%s/cmdline' % p, 'rb').read().replace(b'\0', b' ').decode('utf8', 'replace')[:300]
    except OSError:
        continue
    procs.append((p, cwd, comm, cl))
def meta(i):
    try:
        return dict(l.rstrip('\n').split('=', 1) for l in open('%s/state/%s.meta' % (H, i)) if '=' in l)
    except OSError:
        return {}
def agents(wt):
    wt = (wt or '').rstrip('/')
    return {p for p, cwd, comm, cl in procs if wt and (cwd == wt or cwd.startswith(wt + '/')) and (rl.AGENT.search(comm) or rl.AGENT.search(cl))}
def last(i):
    try:
        ls = [l for l in open('%s/state/%s.status' % (H, i), errors='replace') if l.strip()]
        return ls[-1] if ls else ''
    except OSError:
        return ''
work = {}
for m in glob.glob(H + '/state/dos-*.meta'):
    i = os.path.basename(m)[:-5]; d = meta(i)
    if not d.get('model', '').startswith('opencode-go/'):
        continue
    a = agents(d.get('worktree'))
    if rl.is_working('', last(i), bool(a)):
        work[i] = a
if cmd == 'pids':
    print(' '.join(sorted(agents(meta(sys.argv[4]).get('worktree')))))
    sys.exit(0)
def drop(r):
    if MUT:
        try:
            stamp = str(int(time.time() * 1000000))
            os.replace(r, r + '.bak-' + stamp)
        except FileNotFoundError:
            pass
n = len(work)
bad = set()
valid = set()
for r in glob.glob(RES + '/*'):
    i = os.path.basename(r)
    if '.bak-' in i:
        continue   # retained deletion backup, never an active reservation
    try:
        raw = open(r).read()
    except FileNotFoundError:
        continue   # chief 2340 #1: vanished concurrently - the only 'gone' case
    except OSError:
        n += 1; bad.add(i); continue   # unreadable: counts as taken, never deleted
    try:
        f = raw.split(); ts = int(f[0]); mode = f[1] if len(f) > 1 else 'new'; old = set(f[2:])
        if mode not in ('new', 'same'):
            raise ValueError(mode)
    except (ValueError, IndexError):
        n += 1; bad.add(i); continue   # malformed: counts as taken, never deleted
    cur = agents(meta(i).get('worktree'))
    if i in work and (mode == 'same' or work[i] - old):
        drop(r); continue   # retired: the lane itself is counted above
    if time.time() - ts > 1800 and not (cur - old if mode == 'new' else i in work):
        if MUT:
            sys.stderr.write('go-slot: dropped stale reservation %s (30 min, no new agent / not resumed)\n' % i)
        drop(r); continue
    n += 1; valid.add(i)
if cmd == 'self':   # run under the lock after prune: <id> holds a slot only via a still-valid (or unparseable, kept) reservation or a working lane
    i = sys.argv[4]
    print('yes' if i in work or i in valid or i in bad else 'no')
    sys.exit(0)
print(n)
PY
}
count(){ local n; n=$(gs "${1:-count}") || { echo "go-slot: counting failed" >&2; return 3; }   # chief 2337: an error, never 0
  case $n in ''|*[!0-9]*) echo "go-slot: counting gave no number ('$n')" >&2; return 3;; esac; echo "$n"; }
route(){ local n
  python3 "$ROUTER_BIN/openscale-spend.py" --enforce >/dev/null 2>&1
  python3 "$ROUTER_BIN/go-spend.py" --enforce >/dev/null 2>&1   # chief 3885: <= $2/day fleet-wide (reserve pace from 10-23); marker data/ds-route-down-go-budget
  n=$(count "${1:-count}") || { echo none; return 3; }
  if [ ! -e "$H/data/ds-route-down-go" ] && [ ! -e "$H/data/ds-route-down-go-budget" ] && [ "$n" -lt "$GO_CAP" ]; then echo go
  elif [ ! -e "$H/data/ds-route-down-openscale" ]; then echo openscale
  else echo none; fi; }
take(){ local r s p; exec 7>"$LOCK"; flock -w 120 7 || { echo none; return 3; }
  if [ "${2:-new}" = same ]; then   # chief 2337/2340 #2: prune under the lock first, then reuse only a valid reservation or counted working lane
    count prune >/dev/null || { flock -u 7; echo none; return 3; }
    s=$(gs self "$1") || { flock -u 7; echo none; return 3; }
    [ "$s" = yes ] && { flock -u 7; echo go; return 0; }
  fi
  r=$(route prune) || { flock -u 7; echo none; return 3; }   # prune = the one reservation-deleting count, under the lock
  if [ "$r" = go ]; then p=$(gs pids "$1") || { flock -u 7; echo none; return 3; }; echo "$(date +%s) ${2:-new} $p" > "$RES/$1" || { [ ! -e "$RES/$1" ] || mv "$RES/$1" "$RES/$1.bak-$(date +%s%N)"; flock -u 7; echo none; return 3; }; fi   # chief 2350 #1: a failed reservation write admits nothing
  flock -u 7; echo "$r"; }
release(){ exec 7>"$LOCK"; flock -w 120 7 || { echo "go-slot: lock busy, $1 not released" >&2; return 3; }; [ ! -e "$RES/$1" ] || mv "$RES/$1" "$RES/$1.bak-$(date +%s%N)"; flock -u 7; }
rx(){ case $1 in go) echo "--harness opencode --model opencode-go/deepseek-v4.1-flash";; openscale) echo "--harness pi --model openscale/deepseek/deepseek-v4.1-flash";; esac; }
launch(){ local kind=$1; shift; local id=$1; shift; local r rc out ambiguous=0
  local real task_text labels
  if [ "${ROUTER_LIVE:-0}" = 1 ]; then
    task_text=$(python3 - "${ROUTER_PROJECT_DIR:-/home/holu/decision-os}/.beads/issues.jsonl" "$id" 2>/dev/null <<'PY' || true
import json, sys
path, wanted = sys.argv[1:]
for line in open(path, encoding='utf-8'):
    row = json.loads(line)
    if str(row.get('id') or '') == wanted:
        print(json.dumps(row, sort_keys=True)); break
PY
)
    [ -n "$task_text" ] || task_text=$(cat "$H/data/$id/brief.md" 2>/dev/null || true)
    [ -n "$task_text" ] || { echo "go-slot: WAIT: current task text/labels unavailable for $id" >&2; return 4; }
    labels=$(router_labels_from_rows "$task_text") || { echo "go-slot: WAIT: current tracker labels unavailable or malformed for $id" >&2; return 4; }
    real=$(router_classify_task "$task_text" "$labels") || { echo "go-slot: WAIT: classification failed for $id" >&2; return 4; }
  fi
  r=$(take "$id" new); [ "$r" = none ] && { echo "go-slot: Go full and OpenScale marked down (or lock busy); $id not launched"; exit 4; }
  echo "go-slot: $id -> $r (Go cap $GO_CAP)"
  local -a launch_args
  if [ "${ROUTER_LIVE:-0}" = 1 ]; then
    if [ -n "${ROUTER_GO_ONLY_BINDING:-}" ]; then
      router_admit "$id" "${ROUTER_GO_KIND:-go}" "${ROUTER_GO_ROLE:-build}" netcup "$real" "$ROUTER_GO_ONLY_BINDING" || { release "$id"; return 4; }
    else
      router_admit "$id" "${ROUTER_GO_KIND:-go}" "${ROUTER_GO_ROLE:-build}" netcup "$real" || { release "$id"; return 4; }
    fi
    launch_args=("${RA_ARGV[@]}")
  else
    # ROUTER_LIVE=0 retains the established Go/OpenScale selection semantics.
    read -r -a launch_args <<< "$(rx "$r")"
  fi
  if [ "${ROUTER_LIVE:-0}" = 1 ]; then
    cs_n=0; cs_why="can-start did not run"
    IFS=$'\t' read -r cs_n cs_why < <(python3 "$ROUTER_BIN/refill_lib_v2.py" can-start "$H/data/refill-starts.log" 2>/dev/null) || true
    case ${cs_n:-} in ''|*[!0-9]*) cs_n=0;; esac
    if [ "$cs_n" -le 0 ]; then
      echo "go-slot: WAIT: can-start allows no start (${cs_why:-no reason})" >&2
      router_cancel "$id" || true; release "$id"; return 4
    fi
  fi
  router_prelaunch || { [ "${ROUTER_LIVE:-0}" != 1 ] || router_cancel "$id"; release "$id"; return 4; }
  set +e
  if [ "$kind" = spawn ]; then out=$("$H/bin/fm-spawn.sh" "$id" "$@" "${launch_args[@]}" 2>&1); rc=$?
  else out=$("$H/bin/fm-control.sh" "$id" relaunch "$@" "${launch_args[@]}" 2>&1); rc=$?; fi
  set -e
  printf '%s\n' "$out"
  if [ "${ROUTER_LIVE:-0}" = 1 ]; then
    if [ "$rc" = 0 ] && router_confirm_verified "$id" "$out"; then
      ROUTER_HELPER_ACCOUNTS=1; export ROUTER_HELPER_ACCOUNTS
      if ! python3 "$ROUTER_BIN/refill_lib_v2.py" note-start "$H/data/refill-starts.log" >/dev/null 2>&1; then
        echo "go-slot: verified launch accounting failed; reservation retained" >&2
        ambiguous=1; rc=4
      fi
    elif [ "$rc" != 0 ]; then
      if [ "$rc" = 124 ] || printf ' %s ' "$out" | grep -qE ' (window|endpoint|session)=[^[:space:]]+'; then
        router_ambiguous "$id" "unverified-$RA_INCARNATION" || true
        ambiguous=1
      else
        router_failure "$id" "go-sync-$RA_INCARNATION" "$rc" "$out" || true
      fi
    else
      router_ambiguous "$id" "unverified-$RA_INCARNATION" || true
      ambiguous=1; rc=4
    fi
  fi
  if [ "$rc" != 0 ]; then
    # chief 2259 #4: release only on a launch proven not to have happened; a relaunch whose replacement merely was not confirmed in time keeps it
    if [ "$ambiguous" = 0 ] && { [ "$kind" = spawn ] || printf '%s' "$out" | grep -qE 'refusing|not dispatchable|could not be launched|usage:'; }; then release "$id"
    else echo "go-slot: $id relaunch unconfirmed (rc=$rc); Go reservation kept until the lane shows working or 30 min pass"; fi
  fi
  exit $rc; }
check_existing(){
  local id=$1 only_binding=$2 real=$3
  # Read-only admission: only_binding and the route-check command avoid cursor
  # movement or silent rerouting for a live worker receiving GO.
  router_check "$id" go "${ROUTER_GO_ROLE:-build}" netcup "$real" "$only_binding"
}
case ${1:-} in
  count) count;;
  route) route;;
  prune) exec 7>"$LOCK"; flock -w 120 7 || exit 3; count prune;;
  take) [ $# -ge 2 ] || { echo "usage: go-slot.sh take <task-id> [new|same]"; exit 2; }; take "$2" "${3:-new}";;
  release) [ $# -ge 2 ] || { echo "usage: go-slot.sh release <task-id>"; exit 2; }; release "$2";;
  check) [ $# -eq 4 ] || { echo "usage: go-slot.sh check <task-id> <only_binding> <yes|no>"; exit 2; }; check_existing "$2" "$3" "$4";;
  spawn|relaunch) k=$1; shift; [ $# -ge 1 ] || { echo "usage: go-slot.sh $k <task-id> <args...>"; exit 2; }; launch "$k" "$@";;
  *) sed -n 2,22p "$0"; exit 2;;
esac
