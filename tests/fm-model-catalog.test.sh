#!/usr/bin/env bash
# Pre-launch model catalog check (bin/fm-model-catalog-lib.sh) for Pi,
# Pi-signed, and OpenCode, and its use by bin/fm-spawn.sh before any endpoint
# or record exists. The fake listings copy the real shapes: Pi 1.2.0's
# `--list-models` table and opencode 1.19.0's `models` lines, including the two
# ids that left bosgame workers at a shell prompt - a dash-joined
# "meta-muse-spark-1.3-contributor" and a bare id listed under two
# authenticated providers.
# shellcheck disable=SC2030,SC2031 # Cases scope PATH and listing knobs to one subshell on purpose.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-model-catalog-lib.sh
. "$ROOT/bin/fm-model-catalog-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-catalog)
mkdir -p "$TMP_ROOT"

FAKE="$TMP_ROOT/catalog-bin"
mkdir -p "$FAKE"
cat > "$FAKE/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ -z "${FM_FAKE_PI_LIST_LOG:-}" ] || echo listed >> "$FM_FAKE_PI_LIST_LOG"
  [ -z "${FM_FAKE_PI_LIST_FAIL:-}" ] || exit 1
  [ -z "${FM_FAKE_PI_LIST_EMPTY:-}" ] || exit 0
  [ -z "${FM_FAKE_PI_LIST_SLOW:-}" ] || /bin/sleep 5
  [ -z "${FM_FAKE_PI_AGENT_DIR_LOG:-}" ] || printf '%s\n' "${PI_CODING_AGENT_DIR:-unset}" > "$FM_FAKE_PI_AGENT_DIR_LOG"
  cat <<'EOF'
provider     model                         context  max-out  thinking  images
meta         muse-spark-1.3-contributor    262.1K   131.1K   yes       yes
nvidia       meta/muse-glimmer-30b         131.1K   131.1K   yes       yes
opencode-go  muse-spark-1.3-contributor    262.1K   131.1K   yes       yes
openai-codex gpt-6.1-sol                   262.1K   131.1K   yes       yes
EOF
  [ -z "${FM_FAKE_PI_DUP_SLASH:-}" ] || printf "openrouter   meta/muse-glimmer-30b         131.1K   131.1K   yes       yes\n"
fi
exit 0
SH
cat > "$FAKE/opencode" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  [ -z "${FM_FAKE_OPENCODE_LIST_FAIL:-}" ] || exit 1
  [ -z "${FM_FAKE_OPENCODE_LIST_EMPTY:-}" ] || exit 0
  [ -z "${FM_FAKE_OPENCODE_LIST_SLOW:-}" ] || /bin/sleep 5
  printf '%s\n' opencode/muse-spark-1.3-contributor-free opencode-go/cat-jam-free openrouter/meta/muse-spark-1.1
fi
exit 0
SH
chmod +x "$FAKE/pi" "$FAKE/opencode"

pi_ok() {  # <model> <why>
  local out
  out=$(fm_model_catalog_validate pi "$FAKE/pi" "$1" 2>&1) || fail "$2: '$1' was refused: $out"
}
pi_refused() {  # <model> <expected-fragment> <why>
  local out
  if out=$(fm_model_catalog_validate pi "$FAKE/pi" "$1" 2>&1); then fail "$3: '$1' was accepted"; fi
  assert_contains "$out" "$2" "$3"
}

pi_ok meta/muse-spark-1.3-contributor 'a canonical provider/id is launchable'
pi_ok gpt-6.1-sol 'a bare id listed once is launchable'
pi_ok OpenAI-Codex/GPT-6.1-sol "Pi's resolver matches case-insensitively"
pi_ok gpt-6.1-sol:high 'a valid thinking suffix rides on a listed id'
pi_ok nvidia/meta/muse-glimmer-30b 'a listed id that itself contains a slash is canonical'
pi_ok default 'an omitted model is not checked'
pi_refused meta-muse-spark-1.3-contributor 'no listed model matches it exactly' 'the dash-joined id that bosgame launched is not in the catalog'
pi_refused muse-spark-1.3-contributor 'several authenticated providers (meta/muse-spark-1.3-contributor, opencode-go/muse-spark-1.3-contributor)' 'a bare id Pi itself would call ambiguous refuses and names both providers'
pi_refused meta/muse-spark-9 'provider meta is listed but does not list model muse-spark-9' 'a listed provider missing the id refuses'
pi_refused gpt-6.1-sol:turbo 'no listed model matches it exactly' 'an invalid thinking suffix is part of the id, as in Pi strict CLI parsing'
pi_ok meta/muse-glimmer-30b 'a listed provider prefix falls back to the whole input as a raw id, as Pi resolves it'
out=$(FM_FAKE_PI_DUP_SLASH=1 fm_model_catalog_validate pi "$FAKE/pi" meta/muse-glimmer-30b 2>&1) \
  && fail 'a raw slash id listed under several providers was accepted'
