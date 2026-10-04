#!/usr/bin/env bash
# tests/fm-open-decisions-fold-linear.test.sh - the open-decisions fold
# (bin/fm-classify-lib.sh) costs time linear in a status log's lines plus its
# open decisions and stays byte for byte equal to the original per-line fold.
# The original re-walked the whole open set for every line that opened or closed
# a key, which made a session-start digest over a few thousand status lines take
# minutes. The reference below is a verbatim copy of that original fold (its
# set-drop loop, its per-line rule, and its note and key readers), kept here so
# equality is proven against what shipped rather than against the new code.
# Cases drive the real status_open_decisions / status_open_decisions_incremental
# over synthetic logs and compare every output, then bound the cost of a large
# log by wall time and by the processes it spawns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-open-decisions-fold-linear-tests)

# --- reference: the original fold, unchanged --------------------------------

ref_key_at_note_head() {  # <status-line> -> raw slug
  local rest
  case "$1" in
    *:*) rest=${1#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[key=*\]*) rest=${rest#\[key=}; printf '%s' "${rest%%\]*}" ;;
    *) return 1 ;;
  esac
}

ref_status_line_note() {  # <status-line>
  local n k unstamped
  _fm_status_unstamped "$1" unstamped
  case "$unstamped" in
    *:*) n=${unstamped#*:}; n=${n#"${n%%[![:space:]]*}"} ;;
    *) printf '%s' "$unstamped"; return 0 ;;
  esac
  if ! _fm_key_before_colon "$unstamped" && k=$(ref_key_at_note_head "$unstamped") \
    && _fm_decision_slug_ok "$k"; then
    n=${n#"[key=$k]"}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  printf '%s' "$n"
}

ref_decision_key() {  # <status-line> [<keyless>]
  local k unstamped
  _fm_status_unstamped "$1" unstamped
  if _fm_key_before_colon "$unstamped"; then
    k=${unstamped%%:*}
    k=${k#*\[key=}
    k=${k%%\]*}
  else
    k=$(ref_key_at_note_head "$unstamped") || { printf '%s' "${2-default}"; return 0; }
  fi
  _fm_decision_slug_ok "$k" || return 1
  printf '%s' "$k"
}

ref_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}

