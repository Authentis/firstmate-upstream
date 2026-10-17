#!/usr/bin/env bash
# Shared per-host periodic timer wiring: one launchd LaunchAgent on macOS, one
# systemd user service plus timer elsewhere.
# Sourced by bin/fm-status-probe.sh and bin/fm-order-ledger.sh, which own the
# job each timer runs; this file has no side effects on source.
#
# Every timer is scoped to one firstmate home: the label carries a short hash of
# FM_HOME, and the unit exports that FM_HOME, so two homes on one host never
# share or clobber a timer.
#
# Test and dry-run seams: FM_TIMER_DIR relocates the unit directory, and
# FM_TIMER_NOLOAD=1 writes or removes the unit files without calling
# launchctl or systemctl.

_FM_TIMER_UNAME=$(uname 2>/dev/null || echo unknown)

fm_timer_label() {  # <job> <home> -> label
  local job=$1 home=$2 sum
  sum=$(printf '%s' "$home" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-8)
  printf 'fm-%s-%s\n' "$job" "$sum"
}

fm_timer_kind() {
  [ "$_FM_TIMER_UNAME" = Darwin ] && echo launchd || echo systemd
}

fm_timer_dir() {
  if [ -n "${FM_TIMER_DIR:-}" ]; then
    printf '%s\n' "$FM_TIMER_DIR"
  elif [ "$(fm_timer_kind)" = launchd ]; then
    printf '%s\n' "$HOME/Library/LaunchAgents"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  fi
}

_fm_timer_xml() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  printf '%s' "${s//>/&gt;}"
}

# _fm_timer_sd_quote <word> -> the word as one systemd command-line or
# environment word: double-quoted, with the backslash, double quote, newline,
# and the % and $ that systemd would otherwise expand escaped the systemd way.
_fm_timer_sd_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//%/%%}
  s=${s//\$/\$\$}
  printf '"%s"' "$s"
}

# fm_timer_render <kind> <label> <interval-seconds> <home> <command-path> [arg...]
# Prints the unit text: the plist for launchd, or the service then the timer
# (separated by a line holding only `---`) for systemd.
fm_timer_render() {
  local kind=$1 label=$2 interval=$3 home=$4 arg
  shift 4
  if [ "$kind" = launchd ]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>com.firstmate.%s</string>\n' "$label"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    for arg in "$@"; do
      printf '    <string>%s</string>\n' "$(_fm_timer_xml "$arg")"
    done
    printf '  </array>\n'
    printf '  <key>EnvironmentVariables</key><dict><key>FM_HOME</key><string>%s</string></dict>\n' "$(_fm_timer_xml "$home")"
    printf '  <key>StartInterval</key><integer>%s</integer>\n' "$interval"
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '</dict>\n</plist>\n'
  else
    printf '[Unit]\nDescription=Firstmate %s\n\n' "$label"
    printf '[Service]\nType=oneshot\nEnvironment=%s\nExecStart=' "$(_fm_timer_sd_quote "FM_HOME=$home")"
    for arg in "$@"; do
      printf '%s ' "$(_fm_timer_sd_quote "$arg")"
    done
    printf '\n---\n'
    printf '[Unit]\nDescription=Firstmate %s every %ss\n\n' "$label" "$interval"
    printf '[Timer]\nOnBootSec=%s\nOnUnitActiveSec=%s\nAccuracySec=1s\n\n' "$interval" "$interval"
    printf '[Install]\nWantedBy=timers.target\n'
  fi
}

# fm_timer_install <job> <interval> <home> <command-path> [arg...]
fm_timer_install() {
  local job=$1 interval=$2 home=$3 kind label dir
  shift 3
  kind=$(fm_timer_kind)
  label=$(fm_timer_label "$job" "$home")
  dir=$(fm_timer_dir)
  mkdir -p "$dir" || return 1
  if [ "$kind" = launchd ]; then
    fm_timer_render "$kind" "$label" "$interval" "$home" "$@" > "$dir/com.firstmate.$label.plist" || return 1
    [ "${FM_TIMER_NOLOAD:-}" = 1 ] && return 0
    launchctl bootout "gui/$(id -u)/com.firstmate.$label" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$dir/com.firstmate.$label.plist"
  else
    local text
    text=$(fm_timer_render "$kind" "$label" "$interval" "$home" "$@") || return 1
    printf '%s\n' "$text" | sed '/^---$/,$d' > "$dir/$label.service"
    printf '%s\n' "$text" | sed '1,/^---$/d' > "$dir/$label.timer"
    [ "${FM_TIMER_NOLOAD:-}" = 1 ] && return 0
    systemctl --user daemon-reload && systemctl --user enable --now "$label.timer"
  fi
}

# fm_timer_remove <job> <home>
fm_timer_remove() {
  local job=$1 home=$2 kind label dir
  kind=$(fm_timer_kind)
  label=$(fm_timer_label "$job" "$home")
  dir=$(fm_timer_dir)
  if [ "$kind" = launchd ]; then
    [ "${FM_TIMER_NOLOAD:-}" = 1 ] || launchctl bootout "gui/$(id -u)/com.firstmate.$label" >/dev/null 2>&1 || true
    rm -f -- "$dir/com.firstmate.$label.plist"
  else
    [ "${FM_TIMER_NOLOAD:-}" = 1 ] || systemctl --user disable --now "$label.timer" >/dev/null 2>&1 || true
    rm -f -- "$dir/$label.service" "$dir/$label.timer"
  fi
}
