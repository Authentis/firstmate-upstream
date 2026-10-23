#!/usr/bin/env bash
# Lab stub digest producer: emits a large re-emit digest (~92k chars) so the
# real extension's compaction cap and .reemit-latest.txt save are exercised.
src=""
while [ $# -gt 0 ]; do case "$1" in --source) src=$2; shift 2;; *) shift;; esac; done
echo "$src $(date +%s)" >> "$FM_HOME/state/runner-calls.log"
if [ "$src" != compact ]; then printf 'STARTUP_DIGEST source=%s\n' "$src"; exit 0; fi
printf 'LIVE_DIGEST_HEAD source=%s\n' "$src"
for i in $(seq 1 1100); do printf 'fleet row %04d: lorem ipsum dolor sit amet consectetur adipiscing elit sed do\n' "$i"; done
printf 'LIVE_DIGEST_TAIL\n'
