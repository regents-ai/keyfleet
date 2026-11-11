---------------------------- MODULE PairingLife ----------------------------
(***************************************************************************)
(* The life of one agent wallet's pairing on Keyfleet, the Key a person    *)
(* puts it on, and one protected write the agent sends while the pairing   *)
(* changes.                                                                *)
(*                                                                         *)
(* Code it describes (Keyfleet 9de7fc8c, elixir-utils d89c69df):           *)
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
(*   Commit    The write commits. Every database write an agent makes      *)
(*             takes Authority.lock/4 on the pairing row inside its        *)
(*             transaction and holds it until commit (UseLock = TRUE):     *)
(*             RegentAgents.RequirePairing on rooms, direct messages,      *)
(*             polls, mutes, agent profiles, check-ins, pins, the posting  *)
(*             Key, wall removal, checkpoints and proposal words, and      *)
(*             KeyActor.held_command/5 or hold_pairing/1 on project steps, *)
(*             publications and notebook locks (0001d1f7). A workspace     *)
(*             graph write (Keyfleet.Graph.Writer) checks with             *)
(*             KeyActor.command/5 and sends to the graph host without      *)
(*             holding a transaction across the call (f67913e6), so an     *)
(*             unpair can commit between Recheck and Commit                *)
(*             (UseLock = FALSE): finding F1, still open for these writes. *)
(*   Answer    A signed request is answered as committed. Over MCP,        *)
(*             McpAgent.recheck/2 reads the pairing again before the       *)
(*             answer leaves and replaces it with agent_not_paired if the  *)
(*             pairing ended or changed hands, so no answer carries the    *)
(*             former person's data.                                       *)
(*   Place     Keys.AgentKey :assign (PutAgent): only the signed-in person *)
(*             puts an agent on one of their Keys, and only an agent       *)
(*             paired to them; no agent route places one (565ab08e). The   *)
(*             row keeps the pairing's id, and every reader matches it     *)
(*             against the wallet's current pairing (Keys.assigned_keys/3, *)
(*             agents_on_keys/2), so an unpair takes the agent off every   *)
(*             Key as it commits. Which Key, and whether it still stands   *)
(*             after a transfer, is ShardLife's and ActionGuards' part.    *)
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
NoPlacement == [by |-> "none", episode |-> 0]
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
  placement,  \* the agent_keys row: who put the agent on a Key, under which pairing
  write       \* the agent's one protected write

vars == <<wallet, code, codeUses, row, episodes, receipt, placement, write>>

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
  /\ placement = NoPlacement
  /\ write = NoWrite

PersonMakesCode(p) ==
  /\ Live
  /\ code[p] /= "issued"
  /\ code' = [code EXCEPT ![p] = "issued"]
  /\ codeUses' = [codeUses EXCEPT ![p] = 0]
  /\ UNCHANGED <<wallet, row, episodes, receipt, placement, write>>

CodeRunsOut(p) ==
  /\ Live
  /\ code[p] = "issued"
  /\ code' = [code EXCEPT ![p] = "expired"]
  /\ UNCHANGED <<wallet, codeUses, row, episodes, receipt, placement, write>>

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
  /\ UNCHANGED <<wallet, receipt, placement, write>>

(* The row is left as it is: readers match its pairing id against the
   wallet's current pairing. *)
PersonUnpairs ==
  /\ Live
  /\ row /= NoRow
  /\ ~(UseLock /\ write.phase = "checked")
  /\ row' = NoRow
  /\ UNCHANGED <<wallet, code, codeUses, episodes, receipt, placement, write>>

(* PutAgent locks the agent's current pairing with the person who writes;
   a wallet not paired to them now is agent_unknown. *)
PersonPlaces(p) ==
  /\ Live
  /\ row /= NoRow
  /\ (row.owner = p \/ Broken = "place_others_agent")
  /\ placement' = [by |-> p, episode |-> row.episode]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt, write>>

SignInRunsOut ==
  /\ Live
  /\ receipt = "valid"
  /\ receipt' = "expired"
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, placement, write>>

AgentSignsInAgain ==
  /\ Live
  /\ receipt = "expired"
  /\ receipt' = "valid"
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, placement, write>>

AgentSends(s) ==
  /\ write.phase = "not_sent"
  /\ write' = IF /\ (receipt = "valid" \/ Broken = "no_sign_in_check")
                   /\ Counts
                   /\ (row /= NoRow \/ Broken = "no_pairing_check")
                THEN [NoWrite EXCEPT !.phase = "admitted", !.surface = s,
                        !.episode = row.episode, !.owner = row.owner,
                        !.paired = row /= NoRow, !.signedIn = receipt = "valid"]
                ELSE [NoWrite EXCEPT !.phase = "refused", !.surface = s]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt, placement>>

Recheck ==
  /\ write.phase = "admitted"
  /\ write' = IF \/ (row.episode = write.episode /\ row.owner = write.owner)
                   \/ Broken = "no_recheck"
                THEN [write EXCEPT !.phase = "checked"]
                ELSE [write EXCEPT !.phase = "refused"]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt, placement>>

Commit ==
  /\ write.phase = "checked"
  /\ write' = [write EXCEPT !.phase = "committed",
                            !.landed = (row.episode = write.episode)]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt, placement>>

Answer ==
  /\ write.phase = "committed"
  /\ LET changed == row.episode /= write.episode \/ row.owner /= write.owner
         replaced == write.surface = "mcp" /\ changed /\ Broken /= "no_mcp_recheck"
     IN write' = [write EXCEPT !.phase = "answered",
                    !.answer = IF replaced THEN "not_paired" ELSE "written",
                    !.carries = IF replaced THEN "none"
                                ELSE IF changed THEN "former_person"
                                ELSE "same_person"]
  /\ UNCHANGED <<wallet, code, codeUses, row, episodes, receipt, placement>>

Done ==
  /\ write.phase \in {"answered", "refused"}
  /\ UNCHANGED vars

Next ==
  \/ \E p \in People : PersonMakesCode(p) \/ CodeRunsOut(p) \/ AgentPairs(p)
  \/ PersonUnpairs
  \/ \E p \in People : PersonPlaces(p)
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
  /\ placement = NoPlacement
       \/ (placement.by \in People /\ placement.episode \in 1..MaxEpisodes)
  /\ receipt \in {"valid", "expired"}
  /\ write.phase \in {"not_sent", "admitted", "checked", "committed", "answered", "refused"}

Admitted == write.phase \in {"admitted", "checked", "committed", "answered"}

(* An agent that is not paired, or whose sign-in ran out, gets no write in. *)
NoWriteWithoutPairing == Admitted => (write.paired /\ write.signedIn)

(* A smart wallet counts only when it signed in on Base. *)
SmartWalletOnlyOnBase == Admitted => wallet \in {"eoa_base", "eoa_eth", "smart_base"}

(* Each code pairs at most once, and only before it runs out. *)
CodeSingleUse == \A p \in People : codeUses[p] <= 1

(* No write is saved after the person's unpair was saved. Holds for every
   database write (UseLock = TRUE); breaks for a workspace graph write
   (open finding F1). *)
NoWriteAfterUnpair == write.phase \in {"committed", "answered"} => write.landed

(* Over MCP, an answer never carries the person's data once the pairing has
   ended or moved to someone else (the promise in McpAgent's moduledoc; the
   REST path under /api/v1/agent makes no such promise and has no recheck). *)
NoFormerPersonDataInAnswer ==
  write.surface = "mcp" => write.carries /= "former_person"

(* A paired wallet moves to another person or pairing only through an
   unpair first. *)
OnePairingAtATime == [][row /= NoRow /\ row' /= NoRow => row' = row]_vars

(* Whether the agent is on the Key it was put on, as every reader asks it:
   the row's pairing id is the wallet's current pairing. *)
OnAKey ==
  /\ placement /= NoPlacement
  /\ row /= NoRow
  /\ (placement.episode = row.episode \/ Broken = "placement_outlives_pairing")

(* An agent is on a Key only while it is paired to the person who put it
   there: never by someone else's say, and never once unpaired, even if it
   pairs again later, with that person or another. *)
OnKeyOnlyForItsPerson == OnAKey => placement.by = row.owner /\ placement.episode = row.episode
=============================================================================
