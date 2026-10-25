# Bosgame remote delivery contract

Leaf delivery and cloud pickup delivery use the v3 transport contract. A send
is delivered when the receiver reply contains an anchored line beginning
`replied` or `sent`, and the complete reply has no error marker (`must start`,
`not sent`, `error`, `denied`, `refused`, `fail`, `unknown`, or `timeout`).

Delivery does not wait for an owner receipt grammar. A missing receipt must not
prevent transport, create `reconcile-required.txt`, or turn a positive
acknowledgment into a failure. The successful send records the normal `sent`
ledger row and exits zero; a ledger-append warning does not undo delivery.

A later receipt verifier may be added as an optional observer, disabled by
default. It may report or record receipt evidence after delivery, but it must
never replace the acknowledgment rule, block a positive delivery, or alter the
delivery exit status.

## Busy doorbell: durably recorded counts as delivered

A busy receiver may answer `fm-ring: doorbell refused ... the steer stays
durably recorded at .../N.msg`. That message is delivered (the doorbell rings
later), so `bosgame-leaf-send.sh`, `cloud-pickup-send.sh` and
`bosgame-plan-send.sh` accept it even though the reply carries the word
`refused`, record `delivered.rec` beside the task, and never resend it. A
`refused` reply with no durable record stays a failure.

On every acceptance each sender prints its own positive line anchored at the
start of a line, `sent <id> ...`, and exits zero. Callers decide on the exit
status and that line, not on the transport's prose.
