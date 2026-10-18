#!/usr/bin/env bash
# Live guard for the pre-launch model catalog check (bin/fm-model-catalog-lib.sh)
# against every INSTALLED Pi, Pi-signed, and OpenCode. It reads each harness's
# real listing (no prompt, no model tokens), then proves a listed id launches
# and a fabricated id refuses, so a vendor change to the listing shape fails
# here naming the harness and version instead of silently letting bad ids
# through. FM_MODEL_CATALOG_LIVE=1 makes an absent harness a failure.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_MODEL_CATALOG_LIVE
# shellcheck source=bin/fm-model-catalog-lib.sh
. "$ROOT/bin/fm-model-catalog-lib.sh"

checked=0
absent=()
for harness in pi pi-signed opencode; do
  if ! bin=$(command -v "$harness"); then
    absent+=("$harness")
    continue
  fi
  version=$("$bin" --version 2>/dev/null | head -1)
  case "$harness" in
    opencode)
      listed=$(fm_run_timed 30 "$bin" models 2>/dev/null < /dev/null | grep / | head -1)
      ;;
    *)
      listed=$(fm_run_timed 30 "$bin" --list-models 2>/dev/null < /dev/null \
        | awk 'NR == 1 && tolower($1) == "provider" { next } NF >= 2 { print $1 "/" $2; exit }')
      ;;
  esac
  if [ -z "$listed" ]; then
    printf 'skip: %s %s lists no authenticated models on this host\n' "$harness" "${version:-unknown}"
    continue
  fi
  out=$(fm_model_catalog_validate "$harness" "$bin" "$listed" 2>&1) \
    || fail "$harness ${version:-unknown}: listed model '$listed' was refused: $out"
  if out=$(fm_model_catalog_validate "$harness" "$bin" fm-catalog-guard/not-a-model-zz 2>&1); then
    fail "$harness ${version:-unknown}: a fabricated model was accepted"
  fi
  if out=$(fm_model_catalog_validate "$harness" "$bin" not-a-model-zz-fm-guard 2>&1); then
    fail "$harness ${version:-unknown}: a fabricated bare id was accepted"
  fi
  pass "$harness ${version:-unknown}: listed '$listed' launches; fabricated ids refuse"
  checked=$((checked + 1))
done
[ "${#absent[@]}" -eq 0 ] || printf 'skip: absent harness: %s\n' "${absent[*]}"
if [ "${FM_MODEL_CATALOG_LIVE:-${FM_LIVE:-}}" = 1 ] && [ "${#absent[@]}" -gt 0 ]; then
  fail "FM_MODEL_CATALOG_LIVE=1 was requested but ${absent[*]} is not installed"
fi
[ "$checked" -gt 0 ] || fail "no installed harness listing was checked; refusing a pass that checked nothing"
