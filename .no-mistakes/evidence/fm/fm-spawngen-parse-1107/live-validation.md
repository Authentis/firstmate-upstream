# Local PR-poll metadata validation

Oracle: the author's acceptance contract requires control metadata and `spawn_gen=3` after `pr_head` to be accepted, but unknown trailing keys and a second `pr=` to remain rejected.

The driver executed the unmodified `bin/fm-watch.sh` from the target worktree in a disposable marked FM_HOME inside that worktree. Poll artifacts were prepared and published by the actual `bin/fm-pr-lib.sh` against a control record, then the same record was updated in place to each scenario's metadata. No product functions or backends were mocked. Each watcher was awaited; quiet successful cycles were stopped with SIGTERM after `.last-check` appeared. The lab was removed afterward.

| Metadata tail | Actual watcher behavior |
| --- | --- |
| Ends at `pr_head` | Completed check cycle, remained running, stdout and stderr empty; no rejection wake |
| `spawn_gen=3` after `pr_head` | Completed check cycle, remained running, stdout and stderr empty; no rejection wake |
| `spawn_gen=3`, then `evil=1` | Exited 0 after emitting `check: rejected unauthenticated state checks: …/state/task-a.check.sh` |
| `spawn_gen=3`, then another identical `pr=` | Exited 0 after emitting the same rejection wake |

`local-watch-results.json` contains the input metadata, watcher observations, exit statuses, and exact stdout/stderr. Individual `.meta`, `.watch.stdout`, `.watch.stderr`, and wake-queue files preserve the inputs and product outputs.

Scope: these are local synthetic GitLab poll-authorization scenarios, not forge/tenant merge validation. The synthetic URL uses `gitlab.example.invalid`; glab is absent, so an authenticated poll remains silent without reading any forge or operator account. A nonexistent lab-local tmux socket prevents access to real fleet panes. This isolates exactly the metadata-authentication boundary changed by this patch.

Separately, `parser-regression.sh` executed the base and target product parsers against identical GitHub metadata with `spawn_gen=3` after `pr_head`. The base parser returned 1 and the target parser returned 0, reproducing the reported regression without changing tracked source files.

No rendered UI is changed. PR 58 delivery and its required signature check belong to the outer pipeline's delivery/CI phases and were not executed in this test phase.
