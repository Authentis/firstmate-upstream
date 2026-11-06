#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and TWO named exceptions to that purity - fm_control_endpoint_absence_verdict,
# the single owner of the per-backend endpoint-absence proof (with its
# read-only process-table helper fm_control_task_process_evidence), and
# fm_control_clear_draft, the single owner of the verified composer-draft clear
# (with its checkpoint-picker helpers fm_control_overlay_open and
# fm_control_dismiss_overlay); both run backend commands. Everything else has no side effects, runs no
# backend command, and reads no state, so sourcing this file is still free and
# the tables can be read by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which key sequence clears a draft an idle composer holds, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb: it is not deterministic across the
# verified adapters (docs/agent-control.md owns the per-adapter resume facts).
# `relaunch` uses the brief on disk rather than a harness-private session as
# its durable instruction. The relaunch-time exception is
# fm_control_relaunch_resume_flag below: a reference the endpoint's runtime
# bound as its status authority is returned to a replacement with that adapter.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
launch-check
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch|launch-check) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harnesses() {
  printf '%s\n' claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin commandcode
}

fm_control_harness_supported() {  # <harness>
  local harness found=1
  while read -r harness; do
    [ "$harness" = "${1-}" ] && found=0
  done < <(fm_control_harnesses)
  return "$found"
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands, `agy`
# is exact for the same reason on an even shorter name, `commandcode` is exact
# because a raw `commandcode` launch already records the adapter name, and an
# unrecognized value returns nonzero rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    agy) printf 'agy' ;;
    devin) printf 'devin' ;;
    commandcode) printf 'commandcode' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    rovo*) printf 'rovo' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse, gemini, rovo, agy, devin,
# and commandcode are crewmate/scout adapters only: none has a primary supervision protocol,
# and bin/fm-spawn.sh refuses a --secondmate launch on any of them. The control
# plane asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini|rovo|agy|devin|commandcode) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
# rovo cancels on a single Escape too, printing "Agent cancelled" (verified,
# 202609.1.2). agy cancels on a single Escape, printing the Interrupted row
# with an idle composer and no repollution (verified live, agy 1.2.0 through
# Herdr). omp (Oh My Pi) shares Pi's single Escape, empty composer
# afterwards, and /quit exit (verified omp 18.1.2 in a PTY, re-verified 18.1.11
# through Herdr). Command Code cancels on a single Escape, records the run as
# interrupted, and leaves its idle placeholder composer with no restored draft;
# a lone Escape on an idle Command Code opens nothing (verified, commandcode
# 1.73.4 in tmux).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo|agy|devin|commandcode) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode and Devin need a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode|devin) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode) printf '1' ;;
    *) return 1 ;;
  esac
}

# The rendered proof, read from the visible viewport between presses, that the
# first interrupt press landed on a RUNNING turn; empty when the adapter sends
# its presses blind. Devin needs it because the same fast double Escape that
# cancels a running turn opens its /revert "Revert to step" picker on an idle
# agent, where a later Enter reverts file changes. One Escape on a running turn
# renders `esc again to interrupt` for about three seconds, while an idle agent
# renders nothing, so the second press is sent only after that proof and never
# sooner than fm_control_interrupt_press_gap: an unproven arm sends nothing
# more. Verified live on devin 3000.11.1: an idle pair opened the picker at a
# 0.05-0.1 s gap and did not at 0.15 s or more, and a running turn cancelled
# with a 0.6 s gap.
fm_control_interrupt_arm_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'esc again to interrupt' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode) ;;
    *) return 1 ;;
  esac
}

# The minimum seconds between two presses of an armed interrupt: several times
# Devin's observed idle double-tap window, well inside its three-second armed
# window. A turn that ends between the presses therefore cannot pair them.
fm_control_interrupt_press_gap() {  # <harness>
  case "${1-}" in
    devin) printf '0.5' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode) printf '0.2' ;;
    *) return 1 ;;
  esac
}

# A rendered surface that a mistimed interrupt press can open and that must be
# dismissed with one more interrupt key before anything else is typed; empty
# when the adapter has none. Devin's revert picker is recognized by either of
# two independent rows, its `Revert to step:` title or its `↵ revert` footer,
# and Escape cancels it without reverting (verified live, devin 3000.11.1).
fm_control_interrupt_hazard_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'Revert to step:|↵ revert' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode) ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin|commandcode) ;;
    *) return 1 ;;
  esac
}

