#!/usr/bin/env bash
# fm-spawn-admission-lib.sh - fresh-spawn admission helpers for bin/fm-spawn.sh.
#
# Sourced by fm-spawn.sh, which owns the globals these read (ADMISSION_OVERRIDE,
# ADMISSION_OVERRIDE_REASON, ID, KIND, RELAUNCH, STATE, CONFIG, SCRIPT_DIR).
# Kept out of fm-spawn.sh so ShellCheck stays under bin/fm-lint.sh's memory
# ceiling.  The admission contract itself is documented in fm-spawn.sh's header.
# shellcheck disable=SC2153 # KIND and the other globals are assigned by fm-spawn.sh
record_admission_override() {
  [ "$ADMISSION_OVERRIDE" -eq 0 ] && return 0
  [ -n "$ADMISSION_OVERRIDE_REASON" ] || {
    echo "error: --admission-override requires a non-empty reason" >&2
    exit 1
  }
  printf 'paused [at=%s]: admission override used task=%s reason=%s\n' \
    "$(date +%s)" "$ID" "$ADMISSION_OVERRIDE_REASON" >> "$STATE/overlay-events.log"
}

# Fresh ordinary workers consume the finite local RAM and endpoint budget.
# Config files are intentionally tiny one-value contracts so an operator can
# tune the overlay without making a spawn silently guess a malformed value.
spawn_admission_uint() { # <config-name> <default>
  local name=$1 default=$2 value path
  path="$CONFIG/$name"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || {
    echo "error: config/$name must be a readable regular file" >&2
    return 1
  }
  value=$(tr -d '[:space:]' < "$path")
  case "$value" in ''|*[!0-9]*)
    echo "error: config/$name must contain one whole number" >&2
    return 1
    ;;
  esac
  printf '%s\n' "$value"
}

spawn_resident_agents() {
  local meta task kind agent
  SPAWN_RESIDENT_AGENTS=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=$(basename "$meta" .meta)
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    [ "$kind" != secondmate ] || continue
    if fm_backend_validate_task_endpoint "$meta" "$task" >/dev/null 2>&1; then
      agent=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")
      # Only a recovery-grade dead or missing verdict proves that this home no
      # longer has an agent at the endpoint.  Treat every other runtime read
      # conservatively: an unavailable liveness probe must not create an eighth
      # lane beside a possibly live worker.
      case "$agent" in
        dead|missing) ;;
        *) SPAWN_RESIDENT_AGENTS=$((SPAWN_RESIDENT_AGENTS + 1)) ;;
      esac
    fi
  done
}

spawn_refuse_if_admission_exhausted() {
  local min_gb max_agents available_kib min_kib
  [ "$RELAUNCH" -ne 1 ] || return 0
  [ "$KIND" != secondmate ] || return 0
  [ "$ADMISSION_OVERRIDE" -eq 0 ] || return 0
  min_gb=$(spawn_admission_uint admission-min-ram-gb 3) || exit 1
  max_agents=$(spawn_admission_uint admission-max-agents 7) || exit 1
  available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  case "$available_kib" in ''|*[!0-9]*)
    echo "error: spawn refused - MemAvailable could not be measured for admission" >&2
    exit 1
    ;;
  esac
  min_kib=$((min_gb * 1024 * 1024))
  if [ "$available_kib" -lt "$min_kib" ]; then
    echo "error: spawn refused - available RAM is ${available_kib} KiB; admission requires at least ${min_gb} GiB (${min_kib} KiB)" >&2
    exit 1
  fi
  spawn_resident_agents
  if [ "$SPAWN_RESIDENT_AGENTS" -ge "$max_agents" ]; then
    echo "error: spawn refused - resident agents are $SPAWN_RESIDENT_AGENTS; admission allows fewer than $max_agents" >&2
    exit 1
  fi
}

spawn_refuse_if_leaf_unavailable() { # <project-path>
  local enabled path output rc
  [ "$RELAUNCH" -ne 1 ] || return 0
  [ "$KIND" != secondmate ] || return 0
  [ "$ADMISSION_OVERRIDE" -eq 0 ] || return 0
  case "$ID" in dos-product-*) ;; *) return 0 ;; esac
  path="$CONFIG/leaf-admission"
  enabled=on
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || {
      echo "error: config/leaf-admission must be a readable regular file" >&2
      exit 1
    }
    enabled=$(tr -d '[:space:]' < "$path")
    case "$enabled" in
      on|off) ;;
      *) echo "error: config/leaf-admission must be on or off" >&2; exit 1 ;;
    esac
  fi
  [ "$enabled" = on ] || return 0
  if output=$("$SCRIPT_DIR/fm-leaf-supply.sh" "$1" --check "$ID" 2>&1); then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 10 ]; then
    echo "error: spawn refused - leaf admission for $ID: $output" >&2
  else
    echo "error: spawn refused - leaf admission could not verify $ID: $output" >&2
  fi
  exit 1
}
