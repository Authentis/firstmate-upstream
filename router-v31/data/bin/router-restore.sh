#!/usr/bin/env bash
set -eu
H=${FM_HOME:?FM_HOME must be explicit for router restoration}
C=${ROUTER_PRODUCER_CONTROL:?ROUTER_PRODUCER_CONTROL must be explicit}
V=${1:?usage: router-restore.sh VERSION|previous}
B=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$B/router_bundle_v31.py" restore --home "$H" --control "$C" "$V"
