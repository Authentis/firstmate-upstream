#!/usr/bin/env bash
# Print a GitHub pull request's state through the shared read throttle.
#
# Usage: fm-pr-read.sh <owner> <repo> <number>
#   Prints "state=<STATE>" and "merged=<true|false>", the answer cached for up
#   to FM_PR_READ_TTL seconds (default 300) and shared with every other caller
#   on the machine; exits 1 with no output when no answer is available, which
#   includes a rate-limit backoff with nothing cached. The throttle's contract
#   lives in bin/fm-pr-lib.sh. Scripts that poll a PR's state on a timer should
#   call this instead of `gh pr view`.
set -u
[ "$#" -eq 3 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
fm_pr_github_read_record "$1" "$2" "$3" || exit 1
printf 'state=%s\nmerged=%s\n' "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
