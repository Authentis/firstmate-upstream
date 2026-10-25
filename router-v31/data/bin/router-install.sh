#!/usr/bin/env bash
set -eu
H=${FM_HOME:?FM_HOME must be explicit for router installation}
C=${ROUTER_PRODUCER_CONTROL:?ROUTER_PRODUCER_CONTROL must be explicit}
S=${2:?usage: router-install.sh VERSION ABSOLUTE-SOURCE}
V=${1:?usage: router-install.sh VERSION ABSOLUTE-SOURCE}
B=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$B/router_bundle_v31.py" install --home "$H" --control "$C" --source "$S" --wrapper "$B/router-pointer-wrapper.sh" "$V"