assert_contains "$out" 'several authenticated providers (nvidia/meta/muse-glimmer-30b, openrouter/meta/muse-glimmer-30b)' 'a raw slash id listed under several providers refuses as ambiguous'
pi_refused metaa/nonexistent-model 'provider metaa is not listed' 'a provider-qualified id whose provider is not listed refuses'
pi_refused codex-native/gpt-6-astra 'provider codex-native is not listed' 'an extension provider this launch does not load refuses'
out=$(fm_model_catalog_validate pi "$FAKE/pi" codex-native/gpt-6-astra '' codex-native 2>&1) \
  || fail "the provider this launch's own extension registers must not refuse: $out"
assert_contains "$out" "provider 'codex-native' is registered by this launch's own extension" 'the launch-registered provider launches unvalidated with a notice'
if fm_model_catalog_validate pi "$FAKE/pi" metaa/nonexistent-model '' codex-native 2>/dev/null; then
  fail 'naming one launch provider must not admit a different unlisted provider'
fi
pass "Pi: canonical, bare, case, thinking-suffix, and slash-id matches launch; absent, ambiguous, and unlisted-provider ids refuse unless this launch registers that provider"

# An unavailable, empty, or timed-out listing cannot verify even a model the
# real listing carries, so each refuses rather than launching unverified.
for listing in FM_FAKE_PI_LIST_FAIL FM_FAKE_PI_LIST_EMPTY FM_FAKE_PI_LIST_SLOW; do
  if out=$(export "$listing=1" FM_PI_MODELS_TIMEOUT=1; fm_model_catalog_validate pi "$FAKE/pi" gpt-6.1-sol 2>&1); then
    fail "$listing: an unverifiable Pi listing let 'gpt-6.1-sol' launch: $out"
  fi
  assert_contains "$out" 'so the model is unverified' "$listing: the refusal says the model is unverified"
done
out=$(FM_FAKE_PI_LIST_SLOW=1 FM_PI_MODELS_TIMEOUT=1 fm_model_catalog_validate pi "$FAKE/pi" gpt-6.1-sol 2>&1)
assert_contains "$out" 'did not answer within 1s' 'a timed-out listing names its bound'
if FM_FAKE_PI_LIST_EMPTY=1 fm_model_catalog_validate pi "$FAKE/pi" codex-native/gpt-6-astra '' codex-native 2>/dev/null; then
  fail 'an empty listing must not let even a launch-registered provider through'
fi
FM_FAKE_PI_AGENT_DIR_LOG="$TMP_ROOT/agent-dir" fm_model_catalog_validate pi-signed "$FAKE/pi" gpt-6.1-sol "$TMP_ROOT/pinned" 2>/dev/null \
  || fail 'a pinned Pi-signed listing should accept a listed id'
[ "$(cat "$TMP_ROOT/agent-dir")" = "$TMP_ROOT/pinned" ] \
  || fail "the listing must read the pinned PI_CODING_AGENT_DIR, got $(cat "$TMP_ROOT/agent-dir")"
pass "Pi: an unavailable, empty, or timed-out listing refuses; a pinned root lists its own authentication"

fm_model_catalog_validate opencode "$FAKE/opencode" opencode/muse-spark-1.3-contributor-free 2>/dev/null \
  || fail 'a listed opencode provider/model must launch'
fm_model_catalog_validate opencode "$FAKE/opencode" cat-jam-free 2>/dev/null \
  || fail 'a bare opencode id that is the model part of a listed line must launch'
if out=$(fm_model_catalog_validate opencode "$FAKE/opencode" opencode/cat-jam-free 2>&1); then
  fail 'an opencode provider/model absent from the listing was accepted'
fi
assert_contains "$out" "opencode model 'opencode/cat-jam-free' is not listed" 'the opencode refusal names the id'
if fm_model_catalog_validate opencode "$FAKE/opencode" spark-free 2>/dev/null; then
  fail 'a bare opencode id no listed line carries was accepted'
fi
for listing in FM_FAKE_OPENCODE_LIST_FAIL FM_FAKE_OPENCODE_LIST_EMPTY FM_FAKE_OPENCODE_LIST_SLOW; do
  if out=$(export "$listing=1" FM_OPENCODE_MODELS_TIMEOUT=1; fm_model_catalog_validate opencode "$FAKE/opencode" opencode/muse-spark-1.3-contributor-free 2>&1); then
    fail "$listing: an unverifiable opencode listing let a model launch: $out"
  fi
  assert_contains "$out" 'so the model is unverified' "$listing: the opencode refusal says the model is unverified"
done
fm_model_catalog_validate claude "$FAKE/pi" anything 2>/dev/null || fail 'an uncovered harness must pass'
pass "OpenCode: listed and bare-listed ids launch; unlisted ids and unavailable, empty, or timed-out listings refuse; uncovered harnesses pass"

# --- fm-spawn refuses before any endpoint or record ---------------------------
case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
cp "$FAKE/pi" "$FAKE/opencode" "$fakebin/"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home"
fm_git_worktree "$proj" "$wt" catalog-test

