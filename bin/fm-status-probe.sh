#!/usr/bin/env bash
# fm-status-probe.sh - per-host fleet-truth probe that writes state/status.json.
#
# One run observes this host and atomically replaces state/status.json (schema
# `fm-status-probe.v1`) with three sections plus a record of which sources
# answered. A 5-minute timer keeps it current (`timer install`).
#
#   prs[]         One entry per PR url recorded as `pr=` in state/*.meta or given
#                 with --pr. Fields: url, head_sha, state (the forge's own
#                 word), merged, merge_commit, gate (the newest no-mistakes run
#                 status for that PR url, else null).
#                 `merged` is true only when the forge reports the PR merged,
#                 names its merge commit, the PR targeted the repo's default
#                 branch, and the forge's compare API shows that commit reachable
#                 from the default branch tip. A closed-unmerged PR reads
#                 merged=false; a PR whose proof could not be read reads null.
#   lanes[]       One entry per lane record: state/lanes/<id>.lane or a
#                 state/<id>.meta that carries `pid=` or `log=`, as key=value
#                 lines. Fields: id, pid, pid_alive, log, log_age_s, fresh
#                 (log mtime under 300 seconds), state. `state` is live (pid
#                 alive and fresh), stalled (pid alive, log not fresh), or dead
#                 (pid gone or absent).
#   gate_waits[]  One entry per running no-mistakes run that is parked at a
#                 gate, parsed from `no-mistakes axi status --run <id>`:
#                 run_id, branch, step, gate_status, age (the tool's own text),
#                 age_s (null when the tool printed none).
#   sources       {gh,no_mistakes} each {ok,error}; a section whose source is not
#                 ok is incomplete and proves nothing.
#
# Reporting rule: a status or report claim about a PR, a lane, or a gate wait
# must quote the matching status.json field (section, key, value); a claim with
# no matching field is not counted. docs/status-probe.md owns the rule.
#
# A source is ok only when every query it was asked answered: one unreadable PR,
# an unprovable merge commit, or a running no-mistakes run whose status could
# not be read marks the whole source not ok, and the remaining queries still run.
#
# Usage:
#   fm-status-probe.sh [run] [--home <dir>] [--out <file>] [--pr <url>]... [--stdout]
#   fm-status-probe.sh read [--home <dir>] [--out <file>] [--max-age <seconds>]
#       Print status.json with a verdict. Data older than --max-age (default
#       900, three probe intervals), a missing or unreadable file, or a section
#       whose source is not ok reads "unknown" instead of a value. Exits 0 for a
#       fresh file and 3 for a verdict of unknown.
#   fm-status-probe.sh timer install|remove|print [--home <dir>]
#
# Environment seams: FM_PROBE_GH (default gh) and FM_PROBE_NM (default
# no-mistakes) name the tools; FM_PROBE_FRESH_SECONDS (default 300) is the lane
# freshness bound; FM_PROBE_MAX_AGE_SECONDS sets the `read` default.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GH=${FM_PROBE_GH:-gh}
NM=${FM_PROBE_NM:-no-mistakes}
FRESH=${FM_PROBE_FRESH_SECONDS:-300}

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-status-probe: %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required"

CMD=run
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  run|timer|read) CMD=$1; shift ;;
esac

HOME_DIR=${FM_HOME:-$FM_ROOT}
OUT=
TO_STDOUT=0
MAX_AGE=${FM_PROBE_MAX_AGE_SECONDS:-900}
EXTRA_PRS=()
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -ge 2 ] || die "--home needs a directory"; HOME_DIR=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || die "--out needs a file"; OUT=$2; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || die "--pr needs a url"; EXTRA_PRS+=("$2"); shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    --max-age) [ "$#" -ge 2 ] || die "--max-age needs seconds"; MAX_AGE=$2; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
case "$FRESH" in ''|*[!0-9]*) die "FM_PROBE_FRESH_SECONDS must be whole seconds" ;; esac
case "$MAX_AGE" in ''|*[!0-9]*) die "--max-age must be whole seconds" ;; esac

STATE="$HOME_DIR/state"
[ -n "$OUT" ] || OUT="$STATE/status.json"

