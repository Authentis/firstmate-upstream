---
name: updatetools
description: >-
  Apply updates for the watched tools this fleet depends on - no-mistakes, herdr, br, the axi family, and any other tool listed in config/watched-tools.json.
  Use when the captain invokes /updatetools (e.g. "/updatetools", "update the tools", "apply the tool updates"), or on a `check: tool-updates ...` wake reporting a watched tool needs attention.
  Drives bin/fm-tool-update.sh, the applier half of fm-tool-update-check.sh's detection, on this host and every registered secondmate host.
user-invocable: true
metadata:
  internal: true
---

# updatetools

`bin/fm-tool-update-check.sh` already watches `config/watched-tools.json` and reports what is outdated; it deliberately repairs nothing.
This skill drives `bin/fm-tool-update.sh`, the applier: a mechanical guarded script plus this captain-invocable skill, the same shape as `bin/fm-update.sh` and the `updatefirstmate` skill for the firstmate repo itself.
See `docs/configuration.md` "Watched tool updates" for the full schema and applier contract; this skill only owns when and how to run it and how to report the result.

## Safety model

Prefer each tool's own refusal over a guard of our own.
`fm-tool-update.sh` never passes `--force` to anything.
A command tool's nonzero exit from its own update command, or git's own refusal of `git pull --ff-only` on a dirty or diverged tree, is read as that tool's authoritative refusal - reported skipped, never retried, never worked around.
`no-mistakes update` without `--force` already refuses outright while pipeline runs are active, which is exactly this mechanism; no separate busy-check exists or is needed.
A command tool with neither `update_args` nor `npm_package` configured in `config/watched-tools.json` is reported manual-only and never attempted - nothing is guessed at.
Every attempted update is verified, never assumed: the tool is asked its own version (or, for a git tool, its own HEAD) before and after, and an unchanged result after a clean exit is reported failed, not done.

## What it does

1. **Run the applier:**
   ```sh
   bin/fm-tool-update.sh
   ```
   With no argument this applies updates on this host, then on every host registered in `data/secondmates.md` - a local secondmate through its own copy of the script, a remote one through `bin/fm-on.sh` - because `config/watched-tools.json` is local to each home and is not inherited.
   Each host prints one line per tool (`done`, `skipped`, `failed`, `manual`, or `unreachable`) and a `host-summary:` line, followed by one final `fleet-summary:` line summing every host.
   To apply only on this host, run `bin/fm-tool-update.sh apply` instead.

2. **Read the outcome per tool and per host**, not just the fleet total.
   - `done: <old> -> <new>` - verified: the tool actually moved.
   - `skipped: <reason>` - the tool (or git) refused the update itself; nothing was forced.
     A `no-mistakes` skip during active pipeline runs is expected and needs no action - it will pick up the update the next time it is quiet.
   - `failed: <reason>` - the update command exited cleanly but the tool's version (or the git repo's HEAD) did not move; this needs attention, most often the PATH-skew shape where an update installs correctly but an earlier copy on `PATH` still shadows it.
   - `manual: <reason>` - neither `update_args` nor `npm_package` is configured for that tool in `config/watched-tools.json`; add one (see `docs/examples/watched-tools.json`) or update it by hand.
   - `unreachable: <reason>` - the command is missing from `PATH`, the git repo is missing or not a repository, or (for a secondmate host) that home does not yet have `bin/fm-tool-update.sh` - update firstmate there first.

3. **Report to the captain in plain outcomes**, per `AGENTS.md` section 9, without the internal per-line vocabulary above.
   Summarize what updated, what was skipped because it was busy (and will retry on its own next time), and what needs attention (a failed or manual-only tool) - never report a fleet-summary count on its own without naming what it means.

## When this runs unattended

On a `check: tool-updates ...` wake, this is the existing check wake becoming actionable, not a new timer: run the applier, then handle the result as an ordinary wake per `AGENTS.md` section 8.
A fleet-summary of all `done` or `skipped` (busy) needs no captain-facing message beyond the ordinary wake handling; a `failed` or a newly `manual` tool is worth a line to the captain so it does not sit unnoticed.

## Safety

- Never passes `--force`, never counts active runs itself, and never retries or works around a tool's own refusal.
- Never touches `PATH`, a version manager's configuration, or installs a tool for the first time; a tool absent from `PATH` is reported unreachable, not installed.
- A git-tracked watched tool only ever fast-forwards with `git pull --ff-only`; a dirty or diverged clone is left untouched and reported skipped, exactly like prime directive #3.
- Runs only `bin/fm-tool-update.sh`, never a hand-composed update command; adding, removing, or reconfiguring a watched tool is a `config/watched-tools.json` edit, not a code change.
