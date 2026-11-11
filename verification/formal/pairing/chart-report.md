# PairingLife

TLC reached 246 states and 656 steps. The chart draws 11 states and 18 arrows.
The chart does not draw 336 steps that stay in one chart state.
The view hides 110 steps, so the chart does not draw them.

## NoWriteAfterUnpair breaks
The shortest path has 6 steps:
0. Not paired
1. the person makes a pairing code: Code waiting
2. the agent pairs with the code: Paired
3. the agent sends a write: Being checked
4. the second check finds the same pairing: Cleared to save
5. the person unpairs the agent: Cleared, then unpaired
6. the write is saved: Saved after unpair

## Rules that hold
TypeOK, NoWriteWithoutPairing, SmartWalletOnlyOnBase, CodeSingleUse, NoFormerPersonDataInAnswer, OnKeyOnlyForItsPerson, NoDeadlock, OnePairingAtATime
