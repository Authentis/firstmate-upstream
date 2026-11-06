# Teardown live validation

Head: bf0c8c706256aefca01af57d2bc6526234abc7f0

Executed the real `bin/fm-teardown.sh`, installed Treehouse, Git, and tmux on Linux. Each case used a marked disposable FM_HOME, repository-local Git remotes/config, an isolated Treehouse root, and a private tmux server. No operator fleet/canary state or production credentials were used. The author intent is the independent oracle: stale leases must refuse before mutation, and user work must survive with and without --force.

## Results

- **Old pool after origin rewrite:** allocated a real Treehouse lease, applied a fixture-local Git insteadOf rewrite, then ran ordinary teardown without --force or a teardown bypass. It returned the slot, removed the task record, and produced verified complete Git bundles. See `old-happy-3.log` and `happy-persisted-state.log`.
- **User files survive:** both old and current pools refused tracked edits, ordinary untracked files and `.claude/research.md`, with and without --force. Assertions compared file bytes, HEAD identity and retained task metadata. See `matrix-verified.log`. Current-pool unforced `.claude` refusal occurs at Treehouse return after detachment; it still preserves the user file and commit. This scenario does not assert an unchanged branch name on that existing path.
- **Unpushed commits survive:** both pools refused a new unpushed commit with and without --force, preserving HEAD and task metadata. See the same matrix transcript.
- **Stale lease under contention:** a real flock held the old pool lock while teardown read its initial lease. Under that lock, a synthetic competing lease identity was persisted in the real pool state; releasing the lock caused teardown to refuse its reconfirmation. Branch, generated hooks and task metadata survived. This drives real teardown locking but is not a claim that a concurrent Treehouse allocator was executed. See `old-lock-race.log`.
- **Missing lsof:** this host actually lacks lsof. With a real non-tmux process holding the slot cwd, forced cleanup refused in old and current pools before branch, hook or task-record deletion. The worker remained alive until explicitly stopped by the driver. See `writer-current.log` and `writer-old.log`.

## Focused regression check

`TMPDIR="$PWD/.test-live-teardown/tmp" bash tests/fm-treehouse-lease.test.sh` exited 0. This is supplementary regression evidence, not a live Treehouse proof: that test uses external-boundary fakes. It covers late writes, stale lease races, lock waiting, forced retries and missing-lsof fallback behavior.

Initial driver setup used a missing endpoint/socket and could not complete endpoint cleanup. Replaced it with real isolated tmux windows and re-ran successfully. An initially overstrict matrix assertion expected branch preservation on the existing current-pool unforced `.claude` return-refusal path; corrected it to the required user-content/HEAD/metadata preservation contract and re-ran the complete matrix successfully. No product changes were made.

Retained the four driver scripts for reproducibility. All started checks finished, private tmux servers and worker processes were stopped, temporary labs were removed, and git status was clean. No visual artifact is needed: the changed product surface is a shell CLI; transcripts and persisted state are the reviewer-visible evidence. The operator's named historical canary was not touched; the old-pool workflow was reproduced with disposable local repositories instead.
