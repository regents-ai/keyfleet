# activegraph 1.13: a fleet's write stays whole

Opened 4 Nov 2026 from the packages-to-latest lane (Sean: "all packages need to be updated").

## State

activegraph stays at 1.10.0. The newest is 1.13.0.

## Reason

From 1.11 the store opens its own transaction on every event. A fleet's accepted write and its
ledger entry are held in one transaction, and a per-event transaction cannot run inside it: 205
of the graph host's 241 tests stop on it. Upstream offers no way to append several events
together.

## Work

Redesign how an accepted write stays whole with a store that commits per event, or get a
several-events append from upstream. Then move to the newest release and run the host's tests
and the full check.

## Done

- activegraph at the newest stable release, with no pin held back.
- A fleet's write and its ledger entry cannot land apart: a crash between them leaves neither,
  or leaves a state the host finishes on restart.
- Full check exit 0, and the release record names the move and its rollback.
