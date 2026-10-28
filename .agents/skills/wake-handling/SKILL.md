---
name: wake-handling
description: >-
  Load before handling any actionable signal, stale, check, or heartbeat wake, including a merged-PR, contributions, secondmate auto-relaunch, captain inbox note, or Relay-linked milestone or terminal wake.
user-invocable: false
metadata:
  internal: true
---

# Wake handling

This skill holds the per-wake procedure moved out of `../../../AGENTS.md` section 8.
The always-loaded boundaries stay there: one live supervision cycle, drain before acting, the `OPEN DECISIONS`, `UNREAD STATUS`, and `RECORD DIVERGENCE` rules, the generation-bound acknowledgement, never broadly killing watchers, and home-scoped repair.
Fleet supervision is an always-loaded operational contract; `docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own mechanisms and harness-specific recipes.

- `bin/fm-classify-lib.sh` owns the distinction between declared `paused:` waits and `blocked:` events needing firstmate action; `bin/fm-brief.sh` owns worker declaration instructions.

## Per-wake procedure

Handle actionable wakes as follows:

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event source results, and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
   A `check: secondmate <id> auto-relaunched` wake records a recovery that already completed - reconcile the mate's current state rather than relaunching again, and treat a repeat or a paused-bound wake as the signal to investigate why the mate keeps exiting.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

Load `bearings` on a contributions check wake or when filing work linked to an upstream issue; its contribution-follow-up section owns triage and exact signal acknowledgement.

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.

A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.

## Guards

The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.
Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle.
