---------------------------- MODULE PairingLife ----------------------------
(***************************************************************************)
(* The life of one agent wallet's pairing on Keyfleet, and one protected   *)
(* write the agent sends while the pairing changes.                        *)
(*                                                                         *)
(* Code it describes (Keyfleet 3aa6c79a, elixir-utils 4e527975):           *)
(*   code      RegentAgents.PairingCode (used_at, expires_at). The person  *)
(*             makes it on their Agents page.                              *)
(*   row       regent_agents.paired_agents, identity :unique_wallet: one   *)
(*             row per wallet. Its id is the pairing "episode".            *)
(*   Pair      RegentAgents.PairedAgent.Actions.Pair.run/3: one            *)
(*             transaction that locks the code row, needs it unused and    *)
(*             unexpired, makes the row and spends the code.               *)
(*   Unpair    PairedAgent :unpair (destroy). Only the person.             *)
(*   Send      KeyfleetWeb.Plugs.SignedAgent.admit/2 (also the signed      *)
(*             path of McpAgent): the SIWA receipt verifies,               *)
(*             Agent.authenticated?/1 (a smart wallet counts only on       *)
(*             Base), then Agents.with_pairing/1 must find a row.          *)
(*   Recheck   Keys.identity/2 -> Agent.refresh/1 inside the Ash policy:   *)
(*             same episode and same person, or refused.                   *)
(*   Commit    The write commits. Writes that carry the change             *)
(*             RegentAgents.RequirePairing take Authority.lock/4 on the    *)
(*             pairing row inside their transaction and hold it until      *)
(*             commit (UseLock = TRUE): rooms, direct messages, polls,     *)
(*             mutes, agent profiles and check-ins. Writes without it only *)
(*             re-read the pairing, so an unpair can commit between        *)
(*             Recheck and Commit (UseLock = FALSE): workspace items,      *)
(*             projects, publications, pins, Key wall removal, the posting *)
(*             Key, checkpoints and proposal words.                        *)
(*   Answer    A signed request is answered as committed. Over MCP,        *)
(*             McpAgent.recheck/2 reads the pairing again before the       *)
(*             answer leaves and replaces it with agent_not_paired if the  *)
(*             pairing ended or changed hands, so no answer carries the    *)
(*             former person's data.                                       *)
(*                                                                         *)
(* One write per run: once it is answered or refused nothing else moves.  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS People,       \* people who could pair this wallet
          MaxEpisodes,  \* bound on pairings in one run
          Surfaces,     \* subset of {"signed", "mcp"}
          Wallets,      \* subset of {"eoa_base", "eoa_eth", "smart_base", "smart_eth"}
          UseLock,      \* TRUE: the write holds Authority.lock/4 until commit
          Broken        \* "none", or the one check this run removes (run.sh)

NoRow == [owner |-> "none", episode |-> 0]
NoWrite == [phase |-> "not_sent", surface |-> "none", episode |-> 0, owner |-> "none",
            paired |-> FALSE, signedIn |-> FALSE,
            landed |-> FALSE, answer |-> "none", carries |-> "none"]

VARIABLES
  wallet,     \* kind of wallet and the chain it signed in on
  code,       \* person -> "none" | "issued" | "used" | "expired"
  codeUses,   \* person -> pairings made with the person's current code
  row,        \* NoRow or [owner, episode]
  episodes,   \* pairing ids used so far
  receipt,    \* "valid" | "expired": the agent's SIWA sign-in
  write       \* the agent's one protected write

vars == <<wallet, code, codeUses, row, episodes, receipt, write>>

(* Agent.authenticated?/1: an EOA counts on Ethereum or Base, a smart
   wallet (ERC-1271, ERC-6492, connected app) only on Base. *)
Counts ==
  IF Broken = "smart_on_ethereum" THEN TRUE
  ELSE wallet \in {"eoa_base", "eoa_eth", "smart_base"}

Live == write.phase \in {"not_sent", "admitted", "checked", "committed"}

Init ==
  /\ wallet \in Wallets
  /\ code = [p \in People |-> "none"]
  /\ codeUses = [p \in People |-> 0]
  /\ row = NoRow
  /\ episodes = 0
  /\ receipt = "valid"
  /\ write = NoWrite

PersonMakesCode(p) ==
  /\ Live
  /\ code[p] /= "issued"
  /\ code' = [code EXCEPT ![p] = "issued"]
  /\ codeUses' = [codeUses EXCEPT ![p] = 0]
  /\ UNCHANGED <<wallet, row, episodes, receipt, write>>

CodeRunsOut(p) ==
  /\ Live
  /\ code[p] = "issued"
  /\ code' = [code EXCEPT ![p] = "expired"]
  /\ UNCHANGED <<wallet, codeUses, row, episodes, receipt, write>>

AgentPairs(p) ==
  /\ Live
  /\ code[p] = "issued"
  /\ (row = NoRow \/ Broken = "pair_over_row")
  /\ receipt = "valid"
  /\ episodes < MaxEpisodes
  /\ episodes' = episodes + 1
  /\ row' = [owner |-> p, episode |-> episodes + 1]
  /\ code' = [code EXCEPT ![p] = IF Broken = "code_reused" THEN "issued" ELSE "used"]
  /\ codeUses' = [codeUses EXCEPT ![p] = @ + 1]
  /\ UNCHANGED <<wallet, receipt, write>>

PersonUnpairs ==
  /\ Live
  /\ row /= NoRow
  /\ ~(UseLock /\ write.phase = "checked")
  /\ row' = NoRow
  /\ UNCHANGED <<wallet, code, codeUses, episodes, receipt, write>>

SignInRunsOut ==
  /\ Live
  /\ receipt = "valid"
  /\ receipt' = "expired"
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, write>>

AgentSignsInAgain ==
  /\ Live
  /\ receipt = "expired"
  /\ receipt' = "valid"
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, write>>

AgentSends(s) ==
  /\ write.phase = "not_sent"
  /\ write' = IF /\ (receipt = "valid" \/ Broken = "no_sign_in_check")
                   /\ Counts
                   /\ (row /= NoRow \/ Broken = "no_pairing_check")
                THEN [NoWrite EXCEPT !.phase = "admitted", !.surface = s,
                        !.episode = row.episode, !.owner = row.owner,
                        !.paired = row /= NoRow, !.signedIn = receipt = "valid"]
                ELSE [NoWrite EXCEPT !.phase = "refused", !.surface = s]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt>>

Recheck ==
  /\ write.phase = "admitted"
  /\ write' = IF \/ (row.episode = write.episode /\ row.owner = write.owner)
                   \/ Broken = "no_recheck"
                THEN [write EXCEPT !.phase = "checked"]
                ELSE [write EXCEPT !.phase = "refused"]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt>>

Commit ==
  /\ write.phase = "checked"
  /\ write' = [write EXCEPT !.phase = "committed",
                            !.landed = (row.episode = write.episode)]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt>>

Answer ==
  /\ write.phase = "committed"
  /\ LET changed == row.episode /= write.episode \/ row.owner /= write.owner
         replaced == write.surface = "mcp" /\ changed /\ Broken /= "no_mcp_recheck"
     IN write' = [write EXCEPT !.phase = "answered",
                    !.answer = IF replaced THEN "not_paired" ELSE "written",
                    !.carries = IF replaced THEN "none"
                                ELSE IF changed THEN "former_person"
                                ELSE "same_person"]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt>>

Done ==
  /\ write.phase \in {"answered", "refused"}
  /\ UNCHANGED vars

Next ==
  \/ \E p \in People : PersonMakesCode(p) \/ CodeRunsOut(p) \/ AgentPairs(p)
  \/ PersonUnpairs
  \/ SignInRunsOut
  \/ AgentSignsInAgain
  \/ \E s \in Surfaces : AgentSends(s)
  \/ Recheck
  \/ Commit
  \/ Answer
  \/ Done

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Rules                                                                   *)
(***************************************************************************)

