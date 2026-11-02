# Finished-lane live validation

## Scope and oracle

The oracle is the author's acceptance contract and the recorded supervisor decisions: closing is off by default, ordinary teardown must never force discarded work, unpublished commits must be pushed or independently restorable, unsuccessful closes must remain retryable, and cleanup must respect recorded endpoint ownership. Expected results were checked using real Git remote refs, independent bare clones with strict fsck, archive counts, retained/deleted task metadata, returned Treehouse slots, preserved dirty file bytes, and actual private tmux window inventories—not implementation source matching.

## Runtime setup

`live-close.sh` was executed from the gate worktree on Linux. All mutable homes, repositories, bare remotes, Treehouse pools, private tmux socket and tools lived under `.live-validation/` in that worktree. Homes were minted with the real `bin/fm-lab-home.sh create`. The actual installed `treehouse get --lease --no-fetch` allocated each lane; real `fm-teardown.sh` returned its slot. No teardown replacement or gate bypass was used.

The lab lanes used synthetic done/paused declarations and synthetic idle recovery events submitted through the actual `bin/fm-busy-event.sh arm` interface. No Claude or other LLM CLI was impersonated or launched; these scenarios validate the local reaper/merge/teardown product, not harness generation or login. CPU probes used real lsof; because lsof was not on PATH, `apt-get download lsof` downloaded its package into `.live-validation/tools/`, `dpkg-deb -x` extracted it there, and PATH was prepended with that local binary. No package was installed system-wide. The reaper clock and idle/quiet intervals were shortened for the disposable inputs; the guard case separately exercised the default age/quiet thresholds.

## Evidence

- `live-close.log`: final complete successful run of all eight CLI scenario groups, with actual product responses, refused ordinary teardowns, corrupt-pack rejection, standalone restorations, local fast-forward proof, teardown output, and private tmux inventories.
- `live-close.sh`: exact evidence driver and assertions. It cleans up homes and its private tmux server on exit.
- `tmux-smoke.log`: existing real-private-tmux backend smoke test. It exercises shell-only duplicate replacement and refusal of synthetic live/child-process windows. Its process named claude is explicitly a copied sleep binary from the existing test, not a real Claude login or harness proof.
- `reaper-tests.log`, `retire-merge-tests.log`, `pr-merge-tests.log`: focused behavioral test outputs. These include external-boundary stubs and are supplementary, not hosted-forge live evidence.

Initial setup attempts are retained separately as `live-setup-attempt*.log`. They exposed insufficient fixture setup (missing endpoint, missing semantic idle event, same-second timestamp precision, an unmanaged Git worktree, and missing legacy backlog), plus an incorrect missing-window assertion: tmux display-message can fall back to the current window. The final driver uses actual window inventory for absence. No product changes were needed.

## Completed checks

All commands were awaited and exited 0:

- `bash tests/fm-lane-reaper.test.sh`
- `bash tests/fm-lane-retire.test.sh`
- `bash tests/fm-pr-merge.test.sh`
- `bash tests/fm-backend-tmux-smoke.test.sh`
- `bash ~/.no-mistakes/evidence/01M6EWMZZ12NK7JY1EPCDF1RXK/live-close.sh` (final complete run)

Final `git status --short` was empty, `list_sessions` reported zero live command sessions, the private lab tmux server reported no server running, and lsof reported no process with a cwd under the disposable lab directory. No full repository suite, linter, formatter, push, PR mutation, or CI phase was run.

## Approved limitation

A real hosted GitHub PR merge was not attempted: the recorded captain ruling explicitly withholds merge authority from this step and accepts stubbed hosted merge proof. The real local-merge counterpart was driven. To drive the hosted scenario in a future authorized run, the captain must supply an approved disposable hosted PR and explicit merge authority; credentials alone do not supply that authority.

## Presentation and cleanup

This change manages CLI lifecycle and tmux window ownership; it changes no rendered UI or copy placement. CLI transcripts and exact before/after window inventories are the reviewer-visible evidence; no screenshot was captured. All lab homes and the private tmux server were torn down, and the downloaded/extracted tooling was removed from the worktree after validation.