ref_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb> <kind>
  local open=$1 line=$2 resolve=$3 held=$4 kind=$5 verb key note unstamped
  _fm_status_unstamped "$line" unstamped
  case "$unstamped" in
    *:*|*\[key=*\]*) ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  status_line_verb "$line" verb
  case "$unstamped" in
    *:*) case "$verb:$kind" in done:ship|done:scout|failed:ship|failed:scout) return 0 ;; esac ;;
  esac
  case "$verb" in
    needs-decision|blocked|"$resolve"|"$held") ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  key=$(ref_decision_key "$line") || { printf '%s' "$open"; return 0; }
  _fm_decision_key_transition_allowed "$key" "$(ref_status_line_note "$line")" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(ref_status_line_note "$line")
      open=$(ref_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
      open=$(ref_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}

# The original whole-file fold, optionally seeded with an existing open set the
# way a persisted cursor seeds the incremental one.
ref_fold() {  # <status-file> <kind> [<initial-open-set>]
  local f=$1 kind=$2 open=${3-} line verb
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    case "$verb" in
      needs-decision|blocked|done|failed|resolved|captain-held)
        open=$(ref_decision_fold_line "$open" "$line" resolved captain-held "$kind")
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# --- synthetic logs -----------------------------------------------------------

# <lines> <keys> <seed> [terminals]: a deterministic log mixing every transition
# shape the fold reads - opens, resolutions, captain-held transfers and reopens
# in both key positions, keyless lines, stamps, correlation tokens, reserved
# pending-reply keys with and without their vocabulary, malformed slugs, key
# names whose slot encodings would collide under a careless mapping, terminal
# lines, ordinary progress, prose, and blank lines.
gen_log() {
  awk -v n="$1" -v nkeys="$2" -v seed="$3" -v terminals="${4:-0}" '
    function rnd(m) { s = (s * 1103515245 + 12345) % 2147483648; return int(s / 65536) % m }
    function key(   k) {
      k = rnd(nkeys)
      if (k == 0) return "x-y"
      if (k == 1) return "x_2dy"
      if (k == 2) return "x.y"
      if (k == 3) return "x_2ey"
      if (k == 4) return "pending-reply-abc"
      if (k == 5) return "default"
      return "k" k
    }
    BEGIN {
      s = seed
      for (i = 1; i <= n; i++) {
        k = key(); r = rnd(100)
        if (terminals > 0 && rnd(terminals) == 0) { printf "%s: finished %d\n", (rnd(2) ? "done" : "failed"), i; continue }
        stamp = (rnd(3) == 0) ? " [at=17" (10000000 + rnd(9000000)) "]" : ""
        note = "note " i " \\back *glob* [x] trailing  "
        if (r < 22) printf "needs-decision%s [key=%s]: %s\n", stamp, k, note
        else if (r < 32) printf "blocked%s [key=%s]: %s\n", stamp, k, note
        else if (r < 52) printf "resolved%s [key=%s]: answered %d\n", stamp, k, i
        else if (r < 57) printf "captain-held [key=%s]: handed off %d\n", k, i
        else if (r < 62) printf "needs-decision: [key=%s] note-head form %d\n", k, i
        else if (r < 64) printf "needs-decision%s: keyless %d\n", stamp, i
        else if (r < 66) printf "resolved: keyless answer %d\n", i
        else if (r < 68) printf "needs-decision corr=0123456789abcdef [key=%s]: corr %d\n", k, i
        else if (r < 70) printf "resolved corr=fedcba9876543210 [key=%s]: corr answer %d\n", k, i
        else if (r < 72) printf "needs-decision [key=pending-reply-%d]: pending-reply-missed: no reply %d\n", rnd(6), i
        else if (r < 73) printf "resolved [key=pending-reply-%d]: spoofed close %d\n", rnd(6), i
        else if (r < 74) printf "resolved [key=pending-reply-%d]: pending-reply-answered: real close %d\n", rnd(6), i
        else if (r < 75) printf "needs-decision [key=bad key!]: malformed slug %d\n", i
        else if (r < 76) printf "needs-decision\ttabbed [key=%s]: tab\tin\tnote %d\n", k, i
        else if (r < 77) printf "needs-decision [key=%s]:\n", k
        else if (r < 78) printf "   blocked [key=%s]:   leading space %d\n", k, i
        else if (r < 80) printf "\n"
        else if (r < 85) printf "some prose that mentions needs-decision and a colon: here %d\n", i
        else if (r < 90) printf "working [at=1700000%03d]: step %d\n", rnd(1000), i
        else printf "signal%s: progress %d [key=%s]\n", stamp, i, k
      }
    }'
}

# <dir> <name> <kind> -> status path with a sibling .meta stating <kind>
new_status() {
  local dir=$1 name=$2 kind=$3
  mkdir -p "$dir"
  printf 'kind=%s\n' "$kind" > "$dir/$name.meta"
  printf '%s/%s.status' "$dir" "$name"
}

# --- equality ---------------------------------------------------------------

test_fold_equals_reference_on_a_large_mixed_log() {
  local dir f want got
  dir="$TMP_ROOT/equal"
  f=$(new_status "$dir" mixed secondmate)
  gen_log 1500 300 7 > "$f"
  want=$(ref_fold "$f" secondmate)
  [ "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" -ge 100 ] \
    || fail "reference fold left fewer than 100 decisions open; the log no longer exercises a wide open set"
  got=$(status_open_decisions "$f" secondmate)
  [ "$got" = "$want" ] || fail "whole-file fold diverged from the reference on a 1500-line, 300-key log"
  got=$(status_open_decisions "$f")
  [ "$got" = "$want" ] || fail "whole-file fold diverged from the reference when the kind came from the .meta record"
  pass "whole-file fold equals the original fold byte for byte on a large mixed log"
}

test_fold_equals_reference_with_terminal_lines() {
  local dir f kind want got
  dir="$TMP_ROOT/terminals"
  f=$(new_status "$dir" term ship)
  gen_log 700 60 11 60 > "$f"
  grep -Eq '^(done|failed):' "$f" || fail "synthetic log carries no terminal line, so the clear case is vacuous"
  for kind in ship scout secondmate unknown; do
    want=$(ref_fold "$f" "$kind")
    got=$(status_open_decisions "$f" "$kind")
    [ "$got" = "$want" ] || fail "fold with terminal lines diverged from the reference for kind $kind"
  done
  [ "$(ref_fold "$f" ship)" != "$(ref_fold "$f" secondmate)" ] \
    || fail "ship and secondmate kinds folded identically, so the terminal rule went unexercised"
  pass "ship and scout terminals still retire every open decision, and a secondmate terminal still retires none"
}

test_fold_equals_reference_on_small_and_degenerate_logs() {
  local dir f want got seed
  dir="$TMP_ROOT/small"
  f=$(new_status "$dir" small secondmate)
  : > "$f"
  [ -z "$(status_open_decisions "$f" secondmate)" ] || fail "an empty log folded to a non-empty set"
  printf 'resolved [key=never-opened]: nothing to close\n' > "$f"
  [ -z "$(status_open_decisions "$f" secondmate)" ] || fail "closing an unopened key produced a record"
  printf 'needs-decision [key=a]: no trailing newline' > "$f"
  [ "$(status_open_decisions "$f" secondmate)" = "$(ref_fold "$f" secondmate)" ] \
    || fail "an unterminated final line folded differently from the reference"
  for seed in 1 2 3 4 5 6 7 8; do
    gen_log 40 5 "$seed" 5 > "$f"
    want=$(ref_fold "$f" secondmate)
    got=$(status_open_decisions "$f" secondmate)
    [ "$got" = "$want" ] || fail "seed $seed: small dense-reopen log diverged from the reference"
    want=$(ref_fold "$f" ship)
    got=$(status_open_decisions "$f" ship)
    [ "$got" = "$want" ] || fail "seed $seed: small log with terminals diverged from the reference (ship)"
  done
  pass "empty, unterminated, never-opened, and dense-reopen logs fold exactly as the original did"
}

# The persisted-cursor path folds only appended bytes into the saved set, so it
# must land on the same set as one whole-file fold however the log is chunked.
test_incremental_fold_equals_reference_across_chunks() {
  local dir f all want got
  dir="$TMP_ROOT/incremental"
  f=$(new_status "$dir" chunked secondmate)
  all="$dir/all.log"
  gen_log 900 150 23 > "$all"
  : > "$f"
  head -n 300 "$all" >> "$f"
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$(ref_fold "$f" secondmate)" ] || fail "incremental fold diverged from the reference after the first chunk"
  sed -n '301,650p' "$all" >> "$f"
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$(ref_fold "$f" secondmate)" ] || fail "incremental fold diverged from the reference after the second chunk"
  sed -n '651,$p' "$all" >> "$f"
  got=$(status_open_decisions_incremental "$f")
  want=$(ref_fold "$all" secondmate)
  [ "$got" = "$want" ] || fail "incremental fold diverged from the reference after the final chunk"
  [ "$got" = "$(status_open_decisions "$f" secondmate)" ] \
    || fail "incremental and whole-file folds disagree on the same log"
  pass "cursor-backed incremental fold equals the original whole-file fold however the log is chunked"
}

# A cursor can carry a set this code never wrote (hand repair, an older writer).
# The original text fold tolerated duplicate keys, blank lines, and records with
# no tab, and the cursor-backed fold must keep treating them the same way.
test_incremental_fold_tolerates_a_hand_edited_open_set() {
  local dir f cf seed_set got want ident
  dir="$TMP_ROOT/seeded"
  f=$(new_status "$dir" seeded secondmate)
  printf 'working: nothing yet\n' > "$f"
  status_open_decisions_incremental "$f" >/dev/null
  cf=$(_fm_open_decisions_cursor_path "$f")
  ident=$(_fm_open_decisions_file_ident "$f")
  seed_set=$(printf 'dup\tblocked\tfirst\n\nplain record with no tab\nkeep\tneeds-decision\tstays\ndup\tneeds-decision\tsecond\nclose-me\tblocked\tgone soon\n')
  {
    printf 'version=%s:secondmate\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
    printf 'offset=%s\n' "$(_fm_status_file_size "$f" | tr -d '[:space:]')"
    printf 'ident=%s\n' "$ident"
    printf '%s\n' "$seed_set"
  } > "$cf"
  printf 'resolved [key=close-me]: done\nneeds-decision [key=fresh]: new\n' >> "$f"
  tail -n 2 "$f" > "$dir/delta.log"
  want=$(ref_fold "$dir/delta.log" secondmate "$seed_set")
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$want" ] || fail "seeded incremental fold diverged: got '$got' want '$want'"
  case "$got" in *'plain record with no tab'*) ;; *) fail "a tabless seeded record vanished" ;; esac

  printf 'resolved [key=dup]: closes both duplicates\n' >> "$f"
  tail -n 1 "$f" > "$dir/delta2.log"
  want=$(ref_fold "$dir/delta2.log" secondmate "$want")
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$want" ] || fail "closing a duplicated key left one copy behind"

  printf 'working: no transition here\n' >> "$f"
  got=$(status_open_decisions_incremental "$f")
  [ "$got" = "$want" ] || fail "a delta with no transition changed the persisted set"
  pass "a hand-edited persisted set (duplicates, blank lines, tabless records) folds as the original text fold did"
}