# The key sequence that clears a DRAFT an idle composer already holds, as
# distinct from the post-interrupt clear above, which removes a prompt the
# interrupt itself restored. Prints the key or nothing; a harness with no
# verified mechanics returns nonzero, matching the tables above, and every
# other adapter's draft is never touched: a draft there may be the captain's
# own typing. Command Code is the one adapter with a verified draft clear:
# Escape pressed twice within about 0.4 s empties the composer, whatever it
# holds (verified live, commandcode 1.74.0 in tmux: a single-line draft, a
# three-line draft, a pasted five-line block, and a typed-pasted-typed mix all
# read empty afterwards; docs/verification/commandcode.md owns the dated
# result and the live guard). The alternatives fail: Ctrl-U kills only the
# cursor line of a multi-line draft and Ctrl-A then Ctrl-K only the cursor
# line as well; one Ctrl-C clears but arms `Press Ctrl+C again to exit`, so a
# second press would exit the agent; one Escape on a draft changes nothing.
# The same pair on an idle EMPTY composer opens the Rewind checkpoint picker
# once the session has a turn (verified live, commandcode 1.74.1), where Enter
# restores a checkpoint, so fm_control_clear_draft below never sends it to a
# composer that reads empty and closes the picker with one Escape if it opens.
# The same pair on a RUNNING turn is an interrupt, so a caller outside the
# interrupt and exit verbs must prove the agent idle first
# (bin/fm-task-inbox-lib.sh does).
fm_control_draft_clear_key() {  # <harness>
  case "${1-}" in
    commandcode) printf 'Escape' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|devin) ;;
    *) return 1 ;;
  esac
}

# How many times the draft-clear key is delivered; empty when the adapter has
# no draft clear.
fm_control_draft_clear_presses() {  # <harness>
  case "${1-}" in
    commandcode) printf '2' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|devin) ;;
    *) return 1 ;;
  esac
}

# Seconds between the presses. Command Code pairs two Escapes only inside a
# window measured between 0.4 s (paired) and 0.5 s (not paired) including the
# sender's own process overhead, so the gap is a quarter of that.
fm_control_draft_clear_gap() {  # <harness>
  case "${1-}" in
    commandcode) printf '0.1' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|devin) ;;
    *) return 1 ;;
  esac
}

# The key that closes the overlay a mistimed Escape pair can open. Command Code
# is the only adapter whose clear sends the pair, so it is the only one with an
# overlay to close: its Rewind checkpoint picker closes on ONE Escape (verified
# live, commandcode 1.74.1); Enter would restore a checkpoint.
fm_control_overlay_dismiss_key() {  # <harness>
  case "${1-}" in
    commandcode) printf 'Escape' ;;
    *) return 1 ;;
  esac
}

# fm_control_overlay_open: whether the harness's checkpoint picker is on screen.
# Prints nothing; returns 0 open, 1 not open, 2 unreadable or no such overlay
# for the adapter. The picker is two rows, the title `Rewind` directly above
# `Select a checkpoint to restore your session` (docs/verification/
# commandcode.md owns the capture), matched as whole trimmed rows so a
# transcript that merely mentions them is not read as the picker. The viewport
# is read where the backend has a verified bounded read; elsewhere the last 40
# rows stand in, because the picker draws at the bottom.
fm_control_overlay_open() {  # <backend> <target> <harness> [expected-label]
  local backend=${1-} target=${2-} harness=${3-} label=${4-} screen
  fm_control_overlay_dismiss_key "$harness" >/dev/null || return 2
  if fm_backend_visible_capture_supported "$backend"; then
    screen=$(fm_backend_visible_capture "$backend" "$target" "$label" 2>/dev/null) || return 2
  else
    screen=$(fm_backend_capture "$backend" "$target" 40 "$label" 2>/dev/null) || return 2
  fi
  [ -n "$screen" ] || return 2
  printf '%s\n' "$screen" | LC_ALL=C sed $'s/\x1b\\[[0-9;:?]*[A-Za-z]//g; s/\r$//' | LC_ALL=C awk '
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line == "" { next }
    title { if (line == "Select a checkpoint to restore your session") found = 1; title = 0 }
    line == "Rewind" { title = 1 }
    END { exit(found ? 0 : 1) }
  '
}

