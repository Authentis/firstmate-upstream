#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
#        fm-control.sh <task-id> launch-check [--fallback <harness>/<model>]...
#                                         [--window <seconds>]
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action. Devin
#              cancellation invalidates it to unknown because its native hooks
#              emit no cancellation close; this is not a success claim.
#              An adapter whose repeated interrupt key does something else on
#              an idle agent (Devin's revert picker) sends its later presses
#              only after the first press rendered a running turn, and
#              otherwise reports `cancel=not-running` having sent one press.
#              An adapter with a verified draft clear (Command Code's double
#              Escape, fm_control_draft_clear_key) whose composer then reads
#              pending has that clear sent and must read empty afterwards, or
#              the verb refuses; the result carries `draft=cleared`.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              The same draft clear runs before the exit command is typed, so
#              a stuck draft cannot make the command concatenate onto it.
#              Already-stopped is success (idempotent). An endpoint that reads
#              `missing` (or, on Rex, `unreadable`, which is how a stopped Rex
#              server reads without starting it) is put through the control
#              plane's per-backend absence
#              proof (fm_control_endpoint_absence_verdict) before anything is
#              claimed about it, because `missing` also covers an endpoint that
#              is merely unreachable from this seat. That proof exists only on
#              HERDR, whose reads are scoped to the session the record names,
#              and REX, whose never-reused ids answer a structured not-found
#              from the server the record names: proven gone reports `endpoint-gone` rather than
#              `already-stopped`, because the endpoint this verb normally
#              preserves did not survive; a pane that turns out to be there and
#              idle is the ordinary `already-stopped`; one whose agent is back
#              takes the ordinary interrupt-then-exit path. A tmux `missing`
#              always REFUSES: a task record carries no socket identity for its
#              endpoint, so this verb cannot tell a destroyed window from one on
#              a tmux server it cannot address, and it will not claim a stop it
#              cannot see.
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME worktree - and the same endpoint whenever that endpoint
#              still exists - on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. When the recorded endpoint is instead proven gone -
#              a Herdr pane or workspace destroyed in churn, or a Rex block or
#              session gone with its server - the launch owner re-creates one in
#              that worktree, in the herdr session the record names (Rex: the
#              recorded session while it survives, otherwise the ordinary Rex
#              placement), and the task's record rebinds to it; that is how a task
#              whose terminal was destroyed is reclaimed by the home that owns
#              it, rather than being stranded with a parked approval nobody can
#              answer. Reclaim is HERDR- and REX-ONLY for the reason `exit` gives above:
#              a tmux `missing` cannot be proven absent from a task record, so
#              it refuses.
#              Outside a matching keyed secondmate pin, an explicit `default`
#              model or effort clears that axis for the replacement.
#              With no explicit axis, a secondmate
#              re-resolves its durable config/secondmate-harness pin (harness
#              plus its optional model and effort tokens) exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              A replacement Claude or Pi profile must also pass this home's
#              worker account pin (bin/fm-worker-account-lib.sh) here, so a pin
#              that no longer resolves or is signed out refuses before the old
#              agent stops.
#              The same pre-stop refusal applies to this home's worker tool
#              exclusions (bin/fm-exclude-tools-lib.sh): a malformed list, or a
#              replacement runtime that cannot hide the listed tools.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#
#   launch-check  Judge whether the task's CURRENT launch incarnation (the
#              spawn_gen fm-spawn recorded) became a working agent, for a ship
#              or scout only. The worker's own declarations after the
#              incarnation's launch come first and are final: a done line
#              stamped at or after it records `completed`, and a
#              needs-decision, blocked, paused, or failed line records `held`;
#              neither is building, writes a status line, or relaunches. A
#              working line or a commit in the worktree since (its HEAD reflog)
#              only forbids a relaunch. Otherwise an alive agent is `pending`
#              until the incarnation is --window old (default 120 seconds),
#              and only then judged: `building` needs BOTH a process-level
#              `alive` from the backend's recovery-grade classifier AND a
#              running turn: the busy record armed for this exact incarnation
#              (bin/fm-busy-lib.sh; its gen must equal the busy_gen the record
#              names) reads state=busy from the harness's own adapter source,
#              not the fm-spawn launch seed or a Firstmate-written event. A
#              shell prompt, an existing pane, an accepted launch command, or a
#              turn that already ended never qualifies, so an alive agent
#              without a running adapter turn at the window is a failure. A
#              dead or missing agent is a
#              launch failure at once. A harness with no
#              adapter turn source, a backend with no recovery-grade
#              classifier, or an unattributable endpoint reads `unproven`:
#              never building, and nothing is acted on.
#              On failure, a task the current-state owner
#              (bin/fm-crew-state.sh) attributes to a no-mistakes run reads
#              `held` (the run has custody) and a worker that acted fails
#              without a relaunch. Otherwise the verb relaunches at most ONCE per task (bound to
#              spawn_first, so every later incarnation of the same dispatch
#              counts against it) onto the first --fallback route, in the
#              caller's order, that differs from the failed one, can run this
#              kind, passes the account pin, and passes the harness catalog
#              check (bin/fm-model-catalog-lib.sh); that relaunch is the
#              ordinary transactional `relaunch` above, with a generated
#              progress note, under the same lock. When no route is eligible,
#              the relaunch fails, or the relaunched incarnation fails too, the
#              verb appends one `failed:` line to the task's status log, which
#              every current-state reader treats as terminal, so it is never
#              counted as building. The verdict is recorded in
#              state/<id>.launch-check against the incarnation, which
#              bin/fm-crew-state.sh reports as failed ahead of the launch's
#              busy seed when no run is attributed, and so a repeat
#              call prints it again and acts on nothing; route order, the
#              two-minute schedule, and which routes are free stay with the
#              caller. Exit status: 0 building, completed, or held, 3 pending
#              or just relaunched (check again after the window), 4 failed,
#              5 unproven.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr, rex), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, cmux, and paseo are refused
#     rather than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts (a Rex `unreadable` first goes through the absence
#     proof `exit` describes, and refuses unless that proof settles it).
#   - A composer that visibly holds pending text refuses before an exit command
#     is typed, so existing text is preserved instead of being concatenated.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_ARM_WAIT          wait for an armed interrupt's rendered proof
#                                after the press gap (1.5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-polytoken-lib.sh
. "$SCRIPT_DIR/fm-polytoken-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$SCRIPT_DIR/fm-exclude-tools-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-model-catalog-lib.sh
. "$SCRIPT_DIR/fm-model-catalog-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
ARM_WAIT=${FM_CONTROL_ARM_WAIT:-1.5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
LAUNCH_CHECK_RELAUNCH=
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ -n "${LAUNCH_CHECK_RELAUNCH:-}" ] && [ "$status" -ne 0 ] \
     && declare -F launch_check_cleanup_failure >/dev/null 2>&1; then
    launch_check_cleanup_failure || true
    status=4
  fi
  # Remove the dialog file while the lock is still held: once it is released,
  # the next lifecycle command for this task writes the same path.
  if [ -n "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    rm -f "$FM_COMPOSER_DIALOG_SINK"
  fi
  if [ -n "${FM_CONTROL_SUBMIT_ERR:-}" ]; then
    rm -f "$FM_CONTROL_SUBMIT_ERR"
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  [ "$status" != 4 ] || [ -z "${LAUNCH_CHECK_RELAUNCH:-}" ] || exit 4
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters (codex and grok need a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief plus a progress note into a fresh agent on any adapter."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
LAUNCH_FALLBACKS=()
LAUNCH_WINDOW=120
LAUNCH_WINDOW_SET=0
control_want_value=
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      fallback) LAUNCH_FALLBACKS+=("$control_arg") ;;
      window) LAUNCH_WINDOW=$control_arg; LAUNCH_WINDOW_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --fallback) control_want_value=fallback ;;
    --fallback=*) LAUNCH_FALLBACKS+=("${control_arg#--fallback=}") ;;
    --window) control_want_value=window ;;
    --window=*) LAUNCH_WINDOW=${control_arg#--window=}; LAUNCH_WINDOW_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--harness, --model, --effort, and --note apply to 'relaunch' only"
fi
if [ "$VERB" != launch-check ]; then
  [ "${#LAUNCH_FALLBACKS[@]}" = 0 ] && [ "$LAUNCH_WINDOW_SET" = 0 ] \
    || die "--fallback and --window apply to 'launch-check' only"
fi
case "$LAUNCH_WINDOW" in
  ''|*[!0-9]*) die "--window must be a whole number of seconds" ;;
