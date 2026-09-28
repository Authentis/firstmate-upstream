#!/usr/bin/env bash
# fm-leaf-supply.sh - report dispatchable FILES-scoped beads leaves.
#
# Usage: fm-leaf-supply.sh <repo-path> [--repository owner/repo]
#                           [--plan-below <count>] [--check <leaf-id>]
#
# A dispatchable leaf is an open, non-epic `br ready --json` row with a FILES:
# declaration, no matching merged pull request whose declared files are on
# origin/main, and no open pull request that names the leaf or touches one of
# its declared files.  `br ready` is the dependency gate, so an open
# blocks-deps relationship never appears in this report.  The script prints a
# count and ids.  `--plan-below N` reports when planning is due and prints the
# exact suggested spawn command; it never starts a lane itself.
#
# `--check` is the spawn preflight interface.  It exits 0 only when its one
# named leaf is dispatchable and exits 10 when the leaf is unavailable.
set -eu
export LC_ALL=C

usage() {
  sed -n '2,/^set -eu/{/^set -eu/!p}' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-leaf-supply: %s\n' "$1" >&2; exit 1; }

repo_path=
repository=
plan_below=
check_id=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repository) [ "$#" -ge 2 ] || die '--repository requires owner/repo'; repository=$2; shift 2 ;;
    --plan-below) [ "$#" -ge 2 ] || die '--plan-below requires a whole number'; plan_below=$2; shift 2 ;;
    --check) [ "$#" -ge 2 ] || die '--check requires a leaf id'; check_id=$2; shift 2 ;;
    --*) die "unknown argument: $1" ;;
    *) [ -z "$repo_path" ] || die 'only one repo path is accepted'; repo_path=$1; shift ;;
  esac
done
[ -n "$repo_path" ] || die 'repo path is required'
[ -d "$repo_path" ] || die "repo path is unavailable: $repo_path"
case "$plan_below" in ''|*[!0-9]*) [ -z "$plan_below" ] || die '--plan-below must be a whole number' ;; esac
case "$check_id" in ''|[A-Za-z0-9]*[A-Za-z0-9._-]) ;; *) die 'invalid leaf id for --check' ;; esac

for tool in br gh-axi git jq base64; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

if [ -z "$repository" ]; then
  origin_url=$(git -C "$repo_path" ls-remote --get-url origin 2>/dev/null) \
    || die 'could not resolve origin; pass --repository owner/repo'
  case "$origin_url" in
    https://github.com/*.git) repository=${origin_url#https://github.com/}; repository=${repository%.git} ;;
    https://github.com/*) repository=${origin_url#https://github.com/} ;;
    git@github.com:*.git) repository=${origin_url#git@github.com:}; repository=${repository%.git} ;;
    git@github.com:*) repository=${origin_url#git@github.com:} ;;
    ssh://git@github.com/*/*.git) repository=${origin_url#ssh://git@github.com/}; repository=${repository%.git} ;;
    ssh://git@github.com/*/*) repository=${origin_url#ssh://git@github.com/} ;;
    *) die 'origin is not a GitHub repository; pass --repository owner/repo' ;;
  esac
fi
case "$repository" in [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) ;; *) die '--repository must be owner/repo' ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-leaf-supply.XXXXXX") || die 'could not make scratch directory'
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
ready="$tmp/ready.json"
prs="$tmp/prs.json"
(cd "$repo_path" && br ready --json --no-auto-flush --no-auto-import) > "$ready" || die 'br ready failed'
jq -e 'type == "array"' "$ready" >/dev/null || die 'br ready returned invalid JSON'

unwrap_gh_json() {
  local raw=$1 body
  if jq -e 'type == "array"' "$raw" >/dev/null 2>&1; then cat "$raw"; return 0; fi
  grep -Fxq '  truncated: false' "$raw" || return 1
  body=$(sed -n 's/^  body: //p' "$raw")
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | jq -r .
}

raw_prs="$tmp/prs.raw"
gh-axi api --full --paginate "/repos/$repository/pulls?state=all&per_page=100" > "$raw_prs" || die 'pull request verification failed'
unwrap_gh_json "$raw_prs" > "$prs" || die 'pull request verification returned invalid JSON'
jq -e 'type == "array"' "$prs" >/dev/null || die 'pull request verification returned invalid JSON'

