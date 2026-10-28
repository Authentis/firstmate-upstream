---
name: knowledge-routing
description: >-
  Load before capturing any durable fact, captain preference, learning, or task note, before editing a backlog item's notes or filing a main-side thread as a work item, before pruning Done entries or re-evaluating the queue after a teardown or heartbeat, when acting in a manual-backend home, and when deciding where a piece of knowledge belongs.
user-invocable: false
metadata:
  internal: true
---

# Knowledge routing and note hygiene

This skill holds the knowledge-routing and backlog-note procedure moved out of `../../../AGENTS.md` sections 2, 6, and 10.
The always-loaded boundaries stay there: firstmate never writes a project's `AGENTS.md`, a crewmate only corrects it, fleet delivery posture and captain-private strategy stay out of project memory, and every captain decision is held through `bin/fm-captain-hold.sh`.

## Captain and learnings records

Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory, except for a knowledge class that a home-declared external memory tier under [Routing](#routing) owns.

## Routing

Route durable knowledge to its most specific owner:

- A home may declare authoritative external memory tiers in a `Memory layering` section of its captain-preference files ([`docs/configuration.md`](../../../docs/configuration.md) owns the schema); each declared tier owns the knowledge classes it names, this home's `data/` is then only a per-machine cache for those classes, capture to the tier is never skipped because a local file also received the fact, and a correction follows the tier's declared rule rather than an in-place edit.
- When a worker's harness cannot reach a declared tier, firstmate captures on the worker's behalf from its report.
- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under the `secondmate-provisioning` contract.
- Fleet-local operational facts no declared tier owns belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`, which only deliberate human edits extend.
- Knowledge general to every firstmate user belongs in this repo's shared tracked surface, which a user/operator home can only reach through an authorized contribution - otherwise it stays in `data/learnings.md` or a local draft for the captain.

When the captain invokes `/stow`, load the `stow` skill for its memory curation, knowledge routing, and persistence of the open work records this session is holding; it files and corrects only the open work that session is holding, and never reconciles the backlog against repository or PR reality.

## Backlog schema and handoff owners

The configured `tasks-axi` backend is the durable queue; the tracked default is `data/backlog.md`.
It tracks work items only, never agents; persistent secondmates never appear as backlog items.
When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item and hold it through that wrapper.
Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their completion gate and recorded-answer rules.
`docs/configuration.md` owns automatic transition gate applicability and the manual-backend exception.
When `config/lane-capacity` exists, `bin/fm-capacity.sh` reports open lanes and host headroom for queue re-evaluation.

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it, always through `bin/fm-tasks-axi.sh` so the call reaches this home's backlog from any directory, and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

## Note hygiene

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to [Routing](#routing) rather than scattering it through task notes.
