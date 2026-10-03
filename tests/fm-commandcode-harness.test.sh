#!/usr/bin/env bash
# Portable Command Code worker adapter regression. Vendor facts are refreshed by
# fm-commandcode-signals-live-e2e.test.sh; this suite needs no Command Code
# install and no credentials. The parked-cursor tmux read is pinned with real
# processes in fm-tmux-agent-liveness.test.sh.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-commandcode-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

# --- identity -------------------------------------------------------------------
mkdir -p "$TMP_ROOT/names"
for name in command-code command-coder; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/command-code" -c '"$1"; :' _ "$HARNESS")
[ "$out" = commandcode ] || fail "native Command Code ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/command-coder" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm commandcode' ] || fail "unrelated command-coder claimed the adapter"
[ "$(fm_agent_process_classify_name /usr/bin/command-code)" = agent ] || fail "liveness lost Command Code"
[ "$(fm_agent_process_classify_name command-coder)" = other ] || fail "liveness claims an unrelated executable"
pass "Command Code process-title identity; anchored liveness"

# --- lifecycle capabilities ---------------------------------------------------------
[ "$(fm_control_harness_family commandcode)" = commandcode ] || fail 'recorded harness family lost'
[ "$(fm_control_interrupt_key commandcode)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat commandcode)" = 1 ] || fail 'Command Code interrupts on one Escape'
[ -z "$(fm_control_interrupt_clear_key commandcode)" ] || fail 'Command Code restores no draft and needs no clear key'
[ -z "$(fm_control_interrupt_arm_signal commandcode)" ] || fail 'a single press needs no arm proof'
[ "$(fm_control_exit_command commandcode)" = /exit ] || fail 'wrong exit command'
fm_control_harness_supports_kind commandcode ship || fail 'ship refused'
fm_control_harness_supports_kind commandcode scout || fail 'scout refused'
! fm_control_harness_supports_kind commandcode secondmate || fail 'secondmate accepted'
[ "$(fm_control_harness_wiring_paths commandcode /wt /st id1)" = "$(printf '%s\n%s' /st/id1.commandcode-mod.ts /wt/.commandcode/settings.local.json)" ] \
  || fail 'wiring retirement must name the state mod and the worktree settings file'
pass "worker-only lifecycle capabilities and wiring retirement"

# --- composer and delivery signals ------------------------------------------------------
cc_screen() {  # <styled composer row>
  local rule
  rule=$(printf '\033[38;2;138;148;168m%s\033[39m' '────────────────────────────────')
  printf '\n%s\n%s\n%s\n  » permission bypass on [shift+tab]\n  ? for shortcuts · taste on\n' "$rule" "$1" "$rule"
}
idle_row=$(printf '\033[39m❯ \033[7mA\033[0m\033[38;2;138;148;168msk your question...\033[39m')
typed_row=$(printf '\033[39m❯ Ask your question...\033[7m \033[0m')
home_row=$(printf '\033[39m❯ \033[7mA\033[0msk your question...')
nocolor_row=$(printf '\033[39m❯ A\033[38;2;138;148;168msk your question...\033[39m')
draft_row=$(printf '\033[39m❯ hello draft\033[7m \033[0m')
[ "$(fm_composer_classify_screen styled=1 "$(cc_screen "$idle_row")")" = empty ] || fail 'idle placeholder must read empty'
[ "$(fm_composer_classify_screen styled=1 "$(cc_screen "$draft_row")")" = pending ] || fail 'typed draft must read pending'
[ "$(fm_composer_classify_screen styled=1 "$(cc_screen "$typed_row")")" = pending ] || fail 'typed placeholder words must read pending'
[ "$(fm_composer_classify_screen styled=1 "$(cc_screen "$home_row")")" = pending ] || fail 'typed placeholder words with the cursor home must read pending'
[ "$(fm_composer_classify_screen styled=1 "$(cc_screen "$nocolor_row")")" = pending ] \
  || fail 'without the reverse-video cursor cell the placeholder is unproven and must not read empty'
# The styling proof is load-bearing: the identical plain bytes cannot prove empty.
[ "$(fm_composer_classify_screen styled=0 "$(cc_screen "$idle_row" | fm_composer_strip_ansi)")" != empty ] \
  || fail 'an unstyled capture must never prove the placeholder empty'
pass "composer: the styled placeholder proof reads idle empty and every typed shape pending"