if [ "$CMD" = timer ]; then
  # shellcheck source=bin/fm-periodic-timer-lib.sh
  . "$SCRIPT_DIR/fm-periodic-timer-lib.sh"
  case "${ARGS[0]:-}" in
    install) fm_timer_install status-probe 300 "$HOME_DIR" "$SCRIPT_DIR/fm-status-probe.sh" run --home "$HOME_DIR" ;;
    remove) fm_timer_remove status-probe "$HOME_DIR" ;;
    print) fm_timer_render "$(fm_timer_kind)" "$(fm_timer_label status-probe "$HOME_DIR")" 300 "$HOME_DIR" \
      "$SCRIPT_DIR/fm-status-probe.sh" run --home "$HOME_DIR" ;;
    *) die "timer needs install, remove, or print" ;;
  esac
  exit $?
fi

NOW=$(date +%s)

if [ "$CMD" = read ]; then
  # Stale, missing, or unreadable data is never presented as a result: the
  # verdict is unknown and every section reads "unknown". A section whose own
  # source is not ok reads "unknown" too, even when the file is fresh.
  if [ ! -f "$OUT" ]; then
    reason="no status.json at $OUT"
  elif ! jq -e '.schema == "fm-status-probe.v1" and (.generated | type == "number")' "$OUT" >/dev/null 2>&1; then
    reason="$OUT is not a readable fm-status-probe.v1 file"
  else
    reason=
  fi
  if [ -n "$reason" ]; then
    jq -n --argjson now "$NOW" --argjson max "$MAX_AGE" --arg reason "$reason" \
      '{schema:"fm-status-probe.v1",verdict:"unknown",reason:$reason,generated:null,age_s:null,max_age_s:$max,
        prs:"unknown",lanes:"unknown",gate_waits:"unknown"}'
    exit 3
  fi
  RESULT=$(jq --argjson now "$NOW" --argjson max "$MAX_AGE" '
    ($now - .generated) as $age
    | ($age > $max or $age < -60) as $stale
    | . + {age_s:$age,max_age_s:$max,
           verdict:(if $stale then "unknown" else "fresh" end),
           reason:(if $stale then "status.json is \($age)s old; the limit is \($max)s" else null end)}
    | if $stale then . + {prs:"unknown",lanes:"unknown",gate_waits:"unknown"}
      else . + {prs:(if .sources.gh.ok == true then .prs else "unknown" end),
                gate_waits:(if .sources.no_mistakes.ok == true then .gate_waits else "unknown" end)}
      end' "$OUT") || die "could not read $OUT"
  printf '%s\n' "$RESULT"
  [ "$(printf '%s' "$RESULT" | jq -r .verdict)" = fresh ] || exit 3
  exit 0
fi

if [ "$(uname 2>/dev/null)" = Darwin ]; then
  path_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  path_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-probe.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf -- "$SCRATCH"' EXIT HUP INT TERM

# ---- no-mistakes runs -------------------------------------------------------
NM_OK=false
NM_ERR=
NM_RUNS="$SCRATCH/nm-runs.tsv"   # id <TAB> branch <TAB> status <TAB> pr
: > "$NM_RUNS"
if command -v "$NM" >/dev/null 2>&1; then
  if nm_list=$("$NM" axi status 2>&1); then
    NM_OK=true
    printf '%s\n' "$nm_list" | awk '
      /^runs\[[0-9]+\]\{/ { in_runs = 1; next }
      in_runs && /^[^ ]/ { in_runs = 0 }
      in_runs {
        line = $0; sub(/^[ \t]+/, "", line)
        n = 0; field = ""; q = 0
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "\"") { q = !q; continue }
          if (c == "," && !q) { f[++n] = field; field = ""; continue }
          field = field c
        }
        f[++n] = field
        if (n >= 3) printf "%s\t%s\t%s\t%s\n", f[1], f[2], f[3], (n >= 5 ? f[5] : "")
      }' > "$NM_RUNS"
  else
    NM_ERR=$(printf '%s' "$nm_list" | head -c 300 | tr '\n' ' ')
  fi
else
  NM_ERR="$NM not found"
fi

# age_to_seconds <text> -> seconds from the first duration like 1d2h3m4s, else empty
age_to_seconds() {
  printf '%s\n' "$1" | awk '
    {
      total = 0; found = 0; s = $0
      while (match(s, /[0-9]+[dhms]/)) {
        v = substr(s, RSTART, RLENGTH - 1) + 0; u = substr(s, RSTART + RLENGTH - 1, 1)
        total += v * (u == "d" ? 86400 : u == "h" ? 3600 : u == "m" ? 60 : 1)
        found = 1; s = substr(s, RSTART + RLENGTH)
      }
      if (found) print total
    }'
}

