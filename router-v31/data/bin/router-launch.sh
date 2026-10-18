#!/usr/bin/env bash
# Router v3.1 sourceable admission/launch seam.  This file executes no launch.
# Callers must admit, launch with RA_ARGV, verify the endpoint, then confirm.

# Pin one bundle tree for the whole invocation.  Entrypoint wrappers may provide
# these values; otherwise an unbundled development tree resolves from this file.
if [ -z "${ROUTER_BIN:-}" ]; then
  ROUTER_BIN=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
fi
if [ -z "${ROUTER_BUNDLE_ROOT:-}" ]; then
  ROUTER_BUNDLE_ROOT=$(CDPATH= cd -- "$ROUTER_BIN/../.." && pwd -P)
fi
FM_HOME=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
FLEET_YAML=${FLEET_YAML:-$FM_HOME/config/fleet.yaml}
ROUTER_POLICY=${ROUTER_POLICY:-$ROUTER_BIN/refill_lib_v2.py}
export FM_HOME ROUTER_BUNDLE_ROOT ROUTER_BIN FLEET_YAML

RA_BINDING= RA_REASON= RA_HARNESS= RA_MODEL= RA_PROVIDER= RA_EFFORT=
RA_INCARNATION= RA_EXHAUSTED_JSON= RA_TASK= RA_KIND= RA_ROLE= RA_HOST=
RA_ADMITTED_AT= RA_META_BEFORE= RV_SESSION=
RA_ARGV=()

router_global_off() {
  if [ -e "$FM_HOME/data/router-off" ]; then
    printf '%s\n' router-off
    return 0
  fi
  return 1
}

# Called immediately before every process launch, after all other checks.
router_prelaunch() {
  if [ -e "$FM_HOME/data/router-off" ]; then
    printf '%s\n' router-off
    return 75
  fi
  return 0
}

# Readable alias for callers whose conditional is immediately around launch.
router_prelaunch_ok() { router_prelaunch; }

_router_clear_admission() {
  RA_BINDING= RA_REASON= RA_HARNESS= RA_MODEL= RA_PROVIDER= RA_EFFORT=
  RA_INCARNATION= RA_EXHAUSTED_JSON= RA_TASK= RA_KIND= RA_ROLE= RA_HOST=
  RA_ADMITTED_AT= RA_META_BEFORE= RV_SESSION=
  RA_ARGV=()
}

_router_safe_id() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,254}$ ]]
}

_router_safe_lane_value() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,254}$ ]]
}

_router_meta_fingerprint() {
  local path=$1
  if [ -f "$path" ]; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
  else
    printf '%s\n' absent
  fi
}

