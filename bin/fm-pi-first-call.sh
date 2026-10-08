#!/usr/bin/env bash
# Pi secondmate first-call readiness, shared by spawn and all relaunch routes.
# Usage: fm-pi-first-call.sh hook <receipt-path>
#        fm-pi-first-call.sh wait <receipt-path> <model> [timeout-seconds]
# hook emits a message_end handler for the existing spawn extension's pi object.
# It atomically records only the first assistant response, including provider
# errorMessage/stopReason. Each launch uses a fresh generation-specific receipt.
# wait requires a successful response within 60 seconds (override with
# FM_PI_FIRST_CALL_TIMEOUT, or the third argument); no receipt, abort, malformed
# receipt, or provider error refuses launch. Callers retain their ordinary
# failed-launch cleanup and surface the error through their failure path.
set -eu

case "${1:-}" in
  hook)
    [ "$#" -eq 2 ] || exit 2
    receipt=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$2")
    cat <<JS
  let firstCallRecorded = false;
  pi.on("message_end", async (event) => {
    const message = event?.message;
    if (firstCallRecorded || message?.role !== "assistant") return;
    firstCallRecorded = true;
    const { writeFileSync, renameSync } = await import("node:fs");
    const path = $receipt;
    const error = message.errorMessage ||
      (["error", "aborted"].includes(message.stopReason) ? message.stopReason : "");
    const result = error ? "error: " + String(error).replace(/[\\r\\n]/g, " ") :
      (["stop", "length", "toolUse"].includes(message.stopReason) ? "ok" :
       "error: unrecognized Pi first-call stopReason " + String(message.stopReason));
    writeFileSync(path + ".tmp", result + "\\n", { mode: 0o600 });
    renameSync(path + ".tmp", path);
  });
JS
    ;;
  wait)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || exit 2
    receipt=$2 model=$3 timeout=${4:-${FM_PI_FIRST_CALL_TIMEOUT:-60}}
    case "$timeout" in ''|*[!0-9]*|0) echo 'error: Pi first-call timeout must be positive seconds' >&2; exit 2 ;; esac
    deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if [ -f "$receipt" ]; then
        result=$(cat "$receipt")
        [ "$result" != ok ] || exit 0
        echo "error: Pi secondmate model ${model:-default} first call failed: $result" >&2
        exit 1
      fi
      sleep 0.1
    done
    echo "error: Pi secondmate model ${model:-default} first call was not confirmed within ${timeout}s (receipt=$receipt)" >&2
    exit 1
    ;;
  *) echo 'usage: fm-pi-first-call.sh hook <receipt> | wait <receipt> <model> [seconds]' >&2; exit 2 ;;
esac
