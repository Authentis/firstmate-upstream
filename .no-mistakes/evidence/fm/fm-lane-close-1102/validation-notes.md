# Finished-lane local runtime validation

## Scope and oracle

The independent oracle is the supplied author intent and recorded R1–R5 decisions: live closing requires the home file opt-in; dirty or unlanded work must not be discarded; every unpushed HEAD must survive in a real remote or independently restorable bundle before ordinary teardown; unsuccessful closes retry; repeated same-HEAD retries must not multiply valid backups; header-valid corrupt payloads must not be accepted.

`live-close.log` is an actual execution transcript from `live-close-driver.sh` (exit 0), launched from this gate worktree. The driver built disposable marked lab homes, local bare remotes, real Treehouse leased worktrees, and private tmux terminal endpoints. It invoked the real crew-state reader, semantic busy-event writer, reaper, local merge command, and teardown. No Git, teardown, crew-state, CPU-probe, or forge command was replaced in these live checks. The missing `lsof` dependency was downloaded as an Ubuntu package and unpacked only inside the disposable worktree test directory; no system package was installed.

Lane metadata, status declarations, and idle semantic events were synthetic inputs. The terminal endpoint command was `sleep`, not a substitute pretending to be an AI CLI. These checks validate local lane lifecycle behavior with synthetic completed-lane state; they do **not** claim an LLM completed a task, validate an AI harness/login, run Herdr, or prove a hosted forge merge. Real `lsof`, Git, tmux, and Treehouse executed against those isolated local inputs.

## Observable checks

- Without the close opt-in: dry-run names the lane, metadata remains, no preservation bundle is written. `live-boundaries.log` also shows that the removed environment activation does not close anything and the removed CLI flag returns usage/exit 2. That separate driver exited 0.
- With opt-in: ordinary reaper teardown retires the task. A standalone clone restores the exact original HEAD and committed `payload.txt`.
- A dirty lane keeps its task record and uncommitted file contents. The boundary driver also checks that an opted-in paused task is not closed and a missing worktree leaves its record and relocated data intact.
- Repeated unlanded-work teardown refusals keep the task and only one backup.
- An archive deliberately truncated after its valid header still passes Git's header-level bundle verification but fails a real clone. A subsequent scan creates a restorable replacement, and another retry reuses it.
- A local bare remote's rejecting pre-receive hook causes actual pushes to fail. The record and bundle remain; removing that hook allows an ordinary scan with the same done status to push and close.
- A `no-mistakes` mirror containing HEAD does not suppress an independent backup.
- Local fast-forward merge runs actual preservation and teardown immediately when opted in; with closing off, it advances main but leaves the task open.
- Already-pushed work closes without a redundant bundle.
- Blocked backup storage after a successful local merge keeps task, HEAD, and endpoint.
- Dirty-lane teardown refusal does not turn a successful local merge into failure or discard uncommitted edits.

## Supplemental targeted tests

Separately executed, one file at a time: `tests/fm-lane-reaper.test.sh`, `tests/fm-lane-retire.test.sh`, and `tests/fm-pr-merge.test.sh`. All three exited 0 and their logs are retained separately. These use test seams/stubbed boundaries and are supplemental regression checks, **not** live forge or lifecycle proof.

## Remaining boundary

No authorized disposable hosted GitHub repository/PR was supplied. A real `gh pr view` invocation with isolated empty configuration and tokens removed exited 4 asking for authentication (`hosted-pr-blocker.log`). This is not a claim that the operator's normal login is unavailable: the validation deliberately did not inspect or use real operator configuration, credentials, or data. Local Git remotes cannot supply GitHub's hosted PR/queue proof; the existing forge-stub tests do not count as that proof. To validate that path live, provide an authorized disposable GitHub repository/PR plus permission and scoped credentials to push and merge it.

All live fixture homes, worktrees, sockets, servers, local packages, and transient drivers were removed from the worktree after execution. Evidence remains here only.