# fm_control_dismiss_overlay: close the checkpoint picker if it is open, with
# exactly one Escape, and prove it closed. Returns 0 when nothing was open or it
# closed, 1 when it is open and the key was not delivered or one Escape did not
# close it (nothing else is sent: a second key into a picker is how Enter ends
# up restoring a checkpoint). An unreadable screen is treated as not open,
# because the composer read that follows it cannot be proven either.
fm_control_dismiss_overlay() {  # <backend> <target> <harness> [expected-label]
  local backend=${1-} target=${2-} harness=${3-} label=${4-} key polls=0
  key=$(fm_control_overlay_dismiss_key "$harness") || return 0
  fm_control_overlay_open "$backend" "$target" "$harness" "$label" || return 0
  fm_control_backend_supports_key "$backend" "$key" || return 1
  fm_backend_send_key "$backend" "$target" "$key" "$label" >/dev/null 2>&1 || return 1
  while [ "$polls" -lt 8 ]; do
    polls=$((polls + 1))
    sleep 0.25
    fm_control_overlay_open "$backend" "$target" "$harness" "$label" || return 0
  done
  return 1
}

# fm_control_clear_draft: the ONE mechanism that sends the draft-clear keys and
# proves the result, so the interrupt verb, the exit verb, and the doorbell all
# empty a composer the same way. Returns 0 only when the composer then reads
# exactly `empty` and no overlay is open (a verdict of pending-unproven or
# unknown never counts), 1 when the keys could not be delivered or the composer
# still reads otherwise after two attempts, and 2 when the adapter has no
# verified draft clear, in which case nothing was sent. Requires
# bin/fm-backend.sh.
# It never sends the clear to a composer that already reads empty, closes an
# open checkpoint picker with one Escape before and after the pair, and never
# repeats the pair once a picker has opened: the pair opens it only on an EMPTY
# composer, so an opened picker proves the text read before was not a draft.
# On return 1, FM_CONTROL_CLEAR_WHY names why for the caller's refusal:
#   overlay-stuck  a checkpoint picker is open and one Escape did not close it
#   misread        the pair opened the picker, which one Escape then closed: the
#                  composer was empty and still reads as holding text
#   pending        the composer still reads as holding text after both pairs
#   keys           a key could not be delivered
# shellcheck disable=SC2034 # Output global, consumed by sourcing callers.
FM_CONTROL_CLEAR_WHY=
fm_control_clear_draft() {  # <backend> <target> <harness> [expected-label]
  local backend=${1-} target=${2-} harness=${3-} label=${4-} key presses gap attempts=0 polls i
  FM_CONTROL_CLEAR_WHY=
  key=$(fm_control_draft_clear_key "$harness") || return 2
  [ -n "$key" ] || return 2
  presses=$(fm_control_draft_clear_presses "$harness") || return 2
  gap=$(fm_control_draft_clear_gap "$harness") || return 2
  fm_control_backend_supports_key "$backend" "$key" || { FM_CONTROL_CLEAR_WHY=keys; return 1; }
  fm_control_dismiss_overlay "$backend" "$target" "$harness" "$label" \
    || { FM_CONTROL_CLEAR_WHY=overlay-stuck; return 1; }
  [ "$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null)" != empty ] || return 0
  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    i=0
    while [ "$i" -lt "$presses" ]; do
      fm_backend_send_key "$backend" "$target" "$key" "$label" >/dev/null 2>&1 \
        || { FM_CONTROL_CLEAR_WHY=keys; return 1; }
      i=$((i + 1))
      [ "$i" -ge "$presses" ] || sleep "$gap"
    done
    polls=0
    while [ "$polls" -lt 8 ]; do
      polls=$((polls + 1))
      sleep 0.25
      if fm_control_overlay_open "$backend" "$target" "$harness" "$label"; then
        if fm_control_dismiss_overlay "$backend" "$target" "$harness" "$label"; then
          FM_CONTROL_CLEAR_WHY=misread
        else
          FM_CONTROL_CLEAR_WHY=overlay-stuck
        fi
        return 1
      fi
      [ "$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null)" != empty ] || return 0
    done
  done
  # shellcheck disable=SC2034 # Output global, consumed by sourcing callers.
  FM_CONTROL_CLEAR_WHY=pending
  return 1
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    # rovo's TUI prints "Agent cancelled" on Escape, but for parity with
    # claude/cursor this stays 'none': the ack is a rendered string, not a
    # recorded state source, and rovo has no busy wiring to confirm against.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin|commandcode) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse|rovo|commandcode) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini|agy|devin) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The launch argument that makes a RELAUNCH of <harness> RESUME an exact agent
# session instead of starting a fresh one, printed only when <registered-agent>
# is the label that session reference belongs to; nothing otherwise.
#
# This exists for one runtime failure, not as a general resume feature. Herdr
# gives a pane one status authority, and for Pi with its installed integration
# that authority is the lifecycle hooks, which also suppress Herdr's screen
# detection for the pane. That registration outlives its agent process in the
# crew shape - a nested worktree shell under the pane's top shell - and Herdr
# then applies only reports carrying the session identity it bound. A
# replacement agent started fresh in that same pane reports a NEW session, so
# its state reports are ignored and the pane stays frozen at whatever the
# previous agent last reported: a working crewmate reads idle until its task
# ends (reproduced and fixed live 2026-09-21, herdr 0.9.1; the read that
# supplies the reference is
# bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref).
#
# So the reference is not chosen from what looks recent - it is the exact
# identity the endpoint's own runtime recorded, which is why a matched
# registered-agent label is required: resuming a reference reported by a
# DIFFERENT agent would inject another agent's conversation into this launch.
# `pi` is the label Pi and pi-signed both report, so one entry covers both.
# Every other harness returns nothing and keeps today's fresh-session
# relaunch, which is what the adapter tables above (and the absence of a
# verified resume form for those harnesses) require.
#
# Prints the flag name only; the caller quotes and appends the reference, since
# shell quoting belongs to the owner of the launch line (bin/fm-spawn.sh).
fm_control_relaunch_resume_flag() {  # <harness> <registered-agent>
  case "${1-}" in
    pi|pi-signed)
      [ "${2-}" = pi ] && printf -- '--session'
      ;;
  esac
  return 0
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# fm_control_endpoint_absence_verdict: the ONE owner of the per-backend proof
# that an endpoint reading `missing` is actually GONE rather than merely
# unreachable from this seat. Call it only for a `missing` raw state.
#
# Prints "<verdict>\t<reason>" - always exactly one TAB, so a caller splits
# unambiguously with ${raw%%$'\t'*} and ${raw#*$'\t'}. The reason is empty
# except on `unproven`, where it is the concrete sentence the caller's refusal
# message embeds. It is returned on stdout rather than set in a variable
# because every caller reads this through a command substitution, where an
# assignment made here could never reach them.
#
# The verdicts:
#   gone     - absence is PROVEN. There is no endpoint and therefore no agent.
#   dead     - the endpoint is there after all and holds no agent.
#   alive    - the endpoint is there and an agent is running in it.
#   unproven - neither could be established; the caller must refuse.
#
# fm_backend_agent_state's `missing` conflates "the endpoint was DESTROYED"
# with "the endpoint is UNREACHABLE from here right now". An unreachable
# endpoint can still hold a live agent on the task's worktree, so every caller
# that would act on absence - `exit` claiming the agent stopped, `relaunch`
# re-creating the endpoint - must come through here rather than trusting the
# raw verdict.
#
# Whether absence is provable, and from what, is a property of the backend:
#   herdr proves it from the endpoint itself. Every read goes through
#     fm_backend_herdr_cli, which passes `--session <session>`, so the recheck
#     starts and reads the session the RECORD names, through that session's own
#     socket. The answer is about the task's endpoint and nothing else.
#   tmux cannot prove it from the endpoint, because a task record carries no
#     socket identity: `list-windows -a` describes only the server the CURRENT
#     process addresses, so a window absent from it may be alive on another.
#     It proves it from the AGENT instead. Wherever that window lives, an agent
#     working this task is a process in this machine's process table, either
#     named by the task (its id or its fm-<id> lane) or sitting in or naming
#     the recorded worktree. So tmux answers `gone` only when ALL of these
#     hold, and `unproven` on any ambiguity or unreadable read:
#       - this server's whole window inventory was read (a server that
#         definitively does not exist reads as an empty one) and neither the
#         recorded window nor any window of the same name is in it;
#       - fm_backend_agent_alive reads the recorded endpoint as not alive;
#       - fm_control_task_process_evidence finds no process naming the task or
#         the worktree, and none whose current directory is in the worktree.
#     <task-id> and <worktree> are therefore required for tmux; without them
#     the verdict stays `unproven`.
#
# Both control-plane callers share this one implementation so the proof cannot
# drift into two answers for the same endpoint.
fm_control_endpoint_absence_verdict() {  # <backend> <target> [<task-id> <worktree>]
  local backend=${1-} target=${2-} id=${3-} wt=${4-} inventory window evidence
  fm_backend_source "$backend" \
    || { printf 'unproven\tbackend %s could not be loaded to prove anything about that endpoint' "'$backend'"; return 0; }
  case "$backend" in
    tmux)
      [ -n "$id" ] && [ -n "$wt" ] || {
        printf 'unproven\tthe caller named no task id and worktree, so no process evidence could stand in for the socket identity a tmux task record does not carry'
        return 0
      }
      case "$target" in
        *:*:*|'':*|*:'') printf 'unproven\tthe recorded tmux endpoint %s is not a session:window address' "'$target'"; return 0 ;;
        *:*) window=${target#*:} ;;
        *) printf 'unproven\tthe recorded tmux endpoint %s is not a session:window address' "'$target'"; return 0 ;;
      esac
      if ! inventory=$(LC_ALL=C tmux list-windows -a -F '#{session_name}:#{window_name}' 2>&1); then
        case "$inventory" in
          *"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)") inventory= ;;
          *) printf 'unproven\tthe window inventory of the tmux server this process addresses could not be read'; return 0 ;;
        esac
      fi
      if printf '%s\n' "$inventory" | awk -v t="$target" -v w="$window" '
          $0 == t { found = 1 }
          { i = index($0, ":"); if (i && substr($0, i + 1) == w) found = 1 }
          END { exit !found }'; then
        printf 'unproven\ta window named %s is still in the window inventory of the tmux server this process addresses' "'$window'"
        return 0
      fi
      case "$(fm_backend_agent_alive tmux "$target")" in
        dead) ;;
        *) printf 'unproven\tthe recorded endpoint no longer reads as agent-free'; return 0 ;;
      esac
      evidence=$(fm_control_task_process_evidence "$id" "$wt")
      case "${evidence%%$'\t'*}" in
        none) printf 'gone\t%s' "${evidence#*$'\t'}" ;;
        match) printf 'unproven\t%s, so its agent may still be running in a tmux window this process cannot address' "${evidence#*$'\t'}" ;;
        *) printf 'unproven\t%s' "${evidence#*$'\t'}" ;;
      esac
      ;;
    herdr)
      # Start the RECORDED session's server (only the server - nothing is
      # created) and re-read the recorded pane. A pane that comes back with the
      # server was never destroyed.
      case "$(fm_backend_herdr_endpoint_absence_recheck "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe recorded herdr session'"'"'s server could not be started, or its pane could not be classified once it was running' ;;
      esac
      ;;
    *)
      printf 'unproven\tbackend %s has no recovery-grade classifier, so absence cannot be proven on it at all' "'$backend'"
      ;;
  esac
}