_router_parse_pick() {
  local line=$1 tabs launch_model
  tabs=${line//[^$'\t']/}
  [ "${#tabs}" -eq 7 ] || return 1
  IFS=$'\t' read -r RA_BINDING RA_REASON RA_HARNESS RA_MODEL RA_PROVIDER \
    RA_EFFORT RA_INCARNATION RA_EXHAUSTED_JSON <<<"$line"
  [ "$RA_BINDING" != WAIT ] || return 1
  _router_safe_id "$RA_BINDING" || return 1
  _router_safe_id "$RA_INCARNATION" || return 1
  case "$RA_HARNESS" in
    claude|codex|pi|opencode|commandcode|droid|droid-local|kimi|muse) ;;
    *) return 1 ;;
  esac
  _router_safe_lane_value "$RA_MODEL" || return 1
  _router_safe_lane_value "$RA_PROVIDER" || return 1
  case "$RA_EFFORT" in low|medium|high|xhigh|max|ultra) ;; *) return 1;; esac
  python3 -c 'import json,sys; x=json.loads(sys.argv[1]); raise SystemExit(not isinstance(x,list))' \
    "$RA_EXHAUSTED_JSON" >/dev/null 2>&1 || return 1

  launch_model=$RA_MODEL
  case "$RA_HARNESS" in
    pi|opencode)
      case "$launch_model" in */*) ;; *) launch_model=$RA_PROVIDER/$launch_model;; esac
      ;;
  esac
  RA_ARGV=(--harness "$RA_HARNESS" --model "$launch_model" --effort "$RA_EFFORT")
  return 0
}

_router_parse_wait() {
  local line=$1 tabs binding remainder reason exhaustion expected
  tabs=${line//[^$'\t']/}
  [ "${#tabs}" -eq 7 ] || return 1
  binding=${line%%$'\t'*}
  [ "$binding" = WAIT ] || return 1
  remainder=${line#*$'\t'}
  reason=${remainder%%$'\t'*}
  exhaustion=${line##*$'\t'}
  expected=WAIT$'\t'$reason$'\t\t\t\t\t\t'$exhaustion
  [ "$line" = "$expected" ] || return 1
  python3 -c 'import json,sys; x=json.loads(sys.argv[1]); raise SystemExit(not isinstance(x,list))' \
    "$exhaustion" >/dev/null 2>&1 || return 1
  RA_REASON=$reason
  RA_EXHAUSTED_JSON=$exhaustion
  return 0
}

_router_pick_command() {
  local command=$1 task=$2 kind=$3 role=$4 host=$5 live=$6 only=${7:-}
  local out rc meta
  _router_clear_admission
  [ ! -e "$FM_HOME/data/router-off" ] || return 75
  _router_safe_id "$task" || return 75
  _router_safe_id "$kind" || return 75
  _router_safe_id "$role" || return 75
  case "$host" in netcup|bosgame) ;; *) return 75;; esac
  case "$live" in yes|no) ;; *) return 75;; esac
  if [ -n "$only" ]; then _router_safe_id "$only" || return 75; fi
  meta=$FM_HOME/state/$task.meta
  RA_META_BEFORE=$(_router_meta_fingerprint "$meta") || RA_META_BEFORE=unreadable
  RA_ADMITTED_AT=$(date +%s) || return 75
  if [ -n "$only" ]; then
    if out=$(python3 "$ROUTER_POLICY" "$command" "$task" "$kind" "$role" "$host" "$live" "$only" 2>/dev/null); then
      rc=0
    else
      rc=$?
    fi
  else
    if out=$(python3 "$ROUTER_POLICY" "$command" "$task" "$kind" "$role" "$host" "$live" 2>/dev/null); then
      rc=0
    else
      rc=$?
    fi
  fi
  [ "$rc" -eq 0 ] || { _router_clear_admission; return 75; }
  case "$out" in *$'\n'*|*$'\r'*) _router_clear_admission; return 75;; esac
  _router_parse_wait "$out" && return 75
  _router_parse_pick "$out" || { _router_clear_admission; return 75; }
  RA_TASK=$task RA_KIND=$kind RA_ROLE=$role RA_HOST=$host
  return 0
}

# router_admit TASK KIND ROLE HOST yes|no [ONLY_BINDING]
router_admit() {
  [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || { _router_clear_admission; return 75; }
  _router_pick_command route-admit "$@"
}

# Same tuple contract as router_admit, without creating a reservation/sidecar.
# Used by dry-runs and live-worker GO checks.
router_check() {
  [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || { _router_clear_admission; return 75; }
  _router_pick_command route-check "$@"
}

# Classify actual task text plus its labels. Empty/malformed evidence is WAIT.
# Usage: router_classify_task TEXT [LABELS_JSON]
router_classify_task() {
  [ "$#" -ge 1 ] && [ -n "$1" ] || { printf '%s\n' WAIT; return 75; }
  local text=$1 labels=${2:-[]} out rc
  if out=$(python3 "$ROUTER_POLICY" route-classify --labels-json "$labels" --text "$text" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] && { [ "$out" = yes ] || [ "$out" = no ]; } || {
    printf '%s\n' WAIT
    return 75
  }
  printf '%s\n' "$out"
}

# Convert current tracker rows (one JSON object per line) into the label array
# supplied to the credential classifier.  Every row must carry a JSON list of
# string labels: omitting that evidence is unknown, never credential-free.
router_labels_from_rows() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 75
  printf '%s' "$1" | python3 -c '
import json, sys
labels = []
for raw in sys.stdin:
    if not raw.strip():
        raise SystemExit(75)
    row = json.loads(raw)
    if not isinstance(row, dict) or "labels" not in row:
        raise SystemExit(75)
    row_labels = row["labels"]
    if not isinstance(row_labels, list) or any(not isinstance(label, str) for label in row_labels):
        raise SystemExit(75)
    labels.extend(row_labels)
print(json.dumps(labels, separators=(",", ":")))
' || return 75
}

_router_meta_value() {
  local path=$1 key=$2 line value= count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=}; count=$((count + 1));;
    esac
  done < "$path"
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$value"
}

# The canonical fm-crew-state record is one "state:" row.  Wrappers may add
# context lines, but two state rows are contradictory and therefore fail
# closed.  The short alive/1 forms are reserved for argv-safe probe stubs.
_router_alive_positive() {
  local output=$1 line state_rows=0 positive_rows=0
  case "$output" in alive|1) return 0;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state:\ *)
        state_rows=$((state_rows + 1))
        case "$line" in
          state:\ working\ ·\ source:\ *|state:\ parked\ ·\ source:\ *)
            positive_rows=$((positive_rows + 1))
            ;;
        esac
        ;;
    esac
  done <<<"$output"
  [ "$state_rows" -eq 1 ] && [ "$positive_rows" -eq 1 ]
}

# Verify a freshly republished task record and an independently alive endpoint.
# ROUTER_ALIVE_CMD is an argv-safe executable taking TASK and printing alive/1,
# or the standard fm-crew-state "state: working|parked" line.
router_verify_session() {
  [ "$#" -eq 2 ] || return 75
  local task=$1 launch_output=$2 meta now_fp mtime alive_cmd alive_out
  local hs= hp= zs= zp= ow= window= candidate=
  RV_SESSION=
  [ "$task" = "$RA_TASK" ] && [ -n "$RA_INCARNATION" ] || return 75
  meta=$FM_HOME/state/$task.meta
  [ -f "$meta" ] || return 75
  now_fp=$(_router_meta_fingerprint "$meta") || return 75
  [ "$now_fp" != "$RA_META_BEFORE" ] || return 75
  mtime=$(stat -c %Y -- "$meta" 2>/dev/null) || return 75
  [ "$mtime" -ge "$RA_ADMITTED_AT" ] || return 75
  hs=$(_router_meta_value "$meta" herdr_session 2>/dev/null) || hs=
  hp=$(_router_meta_value "$meta" herdr_pane_id 2>/dev/null) || hp=
  zs=$(_router_meta_value "$meta" zellij_session 2>/dev/null) || zs=
  zp=$(_router_meta_value "$meta" zellij_pane_id 2>/dev/null) || zp=
  ow=$(_router_meta_value "$meta" orca_worktree_id 2>/dev/null) || ow=
  window=$(_router_meta_value "$meta" window 2>/dev/null) || window=
  if [ -n "$hs" ] && [ -n "$hp" ]; then
    _router_safe_id "$hs" && _router_safe_id "$hp" || return 75
    candidate=herdr:$hs:$hp
  elif [ -n "$zs" ] && [ -n "$zp" ]; then
    _router_safe_id "$zs" && _router_safe_id "$zp" || return 75
    candidate=zellij:$zs:$zp
  elif [ -n "$ow" ]; then
    _router_safe_id "$ow" || return 75
    candidate=orca:$ow
  elif [ -n "$window" ]; then
    _router_safe_id "$window" || return 75
    candidate=$window
  else
    # endpoint_task_id is the synthetic task id and is never session proof.
    return 75
  fi
  _router_safe_id "$candidate" || return 75
  # fm-spawn names window=; fm-control relaunch names endpoint=. The caller
  # passes stdout only after a zero exit, binding that success to this endpoint.
  case " $launch_output " in
    *" window=$window "*|*" endpoint=$window "*) [ -n "$window" ] || return 75;;
    *)
      # Backends with composite endpoint metadata may print that exact session.
      case " $launch_output " in *" session=$candidate "*|*" endpoint=$candidate "*) ;; *) return 75;; esac
      ;;
  esac
  alive_cmd=${ROUTER_ALIVE_CMD:-$FM_HOME/bin/fm-crew-state.sh}
  [ -x "$alive_cmd" ] || return 75
  alive_out=$("$alive_cmd" "$task" 2>/dev/null) || return 75
  _router_alive_positive "$alive_out" || return 75
  RV_SESSION=$candidate
  return 0
}

router_confirm() {
  [ "$#" -eq 1 ] || [ "$#" -eq 2 ] || return 75
  local task=$1 session=${2:-$RV_SESSION}
  [ "$task" = "$RA_TASK" ] || return 75
  _router_safe_id "$RA_INCARNATION" && _router_safe_id "$session" || return 75
  python3 "$ROUTER_POLICY" route-confirm "$task" "$RA_INCARNATION" "$session" \
    >/dev/null 2>&1 || return 75
}

# A provider returned a verified-looking session, but durable confirmation
# failed. Preserve the reservation for reconciliation; never cancel/relaunch.
router_ambiguous() {
  [ "$#" -eq 2 ] || return 75
  [ "$1" = "$RA_TASK" ] || return 75
  _router_safe_id "$RA_INCARNATION" && _router_safe_id "$2" || return 75
  python3 "$ROUTER_POLICY" route-ambiguous "$1" "$RA_INCARNATION" "$2" \
    >/dev/null 2>&1 || return 75
}

router_confirm_verified() {
  [ "$#" -eq 2 ] || return 75
  router_verify_session "$1" "$2" || return 75
  router_confirm "$1" "$RV_SESSION"
}

# Explicit name used by launch wrappers: TASK plus zero-exit launcher stdout.
router_verify_spawn() { router_verify_session "$@"; }

router_failure() {
  [ "$#" -ge 4 ] || return 75
  local task=$1 event=$2 status=$3
  shift 3
  [ "$task" = "$RA_TASK" ] || return 75
  _router_safe_id "$RA_INCARNATION" && _router_safe_id "$event" || return 75
  python3 "$ROUTER_POLICY" route-failure "$task" "$RA_INCARNATION" "$event" "$status" "$@" \
    >/dev/null 2>&1 || return 75
}

router_cancel() {
  [ "$#" -eq 1 ] || [ "$#" -eq 2 ] || return 75
  [ "$1" = "$RA_TASK" ] && _router_safe_id "$RA_INCARNATION" || return 75
  [ "$#" -eq 1 ] || [ "$2" = "$RA_INCARNATION" ] || return 75
  python3 "$ROUTER_POLICY" route-cancel "$1" "$RA_INCARNATION" >/dev/null 2>&1 || return 75
}
