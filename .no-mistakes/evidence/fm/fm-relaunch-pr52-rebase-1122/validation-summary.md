# Targeted relaunch validation

Validated target `28085ad65d07edbbbeb8f473ae7da1f12e222aac` on Linux. No permanent source or test changes.

## Live product checks

The real `bin/fm-control.sh` ran in a disposable, marked FM_HOME and a private Linux PID/mount namespace. Tmux used private sockets and 100x32 panes. The existing Claude login was exposed to the real CLI through a read-only bind mount; all writable Claude configuration and session state stayed in the disposable worktree lab. No production credential was edited.

The independent oracle was the author's recovery contract: recreate an endpoint only after ownership evidence is clear; refuse on surviving task evidence or an unreadable proof; preserve the task's branch, worktree, and unfinished changes.

- An actual recorded tmux endpoint was created and its private server destroyed. `exit` returned `endpoint-gone`; `relaunch` returned success, rebound the same task to `seat:fm-lv829`, and produced a complete transaction journal. Exactly one replacement window existed. The branch, worktree path, and unfinished file contents survived. The authenticated replacement Claude read its operational input and replied `LAB_READY`.
- A separate real tmux server holding the task's window name caused refusal.
- Renaming that foreign window while retaining a pane in the task worktree still caused refusal.
- A renamed foreign window outside the worktree containing a real sleep process with task-labelled argv caused process-evidence refusal. This is explicitly a synthetic task-process input, not a claim that sleep is a Claude agent.
- SIGSTOP on a real foreign tmux server caused a deadline refusal (configured query deadline 2 seconds, observed total command wall time 3 seconds).
- An external `ps` fault-injection executable returned failure to the real running control command. The command refused with `the process table could not be read`.

Every refusal retained a byte-identical task record and created no replacement window on the addressed server. `live-transcript.log` contains the actual CLI results and oracle checks. `replacement-pane.txt`, `reclaimed.meta`, and `relaunch-journal.txt` retain the resulting product surfaces.

## Supporting targeted tests

Executed serially:

```sh
bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 600 \
  tests/fm-control-relaunch.test.sh \
  tests/fm-control.test.sh \
  tests/fm-control-tmux-timeout.test.sh
```

All three files exited 0. The relaunch suite emitted read-only fixture-hook cleanup diagnostics, without failing a behavioral assertion or its runner status.

For regression sensitivity, a temporary selector reused the existing relaunch suite's two process-evidence test functions. Both passed at the submitted implementation. Temporarily removing only the call to task-process evidence caused the renamed-agent regression to fail: it expected refusal but observed a replacement spawn and exit 0. Restoring the implementation made both tests pass again. These hermetic checks support regression quality; they are not counted as live scenarios. See `process-regression-red.log`, `negative-control.patch`, and `process-regression-restored.log`.

Early live-driver attempts encountered disposable fixture provenance/onboarding prompts, a socket-reuse setup race, and a driver-edit parsing error. Those were resolved; the final stable driver exited 0 and includes cleanup confirmation. They were not product failures.

## Completion boundary

All disposable live servers and their children were stopped; the read-only credential mount was unmounted; generated worktree fixtures and the temporary selector were removed. Git status was clean, tracked files matched the submitted head, and no unified-exec sessions remained. No lint, formatting, broad suite, push, PR, or CI phase was run. PR delivery/check status remains owned by the outer executor. This is a CLI/control change, not a visual UI change; evidence is CLI output, persisted transaction state, and the real Claude pane transcript.