# fm_control_task_process_evidence: whether any process on this machine could
# be an agent still working <task-id> in <worktree>, which is the evidence
# fm_control_endpoint_absence_verdict uses in place of a tmux socket identity.
# Part of that verdict's named exception to this file's purity: it reads the
# process table and process working directories, and changes nothing.
#
# Prints "<result>\t<reason>", with the same one-TAB shape as the verdict:
#   none       - the process table was read and nothing matched.
#   match      - a process names the task id, its fm-<id> lane, or the
#                worktree in its arguments, or its current directory is the
#                worktree or under it; the reason names the pid and which.
#   unreadable - the process table, or the working directory of a process not
#                positively known to have exited or to be a zombie, could not
#                be read, so nothing is proven.
#
# Argument matching is by whole token: arguments are split on every character
# outside [A-Za-z0-9_.-], and a token matches when it is the id, the fm-<id>
# lane, or starts with "<id>." (a task-owned file such as <id>.meta). The
# worktree matches as a path that is not the prefix of a longer name.
# Working directories are compared for this user's own processes only; they
# come from /proc where it exists (FM_CONTROL_PROC_ROOT names another proc
# tree, for tests), and otherwise from one `lsof -a -d cwd` scan, which must
# report every candidate.
# The calling process, its ancestors (the fm-spawn or fm-control invocation
# naming the task) and its descendants (this scan's own subshells) are never
# evidence.
fm_control_known_non_worker() {  # <proc-root> <pid> <uid> <task-id> <worktree> <worktree-real>
  # A process whose working directory cannot be read is accepted as not the
  # task's worker only when its comm is exactly one of a fixed list of
  # session helpers that hide their directory from their own user (systemd's
  # sd-pam, gpg-agent and an SSH login's sshd), its real uid is the caller's,
  # and its readable cmdline names neither the task nor the worktree. The list
  # is closed: adding a name is a deliberate safety decision. Prints the comm
  # on acceptance; anything else, including an unreadable comm, uid or
  # cmdline, is refused.
  local proc=$1 pid=$2 uid=$3 id=$4 wt=$5 wtr=$6 comm puid args t tok
  comm=$(cat "$proc/$pid/comm" 2>/dev/null) || return 1
  case "$comm" in
    sd-pam|'(sd-pam)'|gpg-agent|sshd) ;;
    *) return 1 ;;
  esac
  puid=$(awk '$1 == "Uid:" { print $2; exit }' "$proc/$pid/status" 2>/dev/null) || return 1
  [ -n "$puid" ] && [ "$puid" = "$uid" ] || return 1
  [ -r "$proc/$pid/cmdline" ] || return 1
  args=$(tr '\0' ' ' < "$proc/$pid/cmdline" 2>/dev/null) || return 1
  case "$args" in *"$wt"*|*"$wtr"*) return 1 ;; esac
  t=$(printf '%s' "$args" | LC_ALL=C tr -c 'A-Za-z0-9_.-' ' ')
  for tok in $t; do
    case "$tok" in
      "$id"|"fm-$id"|"$id".*) return 1 ;;
    esac
  done
  printf '%s' "$comm"
}

