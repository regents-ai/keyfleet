---------------------------- MODULE ActionGuards ----------------------------
(***************************************************************************)
(* The checks one request from a paired agent passes, in order, for each   *)
(* kind of action it can take on Keyfleet (3aa6c79a). One request per run. *)
(* Each check reads one fact about the agent, chosen freely when the check *)
(* runs, and either lets the request on or refuses it with its reason.     *)
(*                                                                         *)
(*   Sign-in   KeyfleetWeb.Plugs.SignedAgent.admit/2: the SIWA receipt     *)
(*             verifies and Agent.authenticated?/1 holds (a smart wallet   *)
(*             counts only on Base).                                       *)
(*   Pairing   Agents.with_pairing/1 finds the wallet's pairing; every     *)
(*             tool below is marked pairing_required in the tool manifest. *)
(*   Standing  Who the agent may act as. Three different rules:            *)
(*             - KeyActor.command/5 (graph/checks/key_actor.ex 189-243)    *)
(*               for a write that names a Key: its own Key; else an active *)
(*               shard of that Key while its wallet owns none of the       *)
(*               fleet's Keys; else its person's Key while it holds no     *)
(*               shard in the fleet.                                       *)
(*             - Fleet membership (Keys.identity/2, Access) for notebooks, *)
(*               pins and polls: any Key it acts as.                       *)
(*             - Keys.held_keys/2 for direct messages and rooms: its own   *)
(*               Keys and every Key it holds a shard of; its person's      *)
(*               Keys only when it has neither.                            *)
(*   Fresh     Chain.fresh?/1: the chain reader is current.                *)
(*   Restrict  KeyActor.unrestricted/3 in the writer, the notebook gateway *)
(*             for every change, the code gateway. Not for pins. Rooms and *)
(*             messages stay open by design (keys/edits_restriction.ex).   *)
(*   Rule      The action's own rule: the graph host's owner check, one    *)
(*             poll vote per Key, a poll ended by its starter, the code    *)
(*             store's pre-receive hook, the project's holder.             *)
(*   Wallet    WalletSteps.Build for the agent's own wallet: standing read *)
(*   steps     at the latest block (wallet_steps/reads.ex 113-149); the    *)
(*             Keys it offers come from the site's record (build.ex        *)
(*             160-169). A blocked step is still returned to an agent,     *)
(*             which may send it; the contract decides.                    *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Actions,  \* subset of AllActions
          Roles,    \* subset of AllRoles
          Wallets,  \* subset of {"eoa_base", "eoa_eth", "smart_base", "smart_eth"}
          Broken    \* "none", or the one check this run removes (run.sh)

AllActions == {"workspace_edit", "workspace_fork", "workspace_pin", "notebook_write",
               "poll_vote", "poll_end", "dm_send", "code_push", "project_delete",
               "chain_ballot", "chain_issue_shard"}

(* The agent's relation to the Key K the request is about.
   own_key              its wallet owns K
   shard                it holds an active shard of K and owns no fleet Key
   shard_owns_other     it holds an active shard of K and its wallet owns
                        another Key of the fleet
   shard_other_key      it holds an active shard of another Key, not of K
   person_key           its person owns K; it holds no shard in the fleet
   person_key_has_shard its person owns K and it holds a shard of another Key
   none                 nothing in the fleet *)
AllRoles == {"own_key", "shard", "shard_owns_other", "shard_other_key",
             "person_key", "person_key_has_shard", "none"}

ShardRoles == {"shard", "shard_owns_other"}

Targets(a) ==
  CASE a = "workspace_edit" -> {"own_item", "other_item"}
    [] a = "workspace_fork" -> {"own_item", "other_item"}
    [] a = "poll_vote"      -> {"first_vote", "second_vote"}
    [] a = "poll_end"       -> {"started_it", "other_started_it"}
    [] a = "code_push"      -> {"adds", "force", "deletes", "moves_tag"}
    [] a = "project_delete" -> {"made_by_this_key", "taken_over"}
    [] a = "chain_ballot"   -> {"record_current", "record_behind"}
    [] OTHER                -> {"plain"}

KeyNamed == {"workspace_edit", "workspace_fork", "code_push", "project_delete"}
Membership == {"workspace_pin", "notebook_write", "poll_vote", "poll_end"}
HeldKeys == {"dm_send"}
WalletSteps == {"chain_ballot", "chain_issue_shard"}
RestrictionApplies ==
  {"workspace_edit", "workspace_fork", "notebook_write", "code_push", "project_delete"}

(* Facts not read yet are "-". *)
VARIABLES
  action, signedIn, wallet, paired, role, fresh, restricted, voting, target,
  phase,    \* where the request is
  reason    \* why it was refused or blocked

vars == <<action, signedIn, wallet, paired, role, fresh, restricted, voting, target,
          phase, reason>>

Counts(w) ==
  IF Broken = "smart_on_ethereum" THEN TRUE
  ELSE w \in {"eoa_base", "eoa_eth", "smart_base"}

(* KeyActor.command: may act as K. *)
ActsAsKey(r) ==
  \/ r \in {"own_key", "shard", "person_key"}
  \/ (Broken = "shard_any_key" /\ r \in {"shard_other_key", "shard_owns_other"})

StandingOk(r) ==
  CASE action \in KeyNamed   -> ActsAsKey(r)
    [] action \in Membership -> r /= "none"
    [] action \in HeldKeys   -> r \in {"own_key", "shard", "shard_owns_other", "person_key"}

(* Who may act for the Key at the latest block: its holder; for a ballot
   also a shard holder while the Key's agent voting is on. The rules use
   this; AuthorizedAtHead is the contract's check of it. *)
MayActAtHead(r, v) ==
  \/ r = "own_key"
  \/ (action = "chain_ballot" /\ r \in ShardRoles /\ v = TRUE)

AuthorizedAtHead(r, v) ==
  \/ MayActAtHead(r, v)
  \/ (Broken = "contract_ignores_voting" /\ action = "chain_ballot" /\ r \in ShardRoles)

(* The Keys the site offers come from its own record; a Key bought or a
   shard received after the reader's last read is not there yet. *)
Offered(t) == t /= "record_behind"

RuleOk(t) ==
  CASE action = "workspace_edit" -> t = "own_item" \/ Broken = "no_owner_check"
    [] action = "workspace_fork" -> t = "own_item" \/ Broken /= "fork_needs_owner"
    [] action = "poll_vote"      -> t = "first_vote"
    [] action = "poll_end"       -> t = "started_it" \/ Broken = "anyone_ends_polls"
    [] action = "code_push"      -> t = "adds" \/ Broken = "hook_allows_rewrites"
    [] OTHER                     -> TRUE

RuleRefusal ==
  CASE action = "workspace_edit" -> "not_owner"
    [] action = "workspace_fork" -> "not_owner"
    [] action = "poll_vote"      -> "vote_conflict"
    [] action = "poll_end"       -> "not_starter"
    [] action = "code_push"      -> "push_refused"
    [] OTHER                     -> "refused"

Init ==
  /\ action \in Actions
  /\ signedIn = "-" /\ wallet = "-" /\ paired = "-" /\ role = "-"
  /\ fresh = "-" /\ restricted = "-" /\ voting = "-" /\ target = "-"
  /\ phase = "sent"
  /\ reason = "none"

Pass(next) == phase' = next /\ UNCHANGED reason
Refuse(why) == phase' = "refused" /\ reason' = why

CheckSignIn ==
  /\ phase = "sent"
  /\ \E s \in BOOLEAN, w \in Wallets :
       /\ signedIn' = s /\ wallet' = w
       /\ IF (s \/ Broken = "no_sign_in_check") /\ Counts(w)
            THEN Pass("signed_in") ELSE Refuse("signed_out")
  /\ UNCHANGED <<action, paired, role, fresh, restricted, voting, target>>

CheckPairing ==
  /\ phase = "signed_in"
  /\ \E p \in BOOLEAN :
       /\ paired' = p
       /\ IF p \/ Broken = "no_pairing_check"
            THEN Pass(IF action \in WalletSteps THEN "built" ELSE "paired")
            ELSE Refuse("not_paired")
  /\ UNCHANGED <<action, signedIn, wallet, role, fresh, restricted, voting, target>>

CheckStanding ==
  /\ phase = "paired"
  /\ \E r \in Roles :
       /\ role' = r
       /\ IF StandingOk(r) THEN Pass("stands") ELSE Refuse("not_a_key_holder")
  /\ UNCHANGED <<action, signedIn, wallet, paired, fresh, restricted, voting, target>>

CheckFresh ==
  /\ phase = "stands"
  /\ \E f \in BOOLEAN :
       /\ fresh' = f
       /\ IF f \/ Broken = "no_fresh_check"
            THEN Pass("fresh") ELSE Refuse("ownership_refreshing")
  /\ UNCHANGED <<action, signedIn, wallet, paired, role, restricted, voting, target>>

(* Every action carries the Key's restriction; only some read it. *)
CheckRestriction ==
  /\ phase = "fresh"
  /\ \E x \in BOOLEAN :
       /\ restricted' = x
       /\ IF action \notin RestrictionApplies \/ ~x \/ Broken = "no_restriction_check"
            THEN Pass("unrestricted") ELSE Refuse("edits_restricted")
  /\ UNCHANGED <<action, signedIn, wallet, paired, role, fresh, voting, target>>

(* The action's own rule. A poll vote also carries the Key's agent voting
   switch, which no poll check reads, so the rules can ask about it. *)
CheckRule ==
  /\ phase = "unrestricted"
  /\ \E t \in Targets(action), v \in BOOLEAN :
       /\ target' = t
       /\ voting' = IF action = "poll_vote" THEN v ELSE "-"
       /\ IF RuleOk(t) THEN Pass("allowed") ELSE Refuse(RuleRefusal)
  /\ UNCHANGED <<action, signedIn, wallet, paired, role, fresh, restricted>>

(* Wallet steps: the head read decides whether the step is handed over or
   blocked with its reason. *)
ReadHead ==
  /\ phase = "built"
  /\ \E r \in Roles, v \in BOOLEAN, t \in Targets(action) :
       /\ role' = r /\ voting' = v /\ target' = t
       /\ IF (AuthorizedAtHead(r, v) \/ Broken = "steps_ignore_head") /\ Offered(t)
            THEN Pass("handed_over")
            ELSE /\ phase' = "blocked"
                 /\ reason' = IF ~Offered(t) THEN "no_keys" ELSE "not_your_key"
  /\ UNCHANGED <<action, signedIn, wallet, paired, fresh, restricted>>

(* The agent sends the step, a blocked one too; the contract decides. *)
ContractRuns ==
  /\ phase \in {"handed_over", "blocked"}
  /\ phase' = IF AuthorizedAtHead(role, voting) /\ Offered(target) THEN "landed" ELSE "reverted"
  /\ UNCHANGED <<action, signedIn, wallet, paired, role, fresh, restricted, voting, target, reason>>

Done ==
  /\ phase \in {"allowed", "refused", "landed", "reverted"}
  /\ UNCHANGED vars

Next ==
  \/ CheckSignIn \/ CheckPairing \/ CheckStanding \/ CheckFresh
  \/ CheckRestriction \/ CheckRule \/ ReadHead \/ ContractRuns \/ Done

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Rules                                                                   *)
(***************************************************************************)

Through == phase \in {"allowed", "handed_over", "landed"}

TypeOK ==
  /\ action \in AllActions
  /\ role \in AllRoles \cup {"-"}
  /\ phase \in {"sent", "signed_in", "paired", "stands", "fresh", "unrestricted",
                "allowed", "refused", "built", "handed_over", "blocked",
                "landed", "reverted"}

(* An unpaired or signed-out agent gets nothing through. *)
NoWriteWithoutPairing == Through => (signedIn = TRUE /\ paired = TRUE)

(* A smart wallet counts only on Base. *)
SmartWalletOnlyOnBase == Through => wallet \in {"eoa_base", "eoa_eth", "smart_base"}

(* A shard gives rights only for its own Key. *)
ShardOnlyForItsKey ==
  (Through /\ action \in KeyNamed \cup WalletSteps) => role /= "shard_other_key"

(* Agent voting off: a shard holder's ballot never lands. *)
AgentVotingOffStopsBallots ==
  (action = "chain_ballot" /\ phase = "landed" /\ role \in ShardRoles) => voting = TRUE

(* The same for the fleet's polls (expected to break: no poll check reads
   the agent voting switch, polls/checks/standing.ex). *)
AgentVotingOffStopsPollVotes ==
  (action = "poll_vote" /\ phase = "allowed" /\ role \in ShardRoles) => voting = TRUE

(* Group work: nobody changes another Key's item; anyone may fork it. *)
NobodyChangesAnotherKeysItem ==
  (action = "workspace_edit" /\ phase = "allowed") => target = "own_item"
AnyoneMayFork ==
  (action = "workspace_fork" /\ phase = "refused")
    => reason \in {"signed_out", "not_paired", "not_a_key_holder",
                   "ownership_refreshing", "edits_restricted"}

(* Restricted Keys are read-only in notebooks. *)
RestrictedReadOnlyInNotebooks ==
  (action = "notebook_write" /\ phase = "allowed") => restricted = FALSE

(* A restricted Key adds nothing to the workspace (expected to break on
   pins: graph/pin.ex 77-85 checks no restriction). *)
RestrictedAddsNothingToWorkspace ==
  (action \in {"workspace_edit", "workspace_fork", "workspace_pin"} /\ phase = "allowed")
    => restricted = FALSE

(* The code store only adds: no force push, no delete, no moved tag. *)
CodeStoreOnlyAdds == (action = "code_push" /\ phase = "allowed") => target = "adds"

(* Only the Key that started a poll ends it. *)
PollEndOnlyByStarter == (action = "poll_end" /\ phase = "allowed") => target = "started_it"

(* No Key-based right while the chain reader is behind. *)
NothingWhileReaderBehind == phase = "allowed" => fresh = TRUE

(* Wallet steps are handed over, and land, only for whoever the chain says
   holds or governs the Key at the latest block. *)
WalletStepsOnlyForHolder ==
  (action \in WalletSteps /\ phase \in {"handed_over", "landed"})
    => MayActAtHead(role, voting)

(* Rule 11: a press is withheld only when the chain's own state says it
   fails (expected to break: the offered Keys come from the site's record). *)
BlockedOnlyWhenChainSaysNo == phase = "blocked" => ~MayActAtHead(role, voting)

(* A Key deletes only projects it made (expected to break: take over, then
   delete, is the design in docs/plans/2026-10-26-projects-inside-a-fleet.md). *)
OnlyOwnProjectsDeleted ==
  (action = "project_delete" /\ phase = "allowed") => target = "made_by_this_key"

(* Messages follow the workspace's rule for who acts as a Key (expected to
   break: Keys.held_keys/2 lets a wallet that owns a Key also act as a Key
   it holds a shard of; KeyActor says never as a shard). *)
MessagesFollowWorkspaceRule ==
  (action = "dm_send" /\ phase = "allowed") => role /= "shard_owns_other"
=============================================================================
