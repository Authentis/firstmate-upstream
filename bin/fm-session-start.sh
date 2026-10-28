#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# fm-wake-drain.sh, and fm-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   1b. home role    - the resolved firstmate-repository role line
#                      (bin/fm-role.sh report), purely local, no network.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (same-home backlog reconciliation,
#                       secondmate convergence, secondmate liveness, pending remote
#                       handoff retry, X-mode artifact writes, fleet sync) also run only when
#                       locked; the four network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. wake-drain     - presents durable wakes and advances recovery handling
#                       state, so it only runs when locked. The local bounded
#                       inactive-outcome startup scan runs in the deferred worker.
#                       First, on every harness and away posture, it seeds the
#                       outcome store's display tail copy when that is absent
#                       (bin/fm-branch-outcome.sh seed-tail).
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a bounded state/*.status tail,
#                       the away posture (state/.afk-contract and the legacy
#                       state/.afk daemon flag), and a cheap per-task
#                       endpoint-liveness read, each bounded and crash-
#                       isolated so one task's read can never abort the
#                       digest: read-only, always runs. The per-task reads
#                       run serially, so with a wedged backend the stage's
#                       ceiling is tasks x the per-read bound
#                       (FM_SESSION_START_ENDPOINT_TIMEOUT, default 10s) and
#                       can itself reach the digest's runtime bound.
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# Those ten names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran - and the parent banners
# EVERY nonzero child exit, not only the bound: a child that dies or is killed
# mid-stage must never truncate the digest silently.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the captain
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote secondmate could burn the
# entire FM_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The five that did - `gh auth status`, secondmate liveness, secondmate
# convergence, pending remote handoff delivery, and the fleet-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 7 without ever blocking on it. The bounded inactive-outcome
# startup scan joins that worker because its local current-state reads can also
# be slow. bin/fm-startup-network.sh owns that stage and its safety argument;
# bin/fm-bootstrap.sh and bin/fm-inactive-reconcile.sh remain the owners of the
# work itself and still run it.
# The digest is therefore composed from bounded local reads and local
# subprocesses only, while slow network or inactive-state reconciliation delays
# a reported check rather than startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# ORDERING, and why FLEET STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a captain-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live fleet identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So fleet state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes and receiver wakes, writing
# X-mode artifacts, and fetching or fast-forwarding every project clone - before
# ever discovering another session already holds the lock. Two sessions racing
# those sweeps is exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, tasks-axi and quota-axi
# tool checks, and tasks-axi availability - none of which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the six bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - `done` rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/fm-bearings-snapshot.sh, /ahoy), and at startup it
#     is pure weight - 10 done rows cost 3.3KB in an observed main-home digest.
#   - Every in-flight, held, and blocked row is listed, never bounded away
#     (AGENTS.md sections 7 and 10 make them actionable at startup), but each
#     prints as ONE line: "id | state | reason | full: backlog.md". The reason
#     is the decoded hold reason (or blocked_by when there is none) with line
#     breaks collapsed and cut at BACKLOG_REASON_CHARS characters with an
#     ellipsis. The record itself is untouched; the full row is
#     data/backlog.md or `bin/fm-tasks-axi.sh show <id> --full`.
#   - Only the plain queued (dispatchable-now) listing is bounded, by
#     FM_SESSION_START_QUEUED_LIMIT, default 20. Anything it omits is disclosed
#     with an exact remainder count and the command that shows the rest, so a
#     deep queue costs a counter rather than kilobytes.
#     (This replaces FM_SESSION_START_BACKLOG_LIMIT, which bounded the whole
#     listing indiscriminately and so could drop a held or blocked row.)
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body. The groups are the tool's own filters
# (`--state in_flight`, `--state held`, `--state queued --blocked`, and
# `tasks-axi ready`), so this script never reimplements task state; the groups
# can overlap, because an in-flight item that is also held appears under both.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest; the same never-bound-a-held-or-blocked-row
# rule applies, recognized there from the title line's own hold/blocked-by
# markers.
# Full bodies are targeted follow-up only: `bin/fm-tasks-axi.sh show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# STATUS TAILS: FM_SESSION_START_STATUS_TAIL bounds how many lines each task's
# tail prints, and bin/fm-line-cap-lib.sh bounds how long each of those lines
# may be. Both bounds are safe because the section prints every task's full
# status log path, and AGENTS.md section 8 treats a status line as a wake EVENT
# rather than current state - bin/fm-crew-state.sh owns current state.
#
# CONTEXT RE-EMIT STATE SUMMARY: a locked --reemit replaces the FLEET STATE
# record dump (every meta line, every status tail, the whole backlog listing)
# with current STATE, because a compacted session needs what is open now, not
# a replay of the log - one observed re-emit spent 66KB there.
#   - OPEN ITEMS is mandatory and never cut: one entry per state/*.meta with
#     its kind, mode, yolo, and endpoint liveness; for a ship or scout its
#     branch, the exact worktree HEAD (a bounded local git read), and its
#     recorded pr=/pr_head= with a PR state read from local merge evidence only
#     (the merge-notified marker or retirement receipt bin/fm-pr-lib.sh owns,
#     else whether its merge poll is armed; no forge call); the latest status
#     event with its identical repeats collapsed to a count (bin/fm-classify-
#     lib.sh's retry identity) and the other events in the classifier's event
#     window folded into one earlier-event count; its open decision keys from
#     the same incremental fold the drain just refreshed, the newest four by
#     name and the rest as a count (OPEN DECISIONS in the wake queue and the
#     status log carry every key and note); and every receipt path its open
#     decisions, latest event, last FM_SESSION_START_STATUS_TAIL lines, and
#     data/<id>/report.md cite, uncapped so each path stays exact.
#   - Resolved and superseded status history is dropped, and status logs whose
#     task record is gone (cleaned-up work) collapse to a count and their ids.
#   - FM_SESSION_START_REEMIT_STATE_BYTES (default 15000) bounds the whole
#     summary in bytes, its lede and its closing tally included, and the tally
#     counts its own line. The lede, OPEN ITEMS, the backlog counts, every cut
#     disclosure, and the tally are mandatory; the held, blocked, untracked
#     in-flight, and ready backlog rows, then the closed-log ids, print in that
#     order only while the exact whole still fits, and every cut is disclosed
#     with its count and command. So the summary overruns its budget only when
#     its mandatory lines alone do, and then only they print and the tally says
#     so.
# The wake queue, the supervision block, any AGENTS.md refresh, and CONTEXT
# keep their own owners and bounds. A read-only re-emit drained nothing, so it
# keeps the full dump instead of a fold no lock-holding drain refreshed.
#
# DIGEST CAP: the whole digest is capped at FM_SESSION_START_DIGEST_BYTES
# (default 10240). In-flight, held, blocked, ready, meta, orphan, and context
# blocks print one capped line per item, at most FM_SESSION_START_LIST_LIMIT
# (default 3) items per block, then a shown/total count and a pointer to the
# full source, so each section fits natively. WAKE QUEUE and OPEN DECISIONS
# are never cut or capped by any byte budget: the wake queue is drained by
# the child, so nothing may truncate it afterwards. If the digest is still
# over the budget, the parent drops whole lowest-priority sections only -
# CONTEXT first, then FLEET STATE detail - replacing each with a one-line
# pointer to its full sources, never a mid-line byte cut. If safety content
# alone exceeds the budget it prints whole and the total exceeds the cap.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/fm-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes and the backlog
# listing are unbounded subprocesses, while each per-task endpoint read runs
# in its own crash-isolated child under FM_SESSION_START_ENDPOINT_TIMEOUT
# (default 10s). So the whole digest still runs as ONE bounded child of this
# script (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the child stopped is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner on ANY nonzero child exit - the runtime bound
# or an unexpected child death, named with its exit status - naming the stage
# that did not finish and the sections that were therefore never emitted, and
# still exits 0. The child
# records its progress in FM_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: fm-session-start.sh [--reemit] [--source <source>]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (fleet
#             sync, same-home backlog reconciliation, secondmate convergence and
#             liveness, pending remote handoff retry, X-mode
#             artifact writes) - and
#             re-emit the rest, with FLEET STATE as the capped state summary
#             described above. Wake-queue presentation is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             handle and acknowledge them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: fm-lock.sh
#             already treats a lock owned through shared ancestry or a trusted
#             same-session Claude id as its own, so the re-emit proceeds, while
#             a lock another live session took meanwhile still produces the
#             ordinary read-only path. A re-emit prints a short RE-EMIT CUE
#             first, so a harness that spills a large output and shows only its
#             head still tells the model to read the saved full output.
#
#   --source  The native session-open source, supplied only by
#             fm-sessionstart-run.sh. A genuine `startup` that owns the active
#             session lock records AGENTS.md's SHA-256 baseline only after the
#             digest completion record is published, keyed to that lock's
#             harness pid. No resume, clear, reset, compact, or other rebuild
#             creates or replaces it. Pi and pi-signed compaction are the only
#             supported stale-cache rebuild pair: a missing baseline, a baseline
#             for another harness pid, or a changed hash causes the complete
#             current AGENTS.md to print before the bulky digest. The baseline
#             remains immutable so every later drifted compaction refreshes
#             again, while an equal baseline emits no instruction refresh.
#             A complete sourceless run (a manual rerun after a truncated
#             startup) records the baseline the same way, but only when the
#             baseline does not already belong to this lock owner.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"

REEMIT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock role bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${FM_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# A stale FM_SESSION_START_STAGE_FILE inherited from an unrelated ancestor
# shell (not created by the block below for THIS invocation) must never be
# read as proof that the runtime bound already wraps this process: that
# reading skips fm_run_timed entirely, so a real hang anywhere below runs
# forever instead of hitting the ordinary bound. The block below always
# creates this file moments before handing it to the exact child that reads
# it, so a genuine handoff is always both present and only instants old;
# requiring both tells that live handoff apart from an inherited variable
# whose file has since been cleaned up by its own owner, and from one whose
# process was killed before it could clean up but is long since finished.
fm_session_start_stage_file_handoff() {
  local f=$1 mtime now
  [ -n "$f" ] && [ -e "$f" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$f" 2>/dev/null)
  else
    mtime=$(stat -c %Y "$f" 2>/dev/null)
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $(( now - mtime )) -le 5 ]
}

if ! fm_session_start_stage_file_handoff "${FM_SESSION_START_STAGE_FILE:-}"; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*) SESSION_START_BUDGET=120 ;; esac
  [ "$SESSION_START_BUDGET" -gt 0 ] 2>/dev/null || SESSION_START_BUDGET=120
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  DIGEST_CAP_BYTES=${FM_SESSION_START_DIGEST_BYTES:-10240}
  case "$DIGEST_CAP_BYTES" in ''|*[!0-9]*|0) DIGEST_CAP_BYTES=10240 ;; esac
  DIGEST_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-digest.XXXXXX" 2>/dev/null) || DIGEST_TMP=
  if [ -z "$DIGEST_TMP" ]; then
    # Without a capture file the structured bounds still apply; stream directly.
    DIGEST_TMP=/dev/stdout
  fi
  if [ "$REEMIT" -eq 1 ]; then
    if [ -n "$SESSION_SOURCE" ]; then
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SESSION_SOURCE" > "$DIGEST_TMP"
    else
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit > "$DIGEST_TMP"
    fi
  elif [ -n "$SESSION_SOURCE" ]; then
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SESSION_SOURCE" > "$DIGEST_TMP"
  else
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh" > "$DIGEST_TMP"
  fi
  SESSION_START_RC=$?
  if [ "$DIGEST_TMP" != /dev/stdout ]; then
    # The capture below is emitted whole or with whole sections dropped;
    # the truncation banner (further below) prints after it, never cut.
    :
  fi
  # ANY nonzero child exit is a truncation: the banner contract promises that
  # a stage that cannot print is named. Exit 124 is the bound firing; any
  # other status means the child died or was killed mid-stage, which truncates
  # silently when unbanned - the parent must banner it, never exit 0 around it.
  if [ "$DIGEST_TMP" != /dev/stdout ] && [ -f "$DIGEST_TMP" ]; then
    DIGEST_SIZE=$(wc -c < "$DIGEST_TMP" 2>/dev/null | tr -d ' ')
    case "$DIGEST_SIZE" in ''|*[!0-9]*) DIGEST_SIZE=0 ;; esac
    if [ "$DIGEST_SIZE" -le "$DIGEST_CAP_BYTES" ]; then
      cat "$DIGEST_TMP"
    else
      # Drop whole lowest-priority sections only, never a mid-line cut and
      # never WAKE QUEUE/OPEN DECISIONS (inside the first section, kept whole).
      perl -e '
        use strict; use warnings;
        my ($file, $limit) = @ARGV;
        open my $fh, "<:raw", $file or exit 0;
        my @lines = <$fh>; close $fh;
        my @starts;
        for (my $i = 0; $i + 2 < @lines; $i++) {
          if ($lines[$i] =~ /^=+\r?\n?$/ && $lines[$i+2] =~ /^=+\r?\n?$/) {
            push @starts, $i;
          }
        }
        my %pointer = (
          "CONTEXT" => "CONTEXT omitted for $limit-byte digest - data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md, data/learnings.md\n",
          "FLEET STATE" => "FLEET STATE omitted for $limit-byte digest - full sources: data/backlog.md, state/*.meta, state/*.status, bin/fm-crew-state.sh\n",
        );
        my $total = sub { my $s = 0; $s += length $_ for @_; $s };
        for my $drop ("CONTEXT", "FLEET STATE") {
          last if $total->(@lines) <= $limit;
          my @new; my $i = 0;
          while ($i < @lines) {
            my $is_start = grep { $_ == $i } @starts;
            if ($is_start) {
              my $title = $lines[$i+1]; $title =~ s/\s+$//;
              my $j = $i + 1;
              $j++ while $j < @lines && !grep { $_ == $j } @starts;
              if ($title eq $drop) {
                push @new, $lines[$i], $lines[$i+1], $lines[$i+2], $pointer{$drop};
                $i = $j; next;
              }
            }
            push @new, $lines[$i]; $i++;
          }
          @lines = @new;
          @starts = ();
          for (my $k = 0; $k + 2 < @lines; $k++) {
            push @starts, $k if $lines[$k] =~ /^=+\r?\n?$/ && $lines[$k+2] =~ /^=+\r?\n?$/;
          }
        }
        binmode STDOUT, ":raw";
        print @lines;
      ' "$DIGEST_TMP" "$DIGEST_CAP_BYTES" || cat "$DIGEST_TMP"
    fi
    rm -f "$DIGEST_TMP" 2>/dev/null || true
  fi
  if [ "$SESSION_START_RC" -ne 0 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    else
      printf '●  STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit %s, not its runtime bound)\n' "$SESSION_START_RC"
    fi
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
      printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    else
      printf '●  again, report the exit status and the stage - raising the runtime bound\n'
      printf '●  cannot help a digest that died, and a stage that dies is a fleet problem.\n'
    fi
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the fm-bootstrap.sh child, which reports
# an incompatible build as OUTDATED. Computing it once and handing it, with the
# reason behind it, to that child collapses six subprocesses to three; the reason
# travels too so the child's OUTDATED requirement text names a missing capability
# without running the child's own `--help` probes over again. fm-tasks-axi-lib.sh
# owns both reuse layers and the one-hop consumption rule that keeps them out of
# any agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi
TASKS_AXI_CHECK_REASON=$(fm_tasks_axi_check_reason)

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-3}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=3 ;; esac
LIST_LIMIT=${FM_SESSION_START_LIST_LIMIT:-3}
case "$LIST_LIMIT" in ''|*[!0-9]*|0) LIST_LIMIT=3 ;; esac
DIGEST_BYTES=${FM_SESSION_START_DIGEST_BYTES:-10240}
case "$DIGEST_BYTES" in ''|*[!0-9]*|0) DIGEST_BYTES=10240 ;; esac
# The whole re-emit state summary's byte budget; only its mandatory lines
# print past it.
REEMIT_STATE_BYTES=${FM_SESSION_START_REEMIT_STATE_BYTES:-3500}
case "$REEMIT_STATE_BYTES" in ''|*[!0-9]*) REEMIT_STATE_BYTES=3500 ;; esac
[ "$REEMIT_STATE_BYTES" -gt 0 ] 2>/dev/null || REEMIT_STATE_BYTES=3500
# One per-task endpoint read may never outlive this bound: a hung backend CLI
# becomes that task's endpoint: error line instead of the digest's whole
# runtime budget.
ENDPOINT_TIMEOUT=${FM_SESSION_START_ENDPOINT_TIMEOUT:-10}
case "$ENDPOINT_TIMEOUT" in ''|*[!0-9]*) ENDPOINT_TIMEOUT=10 ;; esac
[ "$ENDPOINT_TIMEOUT" -gt 0 ] 2>/dev/null || ENDPOINT_TIMEOUT=10
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason
BACKLOG_REASON_CHARS=100

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2 line total=0 shown=0
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        total=$((total + 1))
        if [ "$shown" -lt "$LIST_LIMIT" ]; then
          fm_cap_line "$line" 120
          shown=$((shown + 1))
        fi
      done < "$path"
      if [ "$total" -gt "$shown" ]; then
        printf '(shown %s of %s line(s) in %s; %s more - read %s)\n' \
          "$shown" "$total" "$label" $((total - shown)) "$path"
      fi
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# print_axi_group_bounded <listing> <label> <pointer>: non-indented header
# lines pass through, indented rows print one capped line each up to
# LIST_LIMIT, then a shown/total disclosure with the full-source pointer.
print_axi_group_bounded() {
  local listing=$1 label=$2 pointer=$3 line total=0 shown=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      help\[*) break ;;
      [[:space:]]*)
        total=$((total + 1))
        if [ "$shown" -lt "$LIST_LIMIT" ]; then
          fm_cap_line "$line" 90
          shown=$((shown + 1))
        fi
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$listing
EOF
  if [ "$total" -gt 0 ]; then
    if [ "$total" -gt "$shown" ]; then
      printf '(shown %s of %s %s item(s); %s more %s - full source: %s)\n' "$shown" "$total" "$label" $((total - shown)) "$label" "$pointer"
    else
      printf '(shown %s of %s %s item(s); full source: %s)\n' "$shown" "$total" "$label" "$pointer"
    fi
  fi
}

print_backlog_pointer() {
  printf 'Full bodies: bin/fm-tasks-axi.sh show <id> --full or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

# oneline_backlog_rows toon|markdown: print each in-flight, held, and blocked
# row as "id | state | reason | full: backlog.md". The reason is read AFTER
# fm_hold_reason_decode_stream, so a marked hold reason shows decoded, then
# collapsed to one line and cut at BACKLOG_REASON_CHARS with an ellipsis.
# toon: the rows under a tasks[N]{...} header; every other line passes through.
# markdown: only lines the manual renderer tagged with a leading \001<state>\001.
oneline_backlog_rows() {
  perl -MJSON::PP -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my ($format, $max) = @ARGV;
    my $json = JSON::PP->new->allow_nonref;
    sub reason_text {
      my ($text) = @_;
      if ($text =~ /^"/) { my $v = eval { $json->decode($text) }; $text = $v if defined $v; }
      $text =~ s/\s+/ /g;
      $text =~ s/^ | $//g;
      $text = "-" if $text eq "";
      $text = substr($text, 0, $max) . "..." if length($text) > $max;
      return $text;
    }
    sub emit {
      my ($id, $state, $reason) = @_;
      print "  $id | $state | ", reason_text($reason), " | full: backlog.md\n";
    }
    my @names;
    while (my $line = <STDIN>) {
      chomp $line;
      if ($format eq "markdown") {
        if ($line =~ s/^\x01([a-z_]+)\x01//) {
          my $state = $1;
          my ($id) = $line =~ /^[-*]\s+\[[^\]]*\]\s+(\S+)/;
          $id = "?" unless defined $id;
          my $reason = "-";
          if ($line =~ /\(hold: (.*)$/) {
            $reason = $1;
            $reason =~ s/\)\s*\(hold-kind:[^)]*\)\s*$//;
            $reason =~ s/\)\s*$//;
          } elsif ($line =~ /(blocked-by: [^\s()]+)/) {
            $reason = $1;
          }
          emit($id, $state, $reason);
        } else {
          print "$line\n";
        }
      } elsif ($line =~ /^tasks\[(\d+)\]\{([^}]*)\}:$/) {
        @names = split /,/, $2;
        print "tasks[$1]{id,state,reason}:\n";
      } elsif (@names && $line =~ /^  (.*)$/) {
        my @f = $1 =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
        my %row;
        @row{@names} = @f;
        my $reason = defined $row{hold_reason} ? $row{hold_reason} : "-";
        $reason = "-" if $reason eq q("-");
        if (($reason eq "-" || $reason eq "") && defined $row{blocked_by} && $row{blocked_by} !~ /^(none|-)$/) {
          $reason = "blocked-by: $row{blocked_by}";
        }
        emit($row{id}, $row{state}, $reason);
      } else {
        @names = () if $line !~ /^  /;
        print "$line\n";
      }
    }
  ' "$1" "$BACKLOG_REASON_CHARS"
}

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; in-flight, held, and blocked title lines bounded to %s each; other queued bounded to %s; indented task bodies omitted; full source: data/backlog.md)\n' \
    "$reason" "$LIST_LIMIT" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v list_max="$LIST_LIMIT" -v keep_re="$MANUAL_KEEP_RE" '
    function cap(s) { if (length(s) > 90) return substr(s, 1, 77) " [truncated]"; return s }
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; if (in_flight_shown < list_max) { print "\001in_flight\001" $0; in_flight_shown++ } next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; if (gated_shown < list_max) { print "\001queued\001" $0; gated_shown++ } next }
      if (plain_shown < max) { plain_shown++; print cap($0) }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d in-flight, %d of %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted; full source: data/backlog.md)\n", \
          in_flight_shown, in_flight, gated_shown, gated, plain_shown, plain_total, done_total
        if (in_flight > in_flight_shown) {
          printf "(%d more in-flight - read data/backlog.md for the rest)\n", in_flight - in_flight_shown
        }
        if (gated > gated_shown) {
          printf "(%d more held or blocked queued - read data/backlog.md for the rest)\n", gated - gated_shown
        }
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' <(fm_hold_reason_decode_stream markdown < "$path") | oneline_backlog_rows markdown
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly.
print_ready_queued_bounded() {
  local ready=$1
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" '
    function cap(s) { if (length(s) > 90) return substr(s, 1, 77) " [truncated]"; return s }
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print cap($0); shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        if (total > shown) printf "(shown %d of %d ready queued item(s); %d more queued - bin/fm-tasks-axi.sh ready)\n", shown, total, total - shown
        else printf "(shown %d of %d ready queued item(s))\n", shown, total
      }
    }
  '
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; bounded to %s each; full source: data/backlog.md)\n' \
      "$LIST_LIMIT" "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    print_axi_group_bounded "$(printf '%s\n' "$in_flight" | fm_hold_reason_decode_stream | strip_axi_help | oneline_backlog_rows toon)" "in-flight" "data/backlog.md"
    printf '\nheld:\n'
    print_axi_group_bounded "$(printf '%s\n' "$held" | fm_hold_reason_decode_stream | strip_axi_help | oneline_backlog_rows toon)" "held" "data/backlog.md"
    printf '\nblocked queued:\n'
    print_axi_group_bounded "$(printf '%s\n' "$blocked" | fm_hold_reason_decode_stream | strip_axi_help | oneline_backlog_rows toon)" "blocked queued" "data/backlog.md"
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$ready"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$FM_LINE_CAP_DEFAULT" "$status"
  # A crewmate writes its own status lines, so their length is unbounded: one
  # observed line ran 865 characters. Cap each one the way the wake digest's
  # OPEN DECISIONS section does; the lede carries the state word and the key,
  # and the full log path above reaches the rest.
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

# endpoint_verdict <meta> <id>: one bounded endpoint-liveness read, shared by
# the full record dump and the re-emit state summary. Sets ENDPOINT_VERDICT
# (alive, dead, error, or unknown when no window is recorded), ENDPOINT_BACKEND,
# and ENDPOINT_WINDOW.
endpoint_verdict() {
  local meta=$1 id=$2 target endpoint_rc=0
  ENDPOINT_WINDOW=$(fm_meta_get "$meta" window)
  ENDPOINT_BACKEND=
  if [ -z "$ENDPOINT_WINDOW" ]; then
    ENDPOINT_VERDICT=unknown
    return 0
  fi
  target=$(fm_backend_target_of_meta "$meta")
  ENDPOINT_BACKEND=$(fm_backend_of_meta "$meta")
  fm_session_start_endpoint_read "$ENDPOINT_BACKEND" "${target:-$ENDPOINT_WINDOW}" "fm-$id" || endpoint_rc=$?
  # Only the timeout owner's own statuses mean the read itself failed: 124 is
  # the bound firing and >=128 is a signal death. Every other nonzero status
  # is the probe's own verdict that the endpoint is gone.
  if [ "$endpoint_rc" -eq 0 ]; then
    ENDPOINT_VERDICT=alive
  elif [ "$endpoint_rc" -eq 124 ] || [ "$endpoint_rc" -ge 128 ]; then
    ENDPOINT_VERDICT=error
  else
    ENDPOINT_VERDICT=dead
  fi
}

endpoint_verdict_line() {  # the record dump's endpoint line for the last endpoint_verdict
  case "$ENDPOINT_VERDICT" in
    unknown) printf 'endpoint: unknown (no window recorded)\n' ;;
    error)
      printf 'endpoint: error (backend=%s window=%s - the endpoint read died or hit its %ss bound; the digest continued past it)\n' \
        "$ENDPOINT_BACKEND" "$ENDPOINT_WINDOW" "$ENDPOINT_TIMEOUT"
      ;;
    *) printf 'endpoint: %s (backend=%s window=%s)\n' "$ENDPOINT_VERDICT" "$ENDPOINT_BACKEND" "$ENDPOINT_WINDOW" ;;
  esac
}

# print_fleet_records_full: the startup record dump - the compact backlog
# listing, every state/*.meta with its endpoint line and status tail, and the
# orphan status logs.
print_fleet_records_full() {
  local meta id kind mode yolo branch worktree project status latest endpoint_detail total=0 shown=0
  print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

  subsection "Work under way (state/*.meta)"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    total=$((total + 1))
  done
  if [ "$total" -gt 0 ]; then
    printf '(shown up to %s of %s meta record(s); %s more meta record(s) - full source: state/<id>.meta or bin/fm-crew-state.sh)\n' "$LIST_LIMIT" "$total" $((total > LIST_LIMIT ? total - LIST_LIMIT : 0))
  fi
  total=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    total=$((total + 1))
    [ "$shown" -lt "$LIST_LIMIT" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind); [ -n "$kind" ] || kind=ship
    mode=$(fm_meta_get "$meta" mode)
    yolo=$(fm_meta_get "$meta" yolo)
    branch=$(fm_meta_get "$meta" branch)
    worktree=$(fm_meta_get "$meta" worktree)
    project=$(fm_meta_get "$meta" project)
    status="$STATE/$id.status"
    endpoint_verdict "$meta" "$id"
    latest='(no status file yet)'
    if [ -f "$status" ]; then
      latest=$(last_status_line "$status" 2>/dev/null || true)
      [ -n "$latest" ] || latest='(empty status log)'
    fi
    fm_cap_line_var "$latest" 100
    latest=$FM_LINE_CAP_LINE
    case "$ENDPOINT_VERDICT" in
      unknown) endpoint_detail='endpoint: unknown (no window recorded)' ;;
      error) endpoint_detail="endpoint: error (backend=$ENDPOINT_BACKEND window=$ENDPOINT_WINDOW - the endpoint read died or hit its ${ENDPOINT_TIMEOUT}s bound; the digest continued past it)" ;;
      *) endpoint_detail="endpoint: $ENDPOINT_VERDICT (backend=$ENDPOINT_BACKEND window=$ENDPOINT_WINDOW)" ;;
    esac
    fm_cap_line "- --- $id --- kind=$kind${mode:+ mode=$mode}${yolo:+ yolo=$yolo} $endpoint_detail${branch:+ branch=$branch}${worktree:+ worktree=$worktree} status=$latest (full: $status)" 300
    shown=$((shown + 1))
  done
  [ "$total" -gt 0 ] || printf '(none)\n'

  subsection "Orphan status logs (state/*.status without matching .meta)"
  total=0; shown=0
  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    [ -f "$STATE/$id.meta" ] && continue
    total=$((total + 1))
    [ "$shown" -lt 1 ] || continue
    latest=$(last_status_line "$status" 2>/dev/null || true)
    [ -n "$latest" ] || latest='(empty status log)'
    fm_cap_line_var "$latest" 60
    latest=$FM_LINE_CAP_LINE
    fm_cap_line "- --- $id --- status=$latest (full: $status)" 220
    shown=$((shown + 1))
  done
  [ "$total" -gt 0 ] || printf '(none)\n'
  if [ "$total" -gt 0 ]; then
    printf '(shown %s of %s orphan status log(s); full source: %s/<id>.status)\n' "$shown" "$total" "$STATE"
    if [ "$total" -gt "$shown" ]; then
      printf '(%s more orphan status log(s) - ls %s/*.status)\n' $((total - shown)) "$STATE"
    fi
  fi
}

# --- context re-emit state summary --------------------------------------------
# This file's header ("CONTEXT RE-EMIT STATE SUMMARY") owns what it keeps and
# drops. Every printed line is charged to REEMIT_STATE_USED in bytes. The
# optional rows after OPEN ITEMS are gathered into groups before anything after
# OPEN ITEMS prints, so each is admitted only when the exact size of the whole
# summary with it, the closing tally included, stays within the budget.
REEMIT_STATE_USED=0
REEMIT_STATE_DIR=state
REEMIT_RECEIPTS=
REEMIT_OPEN_KEY_LIMIT=4
# Each summarized event or backlog row keeps its lede within this many
# characters; the full log or listing command reaches the rest.
REEMIT_LINE_CAP=160
# The optional groups, in print and admission order: group g owns
# REEMIT_G_TOTAL[g] rows of REEMIT_ROWS from REEMIT_G_FIRST[g], of which the
# first REEMIT_G_SHOWN[g] print, and REEMIT_ROW_CUM[k] is the byte cost of every
# row before row k.
REEMIT_G_COUNT=0
REEMIT_G_KIND=()
REEMIT_G_LABEL=()
REEMIT_G_COMMAND=()
REEMIT_G_FIRST=()
REEMIT_G_TOTAL=()
REEMIT_G_SHOWN=()
REEMIT_ROWS=()
REEMIT_ROW_CUM=(0)
REEMIT_BACKLOG_LINES=()
REEMIT_IDS_LEAD='  ids:'

reemit_bytes() {  # <text>: its length in bytes, in REEMIT_BYTES
  local LC_ALL=C
  REEMIT_BYTES=${#1}
}

reemit_state_put() {  # <line>: print one line and charge it to the budget
  local LC_ALL=C
  printf '%s\n' "$1"
  REEMIT_STATE_USED=$((REEMIT_STATE_USED + ${#1} + 1))
}

reemit_state_subsection() {  # <label>
  reemit_state_put ''
  reemit_state_put "$1"
  reemit_state_put "$SUBRULE"
}

# reemit_receipts_add <text>: append every file path <text> cites to the
# newline-separated REEMIT_RECEIPTS, keeping the first citation of each. A path
# is an absolute path with at least two components, or one under data/ or
# state/; URLs are PR identities, not receipts. A path inside this home is
# kept relative to it, the spelling the summary's lede names, so one receipt
# cited both ways is listed once.
reemit_receipts_add() {
  local word
  local -a words=()
  read -r -a words <<<"$1" || true
  for word in "${words[@]+"${words[@]}"}"; do
    case "$word" in *://*) continue ;; esac
    while :; do
      case "$word" in [\(\"\'\`\<\[]*) word=${word#?} ;; *) break ;; esac
    done
    case "$word" in [A-Za-z_]*=/*) word=${word#*=} ;; esac
    while :; do
      case "$word" in *[.,\;:\)\"\'\`\>\]]) word=${word%?} ;; *) break ;; esac
    done
    case "$word" in /?*/?*|data/?*|state/?*) ;; *) continue ;; esac
    case "$word" in "$FM_HOME"/?*) word=${word#"$FM_HOME"/} ;; esac
    case $'\n'"$REEMIT_RECEIPTS" in *$'\n'"$word"$'\n'*) continue ;; esac
    REEMIT_RECEIPTS="$REEMIT_RECEIPTS$word"$'\n'
  done
}

