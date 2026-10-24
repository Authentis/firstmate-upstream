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
| Draft clear | Two Escapes within about 0.4 s empty an idle composer holding any draft (single-line, multi-line, pasted block); one Escape on a draft changes nothing, Ctrl-U and Ctrl-A then Ctrl-K clear only the cursor line, and one Ctrl-C clears but arms an exit on the next. The same pair on an EMPTY composer opens the Rewind checkpoint picker once the session has a turn, and one Escape closes it; Enter would restore a checkpoint. `../../../../../bin/fm-control-lib.sh` owns the key, count, and gap, and `fm_control_clear_draft` the send-and-verify, the picker check, and the single closing Escape. |
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

Command Code draws a bare `❯` composer between two rules, parks the terminal cursor below its footer, and draws its own reverse-video cursor cell.
Its `Ask your question...` placeholder is truecolor bright enough to survive the fleet ghost ceiling, so `../../../bin/fm-composer-lib.sh` reads a screen with a Command Code identity at a higher ceiling; typed text is the default foreground and stays pending.
The launch clears `NO_COLOR` and pins `COLORTERM=truecolor`, because a 256-colour terminal renders the placeholder in an untested palette colour.
`../../../bin/fm-tmux-lib.sh` supplies the `commandcode` identity on tmux, while Herdr's native detection reports `cmd`.
Zellij, cmux, orca, and paseo supply no such identity, so the placeholder would read pending there and `../../../bin/fm-spawn.sh` refuses a Command Code launch on those backends.
The delivery busy signals are `esc to interrupt` and the bullet-framed elapsed cell on the status row.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Command Code.
Do not launch a primary or secondmate with this adapter.
Command Code's GOAT plan exposes no OpenAI-compatible endpoint, so provider wiring through another harness is not an alternative path.
