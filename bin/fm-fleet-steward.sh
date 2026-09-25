#!/usr/bin/env bash
# fm-fleet-steward.sh - keep one verified ready queue and wake a home when its
# productive fleet stays below the refill threshold.
#
# Usage:
#   fm-fleet-steward.sh refresh
#   fm-fleet-steward.sh check
#   fm-fleet-steward.sh exempt <task-id> --state <state> --detail-file <path>
#   fm-fleet-steward.sh park-preserved
#   fm-fleet-steward.sh parked-review
#   fm-fleet-steward.sh arm
#   fm-fleet-steward.sh disarm
#   fm-fleet-steward.sh --help
#
# `refresh` reads config/fleet-steward.json, refreshes the configured project's
# origin/main, reads `br ready`, and verifies every candidate against merged pull
# requests, origin/main, this home's in-flight records, and the config's explicit
# captain/deferred exclusions.
# It atomically replaces data/next-up.md only after every source succeeds.
#
# `check` reads the newest lane-reaper summary from the configured capacity log.
# It prints one line only after productive lanes have stayed below six for at
# least fifteen minutes while the generated queue contains READY rows.
# The episode record is durable, emits once, and resets on healthy, uncertain,
# stale, or no-ready state.
#
# `exempt` records one guarded-teardown refusal in the existing
# state/steward-exemptions.json schema so finish-then-refill can preserve the
# task without hiding or overwriting sibling rows.
# It re-reads the task through fm-crew-state.sh, refuses unless that reconciled
# state still equals --state, and records the exact observed state and detail
# with a child-state hold identity, because fm-fleet-snapshot.sh matches an
# exemption only against that exact observation; the refusal text is kept in
# the reason and refusal fields.
#
# `park-preserved` is the automatic park trigger: it reads a fresh
# fm-fleet-snapshot.sh --json and runs `fm-teardown.sh <id> --park` for every
# ship task classified parked_preserved (worker exited, hold declared), one line
# per task: `parked: <id>`, `landed: <id>` when park handed landed work to the
# ordinary cleanup, or `park refused: <id>: <reason>`. A refusal leaves that task
# exactly as it was and does not stop the others; the exit is 1 when any task
# was refused or the snapshot could not be read. fm-teardown.sh's header owns
# what park saves and refuses.
#
# `parked-review` raises the one batched captain question about parked work
# nobody resumed. Parked work is never dropped automatically. A parked item is a
# data/<id>/park/receipt whose parked_at is at least 14 days old
# (FM_FLEET_STEWARD_PARKED_AGE_DAYS), whose task has no live record, and whose
# backlog row is still open. At most once per 14 days (the durable last-asked
# epoch in state/.fleet-steward-parked-review) and only when such items exist,
# it files one captain-held backlog item, parked-review-<YYYYMMDD>, listing
# every one of them through fm-captain-hold.sh, prints its id and the list, and
# only then records the ask. Otherwise it prints nothing and changes nothing.
#
# `arm` installs and registers state/fleet-steward.check.sh in this exact home,
# writes the user units next-up-refresh.service and next-up-refresh.timer, and
# enables the persistent thirty-minute timer.
# The generated service unit carries `Environment=PATH=...` copied from the
# arming shell's own PATH, because a user systemd unit does not inherit the
# login PATH, so the scheduled refresh can otherwise fail to find tools such
# as `br` that only resolve through login-shell PATH entries.
# `disarm` retires the check through fm-check-unregister.sh and disables only
# those two named units.
#
# A failed `refresh` writes a durable failure record
# (state/.fleet-steward-refresh-failure) instead of only exiting nonzero, and
# the registered `check` surfaces each new failure once as a wake so a broken
# scheduled refresh is never silently mistaken for an empty ready queue.
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-steward.json"
QUEUE="${FM_DATA_OVERRIDE:-$FM_HOME/data}/next-up.md"
LOW_RECORD="$STATE/.fleet-steward-low"
FAILURE_RECORD="$STATE/.fleet-steward-refresh-failure"
FAILURE_REPORTED="$STATE/.fleet-steward-refresh-failure-reported"
CHECK_ID=fleet-steward
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
SYSTEMD_USER_DIR="${FM_SYSTEMD_USER_DIR_OVERRIDE:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
SYSTEMCTL="${FM_SYSTEMCTL:-systemctl}"
SNAPSHOT_BIN="${FM_FLEET_STEWARD_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
TEARDOWN_BIN="${FM_FLEET_STEWARD_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
PARKED_REVIEW_RECORD="$STATE/.fleet-steward-parked-review"
PARKED_AGE_DAYS="${FM_FLEET_STEWARD_PARKED_AGE_DAYS:-14}"
GRACE_SECONDS="${FM_FLEET_STEWARD_GRACE_SECONDS:-900}"
PRODUCTIVE_MIN="${FM_FLEET_STEWARD_PRODUCTIVE_MIN:-6}"
CAPACITY_MAX_AGE="${FM_FLEET_STEWARD_CAPACITY_MAX_AGE:-1200}"

