# Relaunch / preserved-head attach: local live validation

Target: `6556ceae506fae2fe713ca0ad549431088b3a75e` (base `86fc36635b5b7a0582b2a1bb20406ecf2125c7ee`).

## Result

All ten local lifecycle scenarios passed. Authenticated worker continuation remains untested, as explicitly deferred by supervisor ruling 003. This is not evidence that a parked production run resumed or that an authenticated model completed work.

Real components: Linux, tmux, Treehouse, Git, Firstmate control/spawn entrypoints, and Codex CLI 0.166.0. Codex genuinely started in non-zero-sized (120 × 40) tmux panes and displayed its sign-in screen. Claude CLI 2.1.316 was installed; its real workspace-trust preflight was exercised with deliberately invalid JSON in the disposable user home. No substitute tmux, process table, Git, Treehouse, harness executable, or credentials were used for these live scenarios.

All fixtures lived in the run worktree's disposable `.v` marked FM_HOME. HOME, CODEX_HOME, CLAUDE_CONFIG_DIR, TREEHOUSE_ROOT, and the private tmux socket directory were isolated. No default tmux server, operator fleet home, production credentials, or operator project checkout was used. There was intentionally no live watcher in this lab; its emitted supervision warnings were not treated as worker failures.

## Scenarios and evidence

| Scenario | Observable oracle | Evidence |
| --- | --- | --- |
| Recover a recorded task whose tmux session disappeared | Relaunch succeeds, rebinds the existing task, preserves exact branch, commit and dirty-file checksum, and starts real Codex | `recovery.log`, `recovery-meta.txt`, `recovery-pane.txt`, `preserved-state.txt` |
| Exit a proven-gone endpoint | Reports `endpoint-gone`; metadata and brief checksums unchanged; no endpoint created | `gone-exit.log` |
| Refuse a surviving owner on a different private socket | Real process in the worktree blocks exit and relaunch; separately, real task-token argv owner blocks relaunch; record and instructions unchanged | `foreign-owner.log` |
| Refuse a same-name window in another session | Missing recorded session is insufficient when addressed server has the same task-window label; no metadata or brief mutation | `name-collision.log` |
| Fail closed for an unreadable non-allowlisted process | A real Python process made undumpable with Linux `prctl(PR_SET_DUMPABLE, 0)` prevents recovery; after it is stopped recovery can proceed. Real host `(sd-pam)` and `gpg-agent` exceptions are named in successful recovery output | `unreadable-process.log`, `recovery.log`, `retry-cleanup.log` |
| Retry a recorded-task recovery after late trust failure | Invalid disposable Claude trust JSON refuses before publication; unused replacement is removed and original metadata preserved; retry launches Codex | `retry-cleanup.log`, `retry-meta.txt` |
| Attach a recordless task from a relative bundle path containing spaces | Real Treehouse acquires a worktree; branch and HEAD equal the independently minted unpublished commit; restored file content matches; real Codex starts | `bundle-attach.log`, `bundle-meta.txt`, `bundle-pane.txt` |
| Attach to an existing matching branch in an originless project | Existing branch checked out at requested commit without changing any branch ref | `attach-existing.log` |
| Reject invalid, conflicting, or unverifiable attach inputs | Head absent from bundle, missing branch value, local head conflict, remote head conflict beyond a main-only fetch refspec, and unreachable configured origin all refuse without task record, endpoint, or changed local branch refs | `attach-refusals.log` |
| Restore a fresh attach after late preflight failure, then retry | Invalid trust JSON restores original detached HEAD and removes only the newly created branch, leaves no task record; same pool slot successfully attaches on retry | `attach-rollback.log` |

The independent oracles are the accepted preservation and no-duplicate-worker contracts, input commit IDs minted before invocation, known synthetic file contents and checksums, and before/after Git refs, metadata and endpoint inventories. The checks would reject a reset to the base, a duplicate endpoint, a moved conflicting branch, or a leaked replacement preventing retry. Reading generated metadata is checking its persisted public contract, not examining implementation source as a proxy for behavior.

## Executions

- `bash tests/fm-control-relaunch.test.sh`: exit 0. This is supplemental stubbed regression coverage, not live evidence. Raw log: `relaunch-targeted-tests.log`. Its cleanup printed permission errors for sealed hook directories; their permissions were confirmed and the exact temporary test tree was subsequently removed.
- Final clean-fixture chain: `bash .live-driver.sh && sleep 1 && bash .live-more.sh && sleep 1 && bash .live-attach-guards.sh`: exit 0. Retained copies are `live-recovery-driver.sh`, `live-guards-and-bundle-driver.sh`, and `live-attach-guards-driver.sh`; command/result transcript is `live-driver-run.log`. Run from this repository root with an absent `.v` directory if reproducing.
- Earlier driver setup issues were corrected before that final successful chain: the initial foreign-cwd fixture also named the worktree in the tmux server argv; a cleanup command assumed a failed fresh spawn's window still existed even though product cleanup had removed it; and immediate reuse of a just-killed private socket needed a short shutdown interval. None was counted as a product failure or as a scenario pass before the corrected execution.
- Captured real pane text, CLI responses, generated task metadata, commit IDs, file checksums, and Git status. No screenshot was needed: this change alters CLI lifecycle behavior, not visual layout or copy placement.
- Private `fm-lab` and `fm-other` servers were confirmed stopped; owned process inspection found no lab processes, and unified-exec reported zero live sessions. Disposable lab, runtime scratch directories, drivers, and test residue were removed. `git status --short` was empty. No project source or tests were changed.

No full repository suite, lint/format/static checks, Herdr lifecycle, push, PR, or CI phase was run. The previously declined pool-concurrency investigation was not reopened.

## Deferred authenticated scenario

The actual Codex process in the isolated home reaches sign-in. No sign-in, credential copying, normal-account availability probe, or account mutation was attempted. Ruling 003 assigns authenticated continuation to the real post-merge attaches; this gate's passing local lifecycle result does not supersede that remaining operational check. To exercise it before then would require explicitly authorized disposable authenticated CLI access and authority for the continuation itself. An isolated empty account directory is not evidence that the machine's normal login is unavailable.