esac
if [ "${#LAUNCH_FALLBACKS[@]}" -gt 0 ]; then
  for launch_fallback in "${LAUNCH_FALLBACKS[@]}"; do
    case "$launch_fallback" in
      */?*) [ -n "${launch_fallback%%/*}" ] || die "--fallback '$launch_fallback' must be <harness>/<model>" ;;
      *) die "--fallback '$launch_fallback' must be <harness>/<model>" ;;
    esac
  done
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max|ultra) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max, ultra" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
# do_exit runs in a command substitution. That subshell does not run this
# EXIT trap, so the parent has to hold the path the trap removes. Set it
# only once the lock is held: a process that loses the lock runs the same
# trap, and would remove the file the lock holder is reading.
FM_COMPOSER_DIALOG_SINK=$STATE/$ID.composer-dialog
# The exit submit's captured stderr follows the same parent-owned pattern.
FM_CONTROL_SUBMIT_ERR=$STATE/$ID.submit-stderr
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship
# OpenCode's composer exit key changed between its 1.x and 2.x lines; the major
# spawn detected is recorded here so the exit command below matches the running
# agent. Absent (a legacy record or a non-opencode task) it stays empty.
OPENCODE_MAJOR=$(fm_meta_get "$META" opencode_version); OPENCODE_MAJOR=${OPENCODE_MAJOR%%.*}

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# refuse_blocking_prompt: the screen is a dialog a confirming Enter would
# answer. Name it and stop. Do not type Escape or an option: both dismiss
# or choose.
refuse_blocking_prompt() {  # <dialog-name>
  die "task $ID is blocked on a prompt: $1. Refusing to type Enter into it."
}