fm_test_spawn_brief "$home" pi-bad
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" pi-bad "$proj" --scout --harness pi --model meta-muse-spark-1.3-contributor 2>&1)
then fail "a Pi model absent from the catalog was spawned: $out"; fi
assert_contains "$out" "pi model 'meta-muse-spark-1.3-contributor' cannot launch" 'the spawn refusal names the model'
assert_absent "$home/state/pi-bad.meta" 'a refused spawn must not write a task record'

fm_test_spawn_brief "$home" oc-bad
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" oc-bad "$proj" --scout --harness opencode --model opencode/not-listed 2>&1)
then fail "an OpenCode model absent from the catalog was spawned: $out"; fi
assert_contains "$out" "opencode model 'opencode/not-listed' is not listed" 'the opencode spawn refusal names the model'
assert_absent "$home/state/oc-bad.meta" 'a refused opencode spawn must not write a task record'

nooc_fakebin=$(make_spawn_fakebin "$case_dir/fake-nooc" claude)
fm_test_spawn_brief "$home" oc-missing
if out=$(PATH="$(dirname "$(command -v bash)"):/usr/bin:/bin"; fm_test_run_spawn "$home" "$wt" "$nooc_fakebin" oc-missing "$proj" --scout --harness opencode --model opencode/cat-jam-free 2>&1)
then fail "an OpenCode model was spawned with no opencode executable to verify it: $out"; fi
assert_contains "$out" "the opencode executable is not on PATH, so model 'opencode/cat-jam-free' cannot be verified" \
  'the spawn refusal names the missing executable'
assert_absent "$home/state/oc-missing.meta" 'an unverifiable opencode spawn must not write a task record'

fm_test_spawn_brief "$home" pi-native-bad
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" pi-native-bad "$proj" --scout --harness pi --model codex-native/gpt-6-astra 2>&1)
then fail "a codex-native model was spawned without the native ultra launch that registers it: $out"; fi
assert_contains "$out" 'provider codex-native is not listed' 'the spawn refusal names the unlisted provider'
assert_absent "$home/state/pi-native-bad.meta" 'a refused native spawn must not write a task record'

fm_test_spawn_brief "$home" pi-native
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" pi-native "$proj" --scout --harness pi --model codex-native/gpt-6-astra --effort ultra 2>&1) \
  || fail "a native ultra launch must pass the provider its own extension registers: $out"
assert_grep 'model=codex-native/gpt-6-astra' "$home/state/pi-native.meta" 'the native model is recorded'

for listing in PI_LIST_FAIL PI_LIST_EMPTY PI_LIST_SLOW OPENCODE_LIST_FAIL OPENCODE_LIST_EMPTY OPENCODE_LIST_SLOW; do
  sid=unverified-$(printf '%s' "$listing" | tr 'A-Z_' 'a-z-')
  case "$listing" in
    PI_*) set -- --harness pi --model gpt-6.1-sol ;;
    *) set -- --harness opencode --model opencode/muse-spark-1.3-contributor-free ;;
  esac
  fm_test_spawn_brief "$home" "$sid"
  if out=$(export "FM_FAKE_$listing=1" FM_PI_MODELS_TIMEOUT=1 FM_OPENCODE_MODELS_TIMEOUT=1
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$sid" "$proj" --scout "$@" 2>&1)
  then fail "$listing: a spawn launched a model its catalog could not verify: $out"; fi
  assert_contains "$out" 'so the model is unverified' "$listing: the spawn refusal says the model is unverified"
  assert_absent "$home/state/$sid.meta" "$listing: an unverified spawn must not write a task record"
done
set --

# A secondmate keeps its pre-catalog launch: its Pi model is never listed, so an
# unreadable catalog cannot refuse it.
sm_home="$case_dir/sm-home"
mkdir -p "$sm_home/bin" "$sm_home/data"
printf '# Firstmate\n' > "$sm_home/AGENTS.md"
printf 'sm-cat\n' > "$sm_home/.fm-secondmate-home"
printf 'charter\n' > "$sm_home/data/charter.md"
git -C "$sm_home" init -q -b main
out=$(FM_FAKE_PI_LIST_FAIL=1 FM_FAKE_PI_LIST_LOG="$case_dir/sm-list.log" \
  fm_test_run_spawn "$home" "$wt" "$fakebin" sm-cat "$sm_home" --harness pi --model gpt-6.1-sol --secondmate 2>&1) || true
assert_absent "$case_dir/sm-list.log" 'a secondmate spawn must not consult the harness catalog'
assert_not_contains "$out" 'so the model is unverified' 'an unreadable catalog must not refuse a secondmate'

fm_test_spawn_brief "$home" pi-good
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" pi-good "$proj" --scout --harness pi --model meta/muse-spark-1.3-contributor 2>&1) \
  || fail "a listed Pi model must spawn: $out"
assert_grep 'model=meta/muse-spark-1.3-contributor' "$home/state/pi-good.meta" 'the accepted model is recorded'
pass "fm-spawn: catalog refusals, including unavailable, empty, and timed-out listings, happen before any record exists; a listed model launches"