reemit_worktree_head() {  # <meta>: the exact worktree HEAD, or why it is unknown
  local meta=$1 wt remote head
  wt=$(fm_meta_get "$meta" worktree)
  remote=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote" ]; then
    printf 'unknown(worktree on %s)' "$remote"
  elif [ -z "$wt" ]; then
    printf 'unknown(no worktree recorded)'
  elif [ ! -d "$wt" ]; then
    printf 'unknown(worktree missing)'
  elif head=$(fm_run_timed "$ENDPOINT_TIMEOUT" git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) \
    && fm_pr_head_valid "$head"; then
    printf '%s' "$head"
  else
    printf 'unknown(worktree HEAD unreadable)'
  fi
}

# reemit_pr_state <meta> <id>: the recorded PR's state from local merge evidence
# only - the same records bin/fm-afk-return.sh and bin/fm-crew-state.sh accept -
# never a forge read.
reemit_pr_state() {
  local meta=$1 id=$2
  if fm_pr_metadata_identity_parse "$meta" \
    && fm_pr_poll_merge_already_notified "$STATE" "$id" \
      "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"; then
    printf 'merged(merge record)'
  elif fm_pr_poll_retirement_receipt_valid "$STATE" "$id"; then
    printf 'merged(retirement receipt)'
  elif [ -f "$STATE/$id.pr-poll" ] && [ -f "$STATE/$id.check.sh" ]; then
    printf 'watching(merge poll armed, no merge recorded)'
  else
    printf 'unwatched(no merge poll or merge record)'
  fi
}

