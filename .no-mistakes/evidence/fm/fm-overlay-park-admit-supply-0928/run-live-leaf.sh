#!/usr/bin/env bash
set -eu
ROOT=/home/holu/.no-mistakes/worktrees/74707b8d4eb3/01M3KX5JJV97HQAM41SFEK6TMT
E=/home/holu/.no-mistakes/evidence/01M3KX5JJV97HQAM41SFEK6TMT/live-leaf-supply.log
: > "$E"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { rm -rf "$LAB" || true; }
trap cleanup EXIT
PROJ="$LAB/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.name "Live Leaf Lab"
git -C "$PROJ" config user.email "live-leaf-lab@example.invalid"
printf '# leaf lab\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md && git -C "$PROJ" commit -qm initial
(
  cd "$PROJ"
  br init --prefix live --no-auto-flush --no-auto-import >/dev/null
  ID=$(br create --title 'live leaf supply check' --type task --description 'FILES: src/live-leaf.txt' --silent --no-auto-flush --no-auto-import)
  printf 'created leaf: %s\n' "$ID"
  "$ROOT/bin/fm-leaf-supply.sh" "$PROJ" --repository Authentis/firstmate-upstream --plan-below 14
) > "$E" 2>&1
cat "$E"
