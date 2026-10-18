#!/usr/bin/env bash
# chief 4658: the reviewer is chosen by the WRITER family, not by quota rotation:
#   OpenAI-built (codex, gpt-6.1-sol, gpt-5.6-sol) -> muse-spark-1.3-contributor-via-firstmate
#     (literal off-host request marker: Muse is blocked on netcup, so firstmate runs the review elsewhere)
#   Muse-built -> droid:gpt-6.1-sol        Claude-built -> droid-local:gpt-6.1-sol
#   every other writer family (Kimi, free, DeepSeek, unknown) -> droid:gpt-6.1-sol (never WAIT).
# Claude, free and Kimi models are never reviewers; live_data yes|no is threaded into the policy
# (pass-3 M5: it was accepted but dropped before) so the live-data bans apply to reviewer picks too.
# Prints the pick or 'WAIT<TAB>why'.
set -u

FM_HOME=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
if [ -z "${ROUTER_BIN:-}" ]; then
  ROUTER_BIN=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fi
ROUTER_BUNDLE_ROOT=${ROUTER_BUNDLE_ROOT:-$(CDPATH= cd -- "$ROUTER_BIN/../.." && pwd -P)}
FLEET_YAML=${FLEET_YAML:-$FM_HOME/config/fleet.yaml}
export FM_HOME ROUTER_BIN ROUTER_BUNDLE_ROOT FLEET_YAML
# shellcheck source=router-launch.sh
source "$ROUTER_BIN/router-launch.sh"
router_global_off && exit 0

if [ "$#" -ne 2 ]; then
  echo "usage: route-reviewer.sh <author_family> <live_data yes|no>" >&2
  exit 2
fi
case "$2" in yes|no) ;; *) echo "usage: route-reviewer.sh <author_family> <live_data yes|no>" >&2; exit 2;; esac

exec python3 "$ROUTER_BIN/refill_lib_v2.py" route-reviewer "$1" "$2"