fm_control_task_process_evidence() {  # <task-id> <worktree>
  local id=${1-} wt=${2-} wt_real self uid table rows line kind pid cwd lsof_out covered state comm
  local cand=" " proc=${FM_CONTROL_PROC_ROOT:-/proc} accepted=
  [ -n "$id" ] && [ -n "$wt" ] || { printf 'unreadable\tno task id and worktree to match processes against'; return 0; }
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  self=${BASHPID:-$$}
  uid=$(id -u 2>/dev/null) || { printf 'unreadable\tthis user id could not be read to scope the process scan'; return 0; }
  table=$(LC_ALL=C ps -A -o pid= -o ppid= -o uid= -o args= 2>/dev/null) \
    || { printf 'unreadable\tthe process table could not be read'; return 0; }
  rows=$(printf '%s\n' "$table" | LC_ALL=C awk -v self="$self" -v uid="$uid" -v id="$id" \
    -v wt="$wt" -v wtr="$wt_real" '
    function pathhit(s, p,   rest, i, c) {
      if (p == "") return 0
      rest = s
      while ((i = index(rest, p)) > 0) {
        c = substr(rest, i + length(p), 1)
        if (c !~ /[A-Za-z0-9_.-]/) return 1
        rest = substr(rest, i + 1)
      }
      return 0
    }
    NF == 0 { next }
    {
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/) { bad = 1; next }
      n++; pid[n] = $1; parent[$1] = $2; owner[$1] = $3
      a = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]*/, "", a); args[$1] = a
    }
    END {
      if (bad) { print "bad"; exit }
      p = self; hops = 0
      while (p != "" && p != "0" && !(p in skip) && hops < 4096) { skip[p] = 1; p = parent[p]; hops++ }
      changed = 1
      while (changed) {
        changed = 0
        for (k = 1; k <= n; k++) {
          q = pid[k]
          if (!(q in skip) && (parent[q] == self || (parent[q] in desc))) { desc[q] = 1; skip[q] = 1; changed = 1 }
        }
      }
      for (k = 1; k <= n; k++) {
        q = pid[k]
        if (q in skip) continue
        s = args[q]
        if (pathhit(s, wt) || pathhit(s, wtr)) { print "match " q " names the recorded worktree in its arguments"; continue }
        t = s; gsub(/[^A-Za-z0-9_.-]+/, " ", t)
        m = split(t, tok, " ")
        hit = 0
        for (j = 1; j <= m; j++) {
          if (tok[j] == id || tok[j] == "fm-" id || index(tok[j], id ".") == 1) { hit = 1; break }
        }
        if (hit) { print "match " q " names the task in its arguments"; continue }
        if (owner[q] == uid) print "cand " q
      }
    }') || { printf 'unreadable\tthe process table could not be parsed'; return 0; }
  case "$rows" in bad|bad$'\n'*) printf 'unreadable\tthe process table could not be parsed'; return 0 ;; esac
  while IFS=' ' read -r kind pid line; do
    case "$kind" in
      match) printf 'match\tprocess %s %s' "$pid" "$line"; return 0 ;;
      cand) cand="$cand$pid " ;;
    esac
  done <<EOF