usage() {
  sed -n '2,/^set -u/{/^set -u/!p}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fm-fleet-steward: %s\n' "$1" >&2
  return 1
}

require_uint() {
  case "$2" in
    ''|*[!0-9]*) fail "$1 must be a whole number" ;;
    *) return 0 ;;
  esac
}

config_validate() {
  command -v jq >/dev/null 2>&1 || { fail "jq is required"; return 1; }
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || { fail "config is unavailable at $CONFIG"; return 1; }
  jq -e '
    type == "object"
    and .schema == "fm-fleet-steward.v1"
    and (.project_path | type == "string" and startswith("/"))
    and (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
    and (.capacity_log | type == "string" and startswith("/"))
    and (.exclusions | type == "array")
    and all(.exclusions[];
      type == "object"
      and (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      and (.kind == "captain" or .kind == "deferred")
      and (.reason | type == "string" and length > 0))
  ' "$CONFIG" >/dev/null 2>&1 || { fail "config does not match fm-fleet-steward.v1"; return 1; }
}

config_value() {
  jq -r "$1" "$CONFIG"
}

record_epoch_now() {
  case "${FM_FLEET_STEWARD_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FLEET_STEWARD_NOW" ;;
  esac
}

title_one_line() {
  printf '%s' "$1" | tr '\t\r\n|' '     ' | sed 's/  */ /g; s/^ //; s/ $//'
}

decode_base64() {
  local value=$1
  if printf '%s\n' "$value" | base64 --decode 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$value" | base64 -D 2>/dev/null
}

epoch_from_iso() {
  local value=$1
  if date -u -d "$value" +%s 2>/dev/null; then
    return 0
  fi
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null
}

date_plus_thirty_days() {
  local value=$1
  if date -u -d "$value +30 days" +%Y-%m-%d 2>/dev/null; then
    return 0
  fi
  date -j -u -f '%Y-%m-%d' -v+30d "$value" +%Y-%m-%d 2>/dev/null
}

id_excluded() {
  jq -e --arg id "$1" 'any(.exclusions[]; .id == $id)' "$CONFIG" >/dev/null
}

id_in_flight() {
  local id=$1 meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(basename "$meta" .meta)" = "$id" ] && return 0
  done
  return 1
}

id_in_merged_prs() {
  local id=$1 merged_tokens=$2
  grep -Fxq -- "$id" "$merged_tokens"
}

id_on_main() {
  local id=$1 main_log=$2
  grep -Fxq -- "br:$id" "$main_log"
}

failure_record_write() {
  local reason=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.fleet-steward-refresh-failure.XXXXXX") || return 1
  {
    printf 'fm-fleet-steward-refresh-failure.v1\n'
    printf 'at=%s\n' "$(record_epoch_now)"
    printf 'reason=%s\n' "$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FAILURE_RECORD"
}

failure_record_clear() {
  rm -f -- "$FAILURE_RECORD" "$FAILURE_REPORTED"
}

failure_record_read() {
  local version at_line reason_line
  FAILURE_AT=
  FAILURE_REASON=
  [ -f "$FAILURE_RECORD" ] && [ ! -L "$FAILURE_RECORD" ] || return 1
  {
    IFS= read -r version
    IFS= read -r at_line
    IFS= read -r reason_line
  } < "$FAILURE_RECORD" || return 1
  [ "$version" = fm-fleet-steward-refresh-failure.v1 ] || return 1
  FAILURE_AT=${at_line#at=}
  FAILURE_REASON=${reason_line#reason=}
  require_uint at "$FAILURE_AT" >/dev/null 2>&1 || return 1
  [ -n "$FAILURE_REASON" ] || return 1
}

refresh_fail() {
  fail "$1"
  failure_record_write "$1" || true
  return 1
}

action_refresh() {
  local project repository tmpdir ready_json prs_raw merged_tokens main_log candidates output
  local row id title priority issue_type status labels normalized
  config_validate || { failure_record_write "config does not match fm-fleet-steward.v1"; return 1; }
  for tool in br git gh-axi jq base64 sort; do
    command -v "$tool" >/dev/null 2>&1 || { refresh_fail "required tool not found: $tool"; return 1; }
  done
  project=$(config_value '.project_path')
  repository=$(config_value '.repository')
  [ -d "$project" ] || { refresh_fail "project path is unavailable: $project"; return 1; }
  [ -d "$(dirname "$QUEUE")" ] || { refresh_fail "queue directory is unavailable: $(dirname "$QUEUE")"; return 1; }
  [ -d "$STATE" ] || { refresh_fail "state directory is unavailable: $STATE"; return 1; }

  tmpdir=$(mktemp -d "$STATE/.fleet-steward-refresh.XXXXXX") \
    || { refresh_fail "could not create refresh scratch directory"; return 1; }
  ready_json="$tmpdir/ready.json"
  prs_raw="$tmpdir/prs-raw.json"
  merged_tokens="$tmpdir/merged-tokens"
  main_log="$tmpdir/main.log"
  candidates="$tmpdir/candidates.tsv"
  output="$tmpdir/next-up.md"
  trap 'rm -rf -- "$tmpdir"' EXIT HUP INT TERM

  git -C "$project" fetch origin main >/dev/null 2>&1 \
    || { refresh_fail "could not refresh origin/main"; return 1; }
  (cd "$project" && br ready --json --no-auto-flush --no-auto-import) > "$ready_json" 2>/dev/null \
    || { refresh_fail "br ready failed"; return 1; }
  jq -e 'type == "array"' "$ready_json" >/dev/null 2>&1 \
    || { refresh_fail "br ready returned invalid JSON"; return 1; }
  gh-axi api --full --paginate "/repos/$repository/pulls?state=closed&per_page=100" \
    --jq '[.[] | select(.merged_at != null) | ((.title // "") + " " + (.head.ref // "")) | splits("[^A-Za-z0-9_.-]+") | select(length > 0)] | unique | .[]' \
    > "$prs_raw" 2>/dev/null \
    || { refresh_fail "merged pull request verification failed"; return 1; }
  grep -Fxq '  truncated: false' "$prs_raw" \
    || { refresh_fail "merged pull request verification returned invalid JSON"; return 1; }
  sed -n 's/^  body: //p' "$prs_raw" | jq -r . > "$merged_tokens" 2>/dev/null \
    || { refresh_fail "merged pull request verification returned invalid JSON"; return 1; }
  git -C "$project" log origin/main --format='%s%n%b' > "$main_log" 2>/dev/null \
    || { refresh_fail "origin/main verification failed"; return 1; }

  : > "$candidates"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    normalized=$(decode_base64 "$row") || { refresh_fail "could not decode br ready row"; return 1; }
    id=$(printf '%s' "$normalized" | jq -r '.id // empty')
    title=$(printf '%s' "$normalized" | jq -r '.title // empty')
    priority=$(printf '%s' "$normalized" | jq -r '.priority // 999')
    issue_type=$(printf '%s' "$normalized" | jq -r '.issue_type // empty')
    status=$(printf '%s' "$normalized" | jq -r '.status // empty')
    labels=$(printf '%s' "$normalized" | jq -r '[.labels[]?] | join("\n")')
    [ -n "$id" ] && [ -n "$title" ] || continue
    [ "$status" = open ] || continue
    [ "$issue_type" != epic ] || continue
    printf '%s\n' "$labels" | grep -Eq '(^|\n)(gate-[^[:space:]]*|deferred)($|\n)' && continue
    id_excluded "$id" && continue
    id_in_flight "$id" && continue
    id_in_merged_prs "$id" "$merged_tokens" && continue
    id_on_main "$id" "$main_log" && continue
    case "$priority" in ''|*[!0-9]*) priority=999 ;; esac
    title=$(title_one_line "$title")
    printf '%s\t%s\t%s\n' "$priority" "$id" "$title" >> "$candidates"
  done < <(jq -r '.[] | @base64' "$ready_json")

  {
    printf '# Next up - generated %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf "Source: verified \`br ready\`, current \`origin/main\`, merged pull requests, in-flight records, and explicit captain/deferred exclusions.\n\n"
    sort -t "$(printf '\t')" -k1,1n -k2,2 "$candidates" \
      | while IFS="$(printf '\t')" read -r _priority id title; do
          printf -- '- READY %s | acceptance: %s | preconditions: br ready verified; origin/main and merged pull requests clear\n' "$id" "$title"
        done
  } > "$output" || { refresh_fail "could not render queue"; return 1; }
  chmod 0600 "$output" || { refresh_fail "could not secure generated queue"; return 1; }
  mv -f -- "$output" "$QUEUE" || { refresh_fail "could not publish queue"; return 1; }
  trap - EXIT HUP INT TERM
  rm -rf -- "$tmpdir"
  failure_record_clear
}

capacity_read() {
  local log=$1 line timestamp
  CAPACITY_EPOCH=
  CAPACITY_PRODUCTIVE=
  CAPACITY_UNCERTAIN=
  [ -f "$log" ] && [ ! -L "$log" ] || return 1
  line=$(grep 'lane-reaper: summary:' "$log" | tail -n 1) || return 1
  timestamp=${line%% *}
  CAPACITY_EPOCH=$(epoch_from_iso "$timestamp") || return 1
  CAPACITY_PRODUCTIVE=$(printf '%s\n' "$line" | sed -n 's/.* productive=\([0-9][0-9]*\).*/\1/p')
  CAPACITY_UNCERTAIN=$(printf '%s\n' "$line" | sed -n 's/.* uncertain=\([0-9][0-9]*\).*/\1/p')
  require_uint productive "$CAPACITY_PRODUCTIVE" >/dev/null 2>&1 || return 1
  require_uint uncertain "$CAPACITY_UNCERTAIN" >/dev/null 2>&1 || return 1
}

low_record_write() {
  local start=$1 emitted=$2 tmp
  tmp=$(umask 077; mktemp "$STATE/.fleet-steward-low.XXXXXX") || return 1
  {
    printf 'fm-fleet-steward-low.v1\n'
    printf 'start=%s\n' "$start"
    printf 'emitted=%s\n' "$emitted"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$LOW_RECORD"
}

low_record_read() {
  local version start_line emitted_line
  LOW_START=
  LOW_EMITTED=
  [ -f "$LOW_RECORD" ] && [ ! -L "$LOW_RECORD" ] || return 1
  {
    IFS= read -r version
    IFS= read -r start_line
    IFS= read -r emitted_line
    if IFS= read -r; then return 1; fi
  } < "$LOW_RECORD" || return 1
  [ "$version" = fm-fleet-steward-low.v1 ] || return 1
  LOW_START=${start_line#start=}
  LOW_EMITTED=${emitted_line#emitted=}
  require_uint start "$LOW_START" >/dev/null 2>&1 || return 1
  case "$LOW_EMITTED" in 0|1) : ;; *) return 1 ;; esac
}

episode_reset() {
  [ ! -e "$LOW_RECORD" ] || rm -f -- "$LOW_RECORD"
}

action_check() {
  local capacity_log now ready age reported=
  if failure_record_read; then
    [ -f "$FAILURE_REPORTED" ] && reported=$(cat "$FAILURE_REPORTED" 2>/dev/null)
    if [ "$reported" != "$FAILURE_AT" ]; then
      printf 'fleet-steward: refresh failed at=%s: %s\n' "$FAILURE_AT" "$FAILURE_REASON"
      printf '%s\n' "$FAILURE_AT" > "$FAILURE_REPORTED" 2>/dev/null || true
      return 0
    fi
  fi
  config_validate || return 0
  require_uint FM_FLEET_STEWARD_GRACE_SECONDS "$GRACE_SECONDS" >/dev/null 2>&1 || return 0
  require_uint FM_FLEET_STEWARD_PRODUCTIVE_MIN "$PRODUCTIVE_MIN" >/dev/null 2>&1 || return 0
  require_uint FM_FLEET_STEWARD_CAPACITY_MAX_AGE "$CAPACITY_MAX_AGE" >/dev/null 2>&1 || return 0
  capacity_log=$(config_value '.capacity_log')
  now=$(record_epoch_now)
  capacity_read "$capacity_log" || { episode_reset; return 0; }
  age=$((now - CAPACITY_EPOCH))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$CAPACITY_MAX_AGE" ] || [ "$CAPACITY_UNCERTAIN" -ne 0 ]; then
    episode_reset
    return 0
  fi
  ready=0
  if [ -f "$QUEUE" ]; then
    ready=$(grep -c '^- READY ' "$QUEUE" 2>/dev/null || true)
  fi
  if [ "$ready" -eq 0 ] || [ "$CAPACITY_PRODUCTIVE" -ge "$PRODUCTIVE_MIN" ]; then
    episode_reset
    return 0
  fi
  if ! low_record_read || [ "$now" -lt "$LOW_START" ]; then
    low_record_write "$now" 0 || true
    return 0
  fi
  [ "$LOW_EMITTED" -eq 0 ] || return 0
  [ $((now - LOW_START)) -ge "$GRACE_SECONDS" ] || return 0
  printf 'fleet-steward: productive=%s ready=%s low_since=%s action=finish-then-refill\n' \
    "$CAPACITY_PRODUCTIVE" "$ready" "$LOW_START"
  low_record_write "$LOW_START" 1 || true
}

action_exempt() {
  local id=${1:-} state detail_file detail today expires reason steward tmp jq_input
  local observed observed_state observed_detail sep=' · '
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state)
        [ "$#" -ge 2 ] || { fail "--state requires a value"; return 2; }
        state=$2
        shift 2
        ;;
      --detail-file)
        [ "$#" -ge 2 ] || { fail "--detail-file requires a path"; return 2; }
        detail_file=$2
        shift 2
        ;;
      *) fail "unknown exempt argument: $1"; return 2 ;;
    esac
  done
  case "$id" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) fail "invalid task id"; return 2 ;; esac
  case "$state" in done|failed|unknown|stopped) : ;; *) fail "invalid refused task state"; return 2 ;; esac
  [ -f "$detail_file" ] && [ ! -L "$detail_file" ] \
    || { fail "detail file is unavailable"; return 1; }
  [ "$(wc -c < "$detail_file" | tr -d ' ')" -le 8192 ] \
    || { fail "detail file exceeds 8192 bytes"; return 1; }
  detail=$(tr '\t\r\n' '   ' < "$detail_file" | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$detail" ] || { fail "detail file is empty"; return 1; }
  observed=$(env -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE \
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -n 1)
  case "$observed" in
    "state: "*"${sep}source: "*"$sep"*) : ;;
    *) fail "could not read the reconciled task state"; return 1 ;;
  esac
  observed_state=${observed#state: }
  observed_state=${observed_state%%"$sep"*}
  observed_detail=${observed#*"${sep}source: "}
  observed_detail=${observed_detail#*"$sep"}
  [ "$observed_state" = "$state" ] \
    || { fail "reconciled state is now $observed_state, not $state"; return 1; }
  [ -n "$observed_detail" ] || { fail "reconciled state has no detail to bind"; return 1; }
  today=${FM_FLEET_STEWARD_TODAY:-$(date -u +%Y-%m-%d)}
  case "$today" in ????-??-??) : ;; *) fail "invalid steward date"; return 1 ;; esac
  expires=$(date_plus_thirty_days "$today") \
    || { fail "could not calculate steward exemption expiry"; return 1; }
  reason="Held external record: guarded teardown refused while reconciled state was $state; $detail"
  steward="$STATE/steward-exemptions.json"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { fail "state directory is unavailable"; return 1; }
  [ ! -L "$steward" ] || { fail "steward exemption path is unsafe"; return 1; }
  tmp=$(umask 077; mktemp "$STATE/.steward-exemptions.XXXXXX") || return 1
  if [ -f "$steward" ]; then
    jq -e '.schema == "fm-steward-exemptions.v1" and (.exemptions | type == "array")' "$steward" >/dev/null 2>&1 \
      || { rm -f -- "$tmp"; fail "existing steward exemptions are invalid"; return 1; }
    jq_input=$steward
  else
    jq_input=$(umask 077; mktemp "$STATE/.steward-exemptions-base.XXXXXX") \
      || { rm -f -- "$tmp"; fail "could not initialize steward exemptions"; return 1; }
    printf '{"schema":"fm-steward-exemptions.v1","exemptions":[]}\n' > "$jq_input" \
      || { rm -f -- "$tmp" "$jq_input"; fail "could not initialize steward exemptions"; return 1; }
    trap 'rm -f -- "$tmp" "$jq_input"' RETURN
  fi
  if ! jq --arg id "$id" --arg reason "$reason" --arg today "$today" \
      --arg expires "$expires" --arg detail "$detail" \
      --arg state "$observed_state" --arg observed "$observed_detail" '
        .exemptions |= (map(select(.task_id != $id)) + [{
          task_id:$id,
          reason:$reason,
          set_by:("fm-fleet-steward.sh " + $today),
          reviewed_date:$today,
          expires_on:$expires,
          state:$state,
          detail:$observed,
          refusal:$detail,
          hold_identity:{source:"child-state",kind:null,reason:$observed}
        }])
      ' "$jq_input" > "$tmp"; then
    rm -f -- "$tmp" "${jq_input:-}"
    fail "could not render steward exemption"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$steward" || { rm -f -- "$tmp"; return 1; }
  [ "$jq_input" = "$steward" ] || rm -f -- "$jq_input"
  trap - RETURN
  printf 'exempted: %s bound to reconciled state %s after guarded teardown refusal\n' "$id" "$observed_state"
}