GATES="$SCRATCH/gates.jsonl"
: > "$GATES"
NM_UNREAD=
if [ "$NM_OK" = true ]; then
  while IFS=$'\t' read -r rid rbranch rstatus _rpr; do
    [ "$rstatus" = running ] || continue
    if ! detail=$("$NM" axi status --run "$rid" 2>/dev/null); then
      NM_UNREAD="${NM_UNREAD:+$NM_UNREAD }$rid"
      continue
    fi
    step=$(printf '%s\n' "$detail" | awk '/^gate:/ { g = 1; next } g && /^[^ ]/ { g = 0 } g && $1 == "step:" { print $2; exit }')
    gstatus=$(printf '%s\n' "$detail" | awk '/^gate:/ { g = 1; next } g && /^[^ ]/ { g = 0 } g && $1 == "status:" { print $2; exit }')
    [ -n "$step" ] || continue
    age=$(printf '%s\n' "$detail" | sed -n 's/^[[:space:]]*awaiting_agent:[[:space:]]*//p' | head -n1)
    age_s=$(age_to_seconds "$age")
    jq -cn --arg id "$rid" --arg branch "$rbranch" --arg step "$step" --arg gs "$gstatus" \
      --arg age "$age" --arg age_s "$age_s" \
      '{run_id:$id,branch:$branch,step:$step,gate_status:$gs,
        age:(if $age == "" then null else $age end),
        age_s:(if $age_s == "" then null else ($age_s | tonumber) end)}' >> "$GATES"
  done < "$NM_RUNS"
  # A running run whose status could not be read may be parked at a gate, so the
  # gate_waits section is incomplete and must not read as complete.
  if [ -n "$NM_UNREAD" ]; then
    NM_OK=false
    NM_ERR="could not read the status of running run(s): $NM_UNREAD"
  fi
fi

# ---- PRs --------------------------------------------------------------------
GH_OK=false
GH_ERR=
PRS="$SCRATCH/prs.jsonl"
: > "$PRS"
PR_URLS="$SCRATCH/pr-urls.txt"
{
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    sed -n 's/^pr=//p' "$f" | head -n1
  done
  [ "${#EXTRA_PRS[@]}" -eq 0 ] || printf '%s\n' "${EXTRA_PRS[@]}"
} | sed '/^$/d' | sort -u > "$PR_URLS"

gate_for_url() {  # <pr-url> -> newest no-mistakes run status for the url, or empty
  awk -F'\t' -v u="$1" '$4 == u { print $3; exit }' "$NM_RUNS"
}

# gh_note <message>: one PR could not be fully read. The source is then
# incomplete, but the remaining PRs are still queried.
GH_AVAILABLE=false
GH_FAILED=0
gh_note() {
  GH_FAILED=$((GH_FAILED + 1))
  [ -n "$GH_ERR" ] || GH_ERR=$1
}

if [ -s "$PR_URLS" ]; then
  if command -v "$GH" >/dev/null 2>&1; then
    GH_AVAILABLE=true
  else
    GH_ERR="$GH not found"
  fi
  while IFS= read -r url; do
    gate=$(gate_for_url "$url")
    if [ "$GH_AVAILABLE" != true ]; then
      jq -cn --arg url "$url" --arg gate "$gate" \
        '{url:$url,head_sha:null,state:null,merged:null,merge_commit:null,gate:(if $gate == "" then null else $gate end)}' >> "$PRS"
      continue
    fi
    slug=$(printf '%s\n' "$url" | sed -n 's#^https://[^/]*/\([^/]*/[^/]*\)/pull/[0-9]*$#\1#p')
    view=$("$GH" pr view "$url" --json state,headRefOid,mergeCommit,baseRefName 2>/dev/null) || view=
    if [ -z "$view" ] || [ -z "$slug" ] || ! printf '%s' "$view" | jq -e . >/dev/null 2>&1; then
      gh_note "could not read $url"
      jq -cn --arg url "$url" --arg gate "$gate" \
        '{url:$url,head_sha:null,state:null,merged:null,merge_commit:null,gate:(if $gate == "" then null else $gate end)}' >> "$PRS"
      continue
    fi
    pstate=$(printf '%s' "$view" | jq -r '.state // ""')
    head=$(printf '%s' "$view" | jq -r '.headRefOid // ""')
    mcommit=$(printf '%s' "$view" | jq -r '.mergeCommit.oid // ""')
    base=$(printf '%s' "$view" | jq -r '.baseRefName // ""')
    merged=false
    if [ "$pstate" != MERGED ] || [ -z "$mcommit" ]; then
      merged=false
    else
      default=$("$GH" api "repos/$slug" --jq .default_branch 2>/dev/null) || default=
      cmp=
      [ -z "$default" ] || cmp=$("$GH" api "repos/$slug/compare/$mcommit...$default" --jq .status 2>/dev/null) || cmp=
      if [ -z "$default" ] || [ -z "$cmp" ]; then
        merged=null
        gh_note "could not prove the merge commit of $url"
      elif [ "$base" = "$default" ] && { [ "$cmp" = ahead ] || [ "$cmp" = identical ]; }; then
        merged=true
      fi
    fi
    jq -cn --arg url "$url" --arg head "$head" --arg st "$pstate" --argjson merged "$merged" \
      --arg mc "$mcommit" --arg gate "$gate" \
      '{url:$url,head_sha:(if $head == "" then null else $head end),state:$st,merged:$merged,
        merge_commit:(if $mc == "" then null else $mc end),gate:(if $gate == "" then null else $gate end)}' >> "$PRS"
  done < "$PR_URLS"
  if [ "$GH_AVAILABLE" = true ] && [ "$GH_FAILED" -eq 0 ]; then
    GH_OK=true
  elif [ "$GH_FAILED" -gt 1 ]; then
    GH_ERR="$GH_ERR (and $((GH_FAILED - 1)) more)"
  fi