TypeOK ==
  /\ wallet \in {"eoa_base", "eoa_eth", "smart_base", "smart_eth"}
  /\ row = NoRow \/ (row.owner \in People /\ row.episode \in 1..MaxEpisodes)
  /\ receipt \in {"valid", "expired"}
  /\ write.phase \in {"not_sent", "admitted", "checked", "committed", "answered", "refused"}

Admitted == write.phase \in {"admitted", "checked", "committed", "answered"}

(* An agent that is not paired, or whose sign-in ran out, gets no write in. *)
NoWriteWithoutPairing == Admitted => (write.paired /\ write.signedIn)

(* A smart wallet counts only when it signed in on Base. *)
SmartWalletOnlyOnBase == Admitted => wallet \in {"eoa_base", "eoa_eth", "smart_base"}

(* Each code pairs at most once, and only before it runs out. *)
CodeSingleUse == \A p \in People : codeUses[p] <= 1

(* No write is saved after the person's unpair was saved. *)
NoWriteAfterUnpair == write.phase \in {"committed", "answered"} => write.landed

(* Over MCP, an answer never carries the person's data once the pairing has
   ended or moved to someone else (the promise in McpAgent's moduledoc; the
   REST path under /api/v1/agent makes no such promise and has no recheck). *)
NoFormerPersonDataInAnswer ==
  write.surface = "mcp" => write.carries /= "former_person"

(* A paired wallet moves to another person or pairing only through an
   unpair first. *)
OnePairingAtATime == [][row /= NoRow /\ row' /= NoRow => row' = row]_vars
=============================================================================
