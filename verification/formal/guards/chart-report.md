# ActionGuards

TLC reached 376 states and 582 steps. The chart draws 17 states and 21 arrows.
The view hides 217 steps, so the chart does not draw them.

## BlockedOnlyWhenChainSaysNo breaks
The shortest path has 3 steps:
0. Sent
1. the agent signs in: Signed in
2. its pairing is found [wallet step]: Wallet step built
3. the site's record has no Key for it yet: Blocked

## MessagesFollowWorkspaceRule breaks
The shortest path has 6 steps:
0. Sent
1. the agent signs in: Signed in
2. its pairing is found: Paired
3. it acts as the Key: Acts as the Key
4. the chain reading is current: Reading current
5. no restriction check [pins, polls, messages]: Edits open
6. the action's own rule allows it: Message sent

## AgentVotingOffStopsPollVotes breaks
The shortest path has 6 steps:
0. Sent
1. the agent signs in: Signed in
2. its pairing is found: Paired
3. it acts as the Key: Acts as the Key
4. the chain reading is current: Reading current
5. no restriction check [pins, polls, messages]: Edits open
6. the action's own rule allows it: Poll vote counted

## OnlyOwnProjectsDeleted breaks
The shortest path has 6 steps:
0. Sent
1. the agent signs in: Signed in
2. its pairing is found: Paired
3. it acts as the Key: Acts as the Key
4. the chain reading is current: Reading current
5. the Key's edits are open: Edits open
6. the action's own rule allows it: Project deleted

## RestrictedAddsNothingToWorkspace breaks
The shortest path has 6 steps:
0. Sent
1. the agent signs in: Signed in
2. its pairing is found: Paired
3. it acts as the Key: Acts as the Key
4. the chain reading is current: Reading current
5. no restriction check [pins, polls, messages]: Edits open
6. the action's own rule allows it: Pin saved

## Rules that hold
TypeOK, NoWriteWithoutPairing, SmartWalletOnlyOnBase, ShardOnlyForItsKey, AgentVotingOffStopsBallots, NobodyChangesAnotherKeysItem, AnyoneMayFork, RestrictedReadOnlyInNotebooks, CodeStoreOnlyAdds, PollEndOnlyByStarter, NothingWhileReaderBehind, WalletStepsOnlyForHolder, NoDeadlock