action_park_preserved() {
  local snapshot ids id out rc=0
  command -v jq >/dev/null 2>&1 || { fail "jq is required"; return 1; }
  snapshot=$(FM_HOME="$FM_HOME" "$SNAPSHOT_BIN" --json 2>/dev/null) \
    || { fail "could not read a fresh fleet snapshot"; return 1; }
  ids=$(printf '%s\n' "$snapshot" | jq -r '
      .tasks[]? | select(.capacity.class == "parked_preserved" and ((.kind // "ship") == "ship")) | .id
    ' 2>/dev/null) || { fail "the fleet snapshot is unreadable"; return 1; }
  for id in $ids; do
    case "$id" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) continue ;; esac
    if out=$(FM_HOME="$FM_HOME" "$TEARDOWN_BIN" "$id" --park 2>&1); then
      case "$out" in
        *"park $id complete"*) printf 'parked: %s\n' "$id" ;;
        *) printf 'landed: %s\n' "$id" ;;
      esac
    else
      rc=1
      printf 'park refused: %s: %s\n' "$id" \
        "$(printf '%s\n' "$out" | grep -m 1 -E 'REFUSED|error' || printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  return "$rc"
}

# Parked items older than the review age: "<id>\t<parked_at>\t<branch>\t<head>".
parked_review_items() {
  local now=$1 data receipt id parked_at branch head row
  data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  for receipt in "$data"/*/park/receipt; do
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
    id=${receipt%/park/receipt}
    id=${id##*/}
    case "$id" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) continue ;; esac
    [ ! -e "$STATE/$id.meta" ] || continue
    parked_at=$(sed -n 's/^parked_at=//p' "$receipt" | head -n 1)
    case "$parked_at" in ''|*[!0-9]*) continue ;; esac
    [ $((now - parked_at)) -ge $((PARKED_AGE_DAYS * 86400)) ] || continue
    row=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" 2>/dev/null | sed -n 's/^  state: *//p' | head -n 1)
    case "$row" in ''|done*) continue ;; esac
    branch=$(sed -n 's/^branch=//p' "$receipt" | head -n 1)
    head=$(sed -n 's/^head=//p' "$receipt" | head -n 1)
    printf '%s\t%s\t%s\t%s\n' "$id" "$parked_at" "$branch" "$head"
  done
}

