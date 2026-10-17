#!/usr/bin/env bash
# fm-model-catalog-lib.sh - pre-launch model checks against a harness's own
# catalog for ship and scout launches, shared by the launch owner
# (bin/fm-spawn.sh) and bin/fm-control.sh (a relaunch, checked before the old
# agent stops, and launch-check's fallback routes), so every route is judged by
# the exact rule the launch itself would apply. Secondmates are not checked.
#
# A model launches only when a reachable listing verifies it. An unreachable,
# timed-out, or empty listing establishes nothing, so it refuses too: the model
# stays unresolved, and a refused spawn is retried only on a later ordinary
# intake. A harness this library does not cover passes.
#
#   pi, pi-signed  `<executable> --list-models` prints one row per model whose
#                  provider has configured authentication, as
#                  "provider model context ...". Pi's own resolver
#                  (core/model-resolver.js, verified on Pi 1.2.0) matches a
#                  canonical "<provider>/<id>" first, then a "<provider>/<id>"
#                  whose prefix names a known provider, then the whole
#                  input as a raw id (a slash-containing id such as
#                  "meta/<id>" listed under another provider), then a bare
#                  id, and refuses a bare id listed under more than one authenticated
#                  provider. The check requires that exact match, case
#                  insensitively, with an optional ":<thinking>" suffix: a bare
#                  id that is absent, a bare id listed under several providers,
#                  and a "<provider>/<id>" missing from a listed provider and from
#                  every raw id all
#                  refuse, because Pi would stop at its own error and drop the
#                  pane to a shell. A "<provider>/<id>" whose provider the
#                  listing does not know refuses too, unless the caller names
#                  that provider as one this launch's own extension registers
#                  only when it loads (bin/fm-spawn.sh names codex-native for a
#                  native --effort ultra launch); that one passes with a
#                  notice. Pi's partial-name fallback is deliberately
#                  not accepted, so a worker model is always a concrete
#                  catalog id. Under a worker account pin the caller passes the
#                  pinned PI_CODING_AGENT_DIR so the listing reads the same
#                  authentication the launch will use.
#   opencode       `opencode models` prints one "<provider>/<model>" per line.
#                  A provider-qualified id must be listed exactly; a bare id
#                  must be the model part of at least one listed line, and its
#                  provider resolution stays opencode's own.
#
# Bounds: FM_PI_MODELS_TIMEOUT (default 30) and FM_OPENCODE_MODELS_TIMEOUT
# (default 30) seconds, each run stdin-detached through bin/fm-timeout-lib.sh.

FM_MODEL_CATALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_MODEL_CATALOG_LIB_DIR/fm-timeout-lib.sh"

