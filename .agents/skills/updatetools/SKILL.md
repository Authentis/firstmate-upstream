---
name: updatetools
description: >-
  Apply updates for the watched tools this fleet depends on - no-mistakes, herdr, br, the axi family, and any other tool listed in config/watched-tools.json.
  Use when the captain invokes /updatetools (e.g. "/updatetools", "update the tools", "apply the tool updates"), or on a `check: tool-updates ...` wake reporting a watched tool needs attention.
  On a check wake it only reports; applying runs bin/fm-tool-update.sh apply on this host alone, and only on the captain's word.
user-invocable: true
metadata:
  internal: true
---

# updatetools

`bin/fm-tool-update-check.sh` already watches `config/watched-tools.json` and reports what is outdated; it deliberately repairs nothing.
This skill drives `bin/fm-tool-update.sh`, the applier: a mechanical guarded script plus this captain-invocable skill, the same shape as `bin/fm-update.sh` and the `updatefirstmate` skill for the firstmate repo itself.
See `docs/configuration.md` "Watched tool updates" for the full schema and applier contract, including apply classes, pins, the rollback record, and the health check; this skill only owns when and how to run it and how to report the result.

## On a `check: tool-updates ...` wake: report only

A tool-updates wake is a report, never a trigger.
Run nothing: no `bin/fm-tool-update.sh` in any form, and no update command by hand.
Tell the captain in plain outcomes which tools have an update available, which are pinned, and which need attention (an update installed but not in effect, or a check that could not read a source), then handle the wake as an ordinary wake per `AGENTS.md` section 8.
Applying waits for the captain's word.

## Safety model

Prefer each tool's own refusal over a guard of our own.
`fm-tool-update.sh` never passes `--force` to anything.
A command tool's nonzero exit from its own update command, or git's own refusal of `git pull --ff-only` on a dirty or diverged tree, is read as that tool's authoritative refusal - reported skipped, never retried, never worked around.
`no-mistakes update` without `--force` already refuses outright while pipeline runs are active, which is exactly this mechanism; no separate busy-check exists or is needed.
Every attempted update is verified, never assumed, and a failed health check rolls the tool back to the version recorded before the update.

## Applying, on the captain's word

1. **Run the applier on this host only:**
   ```sh
   bin/fm-tool-update.sh apply
   ```
   This applies only `auto`-class tools; a tool with no `class` is `manual` and is never applied by the script.
   Add `--class quiet` only when the captain asks for the `quiet` tools too; a host's own quiet-window step is that host's business, not this skill's.
   The script refuses to run with no action.
   Never run `bin/fm-tool-update.sh fleet` on your own judgment or from any automation: it also applies on every registered secondmate host.
   Run it only when the captain explicitly asks to update those other hosts too.

2. **Read the outcome per tool**, not just the summary.
   - `done: <old> -> <new>` - verified: the tool moved and passed its health check.
   - `skipped: <reason>` - the tool (or git or npm) refused the update itself, or the rollback record could not be written; nothing was forced.
     A `no-mistakes` skip during active pipeline runs is expected and needs no action.
   - `failed: <reason>` - the update did not take effect, or it failed its health check; a health failure names whether it was rolled back or says `ROLLBACK IMPOSSIBLE`, which needs the captain's attention now.
   - `manual: <reason>` - a `manual`-class tool, or one with neither `update_args` nor `npm_package`; it is updated by hand, with a plan where needed.
   - `held: <reason>` - a tool of the other class, or one at its `pin`, left alone on purpose.
   - `unreachable: <reason>` - the command is missing from `PATH`, the git repo is missing or not a repository, or (for a secondmate host in a fleet run) that home does not yet have `bin/fm-tool-update.sh`.
   `data/tool-updates/<YYYY-MM-DD>.md` holds the previous version and binary path or npm version for every update attempted that day.

3. **Report to the captain in plain outcomes**, per `AGENTS.md` section 9, without the internal per-line vocabulary above.
   Summarize what updated, what was left alone and why, and what needs attention - above all a failed health check and whether it was rolled back.

## Safety

- Never passes `--force`, never counts active runs itself, and never retries or works around a tool's own refusal.
- Never touches `PATH`, a version manager's configuration, or installs a tool for the first time; a tool absent from `PATH` is reported unreachable, not installed.
- A git-tracked watched tool only ever fast-forwards with `git pull --ff-only`; a dirty or diverged clone is left untouched and reported skipped, exactly like prime directive #3.
- Runs only `bin/fm-tool-update.sh`, never a hand-composed update command; adding, removing, reclassifying, or pinning a watched tool is a `config/watched-tools.json` edit, not a code change.
