# Router v3.1 planning contract — chief 4900

`lane-refill-v2.sh` invokes `router-planning.sh` before priority dispatch. Below 25 clean dispatchable leaves it opens a planning cycle with a target of 50. Passes run serially and inspect the previous pass's landed yield. At most three distinct, disjoint authority partitions are used per cycle; only open, unassigned unspecced or split-after rows qualify. Three exhausted passes below 25 produce `data/planning-chief-alert.txt`; the chief must inspect their yields before resetting the cycle.

## Bundled runner and model chain

The real runner is `data/bin/fm-planning-runner.sh`, backed by the adjacent `router_planning_runner_v31.py`. It is available on netcup now in this build. Bundle staging copies both files beside the other router scripts, and the trigger resolves the adapter from its pinned script directory. No live installation or paid probe was performed for this fix.

Planning tries Sol high (`pi`, `openai-codex/gpt-6.1-sol`) on netcup, then Muse Wonder on bosgame, then Kimi K3 (`pi`, `kimi-code/k3`) on netcup. Muse never runs on netcup. Grok and Claude are never planning fallbacks. The runner implements the requested pass-1 mechanism using the installed Firstmate Pi template: Pi's `openai-codex` provider, Sol model, high thinking, a fresh session, and a scoped planning brief. Existing admission, credential restrictions, shutdown and host capacity checks still apply.

`--capabilities` describes availability and budget enforcement without launching a model. `--check` checks the requested host/model tuple, binary and budget without a paid call. `--start` launches one scoped planning pass asynchronously with `--home`, `--task`, `--project`, `--host`, `--request`, `--max-tokens 300000`, `--incarnation`, and the exact admitted harness/model/effort. A fresh endpoint and live process evidence are required for local launch confirmation. Local Pi runs in a disposable task worktree detached from cached `origin/main`, with its own isolated tracker marker. Muse requests use the existing forced-command `bosgame-sm` message transport; arbitrary remote shell execution is not supported.

Every unavailable runner, missing model binary, quota stop, or exhausted token budget writes `state/planning-blocked.alert` with a timestamp and reason and is logged on each trigger pass. An unavailable model advances to the next eligible model in the chain. A shared daily budget stop alerts and prevents spending through a different provider. An ambiguous launch retains its reservation to avoid a duplicate billable pass.

## Budget enforcement and completion

The pass budget is 300000 tokens, and the daily budget is 1000000 tokens across the planning chain. The runner reserves budget under a file lock before launch and persists post-hoc usage. Pi has no native hard token-budget flag in the inspected local CLI, so its pass uses a wall-clock bound plus provider usage accounting; these are best-effort limits, not a provider-enforced hard ceiling. Unknown usage retains the full pass reservation. Actual overruns are recorded without clamping, alert, and refuse subsequent passes. A new pass must have enough remaining daily room for its reservation. Both runner accounting and the controller's pending-pass accounting survive restarts.

The request and `partition`/`claim-rows` files remain beside each task. Planning is tracker-only; the brief scopes authority rows and disallows implementation, child model calls, and unrelated changes. Provider usage comes from CLI/session records rather than model prose. Successful usage is retained in `planning-usage.json`; cached-main reconciliation looks for an exact `Planning-task: TASK` commit trailer touching the tracker. Process completion alone does not prove landed yield. A definite exited failure is recorded in `planning-failure.json`, keeps its usage charged, releases the yield barrier, and advances the next attempt to the following model.

The result format is:

```json
{"v":1,"task":"TASK","incarnation":"ADMITTED_INCARNATION","model":"openai-codex/gpt-6.1-sol","tokens":12000,"token_cap":300000,"landed_commit":"40_OR_64_HEX_COMMIT"}
```

A completion requires usage accounting within the pass budget and a tracker commit strictly after the recorded baseline, reachable from locally cached `origin/main`. Unknown usage is conservatively charged at the full 300k reservation. The controller verifies ancestry and computes newly dispatchable, scoped leaves changed by that landing, excluding the starting supply. It does not fetch the network. Usage may be accounted before landing while the yield barrier remains pending. Valid completions log task, partition, binding, model, host, tokens, landed yield, and commit in `data/planning-yields-v31.jsonl`. A missing or invalid landing retains the pending pass for reconciliation. An ambiguous remote transport writes a task-bound `planning-blocked.json`; every controller tick repeats its alert and retains the reservation until reconciliation proves the remote outcome.

## Offline validation and rollback

Run `run-router-v31-tests.py` with fixture homes and stub model/transport executables. The planning shell and runner suites cover present/missing runners, fallback order and host placement, budget alerts, provider failures and metering. Bundle tests verify the runner ships beside the scripts. This build authorizes no live install or model probe.

For rollback, pause/drain producers and archive the adapter while retaining planning ledgers and task evidence. A missing adapter alerts explicitly on every trigger pass and attempts the remaining configured chain; it does not disappear into a silent receipt or hard-cap WAIT. Reconcile any retained process before changing its reservation.