# A real idle 1.74.0 pane as herdr's ANSI viewport read returns it, CR LF row
# endings included (the composer tail, byte-exact).
herdr_idle=$(cat "$ROOT/tests/captures/commandcode-v1.74.0/herdr-idle.ansi")
case "$herdr_idle" in *$'\r'*) ;; *) fail 'capture lost its CR row endings; the case would be vacuous' ;; esac
[ "$(fm_composer_classify_screen styled=1 "$herdr_idle")" = empty ] || fail 'a captured idle 1.74.0 herdr pane must read empty'
[ "$(fm_composer_classify_screen styled=1 "$(printf '%s\n' "$herdr_idle" | tr -d '\r')")" = empty ] || fail 'the same pane without CR must read empty'
for row in "$draft_row" "$typed_row" "$home_row" "$nocolor_row"; do
  [ "$(fm_composer_classify_screen styled=1 "$(cc_screen "$row" | sed 's/$/\r/')")" = pending ] \
    || fail "a CR row ending must not prove a typed row empty: $(printf '%s' "$row" | fm_composer_strip_ansi)"
done
pass "composer: herdr's CR LF rows read the idle placeholder empty and every typed shape pending"

# Real 1.74.1 composer tails, byte-exact, under three launch environments. The
# colour-erased shapes (NO_COLOR and FORCE_COLOR=0) are the verified way an
# empty idle composer reads pending: they stay pending on purpose, because
# without the styling proof the row cannot be told from typed text, and the
# control plane's clear refuses to repeat its Escape pair on them
# (fm-commandcode-composer-clear.test.sh). The launch clears NO_COLOR.
cc174="$ROOT/tests/captures/commandcode-v1.74.1"
truecolor_idle=$(cat "$cc174/truecolor-idle.ansi")
[ "$(fm_composer_classify_screen styled=1 "$truecolor_idle")" = empty ] || fail 'a captured idle 1.74.1 pane must read empty'
[ "$(fm_composer_classify_screen styled=1 "$(cat "$cc174/nocolor-idle.ansi")")" = pending ] \
  || fail 'the captured NO_COLOR placeholder has no cursor cell and must stay pending'
[ "$(fm_composer_classify_screen styled=1 "$(cat "$cc174/forcecolor0-idle.ansi")")" = pending ] \
  || fail 'the captured FORCE_COLOR=0 placeholder has no muted tail and must stay pending'
# A long transcript above the composer, as on a lane that has run for hours,
# changes nothing about the verdict, with LF or CR LF rows.
transcript=$(for n in $(seq 1 30); do printf '  - transcript row %s that is long enough to look like a worker report line\n' "$n"; done)
long_screen=$(printf '%s\n\n%s\n' "$transcript" "$truecolor_idle")
[ "$(fm_composer_classify_screen styled=1 "$long_screen")" = empty ] || fail 'a long transcript above an idle composer must read empty'
[ "$(fm_composer_classify_screen styled=1 "$(printf '%s\n' "$long_screen" | sed 's/$/\r/')")" = empty ] \
  || fail 'a long transcript with CR LF rows above an idle composer must read empty'
# The plain capture from the stalled netcup lane carries no escapes, so it can
# never prove the placeholder: it must not read as empty or as typed text.
netcup_idle=$(cat "$ROOT/tests/captures/commandcode-v1.74.0/netcup-leaf-idle-plain.txt")
case "$(fm_composer_classify_screen styled=0 "$netcup_idle")" in
  empty|pending) fail 'an unstyled capture of the stalled lane must read unknown' ;;
esac
# The checkpoint picker an Escape pair opens on an empty composer is neither.
for picker in "$cc174/rewind-overlay.ansi" "$ROOT/tests/captures/commandcode-v1.74.0/netcup-leaf-rewind-plain.txt"; do
  case "$(fm_composer_classify_screen styled=1 "$(cat "$picker")")" in
    empty|pending) fail "the checkpoint picker must read neither empty nor pending: $picker" ;;
  esac
done
pass "composer: captured 1.74.1 idle, colour-erased, long-transcript, stalled-lane, and checkpoint-picker screens"

# Two independent placeholder signals, each sufficient beside the cursor-cell
# proof: the anchored placeholder text, and a body drawn in the frame rule's own
# foreground. Drive them apart and keep each case honest about which one holds.
cc_framed() {  # <rule fg> <styled composer row>
  local rule
  rule=$(printf '\033[%sm%s\033[0m' "$1" '────────────────────────────────')
  printf '\n%s\n%s\n%s\n  ? for shortcuts\n' "$rule" "$2" "$rule"
}
muted='38;2;138;148;168' other='38;2;232;64;87'
renamed_row=$(printf '\033[39m❯ \033[7mW\033[0m\033[%smhat should we build?\033[0m' "$muted")
! fm_composer_idle_matches 'What should we build?' "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive || fail 'renamed placeholder must not match the idle regex'
[ "$(fm_composer_classify_screen styled=1 "$(cc_framed "$muted" "$renamed_row")")" = empty ] \
  || fail 'a renamed placeholder in the frame colour must read empty without its string'
