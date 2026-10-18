#!/usr/bin/env bash
# Installed beside the router scripts.  The Python half owns locking/accounting.
set -euo pipefail
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$DIR/router_planning_runner_v31.py" "$@"