# rendered_matches <ere>: whether any row of the visible viewport matches.
# An unreadable viewport is a no, so every caller treats it as missing proof.
rendered_matches() {  # <ere>
  local screen
  screen=$(fm_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 1
  printf '%s\n' "$screen" | grep -Eq -- "$1"
}

# wait_rendered <ere> <timeout>: poll the viewport until a row matches.
wait_rendered() {  # <ere> <timeout>
  local elapsed=0 step
  step=$(awk -v p="$POLL" 'BEGIN{printf "%s", (p < 0.1 ? p : 0.1)}')
  while :; do
    rendered_matches "$1" && return 0
    awk -v e="$elapsed" -v t="$2" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$step"
    elapsed=$(awk -v e="$elapsed" -v p="$step" 'BEGIN{printf "%.3f", e + p}')
  done
}

# dismiss_interrupt_hazard <key> <ere>: after the presses, close a surface a
# mistimed press opened (Devin's revert picker) with one more key, before
# anything else can be typed into it. Sets INTERRUPT_HAZARD.
dismiss_interrupt_hazard() {  # <key> <ere>
  local key=$1 hazard=$2 gap
  gap=$(fm_control_interrupt_press_gap "$HARNESS")
  sleep "$gap"
  rendered_matches "$hazard" || return 0
  fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "task $ID shows the $HARNESS revert picker after its interrupt, and the $key that closes it was not delivered; nothing else was typed. Close it with $key, never Enter, before any other action"
  sleep "$gap"
  ! rendered_matches "$hazard" \
    || die "task $ID still shows the $HARNESS revert picker after one $key; nothing else was typed. Close it with $key, never Enter, before any other action"
  INTERRUPT_HAZARD=dismissed
}

# clear_held_draft <verb>: when the adapter has a verified draft clear
# (fm_control_draft_clear_key) and its composer visibly holds text, send that
# clear and require the composer to read empty afterwards, refusing loudly
# otherwise. Without this, a draft left in an idle composer survives the
# interrupt key and blocks both the exit command and the doorbell. A non-empty
# non-pending read is left to the caller's own gate; an adapter without a draft
# clear is never touched, because its composer text may be the captain's own.
# A checkpoint picker already open is closed first with one Escape, because
# typing or Enter into it would restore a checkpoint, and the clear itself
# never runs on a composer that reads empty (fm_control_clear_draft owns both).
# Sets HELD_DRAFT to cleared when it sent the clear.
clear_held_draft() {  # <verb>
  local state rc=0 key
  key=$(fm_control_draft_clear_key "$HARNESS" 2>/dev/null) || return 0
  [ -n "$key" ] || return 0
  fm_control_dismiss_overlay "$BACKEND" "$T" "$HARNESS" "$LABEL" \
    || die "task $ID shows the $HARNESS Rewind checkpoint picker, where Enter restores a checkpoint, and one $(fm_control_overlay_dismiss_key "$HARNESS") did not close it; nothing else was sent. Close it with $(fm_control_overlay_dismiss_key "$HARNESS"), never Enter, then retry '$1'"
  state=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) || state=unknown
  [ "$state" = pending ] || return 0
  fm_control_clear_draft "$BACKEND" "$T" "$HARNESS" "$LABEL" || rc=$?
  case "$rc:$FM_CONTROL_CLEAR_WHY" in
    0:*) ;;
    *:overlay-stuck)
      die "task $ID shows the $HARNESS Rewind checkpoint picker after the composer clear, and one $(fm_control_overlay_dismiss_key "$HARNESS") did not close it; nothing else was sent. Close it with $(fm_control_overlay_dismiss_key "$HARNESS"), never Enter, then retry '$1'"
      ;;
    *:misread)
      die "task $ID's $HARNESS composer reads as holding text but is empty: the $(fm_control_draft_clear_presses "$HARNESS") $key presses opened its Rewind checkpoint picker, which one $(fm_control_overlay_dismiss_key "$HARNESS") then closed, and nothing was typed. The composer read is wrong for this pane, so '$1' cannot proceed; do not retry the clear, and capture the pane with its colour escapes for diagnosis"
      ;;
    *)
      die "task $ID's $HARNESS composer holds text and $(fm_control_draft_clear_presses "$HARNESS") $key presses did not leave it reading empty, so '$1' would concatenate onto it or leave it behind; the composer was not cleared by any other means. Clear it by hand, then retry '$1'"
      ;;
  esac
  HELD_DRAFT=cleared
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it. An adapter
# with an arm signal (fm_control_interrupt_arm_signal) gets each later press
# only after the viewport proves the first one armed a running turn, and never
# sooner than its press gap; without that proof INTERRUPT_ARMED=no and no
# further press is sent. Its hazard surface is then closed before returning.
send_interrupt_keys() {
  local key repeat clear arm hazard gap i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  arm=$(fm_control_interrupt_arm_signal "$HARNESS")
  hazard=$(fm_control_interrupt_hazard_signal "$HARNESS")
  gap=$(fm_control_interrupt_press_gap "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  [ -z "$arm$hazard" ] || fm_backend_visible_capture_supported "$BACKEND" \
    || die "harness $HARNESS must see its screen between interrupt presses, because a repeated $key on an idle agent opens its revert picker, and the $BACKEND backend has no verified viewport read; refusing to press blind"
  INTERRUPT_ARMED=yes
  INTERRUPT_HAZARD=none
  HELD_DRAFT=none
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -lt "$repeat" ] || break
    sleep "$gap"
    if [ -n "$arm" ] && ! wait_rendered "$arm" "$ARM_WAIT"; then
      INTERRUPT_ARMED=no
      break
    fi
  done
  [ -z "$hazard" ] || dismiss_interrupt_hazard "$key" "$hazard"
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
  clear_held_draft interrupt
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery. `not-running` means an armed
# adapter's first press rendered no running turn, so nothing was cancelled; a
# dismissed revert picker is reported beside the claim.
# The rest transport (polytoken) takes a typed branch before any key is read:
# the TUI has no interrupt chord at all (fm_control_interrupt_transport), so
# POST /turn/cancel on the session daemon is the one verified interrupt, with
# its typed acknowledgement (cancel_requested plus the turn settling) as the
# claim, and the busy close written here because a cancelled turn emits no
# stop hook (verified live).
deliver_interrupt() {
  local cancel devin_gen='' port cred token
  if [ "$(fm_control_interrupt_transport "$HARNESS")" = rest ]; then
    port=$(fm_meta_get "$META" polytoken_port)
    cred=$(fm_meta_get "$META" polytoken_credential)
    if [ -z "$port" ] || [ -z "$cred" ]; then
      die "task $ID records no polytoken session binding (port or credential absent from its record); the REST control verbs address the session's own daemon, so an interrupt cannot be delivered without it. The session has likely ended or was launched raw; reconcile the task or relaunch it"
    fi
    token=$(fm_polytoken_credential_token "$cred") || token=
    [ -n "$token" ] || die "task $ID's polytoken credential at $cred is missing or unreadable, so the session cannot be interrupted through its daemon; the session has likely ended. Reconcile the task or relaunch it"
    # A cancelled turn emits no stop hook (verified live), so the close the
    # hooks would have written lands with the cancel: the settled turn is the
    # typed proof this incarnation is no longer busy, unless a queued prompt
    # has reopened it (fm_polytoken_interrupt_task).
    cancel=$(fm_polytoken_interrupt_task "$SCRIPT_DIR" "$STATE" "$ID" "$port" "$token" "$SETTLE_WAIT") \
      || die "task $ID's polytoken turn cancel was not acknowledged on port $port within ${SETTLE_WAIT}s; the interrupt status is unknown, so no further control action is safe here"
    INTERRUPT_ARMED=yes
    INTERRUPT_HAZARD=none
    printf '%s' "$cancel"
    return 0
  fi
  # Devin does not emit Stop for cancellation. Capture this incarnation before
  # keys, then invalidate its state conservatively rather than claiming idle.
  if [ "$HARNESS" = devin ]; then
    devin_gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
  fi
  prepare_interrupt_ack
  send_interrupt_keys
  if [ "$INTERRUPT_ARMED" = no ]; then
    cancel=not-running
  else
    cancel=$(interrupt_cancel_claim)
    if [ "$HARNESS" = devin ] && [ -n "$devin_gen" ]; then
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" unknown \
        --gen "$devin_gen" --source fm-interrupt --event interrupt >/dev/null 2>&1 || true
    fi
  fi
  [ "$INTERRUPT_HAZARD" = none ] || cancel="$cancel revert-picker=$INTERRUPT_HAZARD"
  [ "$HELD_DRAFT" = none ] || cancel="$cancel draft=$HELD_DRAFT"
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

# Drop busy_gen from the task record when it still names <gen>.
# fm-busy-event.sh owns the sidecar and the record; fm_backlog_atomic_transition
# publish owns the task record. Clearing the line inside the busy writer would
# take the task-record lock that teardown and spawn already hold; the busy
# writer is their child process, so it would wait on a live holder that is
# itself waiting on the child, and neither would ever proceed.
clear_retired_meta_busy_gen() {  # <gen>
  local gen=$1 meta="$STATE/$ID.meta" lock tmp current line
  [ -n "$gen" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  if ! declare -F fm_backlog_atomic_transition >/dev/null 2>&1; then
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  fi
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock"
  current=$(fm_meta_get "$meta" busy_gen)
  if [ "$current" != "$gen" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  tmp=$(mktemp "$STATE/.$ID.meta.retire.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      busy_gen=*) ;;
      *)
        printf '%s\n' "$line" >> "$tmp" || {
          rm -f "$tmp"
          fm_lock_release "$lock"
          return 1
        }
        ;;
    esac
  done < "$meta" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

retire_busy_incarnation() {
  local gen=
  if [ -f "$STATE/$ID.busy-gen" ]; then
    gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
    if [ -n "$gen" ] \
      && "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$gen" >/dev/null 2>&1; then
      clear_retired_meta_busy_gen "$gen" || true
    fi
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped`, `endpoint-gone`, or `stopped`.
do_exit() {
  local state cmd hazard verdict composer_state cancel absence interrupt_result=not-needed dialog
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    *)
      fm_control_absence_recheck_applies "$BACKEND" "$state" \
        || die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint"
      # `missing` on its own is not a finding about the endpoint: it conflates
      # "destroyed" with "unreachable from this seat". Route it through the
      # control plane's one absence proof - the same one the relaunch gate uses
      # - and report what that proof actually established, never more.
      absence=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T" "$META")
      case "${absence%%$'\t'*}" in
        gone)
          # Proven gone, so the agent that lived in it went with it: exit's
          # postcondition already holds and there is nothing to send. Its own
          # outcome rather than `already-stopped`, because the endpoint this
          # verb normally preserves did not survive. The worktree and every
          # uncommitted change are untouched, and `relaunch` re-creates the
          # endpoint from here.
          printf 'endpoint-gone'
          return 0
          ;;
        dead)
          # The endpoint was only unreachable and is there after all, holding
          # no agent - a herdr pane whose session server was merely stopped is
          # the common case. Nothing is gone, so this is the ordinary
          # already-stopped outcome.
          printf 'already-stopped'
          return 0
          ;;
        alive)
          # The agent came back with its endpoint. Fall through to the ordinary
          # alive path: interrupt if busy, then the harness's exit command.
          ;;
        *)
          die "task $ID's endpoint $T reads '$state', but ${absence#*$'\t'}; exit will not claim an agent stopped at an address it cannot trust, nor send lifecycle input to one"
          ;;
      esac
      ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS" "$OPENCODE_MAJOR")
  hazard=$(fm_control_interrupt_hazard_signal "$HARNESS")
  if [ -n "$hazard" ] && rendered_matches "$hazard"; then
    die "task $ID shows the $HARNESS revert picker, where typed text becomes a search and Enter reverts file changes; refusing to type the $cmd exit command. Close it with $(fm_control_interrupt_key "$HARNESS"), never Enter, then retry '$VERB'"
  fi
  clear_held_draft exit
  : > "$FM_COMPOSER_DIALOG_SINK" \
    || die "task $ID's dialog check could not be recorded"
  composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
    || composer_state=unknown
  # The classify that filled the sink ran in a subshell, so read the file
  # rather than a function that subshell sourced.
  if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
    refuse_blocking_prompt "$dialog"
  fi
  case "$composer_state" in
    empty) ;;
    pending)
      die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Clear or submit the pending text, then retry '$VERB'"
      ;;
    *)
      die "task $ID's composer state is '$composer_state', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer, then retry '$VERB'"
      ;;
  esac
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter. OpenCode 2 exits from an empty composer on a
  # single Ctrl-C (verified on 2.0.11, 2.0.21, and 2.0.22); typing /exit also
  # exits but opens a completion popup, so the raw key plane avoids that popup
  # interacting with the typed submit verification. A Ctrl-C over leftover
  # composer text only clears it, so Ctrl-U clears the composer first and one
  # more Ctrl-C follows if the agent is still alive.
  case "$cmd" in
    C-c)
      fm_backend_send_key "$BACKEND" "$T" C-u "$LABEL" \
        || die "the exit key could not be sent to task $ID on $BACKEND"
      fm_backend_send_key "$BACKEND" "$T" C-c "$LABEL" \
        || die "the exit key could not be sent to task $ID on $BACKEND"
      if ! wait_agent_state "$SETTLE_WAIT" dead >/dev/null; then
        fm_backend_send_key "$BACKEND" "$T" C-c "$LABEL" \
          || die "the exit key could not be sent to task $ID on $BACKEND"
      fi
      ;;
    *)
      submit_err=$FM_CONTROL_SUBMIT_ERR
      : > "$submit_err" \
        || die "the exit command's submit diagnostics could not be recorded"
      submit_rc=0
      verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL" 2>"$submit_err") \
        || submit_rc=$?
      if [ "$submit_rc" -ne 0 ] || [ "$verdict" = send-failed ]; then
        submit_detail=$(head -n 10 "$submit_err" 2>/dev/null || true)
        rm -f "$submit_err"
        die "the exit command could not be sent to task $ID on $BACKEND
  backend=$BACKEND target=$T submit-rc=$submit_rc verdict=${verdict:-<empty>}
  submit-stderr (first 10 lines):
${submit_detail:-  <none>}"
      fi
      # A successful submit keeps the stderr it always showed the caller.
      cat "$submit_err" >&2 2>/dev/null || true
      rm -f "$submit_err"
      # The submitting Enter can open the picker. The agent is still alive, and
      # another Enter would confirm the selected row. A dead agent may leave the
      # same text behind; that is not a prompt still waiting.
      if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
        dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
        if [ "$(agent_state)" != dead ]; then
          refuse_blocking_prompt "$dialog"
        fi
      fi
      ;;
  esac
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    # A submit can return before any read sees the picker: a native busy
    # verdict needs no composer read, and a cleared composer can be read
    # before the picker renders. Read the screen once more here.
    : > "$FM_COMPOSER_DIALOG_SINK" || true
    fm_backend_composer_state "$BACKEND" "$T" "$LABEL" >/dev/null 2>&1 || true
    if [ -s "$FM_COMPOSER_DIALOG_SINK" ]; then
      refuse_blocking_prompt "$(cat "$FM_COMPOSER_DIALOG_SINK")"
    fi
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
CATALOG_VERIFIED=
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    [ -z "$CATALOG_VERIFIED" ] || echo "catalog_verified=$CATALOG_VERIFIED"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          # The old agent was NOT proven stopped, so no replacement is coming
          # and the agent that may still be reading these instructions is the
          # original one. The note exists to brief a replacement; leaving it in
          # a possibly-live agent's brief would be an unrequested edit to a
          # running task. Restore byte-exact, exactly as the alive case does.
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state', so it was not proven stopped; its original instructions were restored and the durable record was retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ] && [ "$HARNESS_SET" = 0 ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. The mate id
    # is passed so a per-mate override line is honored here too; a crewmate or
    # scout deliberately does NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    if ! CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate "$ID"); then
      die "the configured secondmate runtime pin for $ID cannot be read; fix config/secondmate-harness rather than relaunching onto an unresolved runtime"
    fi
    if ! CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model "$ID"); then
      die "the configured secondmate model pin for $ID cannot be read; fix config/secondmate-harness rather than relaunching onto an unresolved model"
    fi
    if ! CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort "$ID"); then
      die "the configured secondmate effort pin for $ID cannot be read; fix config/secondmate-harness rather than relaunching onto an unresolved effort"
    fi
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max, ultra; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
  if [ "$KIND" = secondmate ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-secondmate-model "$TARGET_HARNESS" "$TARGET_MODEL" "$ID" || return 1
  fi
  if [ "$TARGET_EFFORT" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
  fi
  # The launch owner applies this home's worker account pin too, but only after
  # the old agent has been stopped, so a pin that no longer resolves or is
  # signed out must refuse here, while nothing has changed yet.
  local account_model=$TARGET_MODEL account_mate=
  [ "$account_model" != default ] || account_model=
  [ "$KIND" != secondmate ] || account_mate=$ID
  fm_worker_account_select "$TARGET_HARNESS" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
    "$account_model" "$TARGET_HARNESS" "" "$account_mate" >/dev/null || return 1
  # Likewise polytoken's launch profile and wiring refusals
  # (bin/fm-polytoken-lib.sh owns them). The launch owner retires the prior
  # incarnation's own generated hook layer, so only one it did not generate
  # refuses here.
  if [ "$TARGET_HARNESS" = polytoken ]; then
    local polytoken_bin polytoken_state
    polytoken_bin=$(fm_polytoken_binary) || return 1
    fm_polytoken_launch_ref "$polytoken_bin" "$TARGET_MODEL" "$TARGET_EFFORT" >/dev/null || return 1
    polytoken_state=$(cd "$STATE" && pwd -P) || return 1
    fm_polytoken_require_handler_path "$(fm_polytoken_busy_script "$polytoken_state" "$ID")" || return 1
    fm_control_harness_wiring_paths "$PRIOR_HARNESS" "$WT" "$STATE" "$ID" "$KIND" \
        | grep -qxF "$(fm_polytoken_hooks_file "$WT")" \
      || fm_polytoken_require_hooks_free "$WT" || return 1
  fi
  # Likewise config/crew-exclude-tools: a malformed file, or a replacement
  # runtime that cannot hide the listed tools, refuses here, before the old
  # agent stops. Secondmate agents are not covered.
  if [ "$KIND" != secondmate ]; then
    fm_exclude_tools_check "$TARGET_HARNESS" 0 "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" >/dev/null || return 1
  fi
  # The launch owner's harness catalog check (bin/fm-model-catalog-lib.sh) for
  # a ship or scout runs here too, before the old agent stops; the journal
  # carries the verified route so fm-spawn --relaunch does not list it again.
  # A route this transaction already verified (launch-check's fallback pick) is
  # not listed again.
  case "$KIND" in
    ship|scout)
      if [ "$CATALOG_VERIFIED" != "$TARGET_HARNESS/$TARGET_MODEL" ]; then
        CATALOG_VERIFIED=
        relaunch_catalog_check "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
      fi
      ;;
    *) CATALOG_VERIFIED= ;;
  esac
}

# relaunch_catalog_check: 0 when <harness>'s catalog verifies <model> exactly as
# fm-spawn's own check would (same executable, account root, and native ultra
# provider), setting CATALOG_VERIFIED; 0 with nothing set when the check does
# not apply; 1 with the refusal on stderr otherwise. Cursor runs fm-spawn's own
# Cursor check (bin/fm-cursor-lib.sh) before the stop, with the same semantics:
# a readable listing must carry the model, an unreadable one passes, and either
# pass records the route so fm-spawn does not list it again after the stop.
relaunch_catalog_check() {  # <harness> <model> <effort>
  local h=$1 m=$2 effort=$3 bin account root='' provider='' listing
  if [ "$h" = cursor ]; then
    bin=$(fm_cursor_resolve_binary) || return 1
    [ -n "$m" ] && [ "$m" != default ] || return 0
    if listing=$(fm_cursor_list_models "$bin"); then
      printf '%s\n' "$listing" | fm_cursor_catalog_has_model "$m" || {
        echo "error: Cursor model '$m' is not available from '$bin --list-models'; choose an id listed by that command or omit --model" >&2
        return 1
      }
    fi
    CATALOG_VERIFIED="cursor/$m"
    return 0
  fi
  [ -n "$m" ] && [ "$m" != default ] || return 0
  case "$h" in
    pi|pi-signed)
      bin=$(command -v "$h") || { echo "error: the $h executable is not on PATH, so model '$m' cannot be verified" >&2; return 1; }
      account=$(fm_worker_account_select "$h" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$m" "$h" 2>/dev/null) || account=
      if [ -n "$account" ]; then
        root=${account#*$'\t'}
        root=${root%%$'\t'*}
      fi
      [ "$effort" != ultra ] || provider=codex-native
      fm_model_catalog_validate "$h" "$bin" "$m" "$root" "$provider" || return 1
      ;;
    opencode)
      bin=$(command -v opencode) || { echo "error: the opencode executable is not on PATH, so model '$m' cannot be verified" >&2; return 1; }
      fm_model_catalog_validate opencode "$bin" "$m" || return 1
      ;;
    *) return 0 ;;
  esac
  CATALOG_VERIFIED="$h/$m"
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    # Do not walk state/ with find(1): watcher scratch files can vanish
    # mid-scan and make find fail even when every child *.meta is readable.
    [ -d "$WT/state" ] && [ -r "$WT/state" ] && [ -x "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp inbox_q
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        inbox_q=$(printf '%s' "$STATE/$ID.inbox" | sed "s/'/'\\\\''/g")
        echo "First, check your instruction inbox: list it with"
        echo "\`find '$inbox_q' -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V\`, act on"
        echo "each message in numeric order, then acknowledge each handled one with"
        echo "$FM_ROOT/bin/fm-inbox-ack.sh $ID <seq> (never a raw move). A steer sent before"
        echo "the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line
  local -a spawn_args

  require_state_verified_backend relaunch
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit)
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
    # $T was resolved from the record before the launch. When the recorded
    # endpoint was gone, the launch owner created a fresh one and republished
    # the record pointing at it, so every postcondition below must be read from
    # the endpoint the task now HAS, not the one it had. Re-resolving through
    # the same shared validation is what makes that safe: a record that no
    # longer passes it refuses here rather than leaving this transaction
    # polling an address nothing owns.
    # stdout is dropped (it is only the resolved target), but the refusal on
    # stderr names the exact row that failed - and in this one branch the record
    # was just rewritten by the launch owner, so that row is the whole
    # diagnostic. Let it through rather than dying with nothing to act on.
    if fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null \
       && [ -n "$FM_BACKEND_VALIDATED_TARGET" ]; then
      T=$FM_BACKEND_VALIDATED_TARGET
    else
      die "the replacement agent for $ID was launched, but task $ID's republished record no longer passes endpoint validation (the refusal above names the row), so this transaction cannot say which endpoint to confirm it on; reconcile $META before any further control action"
    fi
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- launch check -----------------------------------------------------------

# state/<id>.launch-check holds key=value lines for one dispatch: spawn_first=
# binds the file to it (a fresh spawn of the same id starts over), relaunch=
# records the one claimed relaunch as "<from-spawn-gen> <harness>/<model>",
# relaunch_result= its outcome, and verdict= the recorded
# "<building|completed|held|failed> <spawn-gen>".
launch_mark_get() {  # <key>
  [ -f "$LAUNCH_MARK" ] || return 0
  [ "$(grep '^spawn_first=' "$LAUNCH_MARK" 2>/dev/null | tail -1 | cut -d= -f2-)" = "$LAUNCH_SPAWN_FIRST" ] || return 0
  grep "^$1=" "$LAUNCH_MARK" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

launch_mark_set() {  # <key> <value>
  local tmp="$LAUNCH_MARK.tmp.$$"
  {
    echo "spawn_first=$LAUNCH_SPAWN_FIRST"
    if [ -f "$LAUNCH_MARK" ] \
       && [ "$(grep '^spawn_first=' "$LAUNCH_MARK" 2>/dev/null | tail -1 | cut -d= -f2-)" = "$LAUNCH_SPAWN_FIRST" ]; then
      grep -v -e '^spawn_first=' -e "^$1=" "$LAUNCH_MARK" || true
    fi
    echo "$1=$2"
  } > "$tmp" || die "could not record the launch-check state for task $ID at $LAUNCH_MARK"
  mv -f "$tmp" "$LAUNCH_MARK" || die "could not record the launch-check state for task $ID at $LAUNCH_MARK"
}

# launch_worker_evidence: fills LW_KIND and LW_REASON from the worker's own acts
# after <launch-at>. The latest working, done, needs-decision, blocked, paused,
# or failed declaration stamped at or after it decides: done is `completed`,
# a decision, custody wait, or failure is `held`, and working is `acted`; with
# no such declaration, a commit made in the worktree since (its HEAD reflog) is
# `acted`. LW_KIND is empty when the worker has not acted. The launch check's
# own failed: lines and the launch owner's (fm-spawn's "failed: launch:") are
# not the worker's.
launch_worker_evidence() {  # <launch-at>
  local launch_at=$1 line verb at entry
  LW_KIND='' LW_REASON=''
  if [ -f "$STATE/$ID.status" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      status_line_verb "$line" verb
      case "$verb" in
        working|done|needs-decision|blocked|failed|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
        *) continue ;;
      esac
      case "$line" in *"]: launch check: "*|*"]: launch: "*) continue ;; esac
      _fm_status_at_epoch "$line" at || continue
      [ "$at" -ge "$launch_at" ] || continue
      case "$verb" in
        done) LW_KIND=completed ;;
        working) LW_KIND=acted ;;
        *) LW_KIND=held ;;
      esac
      LW_REASON="the worker declared $verb at $at, after this launch"
    done < "$STATE/$ID.status"
  fi
  [ -z "$LW_KIND" ] || return 0
  [ -n "$WT" ] && [ -d "$WT" ] || return 0
  entry=$(git -C "$WT" reflog show --date=unix --format='%gd %gs' HEAD 2>/dev/null \
    | awk -v t="$launch_at" '{ at = $1; sub(/^.*@[{]/, "", at); sub(/[}]$/, "", at) } $2 ~ /^commit/ && at + 0 >= t + 0 { print; exit }') || entry=
  [ -n "$entry" ] || return 0
  LW_KIND=acted LW_REASON="the worker committed in its worktree after this launch ($entry)"
}

# launch_verdict: fills LV_STATE (building|pending|failed|unproven) and
# LV_REASON for the incarnation launched at LAUNCH_AT.
launch_verdict() {
  local launch_at=$LAUNCH_AT now state sources adapter gen meta_gen rec r_state r_source
  state=$(agent_state)
  case "$state" in
    alive) ;;
    dead|missing)
      LV_STATE=failed LV_REASON="the agent process is not running (endpoint reads '$state')"
      return 0
      ;;
    unverified)
      LV_STATE=unproven LV_REASON="the $BACKEND backend has no recovery-grade agent classifier"
      return 0
      ;;
    *)
      LV_STATE=unproven LV_REASON="the endpoint reads '$state', so its process cannot be attributed"
      return 0
      ;;
  esac
  sources=$(fm_busy_sources_for_harness "$HARNESS")
  adapter=${sources%% fm-spawn *}
  if [ -z "$sources" ] || [ "$adapter" = "$sources" ]; then
    LV_STATE=unproven LV_REASON="harness '$HARNESS' has no adapter turn source"
    return 0
  fi
  now=$(date +%s)
  if [ $((now - launch_at)) -lt "$LAUNCH_WINDOW" ]; then
    LV_STATE=pending LV_REASON="agent alive $((now - launch_at))s after launch; judged once the launch is ${LAUNCH_WINDOW}s old"
    return 0
  fi
  r_state='' r_source=''
  meta_gen=$(fm_meta_get "$META" busy_gen)
  if gen=$(fm_busy_current_gen "$STATE" "$ID") && [ -n "$meta_gen" ] && [ "$gen" = "$meta_gen" ] \
     && rec=$(fm_busy_record_read "$STATE" "$ID"); then
    r_state=${rec%% *}
    r_source=$(printf '%s' "$rec" | awk '{print $2}')
  fi
  if [ "$r_state" = busy ]; then
    case " $adapter " in
      *" ${r_source:-none} "*)
        LV_STATE=building LV_REASON="agent alive with a running $r_source turn under this incarnation"
        return 0
        ;;
    esac
  fi
  LV_STATE=failed LV_REASON="agent alive but no running $adapter turn ${LAUNCH_WINDOW}s after launch"
}

launch_fail() {  # <reason>
  local spawn_gen
  spawn_gen=$(fm_meta_get "$META" spawn_gen)
  launch_mark_set verdict "failed $spawn_gen"
  printf '%s\n' "$(status_stamp_line "failed: launch check: $1; not building")" >> "$STATE/$ID.status"
  echo "launch-check failed $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) reason=$1"
  exit 4
}

# launch_check_cleanup_failure: the one relaunch failed after the old agent was
# stopped, which ended this process through die. Record the failure the same
# way launch_fail does, from the EXIT trap, while the control lock is held.
launch_check_cleanup_failure() {
  local spawn_gen
  spawn_gen=$(fm_meta_get "$META" spawn_gen)
  launch_mark_set relaunch_result failed
  launch_mark_set verdict "failed $spawn_gen"
  printf '%s\n' "$(status_stamp_line "failed: launch check: $LV_REASON, and the one relaunch onto $LAUNCH_CHECK_RELAUNCH failed (the relaunch journal state/$ID.control-relaunch has the detail); not building")" >> "$STATE/$ID.status"
  echo "launch-check failed $ID reason=$LV_REASON, and the one relaunch onto $LAUNCH_CHECK_RELAUNCH failed"
}

# launch_pick_fallback: prints the first eligible "<harness>/<model>" from
# LAUNCH_FALLBACKS, or nothing; skipped routes are explained on stderr.
launch_pick_fallback() {
  local fb h m prior_model
  prior_model=$(fm_meta_get "$META" model)
  for fb in "${LAUNCH_FALLBACKS[@]}"; do
    h=${fb%%/*}
    m=${fb#*/}
    if [ "$h" = "$RECORDED_HARNESS" ] && [ "$m" = "$prior_model" ]; then
      echo "notice: launch-check skips fallback '$fb': it is the route that just failed" >&2
      continue
    fi
    if ! fm_control_harness_supports_kind "$h" "$KIND"; then
      echo "notice: launch-check skips fallback '$fb': '$h' is not verified to run a $KIND task" >&2
      continue
    fi
    if ! fm_worker_account_select "$h" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$m" "$h" >/dev/null 2>&1; then
      echo "notice: launch-check skips fallback '$fb': this home's worker account pin refuses it" >&2
      continue
    fi
    case "$h" in
      pi|pi-signed|opencode)
        if ! command -v "$h" >/dev/null; then
          echo "notice: launch-check skips fallback '$fb': the $h executable is not on PATH" >&2
          continue
        fi
        ;;
    esac
    if ! relaunch_catalog_check "$h" "$m" default; then
      echo "notice: launch-check skips fallback '$fb': its harness catalog refuses the model" >&2
      continue
    fi
    printf '%s' "$fb"
    return 0
  done
}

do_launch_check() {
  local spawn_gen recorded relaunch relaunch_result chosen prior effort out rc custody
  case "$KIND" in
    ship|scout) ;;
    *) die "launch-check judges ship and scout launches only; task $ID is a $KIND, whose lifecycle stays with its own recovery path" ;;
  esac
  LAUNCH_MARK="$STATE/$ID.launch-check"
  LAUNCH_SPAWN_FIRST=$(fm_meta_get "$META" spawn_first)
  spawn_gen=$(fm_meta_get "$META" spawn_gen)

  recorded=$(launch_mark_get verdict)
  if [ -n "$spawn_gen" ] && [ "${recorded#* }" = "$spawn_gen" ]; then
    echo "launch-check ${recorded%% *} $ID (recorded for this incarnation) harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model)"
    [ "${recorded%% *}" = failed ] && exit 4
    exit 0
  fi
  relaunch=$(launch_mark_get relaunch)
  relaunch_result=$(launch_mark_get relaunch_result)

  LAUNCH_AT=${spawn_gen#s}
  LAUNCH_AT=${LAUNCH_AT%%.*}
  case "$spawn_gen" in s[0-9]*) ;; *) LAUNCH_AT= ;; esac
  case "$LAUNCH_AT" in *[!0-9]*) LAUNCH_AT= ;; esac
  if [ -z "$LAUNCH_AT" ]; then
    echo "launch-check unproven $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) reason=the record names no launch incarnation (spawn_gen='${spawn_gen:-none}'); not counted as building and nothing acted on"
    exit 5
  fi
  launch_worker_evidence "$LAUNCH_AT"
  case "$LW_KIND" in
    completed|held)
      launch_mark_set verdict "$LW_KIND $spawn_gen"
      echo "launch-check $LW_KIND $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) evidence=$LW_REASON; not building and not relaunched"
      exit 0
      ;;
  esac

  launch_verdict
  case "$LV_STATE" in
    building|failed)
      custody=$("$FM_CREW_STATE_BIN" "$ID" 2>/dev/null) || custody=
      case "$custody" in
        *" · source: run-step"*)
          launch_mark_set verdict "held $spawn_gen"
          echo "launch-check held $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) reason=$LV_REASON, but a no-mistakes run holds the task ($custody); not building and not relaunched"
          exit 0
          ;;
      esac
      ;;
  esac
  case "$LV_STATE" in
    building)
      launch_mark_set verdict "building $spawn_gen"
      echo "launch-check building $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) evidence=$LV_REASON"
      exit 0
      ;;
    pending)
      echo "launch-check pending $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) evidence=$LV_REASON"
      exit 3
      ;;
    unproven)
      echo "launch-check unproven $ID harness=$RECORDED_HARNESS model=$(fm_meta_get "$META" model) reason=$LV_REASON; not counted as building and nothing acted on"
      exit 5
      ;;
  esac

  # LV_STATE=failed from here on.
  [ "$LW_KIND" != acted ] || launch_fail "$LV_REASON; $LW_REASON, so it is not relaunched"
  if [ -n "$relaunch" ]; then
    if [ "${relaunch%% *}" = "$spawn_gen" ] && [ -z "$relaunch_result" ]; then
      launch_fail "$LV_REASON, and the one relaunch claimed onto ${relaunch#* } never published a new incarnation"
    fi
    launch_fail "$LV_REASON after the one allowed relaunch (onto ${relaunch#* }, ${relaunch_result:-no result})"
  fi
  chosen=
  [ "${#LAUNCH_FALLBACKS[@]}" -eq 0 ] || chosen=$(launch_pick_fallback)
  [ -n "$chosen" ] || launch_fail "$LV_REASON, and no eligible fallback route was given"
  case "${chosen%%/*}" in pi|pi-signed|opencode|cursor) CATALOG_VERIFIED=$chosen ;; esac

  prior="$RECORDED_HARNESS/$(fm_meta_get "$META" model)"
  effort=$(fm_meta_get "$META" effort)
  case "$effort" in ''|ultra) effort=default ;; esac
  NEW_HARNESS=${chosen%%/*} NEW_MODEL=${chosen#*/} NEW_EFFORT=$effort
  HARNESS_SET=1 MODEL_SET=1 EFFORT_SET=1
  NOTE="Launch check: the previous launch on $prior was not a working agent ($LV_REASON), so Firstmate relaunched this task once on $chosen. Nothing from the previous launch needs undoing; start the task from these instructions."
  NOTE_SET=1
  # The relaunch's pre-stop refusals run first in a subshell, where a refusal
  # (die) returns here with nothing changed. The relaunch itself must run in
  # this process: fm-spawn --relaunch accepts the control lock only from its
  # direct parent. A failure after the stop ends this process, so the EXIT
  # trap records it (launch_check_cleanup_failure).
  rc=0
  out=$({ resolve_relaunch_profile && safe_checkpoint; } 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    launch_fail "$LV_REASON, and the relaunch onto $chosen was refused before anything changed: $(printf '%s' "$out" | grep -v '^notice:' | tail -1)"
  fi
  launch_mark_set relaunch "$spawn_gen $chosen"
  LAUNCH_CHECK_RELAUNCH=$chosen
  do_relaunch
  LAUNCH_CHECK_RELAUNCH=
  launch_mark_set relaunch_result "ok $(fm_meta_get "$META" spawn_gen)"
  echo "launch-check relaunched $ID from=$prior to=$chosen reason=$LV_REASON; check again after ${LAUNCH_WINDOW}s"
  exit 3
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    do_relaunch
    ;;
  launch-check)
    do_launch_check
    ;;
esac
