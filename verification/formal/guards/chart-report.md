# ActionGuards

TLC reached 449 states and 700 steps. The chart draws 17 states and 21 arrows.
The view hides 262 steps, so the chart does not draw them.

## BlockedOnlyWhenChainSaysNo breaks
The shortest path has 3 steps:
0. Sent
1. the agent signs in: Signed in
2. its pairing is found [wallet step]: Wallet step built
3. the site's record has no Key for it yet: Blocked

## Rules that hold
TypeOK, NoWriteWithoutPairing, SmartWalletOnlyOnBase, ShardOnlyForItsKey, PersonKeysOnlyAsLastResort, AgentVotingOffStopsBallots, AgentVotingOffStopsPollVotes, NobodyChangesAnotherKeysItem, AnyoneMayFork, RestrictedReadOnlyInNotebooks, RestrictedAddsNothingToWorkspace, CodeStoreOnlyAdds, PollEndOnlyByStarter, NothingWhileReaderBehind, WalletStepsOnlyForHolder, OnlyOwnProjectsDeleted, MessagesFollowWorkspaceRule, NoDeadlock