else
  GH_OK=true
fi

# ---- lanes ------------------------------------------------------------------
LANES="$SCRATCH/lanes.jsonl"
: > "$LANES"
lane_value() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n1
}
emit_lane() {  # <id> <file>
  local id=$1 file=$2 pid log alive=false mt age=null fresh=false lstate=dead
  pid=$(lane_value "$file" pid)
  log=$(lane_value "$file" log)
  case "$pid" in
    ''|*[!0-9]*) pid= ;;
    *) kill -0 "$pid" 2>/dev/null && alive=true ;;
  esac
  if [ -n "$log" ] && mt=$(path_mtime "$log") && [ -n "$mt" ]; then
    age=$((NOW - mt))
    [ "$age" -ge 0 ] || age=0
    [ "$age" -lt "$FRESH" ] && fresh=true
  fi
  if [ "$alive" = true ]; then
    if [ "$fresh" = true ]; then lstate=live; else lstate=stalled; fi
  fi
  jq -cn --arg id "$id" --arg pid "$pid" --argjson alive "$alive" --arg log "$log" \
    --argjson age "$age" --argjson fresh "$fresh" --arg st "$lstate" \
    '{id:$id,pid:(if $pid == "" then null else ($pid | tonumber) end),pid_alive:$alive,
      log:(if $log == "" then null else $log end),log_age_s:$age,fresh:$fresh,state:$st}' >> "$LANES"
}
for f in "$STATE"/lanes/*.lane; do
  [ -f "$f" ] || continue
  b=${f##*/}
  emit_lane "${b%.lane}" "$f"
done
for f in "$STATE"/*.meta; do
  [ -f "$f" ] || continue
  grep -q '^\(pid\|log\)=' "$f" || continue
  b=${f##*/}
  emit_lane "${b%.meta}" "$f"
done

# ---- assemble ---------------------------------------------------------------
gh_ok=false; [ "$GH_OK" = true ] && gh_ok=true
HOST=$(hostname 2>/dev/null || echo unknown)
RESULT=$(jq -n --argjson now "$NOW" --arg host "$HOST" --arg home "$HOME_DIR" \
  --argjson gh_ok "$gh_ok" --arg gh_err "$GH_ERR" \
  --argjson nm_ok "$NM_OK" --arg nm_err "$NM_ERR" \
  --slurpfile prs "$PRS" --slurpfile lanes "$LANES" --slurpfile gates "$GATES" \
  '{schema:"fm-status-probe.v1",generated:$now,host:$host,fm_home:$home,
    sources:{gh:{ok:$gh_ok,error:(if $gh_err == "" then null else $gh_err end)},
             no_mistakes:{ok:$nm_ok,error:(if $nm_err == "" then null else $nm_err end)}},
    prs:$prs,lanes:$lanes,gate_waits:$gates}') || die "could not assemble status.json"

if [ "$TO_STDOUT" -eq 1 ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi
mkdir -p "$(dirname "$OUT")" || die "cannot create the output directory"
TMP=$(mktemp "$OUT.XXXXXX") || die "cannot write beside $OUT"
if ! { printf '%s\n' "$RESULT" > "$TMP" && chmod 0644 "$TMP" && mv -f -- "$TMP" "$OUT"; }; then
  rm -f -- "$TMP"
  die "could not publish $OUT"
fi
