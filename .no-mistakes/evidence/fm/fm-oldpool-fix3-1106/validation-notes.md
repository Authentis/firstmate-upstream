# Teardown live-validation evidence

Target: `04901a93d32e38adb3bfadad0f1cc582af400b6b`.

## Scope and independent oracle

The acceptance oracle is the supplied author intent: an ordinary clean, pushed old-pool lane must tear down after an origin URL rewrite; a stale lease must not mutate another holder; tracked, untracked, arbitrary `.claude/`, and unpushed work must not be discarded, including under `--force`. The recorded follow-up decision also requires verified writer shutdown before forced ship cleanup.

The driver executes the actual `bin/fm-teardown.sh`, installed Treehouse CLI, Git and tmux. No product executable is mocked. Disposable bare remotes, Git configuration, marked FM_HOME directories, pool state, and private tmux socket are confined to the worktree. The missing host `lsof` was obtained with `apt download lsof` and extracted with `dpkg-deb -x` inside the worktree; nothing was installed system-wide. The missing-lsof cases intentionally omit that extracted directory from PATH.

This is local synthetic-data validation, not validation against the operator's real fleet. The production canary `dos-leaf-10-753-41-r6-wonder-1302` and `~/.treehouse/decision-os-143fee/137/decision-os` were not accessed or changed. The old-pool scenarios reproduce its relevant URL-rewrite/recorded-lease mechanics without bypass flags; FM_HOME and HOME select disposable isolation, not a workaround in the teardown logic.

## Final live checks

- Current and old-pool clean ships, ordinary and forced teardown: record removed, slot available and clean. Old-pool backup bundles verified with `git bundle verify`; the generated `.claude/settings.local.json` hook is accepted and removed.
- Current and old pools, tracked modifications and untracked files, ordinary and forced teardown: refusal retains file bytes, branch, generated hook, lease, and record.
- Arbitrary `.claude/precious-work.md`: old-pool ordinary/forced and current-pool forced teardown refuse with contents preserved. Ordinary current-pool `.claude/` policy is outside the changed contract and was not expanded.
- Current and old pools, commits present on no remote, ordinary and forced teardown: refusal keeps HEAD, branch, files and record.
- Current and old pools without lsof, with a real non-tmux worker: forced ship teardown refuses before branch/file cleanup; the worker remains alive until driver cleanup.
- Current and old pools with real lsof, with a worker that writes `late-work.txt` in its SIGTERM handler: teardown stops the worker, rechecks work, refuses and preserves the late file and branch/lease/record.
- Old-pool stale-lease race: while teardown awaits the allocator's actual flock, the driver pauses its Perl flock-holder child, then uses real Treehouse return/get to re-lease the same slot to `fm/new-holder`. Resuming teardown yields a changed-lease refusal. The new holder's branch, hook, work file, live non-tmux worker and lease remain untouched.

The 24 parameterized local cases are recorded in `live-results.json`. `product-transcripts.log` combines their final CLI transcripts; `observed-state.json` captures actual post-run Git status, branches, pool state, record presence, and preserved file contents before fixture deletion. `live-driver.py` contains the executable driver and assertions.

## Setup corrections (not product failures)

The initial private socket pathname exceeded the Unix socket length limit; moving it to a short pathname within the same worktree resolved that setup issue. Treehouse omits `leased` after successful return, so the driver was corrected to treat absence as false. The stale-race driver recreates the generated hook directory after real Treehouse get cleans it. All affected cases were re-driven successfully; no product or repository test changes were made.

The first endpoint-safety test invocation placed its normally non-Git scratch directories below the gate worktree, allowing Git to discover the parent repository. Its scratch clean therefore refused rather than treating the fixture as a non-Git directory (`endpoint-failure-stderr.log`). A Git-ceiling rerun fixed that issue, but the missing host lsof activated process-group fallback and removed an endpoint before the close-failure fixture expected it to close. Providing the real workspace-local lsof fixed that fixture prerequisite. The remaining secondmate fixture then correctly refused because its home was physically inside the firstmate repository (`child.err`), so relocating only the test runner's incidental temporary data to its normal default temp location is necessary. The final full-file invocation uses the normal toolchain temp location and the real local lsof; no test or product source was edited. Three private tmux servers left by failed test fixtures were stopped by exact PID after verifying their cwd was in this run's deleted disposable fixture directories (`fixture-cleanup.json`); no default tmux server was addressed.

## Targeted automated checks

- `TMPDIR="$PWD/.live-validation/tmp" bash tests/fm-treehouse-lease.test.sh`: exit 0. This suite uses boundary fakes and is supporting regression evidence, not the basis for marking the live cases live.
- `env -u TMPDIR PATH="$PWD/.live-validation/tools/extracted/usr/bin:$PATH" bash tests/fm-teardown-endpoint-safety.test.sh`: exit 0, including the changed shared-project-lock contention case. Earlier setup-only failures and the focused secondmate reproduction are retained in the evidence directory.

No full suite, linter, formatter, static analysis, pipeline-control, push, PR or CI phase was invoked. No UI-facing changes were made, so CLI transcripts and persisted-state evidence are the relevant product artifacts.

## Final cleanup

All disposable worktree fixtures, downloaded/extracted lsof files, temporary scripts and the private socket were removed after the required checks completed. `git status --short` is empty and HEAD remains `04901a93d32e38adb3bfadad0f1cc582af400b6b`. No unified-exec sessions remain. A final process audit found no fixture tmux servers started during this run; older unrelated fixture processes were not touched. See `final-audit.json`.