[ "$(fm_composer_classify_screen styled=1 "$(cc_framed "$other" "$idle_row")")" = empty ] \
  || fail 'the known placeholder must read empty when the frame colour differs'
[ "$(fm_composer_classify_screen styled=1 "$(cc_framed "$other" "$renamed_row")")" = pending ] \
  || fail 'with neither signal the row must stay pending'
mixed_row=$(printf '\033[39m❯ \033[7mW\033[0m\033[%smhat should \033[%smwe build?\033[0m' "$muted" "$other")
[ "$(fm_composer_classify_screen styled=1 "$(cc_framed "$muted" "$mixed_row")")" = pending ] \
  || fail 'a body in more than one foreground is not the frame colour'
for row in "$typed_row" "$home_row" "$nocolor_row"; do
  [ "$(fm_composer_classify_screen styled=1 "$(cc_framed "$muted" "$row")")" = pending ] \
    || fail "the frame colour must not prove a typed row empty: $(printf '%s' "$row" | fm_composer_strip_ansi)"
done
pass "composer: placeholder text and frame colour each carry the idle verdict; neither alone is load-bearing"

for signal in ' ⌘ Crystallizing…  esc to interrupt • 3s • ↓ 0' 'esc to interrupt' ' ☆ Organizing… • 12s • ↓ 418' ' ✧ Calculating… • 2m 8s • ↓ 920'; do
  printf '%s\n' "$signal" | fm_busy_lines_match commandcode || fail "independent delivery signal lost: $signal"
done
! printf '❯ hello draft\n' | fm_busy_lines_match commandcode || fail 'draft read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match commandcode || fail 'borrowed another harness signal'
pass "independent delivery signals"

# --- spawn ------------------------------------------------------------------------------
case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
cat >"$fakebin/commandcode" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  printf 'Available models  ·  2 models\n\nOpen Source\n\n'
  printf 'deepseek/deepseek-v4.1-flash           V4.1 hybrid-attention reasoning with vision\n'
  printf 'xiaomi/mimo-v2.5                       efficient long-context agentic coding\n'
fi
exit 0
SH
chmod +x "$fakebin/commandcode"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" commandcode
fm_git_worktree "$proj" "$wt" commandcode-test
fm_test_spawn_brief "$home" cc-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" cc-worker "$proj" --scout --harness commandcode --model deepseek/deepseek-v4.1-flash --effort high 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
mod="$home/state/cc-worker.commandcode-mod.ts"
assert_contains "$launch" "'$fakebin/commandcode' -t --yolo --skip-onboarding --no-auto-update" 'trust, autonomy, or update flags missing'
assert_contains "$launch" "--model 'deepseek/deepseek-v4.1-flash'" 'model lost'
assert_contains "$launch" "--mod '$mod'" 'per-task mod missing'
assert_contains "$launch" '-u NO_COLOR' 'NO_COLOR would erase the placeholder proof'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
case "$launch" in *--effort*) fail 'effort reached argv, where Command Code persists it globally' ;; esac
assert_grep 'effort=high' "$home/state/cc-worker.meta" 'effort not recorded'
assert_present "$mod" 'spawn did not write the mod'
assert_grep 'const effort = "high";' "$mod" 'mod does not carry the session effort'
settings="$wt/.commandcode/settings.local.json"
jq -e '.attribution.commit == "" and .mods.disabled == ["learning"]' "$settings" >/dev/null \
  || fail 'worktree settings must turn the co-author trailer and taste learning off'
excl=$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)
grep -qxF '.commandcode/settings.local.json' "$excl" || fail 'settings file not excluded from git'
grep -qxF '.commandcode/taste/' "$excl" || fail 'taste directory not excluded from git'
[ -z "$(git -C "$wt" status --porcelain)" ] || fail "spawn left untracked files in the worktree: $(git -C "$wt" status --porcelain)"
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
pass "launch carries model, autonomy, typed brief, and mod; effort rides the mod; settings stay out of git"

# --- the mod drives the busy record ---------------------------------------------------------
drive_mod() {  # <mod> <event>...
  MOD_PATH="$1" EVENTS="${*:2}" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync } from "node:fs";
