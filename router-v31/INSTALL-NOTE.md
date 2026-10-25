# Router v3.1 install note (netcup)

Source: this branch's `router-v31/` tree. It holds the 49 files changed or added
relative to the live home `/home/holu/fm-secondmate-upstream-20260907`, plus
`data/bin/test_router_v31_durable_accept.py`. Install nothing from the branch
by hand; use the bundle tooling below.

## What changed since netcup's final diff (11:20)

- `bosgame-leaf-send.sh`: live durable-record acceptance (netcup 11:23 port of live lines 119/165) kept; the ack line is now anchored `sent <id>`.
- `cloud-pickup-send.sh`, `bosgame-plan-send.sh`: same durable-record acceptance (`delivered.rec`, no resend), anchored `sent <id>` ack; the plan sender also dedupes on `delivered.rec`.
- No `reconcile-required.txt` is written anywhere; no sender reads another tool's output for a verdict beyond its own transport reply (one anchored `durably recorded at .../N.msg` match, documented in `router-remote-restore.md`).
- `lane-refill-v2.sh`: the caller counts a bosgame send as delivered only on exit 0 AND the sender's anchored `sent`/`replied` line (a `router-off` exit 0 is no longer counted as a start).
- Durable-record match narrowed to a line containing `doorbell refused ... durably recorded at .../N.msg`; the leaf sender re-checks `delivered.rec` under its lock like the other two.
- `test_router_v31_durable_accept.py` (10 tests) and two planning-refill end-to-end cases in `test_router_v31_planning_shell.py`.

## Target files

All 49 paths under `config/` and `data/bin/` in this tree (list: `git ls-files router-v31`). The planning runner pair `data/bin/fm-planning-runner.sh` + `data/bin/router_planning_runner_v31.py` must ship together; the bundle ENTRIES already include them.

## Order (backup-first)

1. Run the full suite on netcup against the staged tree: `python3 data/bin/run-router-v31-tests.py` (macOS cannot run it: no `flock`/`timeout`, GNU tools; see receipts).
2. Paid liveness pass of the bundled runner BEFORE install (see below).
3. `FM_HOME=<live home> ROUTER_PRODUCER_CONTROL=<control> data/bin/router-install.sh v3.1 <abs source>`; it backs up the existing scripts to `*.bak-*` and writes a manifest.
4. Verify: confirm the next refill log line reads `PLANNING verified` (not planning-deferred) when ready supply < 25 and slots are free.

## Which runner (answered)

Planning runs under the bundled `fm-planning-runner.sh`: Sol high on netcup, then Muse Wonder on bosgame, then Kimi K3 on netcup. Budgets: 300k tokens/pass, 1M/day (wall-clock plus durable reservation accounting; the 300k is best effort, not provider-enforced). When no runner or binary is usable, or the chain is exhausted, the tick appends `state/planning-blocked.alert` (timestamp, reason, host, model) and logs `PLANNING blocked: ...` on every pass; the daily-cap case alerts and stops spending. The old pass-1 launch path is unrecoverable and is not a fallback.

## Paid liveness pass (required, not yet run)

Run once on netcup with the staged runner and a throwaway home: `fm-planning-runner.sh --check` for Sol and K3 (no-call, already ok in the build log), then one bounded `--start` against a scratch tracker clone and confirm the usage record and the `Planning-task:` trailer path. Do not install until it succeeds. This branch did not run it: the crewmate was authorized for read-only ssh to netcup and a paid pass writes there.

## Kill switch

`touch data/router-off` in the live home: every sender and sweep prints `router-off` and exits 0; planning stops. Roll back with `router-restore.sh previous` (or the `*.bak-*` copies).
