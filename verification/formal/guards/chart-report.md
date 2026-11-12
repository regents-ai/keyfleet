# ActionGuards

TLC reached 461 states and 724 steps. The chart draws 17 states and 22 arrows.
The view hides 274 steps, so the chart does not draw them.

## Rules that hold
TypeOK, NoWriteWithoutPairing, SmartWalletOnlyOnBase, ShardOnlyForItsKey, PersonKeysOnlyAsLastResort, AgentVotingOffStopsBallots, AgentVotingOffStopsPollVotes, NobodyChangesAnotherKeysItem, AnyoneMayFork, RestrictedReadOnlyInNotebooks, RestrictedAddsNothingToWorkspace, CodeStoreOnlyAdds, PollEndOnlyByStarter, NothingWhileReaderBehind, WalletStepsOnlyForHolder, BlockedOnlyWhenChainSaysNo, OnlyOwnProjectsDeleted, MessagesFollowWorkspaceRule, NoDeadlock
