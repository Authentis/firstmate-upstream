# Gone-state teardown live validation

## Surface and independent oracle

Executed the repository's real `bin/fm-teardown.sh` against marked disposable FM_HOME directories, real Git repositories/local bare origins, Treehouse v3.1.6, and a private tmux server. No fake Treehouse, Git, tmux, or teardown executable was used for the live checks. For record-only scenarios, the real `gh` CLI queried a disposable HTTPS localhost GraphQL forge emulator with synthetic PR records. This is local integration validation, not GitHub production or real-account validation.

The author's required contract is the oracle: clean pushed lanes with absent pool/lease state complete after backing up their exact head; different nonempty leases refuse; `--force` must not bypass the gone-state proof; a record-only lane needs matching fetched and merged PR heads, preserves its dummy/shared path, and does not require its receipt. Head hashes were recorded before teardown and compared to bundle heads and the surviving checkout. Refusal checks required the record and copy to survive and no bundle to be published.

## Live outcomes

| End-user action | Observable result | Evidence |
|---|---|---|
| Tear down a clean pushed lane after switching to an empty pool inventory | Exit 0, record removed, verified bundle contains original head, branch/head retained | live-initial.log |
| Tear down after real Treehouse return releases the recorded lease | Treehouse lists empty lease_id; exit 0 with verified head backup; branch/head retained | live-null.log |
| Tear down with a different newly acquired lease, even with --force | Refuses, record and head retained, no bundle | live-foreign-force.log |
| Force teardown with dirty content and absent pool listing | Refuses, sentinel bytes and record retained, no bundle | live-dirty-force.log |
| Force teardown with unpushed/unlanded work and absent listing | Refuses, head and record retained, no bundle | live-unpushed-force.log |
| Force teardown with dirty content after lease release | Refuses, sentinel bytes and record retained, no bundle | live-null-dirty-force.log |
| Force teardown with unpushed/unlanded work after lease release | Refuses, head and record retained, no bundle | live-null-unpushed-force.log |
| Tear down record-only lane with no receipt, synthetic merged matching PR | Real gh reports MERGED; exit 0, record removed, verified bundle holds exact recorded head; shared sentinel unchanged | record-merged.log; forge-api.log |
| Force teardown record-only lane with synthetic open PR | Refuses; record and shared sentinel retained, no bundle | record-open-force.log |
| Force teardown record-only lane with mismatching synthetic forge head | Refuses; record and shared sentinel retained, no bundle | record-mismatch-force.log |
| Force teardown record-only lane with moved fetched PR ref | Refuses; record and shared sentinel retained, no bundle | record-fetch-mismatch-force.log |
| Tear down leased non-record-only lane after its entire copy disappears | **Contradicts the new header's missing-copy refusal:** exit 0, record removed, no bundle. Also reproduced with base script: not a newly introduced runtime regression. | live-missing-copy.log; baseline-missing-copy.log |

`live-null*` are historical driver labels: the installed real Treehouse serializes a released lease as an empty string, not JSON null. Literal null and omitted lease fields were covered only by the mocked behavioral regressions below, not claimed as live wire-format coverage.

## Supplemental regression checks (not live)

Executed the existing targeted test functions from `tests/fm-teardown.test.sh`: invalid inventories; null/empty/omitted/foreign/matching leases; dirty/unpushed force refusals; missing listing backup/refusals; record-only dummy/no-worktree success and head mismatch. All selected functions completed successfully. These tests mock external executables and do not substitute for the live checks. See targeted-regressions.log and run-targeted.py.

## Cleanup and scope

Disposed of lab homes, repositories, synthetic shared paths, private tmux servers, and the HTTPS emulator. Temporary test drivers and the base script copy were removed from the worktree after retaining their reproduction sources here. No tracked source edits were made. No full suite, linter, formatter, push, PR, or CI phase ran. This is a CLI-only change; CLI transcripts are the reviewer-visible surface, so no screenshot was needed.