# reemit_status_state <status-file>: the latest event with its identical
# repeats collapsed to a count and the other events in the classifier's event
# window collapsed to one earlier-event count, the task's open decision keys,
# and the receipts those lines cite.
reemit_status_state() {
  local status=$1 latest want line untimed verb repeats=0 earlier=0 label
  local open row key rest i shown=0 keys='' entry
  local -a lines=() rows=()
  latest=$(last_status_line "$status")
  _fm_status_untimed "$latest" want
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_status_untimed "$line" untimed
    if [ "$untimed" = "$want" ]; then
      repeats=$((repeats + 1))
      continue
    fi
    case "$line" in *:*) status_line_verb "$line" verb ;; *) continue ;; esac
    _fm_status_verb_recognized "$verb" && earlier=$((earlier + 1))
  done < <(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$status" 2>/dev/null)

  if [ -z "$latest" ]; then
    reemit_state_put "  latest event: (empty status log)"
  else
    label="latest event"
    [ "$repeats" -le 1 ] || label="$label x$repeats"
    [ "$earlier" -eq 0 ] || label="$label (+$earlier earlier)"
    fm_cap_line_var "$latest" "$REEMIT_LINE_CAP"
    reemit_state_put "  $label: $FM_LINE_CAP_LINE"
  fi

  open=$(status_open_decisions_incremental "$status") || open=
  while IFS= read -r row; do
    [ -n "$row" ] && rows[${#rows[@]}]=$row
  done <<EOF
$open
EOF
  # Newest first: the fold lists the most recently opened decision last.
  i=${#rows[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    row=${rows[i]}
    key=${row%%$'\t'*}
    rest=${row#*$'\t'}
    if [ "$shown" -lt "$REEMIT_OPEN_KEY_LIMIT" ]; then
      keys="$keys${keys:+, }$key(${rest%%$'\t'*})"
      shown=$((shown + 1))
    fi
    reemit_receipts_add "${rest#*$'\t'}"
  done
  if [ "${#rows[@]}" -gt 0 ]; then
    entry="  open decisions (${#rows[@]}): $keys"
    [ "${#rows[@]}" -le "$shown" ] || entry="$entry, +$((${#rows[@]} - shown)) more"
    reemit_state_put "$entry"
  fi

  # After the open decisions' receipts, newest first: the latest event, then
  # the recent tail.
  reemit_receipts_add "$latest"
  while IFS= read -r line || [ -n "$line" ]; do
    lines[${#lines[@]}]=$line
  done < <(tail -n "$STATUS_TAIL" "$status" 2>/dev/null)
  i=${#lines[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    reemit_receipts_add "${lines[i]}"
  done
}

reemit_state_task_entry() {  # <meta>
  local meta=$1 id kind mode yolo branch head pr pr_head line status path listed=''
  id=$(basename "$meta" .meta)
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  mode=$(fm_meta_get "$meta" mode)
  [ "$mode" != "$kind" ] || mode=
  yolo=$(fm_meta_get "$meta" yolo)
  endpoint_verdict "$meta" "$id"
  line="- $id [$kind${mode:+ $mode}${yolo:+ yolo=$yolo}] endpoint=$ENDPOINT_VERDICT"
  # A dead endpoint has no window worth opening, so only a live or unread one
  # names it.
  case "$ENDPOINT_VERDICT" in
    unknown) line="$line(no window recorded)" ;;
    error) line="$line($ENDPOINT_BACKEND $ENDPOINT_WINDOW: the read died or hit its ${ENDPOINT_TIMEOUT}s bound)" ;;
    alive) line="$line($ENDPOINT_BACKEND $ENDPOINT_WINDOW)" ;;
  esac
  reemit_state_put "$line"
  if [ "$kind" != secondmate ]; then
    branch=$(fm_meta_get "$meta" branch)
    head=$(reemit_worktree_head "$meta")
    pr=$(fm_meta_get "$meta" pr)
    line="  branch=${branch:-none} head=$head"
    if [ -n "$pr" ]; then
      pr_head=$(fm_meta_get "$meta" pr_head)
      [ "$pr_head" != "$head" ] || pr_head='head'
      line="$line pr=$pr pr_head=${pr_head:-none} pr_state=$(reemit_pr_state "$meta" "$id")"
    else
      line="$line pr=none"
    fi
    reemit_state_put "$line"
  fi

  REEMIT_RECEIPTS=
  [ ! -f "$DATA/$id/report.md" ] || reemit_receipts_add "$DATA/$id/report.md"
  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    reemit_status_state "$status"
  else
    reemit_state_put "  latest event: (no status file yet)"
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    listed="$listed $path"
  done <<EOF
$REEMIT_RECEIPTS
EOF
  [ -z "$listed" ] || reemit_state_put "  receipts:$listed"
}

# reemit_group_open <kind> <label> <command>: start gathering one optional
# group. Kind `rows` is a titled listing with one row per line, `lines` the
# untitled manual backlog listing, and `ids` the closed-log ids, which share
# one line.
reemit_group_open() {
  REEMIT_G_KIND[REEMIT_G_COUNT]=$1
  REEMIT_G_LABEL[REEMIT_G_COUNT]=$2
  REEMIT_G_COMMAND[REEMIT_G_COUNT]=$3
  REEMIT_G_FIRST[REEMIT_G_COUNT]=${#REEMIT_ROWS[@]}
  REEMIT_G_TOTAL[REEMIT_G_COUNT]=0
  REEMIT_G_SHOWN[REEMIT_G_COUNT]=0
}

# reemit_group_row <text>: add one row to the group being gathered. Its cost is
# its bytes plus one, its own newline or, for an id, its leading space.
reemit_group_row() {
  local n=${#REEMIT_ROWS[@]}
  reemit_bytes "$1"
  REEMIT_ROWS[n]=$1
  REEMIT_ROW_CUM[n + 1]=$((REEMIT_ROW_CUM[n] + REEMIT_BYTES + 1))
  REEMIT_G_TOTAL[REEMIT_G_COUNT]=$((REEMIT_G_TOTAL[REEMIT_G_COUNT] + 1))
}

reemit_group_close() {  # keep the gathered group only when it has rows
  [ "${REEMIT_G_TOTAL[REEMIT_G_COUNT]}" -eq 0 ] || REEMIT_G_COUNT=$((REEMIT_G_COUNT + 1))
}

# reemit_group_frame <g> <shown>: the heading and the disclosure group g prints
# around its first <shown> rows, each empty when it prints none, and the exact
# bytes the whole group then prints, in REEMIT_GROUP_HEAD, REEMIT_GROUP_TAIL,
# and REEMIT_GROUP_BYTES.
reemit_group_frame() {
  local g=$1 shown=$2 label command total first
  label=${REEMIT_G_LABEL[g]}
  command=${REEMIT_G_COMMAND[g]}
  total=${REEMIT_G_TOTAL[g]}
  first=${REEMIT_G_FIRST[g]}
  REEMIT_GROUP_BYTES=$((REEMIT_ROW_CUM[first + shown] - REEMIT_ROW_CUM[first]))
  REEMIT_GROUP_HEAD=
  REEMIT_GROUP_TAIL=
  case "${REEMIT_G_KIND[g]}" in
    rows)
      if [ "$shown" -eq 0 ]; then
        REEMIT_GROUP_TAIL="$label: $total row(s) omitted by the state budget - $command"
      else
        REEMIT_GROUP_HEAD="$label ($total):"
        [ "$shown" -eq "$total" ] \
          || REEMIT_GROUP_TAIL="  (+$((total - shown)) more omitted by the state budget - $command)"
      fi
      ;;
    lines)
      [ "$shown" -eq "$total" ] \
        || REEMIT_GROUP_TAIL="(+$((total - shown)) $label omitted by the state budget - $command)"
      ;;
    ids)
      REEMIT_GROUP_HEAD="$label: $total"
      if [ "$shown" -gt 0 ]; then
        reemit_bytes "$REEMIT_IDS_LEAD"
        REEMIT_GROUP_BYTES=$((REEMIT_GROUP_BYTES + REEMIT_BYTES + 1))
      fi
      [ "$shown" -eq "$total" ] \
        || REEMIT_GROUP_TAIL="  (+$((total - shown)) more ids omitted by the state budget - $command)"
      ;;
  esac
  if [ -n "$REEMIT_GROUP_HEAD" ]; then
    reemit_bytes "$REEMIT_GROUP_HEAD"
    REEMIT_GROUP_BYTES=$((REEMIT_GROUP_BYTES + REEMIT_BYTES + 1))
  fi
  if [ -n "$REEMIT_GROUP_TAIL" ]; then
    reemit_bytes "$REEMIT_GROUP_TAIL"
    REEMIT_GROUP_BYTES=$((REEMIT_GROUP_BYTES + REEMIT_BYTES + 1))
  fi
}

reemit_group_print() {  # <g>: print group g with its admitted rows
  local g=$1 shown first i=0 ids=''
  shown=${REEMIT_G_SHOWN[g]}
  first=${REEMIT_G_FIRST[g]}
  reemit_group_frame "$g" "$shown"
  [ -z "$REEMIT_GROUP_HEAD" ] || reemit_state_put "$REEMIT_GROUP_HEAD"
  while [ "$i" -lt "$shown" ]; do
    if [ "${REEMIT_G_KIND[g]}" = ids ]; then
      ids="$ids ${REEMIT_ROWS[first + i]}"
    else
      reemit_state_put "${REEMIT_ROWS[first + i]}"
    fi
    i=$((i + 1))
  done
  [ -z "$ids" ] || reemit_state_put "$REEMIT_IDS_LEAD$ids"
  [ -z "$REEMIT_GROUP_TAIL" ] || reemit_state_put "$REEMIT_GROUP_TAIL"
}

# reemit_state_admit <bytes>: choose, group by group in order, the most rows
# each group can print while the whole summary - <bytes> of mandatory lines,
# every earlier group as chosen, and every later group at its disclosure
# alone - stays within the budget. Each row past the first that still leaves
# rows cut costs strictly more bytes, so that scan stops at the first misfit;
# printing every row drops the disclosure, so that is tried on its own first.
reemit_state_admit() {
  local total=$1 g=0 base shown
  local -a bytes=()
  while [ "$g" -lt "$REEMIT_G_COUNT" ]; do
    reemit_group_frame "$g" 0
    bytes[g]=$REEMIT_GROUP_BYTES
    total=$((total + REEMIT_GROUP_BYTES))
    g=$((g + 1))
  done
  g=0
  while [ "$g" -lt "$REEMIT_G_COUNT" ]; do
    base=$((total - bytes[g]))
    reemit_group_frame "$g" "${REEMIT_G_TOTAL[g]}"
    if [ $((base + REEMIT_GROUP_BYTES)) -le "$REEMIT_STATE_BYTES" ]; then
      REEMIT_G_SHOWN[g]=${REEMIT_G_TOTAL[g]}
      bytes[g]=$REEMIT_GROUP_BYTES
    else
      shown=1
      while [ "$shown" -lt "${REEMIT_G_TOTAL[g]}" ]; do
        reemit_group_frame "$g" "$shown"
        [ $((base + REEMIT_GROUP_BYTES)) -le "$REEMIT_STATE_BYTES" ] || break
        REEMIT_G_SHOWN[g]=$shown
        bytes[g]=$REEMIT_GROUP_BYTES
        shown=$((shown + 1))
      done
    fi
    total=$((base + bytes[g]))
    g=$((g + 1))
  done
}

# reemit_tally_text <total> <open-bytes>: the closing tally for a summary of
# <total> bytes, in REEMIT_TALLY with its byte length in REEMIT_BYTES.
reemit_tally_text() {
  if [ "$1" -le "$REEMIT_STATE_BYTES" ]; then
    REEMIT_TALLY="STATE SUMMARY: $1 of $REEMIT_STATE_BYTES bytes, this line included."
  else
    REEMIT_TALLY="STATE SUMMARY: $1 bytes with this line, over the $REEMIT_STATE_BYTES-byte budget, so only its mandatory lines printed: the lede, OPEN ITEMS ($2 bytes), the counts, the cut disclosures, and this tally."
  fi
  reemit_bytes "$REEMIT_TALLY"
}

# reemit_state_tally <bytes-before> <open-bytes>: the closing tally whose count
# includes the tally line itself - the least total that equals the bytes before
# it plus its own line.
reemit_state_tally() {
  local before=$1 total=$1 next
  while :; do
    reemit_tally_text "$total" "$2"
    next=$((before + REEMIT_BYTES + 1))
    [ "$next" -ne "$total" ] || return 0
    total=$next
  done
}

# reemit_gather_rows <label> <listing> <command> [untracked]: the indented rows
# of one tasks-axi listing, each capped, as one optional group. With
# `untracked`, rows whose task already has a state/*.meta entry above are
# skipped, because OPEN ITEMS already carries them.
reemit_gather_rows() {
  local label=$1 listing=$2 command=$3 filter=${4:-} line id in_rows=0
  reemit_group_open rows "$label" "$command"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      help\[*) break ;;
      tasks\[*|ready\[*) in_rows=1; continue ;;
      [[:space:]]*) [ "$in_rows" -eq 1 ] || continue ;;
      *) in_rows=0; continue ;;
    esac
    if [ "$filter" = untracked ]; then
      id=${line#"${line%%[![:space:]]*}"}
      id=${id%%,*}
      [ ! -f "$STATE/$id.meta" ] || continue
    fi
    fm_cap_line_var "$line" "$REEMIT_LINE_CAP"
    reemit_group_row "$FM_LINE_CAP_LINE"
  done <<EOF
$listing
EOF
  reemit_group_close
}

reemit_axi_count() {  # <listing>: the tool's own "count: N" line
  local line
  while IFS= read -r line; do
    case "$line" in "count: "*) printf '%s' "${line#count: }"; return 0 ;; esac
  done <<EOF
$1
EOF
  printf '?'
}

# reemit_gather_backlog: the backlog heading and counts, which always print,
# into REEMIT_BACKLOG_LINES, and its rows as optional groups.
reemit_gather_backlog() {
  local path="$DATA/backlog.md" in_flight held blocked ready listing line
  REEMIT_BACKLOG_LINES=('' "Backlog (data/backlog.md; done rows omitted; full bodies: bin/fm-tasks-axi.sh show <id> --full)" "$SUBRULE")
  if [ ! -f "$path" ]; then
    REEMIT_BACKLOG_LINES[${#REEMIT_BACKLOG_LINES[@]}]='ABSENT'
    return 0
  fi
  if [ ! -s "$path" ]; then
    REEMIT_BACKLOG_LINES[${#REEMIT_BACKLOG_LINES[@]}]='(present, empty)'
    return 0
  fi
  if fm_tasks_axi_backend_available "$CONFIG" \
    && in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>/dev/null) \
    && held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>/dev/null) \
    && blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>/dev/null) \
    && ready=$(tasks-axi ready --file "$path" 2>/dev/null); then
    in_flight=$(printf '%s\n' "$in_flight" | fm_hold_reason_decode_stream)
    held=$(printf '%s\n' "$held" | fm_hold_reason_decode_stream)
    blocked=$(printf '%s\n' "$blocked" | fm_hold_reason_decode_stream)
    REEMIT_BACKLOG_LINES[${#REEMIT_BACKLOG_LINES[@]}]="counts: $(reemit_axi_count "$in_flight") in flight, $(reemit_axi_count "$held") held, $(reemit_axi_count "$blocked") blocked queued, $(reemit_axi_count "$ready") ready queued"
    reemit_gather_rows "held" "$held" "bin/fm-tasks-axi.sh list --state held"
    reemit_gather_rows "blocked queued" "$blocked" "bin/fm-tasks-axi.sh list --state queued --blocked"
    reemit_gather_rows "in flight with no task record" "$in_flight" "bin/fm-tasks-axi.sh list --state in_flight" untracked
    reemit_gather_rows "ready queued" "$ready" "bin/fm-tasks-axi.sh ready"
    return 0
  fi
  # The title-line renderer, budgeted line by line; it needs no task model.
  if fm_backlog_backend_manual "$CONFIG"; then
    listing=$(print_backlog_manual_compact "$path" "manual backend")
  else
    listing=$(print_backlog_manual_compact "$path" "tasks-axi unavailable, incompatible, or failed")
  fi
  reemit_group_open lines "backlog listing line(s)" "data/backlog.md"
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line_var "$line" "$REEMIT_LINE_CAP"
    reemit_group_row "$FM_LINE_CAP_LINE"
  done <<EOF
$listing
EOF
  reemit_group_close
}

# Status logs whose task record is gone: cleaned-up work, counted and named
# but never replayed.
reemit_gather_closed_logs() {
  local status id
  reemit_group_open ids "closed task logs ($REEMIT_STATE_DIR/*.status with no task record, not replayed)" \
    "ls $REEMIT_STATE_DIR/*.status"
  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    [ -f "$STATE/$id.meta" ] && continue
    reemit_group_row "$id"
  done
  reemit_group_close
}

print_reemit_state_summary() {
  local meta found=0 open_start open_bytes line mandatory g=0
  REEMIT_STATE_USED=0
  REEMIT_G_COUNT=0
  REEMIT_ROWS=()
  REEMIT_ROW_CUM=(0)
  REEMIT_STATE_DIR=$STATE
  case "$STATE" in "$FM_HOME"/?*) REEMIT_STATE_DIR=${STATE#"$FM_HOME"/} ;; esac
  reemit_state_put "Context re-emit: CURRENT STATE, not the log. Repeated status events are collapsed to counts,"
  reemit_state_put "superseded and resolved history is dropped, and cleaned-up tasks are counted, not replayed."
  reemit_state_put "Status lines are wake EVENTS: bin/fm-crew-state.sh <id> owns current state, $REEMIT_STATE_DIR/<id>.status"
  reemit_state_put "holds each full log, and OPEN DECISIONS in the WAKE QUEUE above carries decision notes."
  reemit_state_put "Relative paths are under $FM_HOME; pr_state reads local merge evidence only, never the"
  reemit_state_put "forge, and pr_head=head means the PR records the exact worktree head shown beside it."
  reemit_state_put "Budget: $REEMIT_STATE_BYTES bytes for this whole summary, lede and tally included; the mandatory lede,"
  reemit_state_put "OPEN ITEMS, counts, cut disclosures, and tally always print, and other rows only while the whole fits."

  open_start=$REEMIT_STATE_USED
  reemit_state_subsection "OPEN ITEMS (mandatory count: state/*.meta records, first $LIST_LIMIT shown, rest counted)"
  local meta_total=0 meta_shown=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    found=1
    meta_total=$((meta_total + 1))
    [ "$meta_shown" -lt "$LIST_LIMIT" ] || continue
    meta_shown=$((meta_shown + 1))
    reemit_state_task_entry "$meta"
  done
  [ "$found" -eq 1 ] || reemit_state_put '(none)'
  if [ "$meta_total" -gt 0 ]; then
    reemit_state_put "(shown $meta_shown of $meta_total meta record(s); full source: cat $STATE/<id>.meta or bin/fm-crew-state.sh)"
    [ "$meta_total" -le "$meta_shown" ] || reemit_state_put "($((meta_total - meta_shown)) more meta record(s) - cat $STATE/<id>.meta or bin/fm-crew-state.sh)"
  fi
  open_bytes=$((REEMIT_STATE_USED - open_start))

  reemit_gather_backlog
  reemit_gather_closed_logs
  # The mandatory bytes still to come: the backlog heading and counts, the
  # blank line, and the tally at its longest within-budget spelling.
  mandatory=$REEMIT_STATE_USED
  for line in "${REEMIT_BACKLOG_LINES[@]}"; do
    reemit_bytes "$line"
    mandatory=$((mandatory + REEMIT_BYTES + 1))
  done
  reemit_tally_text "$REEMIT_STATE_BYTES" "$open_bytes"
  reemit_state_admit $((mandatory + 1 + REEMIT_BYTES + 1))

  for line in "${REEMIT_BACKLOG_LINES[@]}"; do
    reemit_state_put "$line"
  done
  while [ "$g" -lt "$REEMIT_G_COUNT" ]; do
    reemit_group_print "$g"
    g=$((g + 1))
  done
  reemit_state_put ''
  reemit_state_tally "$REEMIT_STATE_USED" "$open_bytes"
  reemit_state_put "$REEMIT_TALLY"
}

# fm_session_start_endpoint_read <backend> <target> [expected-label]: ONE
# bounded, crash-isolated endpoint-liveness read. The read runs in its own
# bash under fm_run_timed's bound instead of in this digest process, because
# a per-task backend liveness read that dies mid-read would otherwise take
# every later stage with it. Isolation turns any death, hang, or nonzero
# surprise in one task's read into that task's own endpoint line - never a
# silently missing rest of digest. The inner bash re-sources fm-backend.sh
# per read; that cost is a few milliseconds per task and buys the isolation.
fm_session_start_endpoint_read() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 label=${3:-}
  # shellcheck disable=SC2016  # Positional parameters expand inside the child bash, not here.
  fm_run_timed "$ENDPOINT_TIMEOUT" bash -c '
    . "$1"
    fm_backend_target_exists "$2" "$3" "$4"
  ' _ "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$label"
}

hash_file_sha256() {
  local file=$1 digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  return 1
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid baseline_hash current_hash
  [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ] || return 0
  baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  current_hash=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
  [ -n "$current_hash" ] || return 0
  [ "$baseline_pid" = "$lock_pid" ] && [ "$baseline_hash" = "$current_hash" ] && return 1
  return 0
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Firstmate delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  agents_refresh_required "$lock_pid" || return 0
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  if [ -f "$FM_ROOT/AGENTS.md" ]; then
    cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    cat "$FM_ROOT/AGENTS.md"
  else
    printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
  fi
}

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && { [ "$SESSION_SOURCE" = startup ] || [ -z "$SESSION_SOURCE" ]; }; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

if [ "$REEMIT" -eq 1 ]; then
  # First in the output on purpose: a harness that spills a large hook output
  # delivers only a short head inline (Claude: about 2,000 characters), and
  # CONTEXT prints last, so this cue is the part that must survive the spill.
  printf 'RE-EMIT CUE: if this output ends with "Output too large ... Full output saved to <path>",\n'
  printf 'read that whole file now, before acting. Otherwise read data/captain.md, data/captain-shared.md,\n'
  printf 'and data/learnings.md under %s now if any of them is missing below.\n' "$DATA"
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'secondmate convergence and liveness, pending remote handoff\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $FM_HOME"
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
REBUILDING_SESSION_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"

# --- 1b. home role -------------------------------------------------------
# This home's firstmate-repository role: user/operator unless an explicit
# local or receipt-proven inherited grant says otherwise (bin/fm-role-lib.sh).
# Purely local resolution - no network, no gh call.
stage role
subsection "HOME ROLE"
FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-role.sh" report 2>/dev/null \
  || printf 'fm-role: unknown (bin/fm-role.sh report failed)\n'

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # A full locked start publishes this home's current structured summary.
  # Publication is side-band and best-effort, so it can never change the
  # session-start result. A context re-emit is not another session start.
  if [ "$REEMIT" -eq 0 ]; then
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  fi
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
# FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" \
      "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-branch-outcome.sh" seed-tail >/dev/null 2>&1 || true
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_MODE=$(fm_afk_mode "$STATE")
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(fm_pi_extension_version "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(fm_pi_extension_version "$PI_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" active \
    || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
# omp (Oh My Pi) has no project-trust gate: it auto-discovers <cwd>/.omp/extensions
# with no dialog, so the only ways both tracked primary extensions fail to load
# are a session started outside this home, an extension disabled in the omp
# config, or a build older than the tracked file. The markers carry the loaded
# build plus the loading pid, exactly as the Pi ones do (bin/fm-wake-lib.sh).
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
  OMP_TURNEND_EXT="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
  OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
  OMP_LOCK="$STATE/.lock"
  OMP_WATCH_VERSION=$(fm_pi_extension_version "$OMP_EXT" || printf '')
  OMP_TURNEND_VERSION=$(fm_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
    || ! fm_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
    OMP_HOME_PHYS=$(cd -P "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
    OMP_ROOT_PHYS=$(cd -P "$FM_ROOT" 2>/dev/null && pwd -P || printf '%s' "$FM_ROOT")
    if [ "$OMP_HOME_PHYS" = "$OMP_ROOT_PHYS" ]; then
      printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT"
    else
      # shellcheck disable=SC2016  # backticks are literal text in the diagnostic
      printf 'OMP_WATCH_EXTENSION: not loaded - exit omp and relaunch through `fm <project>` (the launcher sets FM_HOME and --cwd) so %s and %s auto-load for this home; a bare omp or /resume from the firstmate checkout does not register the extensions for this home\n' "$OMP_TURNEND_EXT" "$OMP_EXT"
    fi
    # Warning only: name the cause when existing facts establish it.
    OMP_MARKER_PID=$(sed -n '2p' "$OMP_WATCH_MARKER" 2>/dev/null || true)
    OMP_CURRENT_PID=${REBUILDING_SESSION_PID:-$(sed -n '1p' "$OMP_LOCK" 2>/dev/null || true)}
    if [ -n "$OMP_MARKER_PID" ] && [ -n "$OMP_CURRENT_PID" ] && [ "$OMP_MARKER_PID" != "$OMP_CURRENT_PID" ]; then
      printf 'OMP_WATCH_CAUSE: the extension marker %s names pid %s, which is not this session (pid %s)\n' "$OMP_WATCH_MARKER" "$OMP_MARKER_PID" "$OMP_CURRENT_PID"
    fi
  fi
fi
SUPERVISION_OUT=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --afk-mode "$AFK_MODE" \
  --x-mode "$X_MODE_PRESENT")
SUPERVISION_BYTES=${FM_SESSION_START_SUPERVISION_BYTES:-600}
case "$SUPERVISION_BYTES" in ''|*[!0-9]*|0) SUPERVISION_BYTES=600 ;; esac
if [ "${#SUPERVISION_OUT}" -le "$SUPERVISION_BYTES" ]; then
  printf '%s\n' "$SUPERVISION_OUT"
else
  # Whole lines only, up to the byte budget - never a mid-line cut.
  printf '%s\n' "$SUPERVISION_OUT" | awk -v max="$SUPERVISION_BYTES" '
    { if (used + length($0) + 1 > max) exit; print; used += length($0) + 1 }'
  printf '(supervision block bounded to %s bytes; full protocol: bin/fm-supervision-instructions.sh --harness %s)\n' "$SUPERVISION_BYTES" "$PRIMARY_HARNESS"
fi

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
if [ "$REEMIT" -eq 1 ] && [ "$READ_ONLY" -eq 0 ]; then
  cat <<'EOF'
Everything below is printed for this context re-emit, with FLEET STATE as current
state instead of the record dump: each state/*.meta reduced to its endpoint,
heads, and PR state, each state/*.status to its latest event, counts, open
decision keys, and receipt paths, and data/backlog.md to group counts plus the
rows the state budget fits. data/projects.md, data/secondmates.md,
data/captain.md, data/captain-shared.md, and data/learnings.md are bounded
to the first lines per file, each with a count and full-source pointer.
EOF
else
  cat <<'EOF'
Everything below is capped (10 KB): one capped line per item, bounded per
block, with a shown/total count and a pointer to the full source.
EOF
fi
cat <<'EOF'
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status.
Go to a source only when: flagged ABSENT, corrupt, a full log/body or omitted
items are needed, a capped status line's tail matters, NETWORK CHECKS are IN
PROGRESS (bin/fm-startup-network.sh report), or a re-emit read cue appeared.
STARTUP TRUNCATED banner named the stage that would have printed it.
EOF

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
stage fleet-state
section "FLEET STATE"
# A locked context re-emit prints current state; every other run prints the
# full record dump (see this file's CONTEXT RE-EMIT STATE SUMMARY note).
if [ "$REEMIT" -eq 1 ] && [ "$READ_ONLY" -eq 0 ]; then
  print_reemit_state_summary
else
  print_fleet_records_full
fi

subsection "AFK"
# The away posture is the record (bin/fm-afk-contract.sh); the legacy flag
# still marks a running daemon on the harnesses that launch one.
# A quiet record (bin/fm-afk-contract.sh mode) is a present captain: it holds
# nothing for a return.
if [ -f "$STATE/.afk-contract" ]; then
  if [ "$("$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = quiet ]; then
    printf 'present - quiet mode recorded at %s (the captain is present and nothing is held for a return: requested actions proceed under ordinary attended authority; only an explicit /quiet off exits it)' \
      "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  else
    printf 'present - away posture recorded at %s (hold-for-return only; bin/fm-afk-contract.sh readback for the mandate)' \
      "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  fi
  if [ -e "$STATE/.afk" ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '; the quiet daemon owns the watcher.\n'
    else
      printf '; the away daemon owns the watcher.\n'
    fi
  else
    printf '; no daemon runs, the ordinary supervision session continues.\n'
  fi
elif [ -e "$STATE/.afk" ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf 'present - quiet-mode supervision is active; the daemon owns the watcher, only an explicit /quiet off exits it (legacy flag with no posture record).\n'
  else
    printf 'present - away-mode supervision is active; the daemon owns the watcher (legacy flag with no posture record).\n'
  fi
else
  printf 'absent\n'
fi

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
    printf 'Reconcile terminal results with %s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh retire <id> --reason "...". Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# secondmate that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
  cat <<'EOF'
Quiet mode is active. Follow the supervision operating instructions block
above: load /quiet and ensure the daemon is running, because the daemon owns
watcher supervision. Ordinary captain chat does not exit it; only an
explicit /quiet off does.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$COMPLETION_PID" || COMPLETION_PID=
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  # A sourceless manual rerun by the lock owner (typically after a truncated
  # startup) stands in for the startup source, but only once per lock owner.
  if [ -z "$SESSION_SOURCE" ] && [ "$COMPLETION_RECORDED" -eq 1 ] \
    && [ "$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)" = "$COMPLETION_PID" ]; then
    AGENTS_START_HASH=
  fi
  if { [ "$SESSION_SOURCE" = startup ] || [ -z "$SESSION_SOURCE" ]; } && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