# --- bound ------------------------------------------------------------------

test_large_log_folds_fast_without_spawning_processes() {
  local dir f want got start elapsed counts trace pids
  dir="$TMP_ROOT/bound"
  f=$(new_status "$dir" big secondmate)
  gen_log 10000 300 31 > "$f"
  [ "$(wc -l < "$f" | tr -d ' ')" -ge 10000 ] || fail "synthetic log is shorter than 10,000 lines"

  # Any external command the fold tried to run is counted here, because PATH is
  # empty for the child; subshell forks show as extra BASHPIDs in a trace.
  counts="$dir/spawns"
  : > "$counts"
  start=$(date +%s)
  got=$(
    # shellcheck disable=SC2329 # bash calls this handler itself for a missing command.
    command_not_found_handle() { printf '%s\n' "$1" >> "$counts"; return 127; }
    # shellcheck disable=SC2123 # deliberate: this subshell may reach no external command.
    PATH=/nonexistent
    status_open_decisions "$f" secondmate
  )
  elapsed=$(( $(date +%s) - start ))
  [ -n "$got" ] || fail "10,000-line fold returned an empty open set"
  [ "$elapsed" -le 10 ] || fail "folding 10,000 lines and 300 keys took ${elapsed}s, over the 10s bound"
  [ ! -s "$counts" ] || fail "the fold ran external commands: $(sort -u "$counts" | tr '\n' ' ')"

  # A modest log traced once: every forked subshell would introduce a new pid.
  gen_log 400 60 5 > "$dir/trace.log"
  trace="$dir/trace.out"
  (
    exec 9> "$trace"
    BASH_XTRACEFD=9
    PS4='@@${BASHPID}@@ '
    set -x
    status_open_decisions "$dir/trace.log" secondmate >/dev/null
  )
  pids=$(grep -o '@@[0-9]*@@' "$trace" | sort -u | wc -l | tr -d ' ')
  [ "$pids" -le 2 ] || fail "folding 400 lines forked $((pids - 1)) subshells; the per-line cost must not fork"

  want=$(ref_fold "$dir/trace.log" secondmate)
  [ "$(status_open_decisions "$dir/trace.log" secondmate)" = "$want" ] \
    || fail "traced log diverged from the reference"
  pass "10,000 lines and 300 keys fold in ${elapsed}s with no external command and no per-line subshell"
}

test_fold_equals_reference_on_a_large_mixed_log
test_fold_equals_reference_with_terminal_lines
test_fold_equals_reference_on_small_and_degenerate_logs
test_incremental_fold_equals_reference_across_chunks
test_incremental_fold_tolerates_a_hand_edited_open_set
test_large_log_folds_fast_without_spawning_processes