$rows
EOF
  [ "$cand" != " " ] || { printf 'none\t'; return 0; }
  if [ -n "$(readlink "$proc/self/cwd" 2>/dev/null)" ]; then
    for pid in $cand; do
      if ! cwd=$(readlink "$proc/$pid/cwd" 2>/dev/null) || [ -z "$cwd" ]; then
        # Only a process positively known to have exited since the snapshot,
        # or to be a zombie, has no directory to be working in. Any other
        # process whose directory cannot be read, whatever the reason, could
        # still be the worker, so nothing is proven.
        [ -e "$proc/$pid" ] || continue
        case "$(awk '{ sub(/^.*\) /, ""); print $1 }' "$proc/$pid/stat" 2>/dev/null)" in
          Z|X) continue ;;
        esac
        [ -e "$proc/$pid" ] || continue
        if comm=$(fm_control_known_non_worker "$proc" "$pid" "$uid" "$id" "$wt" "$wt_real"); then
          accepted="$accepted${accepted:+, }$pid $comm"
          continue
        fi
        printf 'unreadable\tthe working directory of process %s could not be read' "$pid"
        return 0
      fi
      case "$cwd" in
        "$wt_real"|"$wt_real"/*|"$wt"|"$wt"/*)
          printf 'match\tprocess %s is working in the recorded worktree' "$pid"
          return 0
          ;;
      esac
    done
    if [ -n "$accepted" ]; then
      printf 'none\tunreadable working directories accepted as known non-workers: %s' "$accepted"
    else
      printf 'none\t'
    fi
    return 0
  fi
  command -v lsof >/dev/null 2>&1 \
    || { printf 'unreadable\tneither /proc nor lsof is available to read process working directories'; return 0; }
  lsof_out=$(lsof -a -d cwd -Fpn 2>/dev/null) \
    || { printf 'unreadable\tlsof could not read process working directories'; return 0; }
  pid=
  covered=" "
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        case "$cand" in *" $pid "*) ;; *) continue ;; esac
        [ -n "$pid" ] || continue
        covered="$covered$pid "
        case "${line#n}" in
          "$wt_real"|"$wt_real"/*|"$wt"|"$wt"/*)
            printf 'match\tprocess %s is working in the recorded worktree' "$pid"
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$lsof_out
EOF
  # lsof silently leaves out a process it could not inspect, so every
  # candidate it did not report is unproven unless it has positively exited
  # or is a zombie.
  for pid in $cand; do
    case "$covered" in *" $pid "*) continue ;; esac
    state=$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null) || state=
    state=${state#"${state%%[![:space:]]*}"}
    case "$state" in
      Z*) continue ;;
      '') kill -0 "$pid" 2>/dev/null || continue ;;
    esac
    printf 'unreadable\tlsof did not report the working directory of process %s' "$pid"
    return 0
  done
  printf 'none\t'
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id> [kind]
  local harness=${1-} wt=${2-} state=${3-} id=${4-} kind=${5-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    # A secondmate's .claude/settings.local.json belongs to the captain.
    # Retire only the firstmate-owned settings file the launch passes to
    # --settings and the Stop pointer that carries the same busy generation.
    # A crewmate's hook file is the worktree settings.local.json.
    claude)
      if [ "$kind" = secondmate ]; then
        printf '%s\n' "$state/$id.claude-settings.json"
        printf '%s\n' "$wt/.fm-busy-stop"
      else
        printf '%s\n' "$wt/.claude/settings.local.json"
      fi
      ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
    devin) printf '%s\n' "$state/$id.devin-config.json" ;;
    # Command Code's busy-state mod lives in state/, and its per-task settings
    # (commit attribution off, taste learning off) are the worktree's
    # project-local settings file, the same shape as Claude's.
    commandcode)
      printf '%s\n' "$state/$id.commandcode-mod.ts"
      printf '%s\n' "$wt/.commandcode/settings.local.json"
      ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
