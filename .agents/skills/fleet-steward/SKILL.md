---
name: fleet-steward
description: >-
  Agent-only finish-then-refill procedure for a `fleet-steward:` check wake.
  Use when this home's durable low-fleet check emits
  `action=finish-then-refill`, and whenever a child completion is being handled
  while verified next-up work remains.
user-invocable: false
metadata:
  internal: true
---

# Fleet steward

This procedure makes completion and refill one supervision step.
It never broadens merge authority, bypasses guarded teardown, invents a brief from tracker prose, or treats a stale capacity count as current truth.

## Finish then refill

1. Reconcile the current state of every child that reported a terminal result through `bin/fm-crew-state.sh <id>`.
2. Land or record each verified deliverable through its existing delivery-mode owner.
   A pull request still follows the merge-authority and `bin/fm-pr-merge.sh` path, a local-only branch still follows `bin/fm-merge-local.sh`, and a scout report is recorded as its artifact.
3. Run ordinary `bin/fm-teardown.sh <id>` without `--force`.
   Successful teardown owns metadata removal and the fused backlog close or retain transition, so never close the row separately.
4. Treat a teardown refusal as occupied capacity.
   Preserve the task and worktree, capture the refusal in a private detail file, and run `bin/fm-fleet-steward.sh exempt <id> --state <reconciled-state> --detail-file <path>`.
   This records the exact held-external steward exemption without discarding work or hiding sibling exemptions.
5. Refresh the queue with `bin/fm-fleet-steward.sh refresh` before selecting work.
   A failed refresh leaves the last known-good queue in place but does not authorize dispatch from it; report the refresh failure and stop the refill portion of this pass.
6. Recompute current productive capacity from a fresh `bin/fm-fleet-snapshot.sh --json` result.
   Count local tasks whose `.current_state.state` is `working` or `parked`, and conservatively count a recorded task with an unresolved or unknown endpoint as occupied.
7. If productive capacity is below six and `data/next-up.md` still has a `READY` row, validate that row's acceptance and preconditions, prepare the ordinary brief, and dispatch it through the normal guarded spawn path.
   Load `harness-adapters` before spawning.
8. Repeat the fresh capacity and ready-row check only until productive capacity reaches six or no verified eligible row remains.

When handling an individual child's `done:` wake, complete steps 1 through 7 in the same pass rather than postponing refill to a later heartbeat.
If landing needs merge authority, preserve the ready child and continue only with capacity that still counts it as occupied.
If an exemption or spawn refuses, report the exact refusal and stop that branch of the pass; do not force, discard, or compensate by exceeding verified capacity.

## Durable inputs

`bin/fm-fleet-steward.sh` owns the queue-refresh algorithm, the low-fleet episode state, custom-check registration, timer installation, and steward-exemption write mechanics.
Its header and `--help` own exact commands and private file names.
`data/next-up.md` is generated output, not a second backlog and not authority to waive a bead's current acceptance or preconditions.
