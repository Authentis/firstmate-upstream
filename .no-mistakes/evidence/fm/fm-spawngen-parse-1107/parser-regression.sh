#!/usr/bin/env bash
set -eu
ROOT=$PWD
TMP=$(mktemp -d "$PWD/.parser-regression.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# Old product code is materialized only inside the worktree, never installed.
git show 2809c3462e31490b481cfa30e760d9a7c2fa8885:bin/fm-pr-lib.sh > "$TMP/base-pr-lib.sh"
URL=https://github.com/a/b/pull/1
HEAD=0123456789abcdef0123456789abcdef01234567
printf 'pr=%s\npr_head=%s\nspawn_gen=3\n' "$URL" "$HEAD" > "$TMP/meta"
for version in base target; do
 if [ "$version" = base ]; then lib="$TMP/base-pr-lib.sh"; expected=1; else lib="$ROOT/bin/fm-pr-lib.sh"; expected=0; fi
 set +e
 bash -c '. "$1"; fm_pr_metadata_identity_parse "$2"; rc=$?; printf "%s parser: exit=%s identity=%s\n" "$3" "$rc" "$FM_PR_META_URL"; exit "$rc"' bash "$lib" "$TMP/meta" "$version"
 rc=$?
 set -e
 [ "$rc" -eq "$expected" ] || exit 1
done