const mod = await import(pathToFileURL(process.env.MOD_PATH).href);
const handlers = {};
const efforts = [];
mod.default({ on: (name, fn) => { handlers[name] = fn; }, setEffort: (e) => efforts.push(e) });
for (const ev of process.env.EVENTS.split(" ").filter(Boolean)) {
  if (ev === "handlers") { console.log(Object.keys(handlers).sort().join(" ")); continue; }
  if (ev === "efforts") { console.log(efforts.join(",") || "none"); continue; }
  await handlers[ev]({ type: ev });
}
await new Promise((resolve) => setTimeout(resolve, 200));
EOF
}
command -v node >/dev/null 2>&1 || fail 'node is required to drive the per-task mod'
state="$home/state"
out=$(drive_mod "$mod" handlers efforts)
[ "$out" = "$(printf '%s\n%s' 'run_end run_error run_start session_shutdown turn_end' high)" ] || fail "mod registration or effort wrong: $out"
rm -f "$state/cc-worker.turn-ended"
drive_mod "$mod" turn_end >/dev/null
assert_present "$state/cc-worker.turn-ended" 'turn_end no longer touches the notification marker'
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'busy fm-spawn' ] || fail 'turn_end must stay a notification'
drive_mod "$mod" run_start >/dev/null
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'busy commandcode-mod' ] || fail 'run_start must open busy'
drive_mod "$mod" run_start run_start run_end >/dev/null
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'busy commandcode-mod' ] || fail 'a nested run_end must not close the outer run'
drive_mod "$mod" run_start run_end >/dev/null
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'idle commandcode-mod' ] || fail 'run_end must settle idle'
drive_mod "$mod" run_start run_error >/dev/null
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'idle commandcode-mod' ] || fail 'run_error must settle idle'
drive_mod "$mod" run_start session_shutdown >/dev/null
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'idle commandcode-mod' ] || fail 'session_shutdown must settle idle'
fm_busy_source_trusted commandcode commandcode-mod || fail 'Command Code must trust its own mod'
! fm_busy_source_trusted commandcode omp-ext || fail 'Command Code must not trust another adapter writer'
"$ROOT/bin/fm-busy-event.sh" arm "$state" cc-worker >/dev/null
drive_mod "$mod" run_start run_end >/dev/null
[ "$(fm_busy_classify tmux fake:w commandcode cc-worker "$state")" = 'busy fm-spawn' ] || fail 'a stale mod generation changed the replacement record'
pass "mod: run_start busy, nested and failed runs, run_end and shutdown idle, stale generation rejected"

# --- spawn variants ---------------------------------------------------------------------------
fm_test_spawn_brief "$home" cc-plain
wt2="$case_dir/wt2"
git -C "$proj" worktree add --quiet -b commandcode-plain "$wt2"
touch "$home/config/keep-ai-trailers"
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch2" fm_test_run_spawn "$home" "$wt2" "$fakebin" cc-plain "$proj" --scout --harness commandcode 2>&1)
then fail "plain spawn failed: $out"; fi
rm -f "$home/config/keep-ai-trailers"
jq -e '(has("attribution") | not) and .mods.disabled == ["learning"]' "$wt2/.commandcode/settings.local.json" >/dev/null \
  || fail 'keep-ai-trailers must leave Command Code attribution alone and still turn learning off'
assert_grep 'const effort = "";' "$home/state/cc-plain.commandcode-mod.ts" 'an unrequested effort must not be set'
case "$(cat "$case_dir/launch2")" in *--model*) fail 'an omitted model reached argv' ;; esac
pass "keep-ai-trailers and omitted model/effort"

fm_test_spawn_brief "$home" cc-bad
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" cc-bad "$proj" --scout --harness commandcode --model nope/not-listed 2>&1)
then fail 'an unlisted model was accepted'; fi
assert_contains "$out" "Command Code model 'nope/not-listed' is not listed" 'wrong model refusal'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" cc-sm "$proj" --secondmate --harness commandcode 2>&1)
then fail 'Command Code secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "unlisted model and secondmate refused"

# --- trailer strip ----------------------------------------------------------------------------
msg="$TMP_ROOT/msg"
printf 'fix: thing\n\nCo-authored-by: CommandCodeBot <noreply@commandcode.ai>\nCo-authored-by: Jane Doe <jane@example.com>\n' >"$msg"
"$ROOT/bin/fm-git-strip-ai-trailers.sh" "$msg" || fail 'strip failed'
! grep -q CommandCodeBot "$msg" || fail 'Command Code default trailer survived'
grep -q 'Jane Doe' "$msg" || fail 'human co-author removed'
pass "Command Code's default co-author trailer is stripped; humans kept"
