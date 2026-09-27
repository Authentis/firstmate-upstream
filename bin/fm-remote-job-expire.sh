#!/usr/bin/env bash
# List or explicitly expire old remote job records that cannot be pending.
#
# Usage: fm-remote-job-expire.sh --dry-run|--apply [--older-than SECONDS]
#
# This is an operator cleanup for abandoned records, not a worker maintenance
# pass.  The worker continues to reap only completed records automatically.
# This command considers a record only after its directory is older than the
# threshold, its state is not queued or running, and it has no claim directory.
# Those conditions exclude every record a worker could still execute.  The
# default is seven days; use --dry-run to inspect the exact candidates before
# passing --apply.  The queue root is the account default or
# FM_REMOTE_JOB_STATE_ROOT for an explicitly selected account.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

MODE=
OLDER_THAN=604800

expire_die() { printf 'fm-remote-job-expire: %s\n' "$1" >&2; exit 2; }

expire_usage() {
  cat <<'TXT'
Usage: fm-remote-job-expire.sh --dry-run|--apply [--older-than SECONDS]

List, or explicitly remove, old remote job records that are neither queued nor
running and have no claim directory.  --dry-run changes nothing.  --apply is
the only deletion mode.  SECONDS defaults to 604800 (seven days).
TXT
}

expire_candidate() { # <job-dir> <now>
  local job=$1 now=$2 state mtime age
  [ -d "$job" ] && [ ! -L "$job" ] || return 1
  [ ! -L "$job/state" ] || return 1
  [ ! -e "$job/.claim" ] && [ ! -L "$job/.claim" ] || return 1
  state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
  case "$state" in queued|running) return 1 ;; esac
  mtime=$(fm_remote_job_path_mtime "$job" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  age=$((now - mtime))
  [ "$age" -ge "$OLDER_THAN" ] || return 1
  printf '%s\n' "$age"
}

expire_records() {
  local account_home=$1 now job age
  fm_remote_job_prepare_state "$account_home" || expire_die "${FM_REMOTE_JOB_ERROR:-cannot prepare remote job state}"
  now=$(date +%s)
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    age=$(expire_candidate "$job" "$now") || continue
    if [ "$MODE" = dry-run ]; then
      printf 'would expire remote job record %s (age %ss)\n' "$job" "$age"
    else
      rm -rf -- "$job" || expire_die "cannot expire $job"
      printf 'expired remote job record %s (age %ss)\n' "$job" "$age"
    fi
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|--apply)
      [ -z "$MODE" ] || expire_die "choose exactly one mode"
      MODE=${1#--}
      ;;
    --older-than)
      shift
      [ "$#" -gt 0 ] || expire_die "--older-than needs seconds"
      OLDER_THAN=$1
      ;;
    -h|--help) expire_usage; exit 0 ;;
    *) expire_die "unexpected argument: $1" ;;
  esac
  shift
done

[ -n "$MODE" ] || expire_die "choose --dry-run or --apply"
case "$OLDER_THAN" in ''|*[!0-9]*|0) expire_die "--older-than must be a positive integer" ;; esac

expire_records "${HOME:-}"
