#!/usr/bin/env bash
# Role-specific engineering-habits text for the opt-in `--habits` switch of
# bin/fm-brief.sh. Sourced, never run. Each function prints one brief section
# for exactly one worker role, so a ship never reads the scout text and a
# secondmate charter never takes either. The text maps five habits (smallest
# change, blast radius, context discipline, verification, role isolation) onto
# the worker contract that already exists and restates none of it: the proof-row
# levels stay owned by fm_dod_proof_block in bin/fm-dod-lib.sh, and the status,
# inbox, and isolation-assertion rules stay owned by bin/fm-brief.sh.
# Heredocs here stay outside command substitutions (Bash 3.2 parse safety).

fm_brief_habits_ship() {
  cat <<'EOF2'
# Engineering habits
These shape how you build and prove the change.
Every other section of this brief takes precedence, and nothing here adds a review pass, an extra validation run, or a waiting step.

1. **Smallest logical change.** Before editing, write one line naming what the task needs and what stays out.
   Subtract before you add: delete dead code or reuse an existing path before writing a new one, and add no guard, option, or fallback the task does not need.
2. **Blast radius.** Before the first edit, grep for the callers, consumers, and tests of what you will change.
   Note in one line the single fact that makes the change safe for them; if you cannot name one, narrow the change.
3. **Context discipline.** Map the surrounding system only when the change crosses into another part of it (a module, process, schema, or public interface).
   Otherwise write one line saying why the change is local and read only the files it touches and their direct callers.
4. **Verification.** Done needs a real artifact: the output of a command you ran on the real surface, or a local verifier you can rerun.
   A compile, type check, or passing unit test is support, and a check on the wrong surface or an inconclusive one is not a pass; say so plainly.
   Label what you state about behavior as measured (you ran it), inferred, or guessed, and let the proof rows under Definition of done carry the level.
5. **Role isolation.** You are a ship worker: your branch in your disposable worktree is the only thing you change.
   Do not run fleet commands (spawn, send, teardown, merge), do not take a scout's report deliverable, and do not treat a Firstmate supervisor contract as your job description.

Load a play only when the task is of that kind:
- A bug: reproduce it yourself before changing code, and show the same reproduction passing after the change.
- A refactor: pin current behavior with a test or recorded output before moving structure; a type check or lint is not a pin.
EOF2
}

fm_brief_habits_scout() {
  cat <<'EOF2'
# Engineering habits
These shape how you investigate and report.
Every other section of this brief takes precedence, and nothing here adds a review pass, an extra run, or a waiting step.

1. **Smallest logical answer.** Before digging, write one line naming the question and what is out of scope.
   Subtract before you add: report what the evidence shows rather than a survey of everything nearby.
2. **Blast radius.** For every change you recommend, name what else depends on the code it touches and the one fact that makes it safe.
3. **Context discipline.** Map the surrounding system only when the question crosses into another part of it (a module, process, schema, or public interface).
   Otherwise write one line saying why the question is local and read only what it touches.
4. **Verification.** Every finding in the report cites a real artifact: command output you ran, a `file:line`, or a commit.
   Label each claim measured (you ran it), inferred, or guessed, and report an unanswerable question as unknown with what you searched.
5. **Role isolation.** You are a scout: the report and the status file are your only writes outside the worktree.
   Make no branch for delivery, push nothing, open no PR, run no fleet commands, and do not promote yourself to a ship; firstmate decides that.
EOF2
}