pr_names_leaf() {
  local pr=$1 id=$2 words
  words=$(printf '%s' "$pr" | jq -r '(.title // "") + " " + (.head.ref // "")') || return 1
  printf '%s\n' "$words" | tr -cs 'A-Za-z0-9._-' '\n' | grep -Fxq -- "$id"
}

pr_files() {
  local number=$1 raw
  raw="$tmp/pr-$number.raw"
  gh-axi api --full --paginate "/repos/$repository/pulls/$number/files?per_page=100" > "$raw" || return 1
  unwrap_gh_json "$raw" | jq -r '.[]?.filename // empty'
}

files_intersect_pr() {
  local files=$1 number=$2 changed
  changed=$(pr_files "$number") || return 2
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    grep -Fxq -- "$changed_file" "$files" && return 0
  done <<EOF
$changed
EOF
  return 1
}

id_landed_on_main() {
  local id=$1 files=$2 pr merged file
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    merged=$(printf '%s' "$pr" | jq -r '.merged_at // empty')
    [ -n "$merged" ] || continue
    pr_names_leaf "$pr" "$id" || continue
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      git -C "$repo_path" cat-file -e "origin/main:$file" 2>/dev/null && return 0
    done < "$files"
  done < <(jq -c '.[]' "$prs")
  return 1
}

id_has_open_pr() {
  local id=$1 files=$2 pr number merged state rc
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    state=$(printf '%s' "$pr" | jq -r '.state // empty')
    [ "$state" = open ] || continue
    merged=$(printf '%s' "$pr" | jq -r '.merged_at // ""')
    [ -z "$merged" ] || continue
    pr_names_leaf "$pr" "$id" && return 0
    number=$(printf '%s' "$pr" | jq -r '.number // empty')
    [ -n "$number" ] || continue
    if files_intersect_pr "$files" "$number"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 1 ] || return 2
  done < <(jq -c '.[]' "$prs")
  return 1
}

dispatchable="$tmp/dispatchable"
: > "$dispatchable"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  leaf=$(printf '%s' "$row" | base64 --decode 2>/dev/null || true)
  id=$(printf '%s' "$leaf" | jq -r '.id // empty')
  state=$(printf '%s' "$leaf" | jq -r '.status // empty')
  kind=$(printf '%s' "$leaf" | jq -r '.issue_type // empty')
  description=$(printf '%s' "$leaf" | jq -r '.description // .body // empty')
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  [ "$state" = open ] && [ "$kind" != epic ] || continue
  files="$tmp/$id.files"
  printf '%s\n' "$description" | sed -n 's/^[[:space:]]*FILES:[[:space:]]*//p' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' > "$files"
  [ -s "$files" ] || continue
  id_landed_on_main "$id" "$files" && continue
  if id_has_open_pr "$id" "$files"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] && continue
  [ "$rc" -eq 1 ] || die "could not verify open pull requests for $id"
  printf '%s\n' "$id" >> "$dispatchable"
done < <(jq -r '.[] | @base64' "$ready")

if [ -n "$check_id" ]; then
  if grep -Fxq -- "$check_id" "$dispatchable"; then printf 'dispatchable: %s\n' "$check_id"; exit 0; fi
  printf 'refused: %s is not dispatchable (merged, open PR, missing FILES, or unmet dependencies)\n' "$check_id"
  exit 10
fi

count=$(wc -l < "$dispatchable" | tr -d '[:space:]')
printf 'dispatchable: %s\n' "$count"
cat "$dispatchable"
if [ -n "$plan_below" ]; then
  if [ "$count" -lt "$plan_below" ]; then
    printf 'planning: due (%s < %s)\n' "$count" "$plan_below"
    printf 'spawn command: bin/fm-spawn.sh leaf-supply-plan <project> --mode no-mistakes --yolo off\n'
  else
    printf 'planning: not due (%s >= %s)\n' "$count" "$plan_below"
  fi
fi
