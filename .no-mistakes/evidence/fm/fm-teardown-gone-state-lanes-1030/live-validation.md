# Teardown live validation

Target: a0ca1fc6e1f4a19da9bbdabb3682b7c9cf833fa2.

## Isolation and oracle

The real `bin/fm-teardown.sh`, installed Treehouse v3.1.6, Git, tmux client, and `gh` CLI were executed. Synthetic project, bare origin, Treehouse pool, and marked FM_HOME were created under `.test-live/` in the gate worktree. No harness primary or default tmux server was used: the already-gone tmux endpoint was queried through a private, nonexistent socket named by TMUX. Lifecycle calls used the supported lab-home marker without a gate bypass. No production forge or user credentials were used.

The acceptance oracle is the author's requirement to finish clean, pushed lanes despite missing pool/lease/receipt records, plus preservation of unlanded work and foreign lease ownership. The drivers assert exit status, durable task-record removal or retention, unchanged worktree branch/HEAD and untracked bytes, and backup bundle validity/head identity. Recovery in a fresh repository confirms the published file is actually recoverable from the bundle, not just named in a log.

## Product transcripts

- `live-pool-matrix.log`: real Treehouse initially allocates a lease, a real return clears it, and status reports an empty lease. The lane has a separately pushed feature commit not in origin/main. Teardown completes with a verified backup while keeping the copy. Pointing Treehouse at a separate empty pool exercises a genuinely missing listing. Dirty and unpushed variants refuse even under --force for both missing states; a new real Treehouse lease refuses the stale recorded identity.
- `live-record.log`: real gh talks to a local HTTPS GraphQL emulator with synthetic MERGED/OPEN state and exact head data. A local bare Git origin publishes refs/pull/7/head. A nonexistent receipt path, both a shared sentinel path and an omitted worktree field, are exercised. Matching merged heads complete with backup; mismatching recorded heads and OPEN PRs refuse with the record retained. These are local emulator checks, not production GitHub validation.
- `local-forge.log`: actual GraphQL requests received from gh and HTTP responses.
- `bundle-recovery.log`: fresh Git repository fetches and checks out the retained bundle and reads the expected `shipped.txt` content.
- `pool-lane.bundle` and `receipt-lane.bundle`: actual generated backups of synthetic commits.

## Reproduction drivers

`pool-driver.sh` and `receipt-driver.sh` retain the executed assertions; `local-forge.py` and `local-forge-openssl.cnf` describe the local HTTPS emulator. The emulator accepts only CONNECT forge.test.invalid:443 on 127.0.0.1:18443, terminating TLS locally; it does not forward traffic. Empty GH_CONFIG_DIR and synthetic token environment isolate the real gh client from user login state.

## Supplemental regression checks

`bash tests/fm-teardown.test.sh` initially reached and passed the new gone-state tests, then failed its existing leaked-process reaping assertion because lsof was absent from PATH. `apt download lsof` and `dpkg-deb -x` materialized a disposable workspace-local binary, without installing or changing system packages. The single file was then rerun with `.test-live/lsof-local/usr/bin` prepended to PATH. The complete single-file rerun exited 0, including the previously failing process-reaping case. Both regression logs are retained. These boundary-mocked tests are supplemental, not the basis for any live scenario designation.

This is a CLI/state change, not a rendered UI change; evidence is CLI transcripts, actual Git bundles, and successful recovery rather than screenshots.