fm_model_catalog_bound() {  # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*|0*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Prints "ok", "launch-provider <provider>", or one refusal reason line, for
# <selector> against the Pi listing rows "<provider> <model>" read on stdin.
fm_model_catalog_pi_match() {  # <selector> [launch-provider]
  awk -v sel="$1" -v lp="${2:-}" '
    function judge(s,   n, i, p, rest, prov_known, hits, ids) {
      s = tolower(s)
      hits = 0
      for (i = 1; i <= n_rows; i++) if (prov[i] "/" id[i] == s) hits++
      if (hits == 1) return "ok"
      p = index(s, "/")
      if (p > 0) {
        rest = substr(s, p + 1)
        prov_known = (substr(s, 1, p - 1) in providers)
        if (prov_known) {
          hits = 0
          for (i = 1; i <= n_rows; i++) if (prov[i] == substr(s, 1, p - 1) && id[i] == rest) hits++
          if (hits == 1) return "ok"
          hits = 0
          for (i = 1; i <= n_rows; i++) if (id[i] == s) hits++
          if (hits == 0) return "provider " substr(s, 1, p - 1) " is listed but does not list model " rest
        }
        hits = 0
        for (i = 1; i <= n_rows; i++) if (id[i] == s) hits++
        if (hits == 0) {
          if (lp != "" && tolower(lp) == substr(s, 1, p - 1)) return "launch-provider " substr(s, 1, p - 1)
          return "provider " substr(s, 1, p - 1) " is not listed"
        }
      }
      ids = ""
      hits = 0
      for (i = 1; i <= n_rows; i++) if (id[i] == s) { hits++; ids = ids (ids == "" ? "" : ", ") prov[i] "/" id[i] }
      if (hits == 1) return "ok"
      if (hits > 1) return "the bare id is listed under several authenticated providers (" ids "); name one as <provider>/<id>"
      return "no listed model matches it exactly"
    }
    NR == 1 && tolower($1) == "provider" { next }
    NF >= 2 { n_rows++; prov[n_rows] = tolower($1); id[n_rows] = tolower($2); providers[tolower($1)] = 1 }
    END {
      if (n_rows == 0) { print "empty"; exit }
      verdict = judge(sel)
      if (verdict != "ok") {
        c = match(sel, /:(off|minimal|low|medium|high|xhigh|max)$/)
        if (c > 0 && judge(substr(sel, 1, c - 1)) == "ok") verdict = "ok"
      }
      print verdict
    }
  '
}

# fm_model_catalog_validate: 0 when <model> may launch on <harness>, 1 (with an
# error line on stderr) when the harness's catalog cannot be read or does not
# verify it.
# <executable> is the resolved harness binary; <pi-agent-dir> is the pinned Pi
# root, or empty for the default one; <launch-provider> is the Pi provider this
# launch's own extension registers at load, or empty when it loads none.
fm_model_catalog_validate() {  # <harness> <executable> <model> [pi-agent-dir] [launch-provider]
  local harness=$1 bin=$2 model=$3 agent_dir=${4:-} launch_provider=${5:-} listing rc=0 bound verdict
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    pi|pi-signed)
      bound=$(fm_model_catalog_bound "${FM_PI_MODELS_TIMEOUT:-}" 30)
      if [ -n "$agent_dir" ]; then
        listing=$(PI_CODING_AGENT_DIR=$agent_dir fm_run_timed "$bound" "$bin" --list-models 2>/dev/null < /dev/null) || rc=$?
      else
        listing=$(fm_run_timed "$bound" "$bin" --list-models 2>/dev/null < /dev/null) || rc=$?
      fi
      verdict=empty
      [ "$rc" -ne 0 ] || verdict=$(printf '%s\n' "$listing" | fm_model_catalog_pi_match "$model" "$launch_provider")
      case "$verdict" in
        ok) return 0 ;;
        launch-provider\ *)
          echo "notice: $harness provider '${verdict#launch-provider }' is registered by this launch's own extension, so it is not in '$harness --list-models'; launching '$model' unvalidated" >&2
          return 0
          ;;
        empty)
          if [ "$rc" -eq 124 ]; then
            echo "error: $harness model '$model' cannot launch: '$harness --list-models' did not answer within ${bound}s, so the model is unverified" >&2
          else
            echo "error: $harness model '$model' cannot launch: '$harness --list-models' listed no models (exit $rc), so the model is unverified" >&2
          fi
          return 1
          ;;
      esac
      echo "error: $harness model '$model' cannot launch: $verdict in '$harness --list-models' (the authenticated catalog); choose a listed <provider>/<id>" >&2
      return 1
      ;;
    opencode)
      bound=$(fm_model_catalog_bound "${FM_OPENCODE_MODELS_TIMEOUT:-}" 30)
      listing=$(fm_run_timed "$bound" "$bin" models 2>/dev/null < /dev/null) || rc=$?
      if [ "$rc" -ne 0 ] || ! printf '%s\n' "$listing" | grep -q /; then
        if [ "$rc" -eq 124 ]; then
          echo "error: opencode model '$model' cannot launch: 'opencode models' did not answer within ${bound}s, so the model is unverified" >&2
        else
          echo "error: opencode model '$model' cannot launch: 'opencode models' listed no models (exit $rc), so the model is unverified" >&2
        fi
        return 1
      fi
      case "$model" in
        */*) printf '%s\n' "$listing" | grep -qxF -- "$model" && return 0 ;;
        *) printf '%s\n' "$listing" | awk -v m="$model" 'index($0, "/") && substr($0, index($0, "/") + 1) == m { found = 1 } END { exit !found }' && return 0 ;;
      esac
      echo "error: opencode model '$model' is not listed by 'opencode models'; choose a listed <provider>/<model>" >&2
      return 1
      ;;
  esac
  return 0
}
