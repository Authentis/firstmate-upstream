#!/usr/bin/env bash
# tests/fork-count-lib.sh - count the external commands a script spawns.
#
# Source this after tests/lib.sh. fc_make_shims writes one PATH shim per common
# helper tool; each shim appends the tool's name to $FC_LOG and then execs the
# real tool, so the number of lines is the number of processes the script under
# test created by that name. Builtins and parameter expansion never reach a
# shim, which is exactly the distinction the fork-churn regressions pin.
#
#   fc_make_shims <dir>          create the shims in <dir>
#   fc_reset                     empty the log
#   fc_total                     print the number of logged calls
#   fc_count <tool>              print the calls of one tool
#   fc_breakdown                 print "<count> <tool>" lines, busiest first
#   fc_per_tick <hi> <lo> <ticks>  print (hi - lo) / ticks to one decimal place

FC_TOOLS="sleep ps awk shasum sha256sum sed tr cat date stat mktemp mv wc head tail dirname basename od perl grep cut sort rm chmod mkfifo mkdir rmdir uname id readlink"

fc_make_shims() { # <dir>
  local dir=$1 tool real
  mkdir -p "$dir"
  FC_SHIM_DIR=$dir
  for tool in $FC_TOOLS; do
    real=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$tool") || continue
    cat > "$dir/$tool" <<SH
#!/bin/sh
printf '%s\n' $tool >> "\$FC_LOG"
exec $real "\$@"
SH
    chmod +x "$dir/$tool"
  done
}

fc_reset() { : > "$FC_LOG"; }
fc_total() { wc -l < "$FC_LOG" | tr -d ' '; }
fc_count() { grep -cx "$1" "$FC_LOG" || true; }
fc_breakdown() { sort "$FC_LOG" | uniq -c | sort -rn | tr -s ' ' | tr '\n' ';'; }
fc_per_tick() { # <hi> <lo> <ticks>
  awk -v hi="$1" -v lo="$2" -v t="$3" 'BEGIN { if (t < 1) t = 1; printf "%.1f", (hi - lo) / t }'
}