action_parked_review() {
  local now last items id parked_at branch head body review days
  require_uint FM_FLEET_STEWARD_PARKED_AGE_DAYS "$PARKED_AGE_DAYS" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { fail "state directory is unavailable: $STATE"; return 1; }
  now=$(record_epoch_now)
  if [ -e "$PARKED_REVIEW_RECORD" ] || [ -L "$PARKED_REVIEW_RECORD" ]; then
    [ -f "$PARKED_REVIEW_RECORD" ] && [ ! -L "$PARKED_REVIEW_RECORD" ] \
      || { fail "the parked-review record is unsafe"; return 1; }
    last=$(head -n 1 "$PARKED_REVIEW_RECORD")
    case "$last" in ''|*[!0-9]*) fail "the parked-review record is unreadable"; return 1 ;; esac
    [ $((now - last)) -ge $((PARKED_AGE_DAYS * 86400)) ] || return 0
  fi
  items=$(parked_review_items "$now")
  [ -n "$items" ] || return 0
  review="parked-review-$(date -u -r "$now" +%Y%m%d 2>/dev/null || date -u -d "@$now" +%Y%m%d)"
  body=$(umask 077; mktemp "$STATE/.fleet-steward-parked-review-body.XXXXXX") || return 1
  {
    printf '%s\n' "Parked work nobody has resumed for at least $PARKED_AGE_DAYS days. Nothing is dropped without the captain's word; for each item, resume it, keep it parked, or drop it."
    printf '\n'
    while IFS="$(printf '\t')" read -r id parked_at branch head; do
      days=$(( (now - parked_at) / 86400 ))
      printf -- '- %s: parked %s days, branch %s at %s, saved in data/%s/park/\n' "$id" "$days" "$branch" "$head" "$id"
    done <<EOF
$items
EOF
  } > "$body"
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$review" >/dev/null 2>&1; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" add "$review" "Parked work older than $PARKED_AGE_DAYS days" \
      --kind captain --body-file "$body" >/dev/null 2>&1 \
      || { rm -f -- "$body"; fail "could not file the parked-work review $review"; return 1; }
  fi
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" hold "$review" \
      --reason "Resume, keep parked, or drop each parked item listed" >/dev/null 2>&1; then
    rm -f -- "$body"
    fail "could not hold the parked-work review $review for the captain"
    return 1
  fi
  printf 'parked-review: %s\n' "$review"
  cat "$body"
  rm -f -- "$body"
  write_atomic "$PARKED_REVIEW_RECORD" 0600 "$now" \
    || { fail "the review $review is filed but its last-asked record could not be written"; return 1; }
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-fleet-steward.sh for this home.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-fleet-steward.sh") check"
}

