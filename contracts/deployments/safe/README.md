# The Regents Safe's Classic #1 files: review note

`base.founding-fleet-1.json` and `base.phase-2.json` are written by `make classic-fork-run`
(`KeyfleetSafeSteps` on a local fork of Base's latest block), carried out there through the real
Regents Safe (`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, its owners' approvals, then
`execTransaction`), and left here unsigned; the run's transcript, `docs/runs/classic-fork-run.md`,
holds the fork block, the Safe transactions and everything bought and voted after them. Sign them
in this order and only with your go on opening Classic. `base.founding-fleet-1.json` is one call to
the factory, `createFoundingFleet(2, 0xe9b1900adb56811096d08f67852af8a64ec509ed2982e94f14f172f687b577e7, 1000, ("Classic #1", "", ""))`:
type Fleet.Tech Classic, the shipped 1,000-card deck, 1,024 Keys from 10 to 100 USDC, 10% to
REGENT staking and 90% turned into REGENT for the treasury, about 11.8 million gas; it opens
nothing, and it stays valid until Classic #1 exists. `base.phase-2.json` is one call to the Key
collection, `advancePhase(opensAt)`, which opens Classic #1's sales at `opensAt`; the collection
refuses it unless it lands before that moment and no more than 30 days before it, so a file written
with the rehearsal's own opening time (the transcript says which) can no longer land and must be
written again with your opening time (`KEYFLEET_OPENS_AT`, in [deployment.md](../../../docs/deployment.md#step-6-phases))
and simulated again before you sign it. Neither adds the collection to the randomness
subscription: Keys 1 to 1,000 hold their cards by number and draw nothing, and Keys past 1,000 wait
in Revealing until the Safe adds it, which the 900-sold alert asks for in time.
