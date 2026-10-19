#!/usr/bin/env bash
# Usage: diff-and-adversarial.sh <worktree> <lab-with-fixed-receiver> <evidence-dir>
set -u
WT=$1; L=$2; EV=$3
T=$(mktemp -d /tmp/fm-lab.XXXXXX)
items() { # <rev> <name>: the inherited item list as the real lib emits it at <rev>
  mkdir -p "$T/$2"
  git -C "$WT" archive "$1" bin | tar -x -C "$T/$2"
  env -u FM_INHERITABLE_CONFIG bash -c ". '$T/$2/bin/fm-config-inherit-lib.sh'; fm_config_inherit_items" | sort
}
items origin/main sender > "$T/s"
items 'dce97aca^' recvbefore > "$T/rb"
items HEAD recvafter > "$T/ra"
{
  echo "primary sender (origin/main $(git -C "$WT" rev-parse --short origin/main)) items: $(wc -l < "$T/s" | tr -d ' ')"
  echo "pre-fix fork receiver (6ec6910c, after PR #21) items: $(wc -l < "$T/rb" | tr -d ' ')"
  echo "fixed fork receiver (dce97aca) items: $(wc -l < "$T/ra" | tr -d ' ')"
  echo "-- in sender, missing from pre-fix receiver:"; comm -23 "$T/s" "$T/rb"
  echo "-- in pre-fix receiver, missing from sender:"; comm -13 "$T/s" "$T/rb"
  echo "-- sender vs fixed receiver:"; diff "$T/s" "$T/ra" && echo "(identical)"
} > "$EV/sender-receiver-diff.txt" 2>&1
cat "$EV/sender-receiver-diff.txt"
echo

R=$L/recv-root/bin/fm-remote-inherit.sh; H=$L/remote-home
E=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
X=$(printf 'x\n' | shasum -a 256 | cut -c1-64)
rx() { env -i PATH=/usr/bin:/bin FM_HOME="$H" bash "$R" "$@"; }
exists() { [ -e "$H/config/firstmate-role" ] && echo yes || echo no; }
{
  echo "== absent config/firstmate-role (primary removed it; removal propagates)"
  rx absent config/firstmate-role 0 "$E" 8; echo "exit=$? file-exists=$(exists)"
  echo "== put config/not-inherited (must refuse)"
  printf 'x\n' | rx put config/not-inherited 2 "$X" 9; echo "exit=$?"
  echo "== put config/../config/firstmate-role (traversal spelling must refuse)"
  printf 'x\n' | rx put config/../config/firstmate-role 2 "$X" 9; echo "exit=$?"
  echo "== put data/firstmate-role (wrong directory must refuse)"
  printf 'x\n' | rx put data/firstmate-role 2 "$X" 9; echo "exit=$?"
  echo "== put config/firstmate-role with bytes not matching digest commitment (must refuse)"
  printf 'evil\n' | rx put config/firstmate-role 5 "$X" 10; echo "exit=$? file-exists=$(exists)"
} > "$EV/adversarial-receiver.txt" 2>&1
cat "$EV/adversarial-receiver.txt"
rm -rf "$T"
