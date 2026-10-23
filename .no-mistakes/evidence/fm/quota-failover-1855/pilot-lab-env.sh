# Sourced by the quota-failover sandbox pilot. Every path is inside the lab.
# The lab is a disposable mktemp home marked by bin/fm-lab-home.sh; the mate is
# an invented id on a private tmux server (TMUX_TMPDIR inside the lab), and
# every agent binary on PATH is a compiled fake that never contacts a provider.
L=/private/tmp/fm-lab.S3NMwZ
SM=/private/tmp/fm-lab-sm.cJGXWw/smhome
WT=~/.no-mistakes/worktrees/0d3d213d42f1/01M5NA34SBKCZZAPDKCEWC1J2H
ID=qf-lab-mate
SES=fmlab
for v in $(env | sed -n 's/^\(FM_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR
export FM_HOME="$L" FM_STATE_OVERRIDE="$L/state" FM_CONFIG_OVERRIDE="$L/config"
export STATE="$L/state"
export TMUX_TMPDIR="$L/tmux"
export HOME="$L/user-home" GROK_HOME="$L/user-home/.grok"
export FAKE_DIR="$L/fake"
export PATH="$L/fakebin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export FM_BACKEND=tmux
lt() { tmux "$@"; }   # TMUX_TMPDIR above points tmux at the lab's private server only
