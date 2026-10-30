# Local validation scope and oracle

The acceptance oracle is the supplied user intent and the published teardown safety contract: absent inventory/lease requires clean pushed-or-landed work plus a verified backup; a different lease, dirt, unlanded work, or missing leased copy must retain the task record. A record-only background-receipt lane must match both the fetched PR ref and merged forge head, preserve its dummy/shared path, and must not kill an unrelated endpoint.

`drive-live.sh` executes the real fm-teardown and Treehouse binaries against fresh marked lab homes, real linked Git worktrees, and local bare Git remotes. No Treehouse or Git CLI is mocked. The final run explicitly pins tmux to an unused private socket.

`drive-receipt.py` executes the real fm-teardown, Git, gh, and tmux binaries. The external forge is a disposable Python HTTPS GraphQL emulator using synthetic data. The real gh client connects through a loopback CONNECT proxy, which avoids privileged port binding and gh URL port normalization. Local trust and synthetic enterprise tokens are scoped to subprocess environment variables; no account login or credential-store changes occur. This proves only local CLI integration with synthetic forge replies, not a real GitHub merge or production credentials.

The receipt success case creates no receipt file and names no endpoint. The endpoint-isolation adversary creates an unrelated `sleep 600` pane on a dedicated private tmux socket. The independent expected result is that teardown leaves that unrelated pane alive. Actual result: teardown reports reaping its process group, exits 0, removes the task record, and the unrelated private server no longer exists. The driver's assertion fails. The emulator and all disposable lab state are removed in finally/trap cleanup.

Initial setup attempts could not connect gh through a URL port (gh normalized it to 443), and binding loopback port 443 was denied. The unprivileged CONNECT proxy resolved those setup issues. An initial endpointless teardown unexpectedly selected the inherited tmux pane and logged TERM/KILL attempts; the retained adversarial reproduction uses a private socket only.

The baseline fm-teardown regression file initially stopped at its leaked-worktree-process assertion because host lsof was absent. lsof was then downloaded and unpacked inside the worktree, not installed system-wide, for a rerun. Regression tests use external-command mocks and are not independently classified as live scenarios.

Final regression rerun: `PATH="$PWD/.test-tools/unpack/usr/bin:$PATH" bash tests/fm-teardown.test.sh` exited 0. The locally unpacked dependency was then removed. The live private-socket isolation adversary still failed independently on the supported missing-lsof fallback. No source or test files were changed.
