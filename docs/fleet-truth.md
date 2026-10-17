# Fleet truth: the status probe and the order ledger

Two small per-host tools keep fleet reports checkable.
The status probe records what a host can observe about its PRs, lanes, and gates, and the order ledger carries orders to a secondmate through a file it polls.

## Status probe

`bin/fm-status-probe.sh` atomically replaces `state/status.json` (schema `fm-status-probe.v1`) in a home.
Its header owns the field list and the exact meaning of each field.
In short:

- `prs[]` reports each PR with `merged` true only when the forge names a merge commit and the compare API shows that commit on the default branch tip, so a closed-unmerged PR reads false.
- `lanes[]` reports each lane's recorded pid and log, with `state` live only when the pid is alive and the log was written in the last 5 minutes.
- `gate_waits[]` lists running no-mistakes runs parked at a gate, parsed from `no-mistakes axi status --run <id>`.
- `sources` says whether `gh` and `no-mistakes` answered; a section whose source is not ok proves nothing.

Lane records are `key=value` files: `state/lanes/<id>.lane`, or a `state/<id>.meta` that carries `pid=` or `log=`.

Install the 5-minute timer on a host with `bin/fm-status-probe.sh timer install --home <home>`, which uses launchd on macOS and a systemd user timer elsewhere.

### Reporting rule

A status or report claim about a PR, a lane, or a gate wait must quote the matching `status.json` field: the section, the key, and the value.
A claim with no matching field is not counted.
A claim whose section has a source that is not ok is not counted either.
Secondmate and firstmate reports follow this rule.

## Order ledger

`bin/fm-order-ledger.sh` keeps one append-only `state/orders.jsonl` per secondmate home, with ids that rise by one.
The secondmate polls it every 60 seconds (`timer install` wires that) and acknowledges an order by its line id.
An order stays pending, and visible through `pending` and `state/orders.pending`, until its own id is acknowledged.
No terminal doorbell or window ring is anywhere in the path, so a failed ring cannot hide an order.
The script header owns the commands and file formats.

## Canary

Roll each tool out to the bosgame secondmate home first and then netcup, and change no live home until the canary passes.