write_atomic() {
  local path=$1 mode=$2 content=$3 dir tmp
  dir=$(dirname "$path")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.fleet-steward.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

service_content() {
  printf '%s\n' \
    '[Unit]' \
    'Description=Refresh the verified Firstmate next-up queue' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "Environment=FM_HOME=$FM_HOME" \
    "Environment=PATH=$PATH" \
    "ExecStart=$SCRIPT_DIR/fm-fleet-steward.sh refresh" \
    'Nice=19' \
    'IOSchedulingClass=best-effort' \
    'IOSchedulingPriority=7'
}

timer_content() {
  printf '%s\n' \
    '[Unit]' \
    'Description=Thirty-minute verified Firstmate next-up refresh' \
    '' \
    '[Timer]' \
    'OnActiveSec=1min' \
    'OnUnitActiveSec=30min' \
    'Persistent=true' \
    'RandomizedDelaySec=20' \
    '' \
    '[Install]' \
    'WantedBy=timers.target'
}

action_arm() {
  local service timer
  config_validate || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { fail "state directory is unavailable: $STATE"; return 1; }
  mkdir -p "$SYSTEMD_USER_DIR" || return 1
  [ -d "$SYSTEMD_USER_DIR" ] && [ ! -L "$SYSTEMD_USER_DIR" ] \
    || { fail "systemd user directory is unsafe"; return 1; }
  service="$SYSTEMD_USER_DIR/next-up-refresh.service"
  timer="$SYSTEMD_USER_DIR/next-up-refresh.timer"
  write_atomic "$CHECK_SHIM" 0700 "$(shim_content)" \
    || { fail "could not install the home-local check shim"; return 1; }
  if ! FM_HOME="$FM_HOME" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    fail "could not register the home-local check"
    return 1
  fi
  if ! write_atomic "$service" 0644 "$(service_content)" \
    || ! write_atomic "$timer" 0644 "$(timer_content)"; then
    FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
    rm -f -- "$service" "$timer"
    fail "could not install user timer units"
    return 1
  fi
  if ! "$SYSTEMCTL" --user daemon-reload \
    || ! "$SYSTEMCTL" --user enable --now next-up-refresh.timer; then
    "$SYSTEMCTL" --user disable --now next-up-refresh.timer >/dev/null 2>&1 || true
    FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
    rm -f -- "$service" "$timer"
    "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1 || true
    fail "could not enable next-up-refresh.timer"
    return 1
  fi
  printf 'armed: state/%s.check.sh and next-up-refresh.timer\n' "$CHECK_ID"
}

action_disarm() {
  "$SYSTEMCTL" --user disable --now next-up-refresh.timer >/dev/null 2>&1 || true
  FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
  rm -f -- "$SYSTEMD_USER_DIR/next-up-refresh.service" "$SYSTEMD_USER_DIR/next-up-refresh.timer" \
    "$LOW_RECORD" "$FAILURE_RECORD" "$FAILURE_REPORTED"
  "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1 || true
  printf 'disarmed: fleet-steward check and next-up-refresh.timer\n'
}

command=${1:-check}
case "$command" in
  refresh) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; action_refresh ;;
  check) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; action_check ;;
  exempt) action_exempt "${@:2}" ;;
  park-preserved) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; action_park_preserved ;;
  parked-review) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; action_parked_review ;;
  arm) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; action_arm ;;
  disarm) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; action_disarm ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
