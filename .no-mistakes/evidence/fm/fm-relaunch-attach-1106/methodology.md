# Live validation scope and results

Validated target d3998b4991583625beff6ea1c6c25dbe7837a4e3 against intent, with recorded human decisions respected. No tracked source or test changes remain.

## Real local product execution

`live-setup.sh`, `live-recovery-driver.py`, and `live-attach-driver.py` are retained disposable drivers. They were executed from the gate worktree, using a marked lab home at `$PWD/.l`, synthetic repositories and task records, private tmux socket directory `$PWD/.l/tmux`, and real installed fm scripts, tmux, Git, Treehouse and Claude. No tmux, process-table, Git, or harness stubs were used for these live drivers. The primary terminal grid was 120x35. An additional private `fm-foreign` socket supplied actual processes for duplicate-agent safety checks; its processes were sleep commands, not authenticated agents. The guards' independent contract is to refuse any matching process, not just an authenticated model process.

`live-scenarios.log` shows missing-window recovery, unchanged HEAD/branch/refs/staged and unstaged diffs and file hashes, status-history preservation, same-name/foreign-process refusals through three entrypoints, invalid real JSON trust-store failure with unused-window rollback and successful retry, and recovery after killing/restarting the private tmux server. `live-attach.log` shows a bundle-only commit restored from an invocation-relative bundle path containing spaces, plus nonexistent-head and conflicting-branch refusals.

Local launch success means actual endpoint recreation, record publication and real Claude process launch. It does NOT establish an authenticated worker turn or resumption of a parked approval. The disposable HOME and CLAUDE_CONFIG_DIR reached Claude's real onboarding/login-method chooser (`claude-auth-boundary.txt`). No login was attempted, credentials were not read/copied/changed, and the operator's normal login availability was NOT assessed. An empty isolated configuration is not evidence that the normal login is absent. To prove authenticated continuation, provide authorized lab API access or an expressly authorized normal-login lab workflow compatible with the workspace/trust-store boundary.

## Existing targeted tests (not counted as live scenarios)

- `bash tests/fm-control-relaunch.test.sh`: exit 0; behavioral assertions passed. Its cleanup printed permission errors for generated read-only hook directories. The exact leftover test directory `/tmp/fm-control-relaunch.7IU7h3` was subsequently made writable and removed.
- `bash tests/fm-control.test.sh`: exit 0.
- `bash tests/fm-spawn-pool-base-freshen.test.sh`: exit 1 at `test_concurrent_pool_slot_claims_keep_one_owner`, before reaching attach assertions.
- A temporary diagnostic copy of that same test file, changing only printing of the two spawn outputs, also exited 1 at the same concurrency check (`pool-diagnostic-rerun.log`).
- All five existing attach test functions ran separately through a temporary driver containing the original function definitions and fixtures: exit 0 (`attach-focused-rerun.log`). These tests stub external terminal/provider boundaries; they are not live.
- The concurrency function alone passed once (`race-diagnostic.log`) then failed on the first repeat (`race-repeat-1.log`; the planned loop stopped at that failure).
- Repeating the concurrency function with only `fm-spawn.sh` replaced by its exact base-commit contents passed once then failed (`race-base-2.log`; loop stopped). Shared helpers remained at target HEAD. This demonstrates the failure also with the base spawn implementation, not a complete base-repository validation. No repair to unrelated pool-allocation policy was attempted.

The repeated failure leaves a slot-owner claim after both spawn invocations exit 1. One invocation reports that the Treehouse project lock is no longer held and leaves its claim; the other refuses because the slot belongs to that task. This intermittent check prevents reporting a green test phase despite the passing local recovery/attach scenarios.

## Cleanup

Private fm-lab and fm-foreign servers were stopped, all executed test children were awaited, and unified-exec reported zero live sessions. Disposable lab home, repositories, pool, temporary test copies, baseline executable, and drivers were removed from the worktree. Final `git status --short` and `git diff --exit-code` were clean. No linters, formatters, full repository suite, pipeline-control commands, push, PR, or CI phases were run. This is a CLI/lifecycle change, not a UI-layout change; evidence consists of actual CLI/state transcripts rather than screenshots.
