# Teardown live validation

Target: `b0e6d28a2992df86bc85f53b819c5b1141887715`

The driver executed the repository's actual `bin/fm-teardown.sh`, the installed real Treehouse CLI, real Git repositories and a private real tmux server. Each case used a marked disposable Firstmate home and a local bare origin, entirely inside the gate worktree. No operator pool, credentials, default tmux server, or real canary data was used. All disposable live fixtures and the private tmux server were stopped and removed by the driver's `finally` block.

## Results

| User action / boundary | Live evidence |
|---|---|
| Tear down a clean, pushed old-pool ship after an `insteadOf` rewrite, without `--force` | Current-pool `treehouse status --json` returned `[]`; ordinary teardown found the original pool, verified backup bundles, returned the real lease, removed the task record, and left a clean slot. |
| Tear down a clean current-pool ship | Ordinary teardown also returned the current-pool lease and retired its record. |
| Return and re-lease the old slot after teardown's initial state read | A transparent jq forwarding shim paused after the real initial state read. A second real Treehouse CLI returned the original lease and acquired the identical slot with a new lease and branch. Resumed teardown refused with `lease changed`; the new branch, HEAD, hooks, and lease remained unchanged. |
| Attempt teardown with modified tracked files or new untracked work | Both current and old pool cases refused, with and without `--force`. File contents, checked-out branch, hooks, lease, and task record were preserved. |
| Place arbitrary untracked work in `.claude/` | Old-pool teardown refused, forced and unforced, preserving user content byte-for-byte. The clean cases separately prove the generated `settings.local.json` hook does not block ordinary cleanup. |
| Attempt teardown with committed work on no remote and not landed | Both pools refused, forced and unforced; the unlanded HEAD, branch, hooks, record, and lease survived. |
| Force cleanup with a live non-tmux worker and no `lsof` | Both pools refused specifically because writer shutdown could not be verified. The real worker was still running, and the branch, hooks, lease, and record were untouched. The driver then terminated and awaited the worker. |

These are 19 disposable live cases, grouped above by acceptance behavior. `live-teardown.log` contains commands, actual CLI output, persisted pool state, bundle verification output, and postcondition checks. `live-results.json` lists the completed cases; `live-teardown.py` is the reproducible driver.

The oracle is the supplied user intent: lease reassignment must preserve the new holder, arbitrary uncommitted data must not be discarded, unlanded commits must refuse, and a clean pushed old-pool ship must return through the ordinary entrypoint. The checks would reject successful destructive cleanup, altered user bytes, changed new-holder state, or a stranded clean lease.

## Scope limits

The named operator canary `dos-leaf-10-753-41-r6-wonder-1302` was not driven: it lives outside this worktree, and this run explicitly forbids touching operator fleet state. The same origin-rewrite/old-pool behavior was reproduced with a real disposable pool instead. Verification of the exact operator lane requires a separately authorized operator-side invocation after confirming its work is safe.

No screenshots were captured because the changed surface is a shell CLI, not rendered UI. Real CLI transcripts and persisted state are the product artifacts. Supplemental repository tests use boundary fakes and are not counted as live product evidence.

## Supplemental test environment

The focused lease regression file completed successfully using worktree-local temporary fixtures. Initial endpoint-file attempts with the same temporary root failed because fixtures intentionally lacking a repository discovered the enclosing gate repository, and a secondmate-removal guard correctly rejected a fixture inside the source repository. A Git ceiling resolved discovery but not the secondmate guard. Separately, the host lacked `lsof`, so the fallback killed an endpoint that the close-failure test intended to keep alive. The endpoint file was therefore rerun with its normal `/tmp` test-toolchain temporary root and a locally downloaded/extracted `lsof` package on PATH; no package was installed system-wide. That final endpoint-file run completed with exit 0, as did the lease regression file. Temporary diagnostic edits were reverted. Failed-run private tmux servers were identified by their exact fixture working directories and stopped; unrelated servers were not touched. The extracted package and all worktree temporary files were removed. Final Git status was clean, the live private socket was absent, and the execution harness reported no remaining sessions.
