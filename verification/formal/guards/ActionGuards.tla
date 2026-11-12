---------------------------- MODULE ActionGuards ----------------------------
(***************************************************************************)
(* The checks one request from a paired agent passes, in order, for each   *)
(* kind of action it can take on Keyfleet (9de7fc8c). One request per run. *)
(* Each check reads one fact about the agent, chosen freely when the check *)
(* runs, and either lets the request on or refuses it with its reason.     *)
(*                                                                         *)
(*   Sign-in   KeyfleetWeb.Plugs.SignedAgent.admit/2: the SIWA receipt     *)
(*             verifies and Agent.authenticated?/1 holds (a smart wallet   *)
(*             counts only on Base).                                       *)
(*   Pairing   Agents.with_pairing/1 finds the wallet's pairing; every     *)
(*             tool below is marked pairing_required in the tool manifest. *)
(*   Standing  Who the agent may act as. Two rules:                        *)
(*             - Keys.agent_keys/3, the one rule for a write that names a  *)
(*               Key (KeyActor.command/5: workspace, code, projects) and   *)
(*               for direct messages and rooms (Keys.held_keys/2): its     *)
(*               own Keys alone; else the Key its person put it on         *)
(*               (Keys.AgentKey, while placed_on?/3) and every Key it      *)
(*               holds an active shard of; else its person's Keys.         *)
(*             - Fleet membership (Keys.identity/2, Access) for notebooks, *)
(*               pins and polls: the first of those it has.                *)
(*   Fresh     Chain.fresh?/1: the chain reader is current.                *)
(*   Restrict  The Key's edits restriction: the graph writer, pins         *)
(*             (Graph.Validations.Unrestricted), the notebook gateway for  *)
(*             every change, the code gateway, projects. Rooms, messages   *)
(*             and polls stay open by design (keys/edits_restriction.ex).  *)
(*   Rule      The action's own rule: the graph host's owner check, one    *)
(*             poll vote per Key and a vote cast through a shard only      *)
(*             while the Key's agent voting is on                          *)
(*             (Polls.Validations.AgentVoting), a poll ended by its        *)
(*             starter, the code store's pre-receive hook, a project       *)
(*             deleted only by the Key that started it (Hold, 12 Nov).     *)
(*   Wallet    WalletSteps.Build for the agent's own wallet: standing read *)
(*   steps     at the latest block (wallet_steps/reads.ex). The Keys it    *)
(*             offers are the site's record and those one chain read finds *)
(*             reached the wallet since the record's last block            *)
(*             (Build.own_keys/3, 12 Nov); when that read fails, nothing   *)
(*             is blocked for want of a Key and the agent is told the      *)
(*             chain can't be read (AgentChainController, 503). A blocked  *)
(*             step is still returned to an agent, which may send it; the  *)
(*             contract decides.                                           *)
(*                                                                         *)
(* Putting an agent on a Key is not an agent's action: only the signed-in  *)
(* person places, moves or removes one, and only an agent paired to them   *)
(* (Keys.AgentKey :assign and :release; PairingLife models it). An agent   *)
(* on a Key acts for it without a shard; marking present, voting and       *)
(* claiming on the chain still need its own Key or a shard.                *)
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
   shard                it holds an active shard of K, owns no fleet Key and
                        is on no Key
   shard_owns_other     it holds an active shard of K and its wallet owns
                        another Key of the fleet
   shard_other_key      it holds an active shard of another Key, not of K,
                        owns no fleet Key and is on no Key
   placed               its person put it on K, which they still hold and
                        which has not changed hands since; it owns no fleet Key
   placed_other         its person put it on another Key and also holds K;
                        it owns no fleet Key and holds no shard
   person_key           its person holds K; it holds no shard in the fleet
                        and is on no Key
   person_key_has_shard its person holds K and it holds a shard of another Key
   none                 nothing in the fleet *)
AllRoles == {"own_key", "shard", "shard_owns_other", "shard_other_key", "placed",
             "placed_other", "person_key", "person_key_has_shard", "none"}

(* Roles whose chain rights come from a shard of K. *)
ShardRoles == {"shard", "shard_owns_other"}

(* Roles whose poll vote is cast through a shard: Keys.identity/2 finds
   neither a Key of its own nor a Key it was put on, but a shard. *)
ShardVoters == {"shard", "shard_other_key", "person_key_has_shard"}

Targets(a) ==
  CASE a = "workspace_edit" -> {"own_item", "other_item"}
    [] a = "workspace_fork" -> {"own_item", "other_item"}
    [] a = "poll_vote"      -> {"first_vote", "second_vote"}
    [] a = "poll_end"       -> {"started_it", "other_started_it"}
    [] a = "code_push"      -> {"adds", "force", "deletes", "moves_tag"}
    [] a = "project_delete" -> {"made_by_this_key", "taken_over"}
    [] a = "chain_ballot"   -> {"record_current", "record_behind", "read_failed"}
    [] OTHER                -> {"plain"}

KeyNamed == {"workspace_edit", "workspace_fork", "code_push", "project_delete"}
Membership == {"workspace_pin", "notebook_write", "poll_vote", "poll_end"}
HeldKeys == {"dm_send"}
WalletSteps == {"chain_ballot", "chain_issue_shard"}
RestrictionApplies ==
  {"workspace_edit", "workspace_fork", "workspace_pin", "notebook_write", "code_push",
   "project_delete"}

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

(* Keys.agent_keys/3: may act as K. *)
ActsAsKey(r) ==
  \/ r \in {"own_key", "shard", "placed", "person_key"}
  \/ (Broken = "shard_any_key" /\ r \in {"shard_other_key", "shard_owns_other"})
  \/ (Broken = "placed_any_key" /\ r = "placed_other")
  \/ (Broken = "person_key_with_shard" /\ r = "person_key_has_shard")

(* Messages ask the same rule; "messages_own_rule" gives them the one the
   code had before 0001d1f7, which let a Key's owner also act as a shard. *)
ActsAsKeyInMessages(r) ==
  \/ ActsAsKey(r)
  \/ (Broken = "messages_own_rule" /\ r = "shard_owns_other")

StandingOk(r) ==
  CASE action \in KeyNamed   -> ActsAsKey(r)
    [] action \in Membership -> r /= "none"
    [] action \in HeldKeys   -> ActsAsKeyInMessages(r)

(* Who may act for the Key at the latest block: its holder; for a ballot
   also a shard holder while the Key's agent voting is on. The rules use
   this; AuthorizedAtHead is the contract's check of it. *)
MayActAtHead(r, v) ==
  \/ r = "own_key"
  \/ (action = "chain_ballot" /\ r \in ShardRoles /\ v = TRUE)

AuthorizedAtHead(r, v) ==
  \/ MayActAtHead(r, v)
  \/ (Broken = "contract_ignores_voting" /\ action = "chain_ballot" /\ r \in ShardRoles)

(* For a ballot, K's place in the site's record.
   record_current  the record has K
   record_behind   K reached the wallet after the record's last block, and
                   the chain read since that block finds it
   read_failed     K reached the wallet after the record's last block, and
                   the chain doesn't answer that read *)
Answered(t) == t /= "read_failed"

(* The Keys the site offers: its record and those the chain read finds.
   "record_only_keys" offers the record's alone, as before 12 Nov. *)
Offered(t) ==
  /\ Answered(t)
  /\ (t = "record_behind" => Broken /= "record_only_keys")

(* A poll vote cast through a shard counts only while agent voting is on. *)
VotingOk(v) ==
  action /= "poll_vote" \/ role \notin ShardVoters \/ v = TRUE
  \/ Broken = "polls_ignore_voting"

RuleOk(t) ==
  CASE action = "workspace_edit" -> t = "own_item" \/ Broken = "no_owner_check"
    [] action = "workspace_fork" -> t = "own_item" \/ Broken /= "fork_needs_owner"
    [] action = "poll_vote"      -> t = "first_vote"
    [] action = "poll_end"       -> t = "started_it" \/ Broken = "anyone_ends_polls"
    [] action = "code_push"      -> t = "adds" \/ Broken = "hook_allows_rewrites"
    [] action = "project_delete" -> t = "made_by_this_key" \/ Broken = "takeover_deletes"
    [] OTHER                     -> TRUE

RuleRefusal ==
  CASE action = "workspace_edit" -> "not_owner"
    [] action = "workspace_fork" -> "not_owner"
    [] action = "poll_vote"      -> "vote_conflict"
    [] action = "poll_end"       -> "not_starter"
    [] action = "code_push"      -> "push_refused"
    [] action = "project_delete" -> "not_creator"
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
       /\ IF \/ action \notin RestrictionApplies
             \/ ~x
             \/ Broken = "no_restriction_check"
             \/ (Broken = "pin_ignores_restriction" /\ action = "workspace_pin")
            THEN Pass("unrestricted") ELSE Refuse("edits_restricted")
  /\ UNCHANGED <<action, signedIn, wallet, paired, role, fresh, voting, target>>

(* The action's own rule. A poll vote also reads the Key's agent voting
   switch when it is cast through a shard. *)
CheckRule ==
  /\ phase = "unrestricted"
  /\ \E t \in Targets(action), v \in BOOLEAN :
       /\ target' = t
       /\ voting' = IF action = "poll_vote" THEN v ELSE "-"
       /\ IF ~VotingOk(v)
            THEN Refuse("agent_voting_off")
          ELSE IF RuleOk(t) THEN Pass("allowed") ELSE Refuse(RuleRefusal)
  /\ UNCHANGED <<action, signedIn, wallet, paired, role, fresh, restricted>>

(* Wallet steps: the head read decides whether the step is handed over or
   blocked with its reason. When the chain doesn't answer which Keys reached
   the wallet, an agent is told it can't be read, and asks again. *)
ReadHead ==
  /\ phase = "built"
  /\ \E r \in Roles, v \in BOOLEAN, t \in Targets(action) :
       /\ role' = r /\ voting' = v /\ target' = t
       /\ IF ~Answered(t)
            THEN Refuse("chain_unavailable")
          ELSE IF (AuthorizedAtHead(r, v) \/ Broken = "steps_ignore_head") /\ Offered(t)
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

(* An agent its person put on a Key acts as that Key, not as the person's
   other Keys; an agent with a shard acts as the shard, not as its person. *)
PersonKeysOnlyAsLastResort ==
  (Through /\ action \in KeyNamed \cup HeldKeys)
    => role \notin {"placed_other", "person_key_has_shard"}

(* Agent voting off: a shard holder's ballot never lands. *)
AgentVotingOffStopsBallots ==
  (action = "chain_ballot" /\ phase = "landed" /\ role \in ShardRoles) => voting = TRUE

(* The same for the fleet's polls: a vote cast through a shard counts only
   while the Key's agent voting is on (F3, fixed in 0001d1f7). *)
AgentVotingOffStopsPollVotes ==
  (action = "poll_vote" /\ phase = "allowed" /\ role \in ShardVoters) => voting = TRUE

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

(* A restricted Key adds nothing to the workspace, pins included (F5, fixed
   in 0001d1f7). *)
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

(* Messages follow the workspace's rule for who acts as a Key: a wallet that
   owns a Key never acts as a Key it holds a shard of (F6, fixed in
   0001d1f7: both ask Keys.agent_keys/3). *)
MessagesFollowWorkspaceRule ==
  (action = "dm_send" /\ phase = "allowed") => role /= "shard_owns_other"

(* Rule 11: a press is withheld only when the chain's own state says it
   fails, so a Key bought or a shard received within the reader's lag is
   offered (F4, fixed 12 Nov 2026, Sean's 3b: Build.own_keys/3 reads the
   chain from the record's last block). *)
BlockedOnlyWhenChainSaysNo == phase = "blocked" => ~MayActAtHead(role, voting)

(* A Key deletes only projects it started, never one it took over (F2, fixed
   12 Nov 2026, Sean's 2a: Hold's creator check and the :deleted filter). *)
OnlyOwnProjectsDeleted ==
  (action = "project_delete" /\ phase = "allowed") => target = "made_by_this_key"
=============================================================================
