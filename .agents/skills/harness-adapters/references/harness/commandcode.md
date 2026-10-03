# Command Code

Verified on 2026-10-02 with Command Code CLI 1.73.4 and 1.74.0 on the GOAT plan.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/commandcode.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | A per-task mod loaded with `--mod` opens on `run_start` and settles idle on `run_end` (including an interrupted run), `run_error`, and `session_shutdown`, writing through the generation-bound writer; `turn_end` touches the turn-ended file; `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/exit`, with the shared slash-command settle before Enter; prints `commandcode --resume <session-id>`. |
| Interrupt | One Escape cancels the running turn, renders `Interrupted`, keeps the agent, and leaves an empty composer; an idle Escape is harmless; no post-interrupt clear key. |
| Draft clear | Two Escapes within about 0.4 s empty an idle composer holding any draft (single-line, multi-line, pasted block); one Escape on a draft changes nothing, Ctrl-U and Ctrl-A then Ctrl-K clear only the cursor line, and one Ctrl-C clears but arms an exit on the next. `../../../../../bin/fm-control-lib.sh` owns the key, count, and gap, and `fm_control_clear_draft` the send-and-verify. |
| Skill invocation | Not verified; steer with ordinary text. |
| Resume | `commandcode --resume <session-id>`. |
| Model flag | `--model <provider/model-id>`, for example `deepseek/deepseek-v4.1-flash`; the spawn refuses an id absent from `commandcode --list-models`. |
| Effort flag | Never passed on argv, because CLI `--effort` persists into the user's global config; the mod sets the recorded effort for the session only (`low`, `medium`, `high`, `xhigh`, or `max`). |
| Model discovery | `commandcode --list-models`; authentication preflight is `commandcode status`. |
| Marker | None; the TUI sets its process title to `command-code`, and that anchored ancestry identifies the adapter. |
| Trust dialogs | `--yolo --skip-onboarding --no-auto-update` skip permission prompts, onboarding, and self-update for this run; the spawn owner carries the exact flags. |
| Workspace files | A git-excluded `.commandcode/settings.local.json` disables taste learning, and Command Code's own `.commandcode/taste/` directory is git-excluded too; no user or project config is edited. |
| Commit attribution | Unless the home sets `config/keep-ai-trailers` (`../../../../../docs/configuration.md` "Commit attribution"), that local settings file sets `attribution.commit` empty, Command Code's switch for its `Co-authored-by: CommandCodeBot` trailer. |

## Worker lifecycle limits

Enter while a run is busy queues the text into the same run as another turn rather than starting a new one.
The interrupt key is acknowledged only through the mod's `run_end`, not a rendered hint.
Herdr is not live-verified: Command Code ships a built-in `herdr` mod that reports its own agent state to Herdr, which a `--herdr-lab` verification must prove before Herdr dispatch is trusted.
Linux process-name identity is inferred from the same vendor process title and is not separately verified.

`../../../../../bin/fm-spawn.sh` owns autonomy, onboarding, brief delivery, the mod, and the local settings file; the user config at `~/.commandcode/` remains vendor-owned.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified `❯` composer row between two solid rules, the `Ask your question...` placeholder proof, and the busy row.
The idle placeholder is rendered at default-like brightness, so it reads empty only when its first cell is the reverse-video cursor and every later cell carries an explicit non-default foreground; typed text renders in the default foreground and stays a draft.
Beside that cursor proof, either the known placeholder text or a body drawn in the foreground of the rule above it identifies the placeholder, so no single vendor string is load-bearing.
A row's trailing carriage return, which Herdr's ANSI read emits, is a row ending rather than a typed cell.
Command Code parks the terminal cursor below its status rows, so `../../../../../bin/fm-tmux-lib.sh` reclassifies its cursor-anchored read from the identified pane.
`NO_COLOR` removes the cursor cell, so the launch unsets it.
The `../../../../../bin/fm-task-inbox-lib.sh` doorbell was read and acknowledged through real `fm-send`.
A draft stranded in an idle composer used to skip that doorbell and make `fm-control exit` refuse.
`fm-control` interrupt and exit now send the draft clear when the composer reads pending and refuse unless it then reads empty, and the doorbell sends it only when both the mod's idle record and the visible screen prove the agent idle, because the same Escape pair interrupts a running turn.
No other adapter's draft is ever cleared: it may be the captain's own typing.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Command Code.
Do not launch a primary or secondmate with this adapter.
Command Code's GOAT plan exposes no OpenAI-compatible endpoint, so provider wiring through another harness is not an alternative path.
