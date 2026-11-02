# Lane-close live validation

Validated head: `b2d28422462a249c257ad645e06d909a9fdab9c7` on Linux.

## Product evidence

- [`live-close.log`](live-close.log): completed execution of [`live-close-driver.sh`](live-close-driver.sh), exit **0**. Sections 1–8 cover default-off behavior; pushed/unpushed cleanup; dirty, paused and working exclusions; refusal retries and bundle reuse; header-valid truncated-pack replacement; changed-HEAD backups; upstream outage/recovery; mirror-only preservation; immediate local-merge teardown; preservation-failure handling; and legacy windowless ownership.
- [`live-tmux.log`](live-tmux.log): completed execution of [`live-tmux-driver.sh`](live-tmux-driver.sh), exit **0**. Actual window inventories show shell-only replacement (`@1` → `@3`), refusal of the running-child window, and selective recorded-window cleanup.

These are **local product** proofs, not hosted GitHub or live-LLM proofs. The drivers execute the real reaper, crew-state reconciliation, preservation library, teardown, merge-local command, Git, Treehouse, tasks-axi and tmux. No fake teardown, crew-state executable, merge proof, or CLI substitutes are used in the live-close driver. Synthetic lane records, aged status/file timestamps and quiet-history inputs are seeded in marked disposable lab homes. Idle lifecycle state is supplied through the real `fm-busy-event.sh arm --state idle --source fm-recovery` interface. Tmux shells use nonzero 120×32 grids on private sockets; no default server is addressed.

The independent preservation oracle is a separate bare clone of the generated bundle, exact saved-HEAD comparison, full strict fsck and reading the committed synthetic payload. Successful lane cleanup is checked by task-record/branch removal, a clean returned slot, and Treehouse JSON reporting one available slot without a lease. Refusal cases check that the lane and its data remain. The corrupted-backup case deliberately retains a header that `git bundle verify` accepts, confirms clone failure, and requires a replacement that restores successfully.

## Focused existing checks

Each completed with exit **0**:

```sh
TMPDIR="$PWD/.validation/tmp" bash tests/fm-lane-reaper.test.sh
TMPDIR="$PWD/.validation/tmp" bash tests/fm-lane-retire.test.sh
TMPDIR="$PWD/.validation/tmp" bash tests/fm-pr-merge.test.sh
TMPDIR="$PWD/.validation/tmp" bash tests/fm-backend-tmux-smoke.test.sh
```

Their retained outputs are `reaper-behavior.log`, `merge-local-behavior.log`, `pr-merge-behavior.log`, and `tmux-smoke.log`. The mocked forge/teardown cases are supplemental behavioral coverage, **not** live hosted-merge evidence. No full suite, linter, formatter or static-analysis command ran.

## Scope and setup qualifications

- A hosted GitHub PR merge was not performed: the supplied ruling reserves that authority to the captain and explicitly accepts behavioral coverage against stubbed merge proof. The focused PR test passed its opt-in, proof-before-teardown and refusal-does-not-fail-merge case. This remains an explicitly untested hosted scenario, not a claim of hosted validation.
- `lsof` was absent on PATH. It was obtained with `apt-get download lsof` inside `.validation/tools` and extracted there using `dpkg-deb -x`; no system package installation occurred.
- Earlier retained `live-close-*-attempt.log` files document resolved fixture setup problems: absent endpoint, untrusted synthetic event source, using an unmanaged Git worktree instead of a real Treehouse slot, an over-specific detached-HEAD expectation, changing origin identity and thereby hiding the original Treehouse pool, and omitting the backlog required for supported legacy windowless cleanup. The final driver corrects those inputs; no product code was changed.
- Watcher-down warnings in the transcript are expected: these disposable homes intentionally have no supervision watcher. They do not prevent the guarded commands from running.
- CLI-only behavior was changed, so CLI transcripts and actual pool/window inventories are the reviewer-visible evidence; no rendered-UI screenshot was needed.

## Cleanup

All private tmux servers and disposable homes were stopped/removed by the drivers. The locally extracted tool, test temp roots and `.validation` directory were removed after all checks exited. Final `git status --short` was empty at the validated head, and the execution session inventory was empty. No source/test changes, production credentials, real fleet state, push, PR, CI, or pipeline-control operations were performed.
