----------------------------- MODULE ShardLife -----------------------------
(***************************************************************************)
(* One shard of Key k1 given to agent wallet A, and one write A sends as a *)
(* Key, while the shard ends, runs out, or k1 changes hands on the chain,  *)
(* and the site reads the chain behind it.                                 *)
(*                                                                         *)
(* Code it describes (Keyfleet 3aa6c79a):                                  *)
(*   chain     the fleet's contract: the Key's owner issues or ends a      *)
(*             shard, the shard's wallet may end it, a transfer moves the  *)
(*             Key and starts a new ownership epoch.                       *)
(*   recorded  what Keyfleet.Chain.Scanner wrote: key_attachments (owner,  *)
(*             ownership_epoch) and Keyfleet.Keys.ShardEvent rows (system  *)
(*             only, never changed or deleted).                            *)
(*   Read      Keyfleet.Chain.ReadFleet / Scanner: records chain events in *)
(*             order, sets observed_at and next_block on the cursor.       *)
(*   Fresh     Keyfleet.Chain.Cursor :fresh?: observed within              *)
(*             @fresh_seconds (420) and next_block within @fresh_blocks    *)
(*             (3,000) of the head. Here S and B ticks.                    *)
(*   Check     Keyfleet.Graph.Checks.KeyActor.command/5 -> authority/4:    *)
(*             fresh_reading, then standing: the wallet owns the Key, or   *)
(*             (owning none of the fleet's Keys) holds an active shard of  *)
(*             THIS Key (Keys.active_shard/4, ShardEvent :active?:         *)
(*             issued, expires_at > now(), ownership_epoch == current,     *)
(*             latest record), or else is paired with the Key's owner and  *)
(*             holds no active shard in the fleet (paired_holding/3).      *)
(*             Agents are checked on every request; nothing is cached for  *)
(*             them (CodeGateway.current_holder/3, NotebookGateway.admit). *)
(*   Commit    the write is saved. No lock holds the recorded shard or Key *)
(*             between Check and Commit.                                   *)
(*                                                                         *)
(* A write is checked and saved within one tick: no tick passes between.   *)
(* One write per run: once it is saved or refused nothing else moves.      *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS S,          \* ticks a reading stays fresh after it was taken
          B,          \* ticks the record may trail the head and stay fresh
          Life,       \* ticks a shard lasts
          MaxTime,    \* last tick in a run
          ReadsAll,   \* TRUE: each reading records everything pending (chart only)
          Writes,     \* FALSE: leave the agent's write out (chart only)
          Broken      \* "none", or the one check this run removes (run.sh)

Keys == {"k1", "k2"}
Owners == {"O1", "O2"}
PersonWallets == {"O2"}   \* A is paired with the person whose wallet is O2
Never == MaxTime + 1   \* endedAt before the right ends
NoShard == [status |-> "none", key |-> "none", epoch |-> 0, expires |-> 0]

VARIABLES
  now,          \* the clock, in ticks
  chainOwner,   \* Key -> owner on the chain
  chainEpoch,   \* Key -> ownership epoch on the chain
  chainShard,   \* A's shard on the chain
  endedAt,      \* tick the shard's right ended on the chain (end or move), or Never
  pending,      \* chain events not yet recorded, oldest first, with their tick
  recOwner,     \* recorded owner
  recEpoch,     \* recorded epoch
  recShard,     \* recorded latest shard row for (k1, A)
  observedAt,   \* tick of the last reading
  behindAt,     \* ticks the record trailed the head at that reading
  moves,        \* Key moves so far
  write         \* A's one write

vars == <<now, chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
          recEpoch, recShard, observedAt, behindAt, moves, write>>

NoWrite == [phase |-> "not_sent", asKey |-> "none", via |-> "none",
            anyShardAtCheck |-> FALSE, shardExpires |-> 0, epochCurrent |-> FALSE,
            atCommitActive |-> FALSE, endedAge |-> 0, chainActiveAtCommit |-> FALSE]

Live == write.phase \in {"not_sent", "checked"}

Init ==
  /\ now = 0
  /\ chainOwner = [k \in Keys |-> IF k = "k1" THEN "O1" ELSE "O2"]
  /\ chainEpoch = [k \in Keys |-> 1]
  /\ chainShard = NoShard
  /\ endedAt = Never
  /\ pending = <<>>
  /\ recOwner = chainOwner
  /\ recEpoch = chainEpoch
  /\ recShard = NoShard
  /\ observedAt = 0
  /\ behindAt = 0
  /\ moves = 0
  /\ write = NoWrite

(* --- the chain ---------------------------------------------------------- *)

OwnerIssuesShard ==
  /\ Live
  /\ chainShard.status = "none"
  /\ chainShard' = [status |-> "issued", key |-> "k1", epoch |-> chainEpoch["k1"],
                    expires |-> now + Life]
  /\ pending' = Append(pending, [kind |-> "shard", shard |-> chainShard', at |-> now])
  /\ UNCHANGED <<now, chainOwner, chainEpoch, endedAt, recOwner, recEpoch, recShard,
                 observedAt, behindAt, moves, write>>

(* The Key's owner or the shard's wallet ends the shard. *)
ShardEnds ==
  /\ Live
  /\ chainShard.status = "issued"
  /\ chainShard' = [chainShard EXCEPT !.status = "ended"]
  /\ endedAt' = IF endedAt = Never THEN now ELSE endedAt
  /\ pending' = Append(pending, [kind |-> "shard", shard |-> chainShard', at |-> now])
  /\ UNCHANGED <<now, chainOwner, chainEpoch, recOwner, recEpoch, recShard,
                 observedAt, behindAt, moves, write>>

KeyMoves ==
  /\ Live
  /\ moves = 0
  /\ chainOwner' = [chainOwner EXCEPT !["k1"] = IF @ = "O1" THEN "O2" ELSE "O1"]
  /\ chainEpoch' = [chainEpoch EXCEPT !["k1"] = @ + 1]
  /\ endedAt' = IF endedAt = Never /\ chainShard.status = "issued" THEN now ELSE endedAt
  /\ pending' = Append(pending, [kind |-> "move", owner |-> chainOwner'["k1"],
                                 epoch |-> chainEpoch'["k1"], at |-> now])
  /\ moves' = moves + 1
  /\ UNCHANGED <<now, chainShard, recOwner, recEpoch, recShard, observedAt, behindAt, write>>

(* --- time and the reader ------------------------------------------------ *)

Tick ==
  /\ Live
  /\ write.phase /= "checked"     \* a write's check and save share one tick
  /\ now < MaxTime
  /\ now' = now + 1
  /\ UNCHANGED <<chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
                 recEpoch, recShard, observedAt, behindAt, moves, write>>

Apply(e, o, ep, sh) ==
  IF e.kind = "shard" THEN <<o, ep, e.shard>>
  ELSE <<[o EXCEPT !["k1"] = e.owner], [ep EXCEPT !["k1"] = e.epoch], sh>>

RECURSIVE ApplyAll(_, _, _, _)
ApplyAll(es, o, ep, sh) ==
  IF es = <<>> THEN <<o, ep, sh>>
  ELSE LET r == Apply(Head(es), o, ep, sh) IN ApplyAll(Tail(es), r[1], r[2], r[3])

(* A reading records the oldest n pending events (n may be 0: a slow read). *)
ReaderReads(n) ==
  /\ Live
  /\ n <= Len(pending)
  /\ (ReadsAll => n = Len(pending))
  /\ LET done == SubSeq(pending, 1, n)
         rest == SubSeq(pending, n + 1, Len(pending))
         r == ApplyAll(done, recOwner, recEpoch, recShard)
     IN /\ recOwner' = r[1]
        /\ recEpoch' = r[2]
        /\ recShard' = r[3]
        /\ pending' = rest
        /\ behindAt' = IF rest = <<>> THEN 0 ELSE now - Head(rest).at
  /\ observedAt' = now
  /\ UNCHANGED <<now, chainOwner, chainEpoch, chainShard, endedAt, moves, write>>

(* --- the site's check --------------------------------------------------- *)

(* What the site's record says about A's shard of k now. The rules use this;
   the check below is the code's, and run.sh removes one part of it at a time. *)
RecordedActive(k) ==
  /\ recShard.status = "issued"
  /\ recShard.key = k
  /\ recShard.expires > now
  /\ recShard.epoch = recEpoch[recShard.key]

Fresh ==
  \/ Broken = "no_fresh_check"
  \/ (now - observedAt <= S /\ behindAt < B)

ShardActive(k) ==
  /\ recShard.status = "issued"
  /\ (recShard.key = k \/ Broken = "shard_any_key")
  /\ (recShard.expires > now \/ Broken = "no_expiry_check")
  /\ (recShard.epoch = recEpoch[recShard.key] \/ Broken = "no_epoch_check")

AnyShardActive == \E k \in Keys : ShardActive(k)

Via(k) ==
  IF ShardActive(k) THEN "shard"
  ELSE IF recOwner[k] \in PersonWallets /\ (~AnyShardActive \/ Broken = "paired_with_shard")
    THEN "paired"
  ELSE "none"

AgentWritesAs(k) ==
  /\ Writes
  /\ write.phase = "not_sent"
  /\ write' = IF Fresh /\ Via(k) /= "none"
                THEN [NoWrite EXCEPT !.phase = "checked", !.asKey = k, !.via = Via(k),
                        !.anyShardAtCheck = \E j \in Keys : RecordedActive(j),
                        !.shardExpires = recShard.expires,
                        !.epochCurrent = (recShard.key \in Keys /\ recShard.epoch = recEpoch[recShard.key])]
                ELSE [NoWrite EXCEPT !.phase = "refused", !.asKey = k]
  /\ UNCHANGED <<now, chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
                 recEpoch, recShard, observedAt, behindAt, moves>>

ChainActive ==
  /\ chainShard.status = "issued"
  /\ chainShard.expires > now
  /\ chainShard.epoch = chainEpoch["k1"]

Commit ==
  /\ write.phase = "checked"
  /\ write' = [write EXCEPT !.phase = "saved",
                 !.atCommitActive = RecordedActive(write.asKey),
                 !.chainActiveAtCommit = ChainActive,
                 !.endedAge = IF endedAt = Never THEN 0 ELSE now - endedAt]
  /\ UNCHANGED <<now, chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
                 recEpoch, recShard, observedAt, behindAt, moves>>

Done ==
  /\ write.phase \in {"saved", "refused"}
  /\ UNCHANGED vars

Next ==
  \/ OwnerIssuesShard
  \/ ShardEnds
  \/ KeyMoves
  \/ Tick
  \/ \E n \in 0..3 : ReaderReads(n)
  \/ \E k \in Keys : AgentWritesAs(k)
  \/ Commit
  \/ Done

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Rules                                                                   *)
(***************************************************************************)

TypeOK ==
  /\ now \in 0..MaxTime
  /\ write.phase \in {"not_sent", "checked", "saved", "refused"}
  /\ Len(pending) <= 3

ShardWrite == write.phase \in {"checked", "saved"} /\ write.via = "shard"

(* A shard lets A act only as the Key it is a shard of. *)
ShardOnlyForItsKey == ShardWrite => write.asKey = "k1"

(* A shard that has run out by the clock gives nothing, at once: its end
   time is the one recorded with it, and the check compares it with now. *)
NothingAfterExpiry == ShardWrite => write.shardExpires > now

(* Once the site has recorded that the Key moved, its shards give nothing:
   the shard was issued in an earlier ownership epoch. *)
NothingAfterRecordedMove == ShardWrite => write.epochCurrent

(* Once the site has recorded the end, the move or the expiry, the shard
   gives nothing more, also to a write already checked and not yet saved
   (expected to break: nothing holds the record between the check and the
   save). *)
NothingAfterRecordedEnd == (write.phase = "saved" /\ write.via = "shard") => write.atCommitActive

(* After the shard ends on the chain or its Key moves, a write through it is
   still saved only while the site's reading is fresh: within S + B ticks. *)
EndsWithinFreshWindow ==
  (write.phase = "saved" /\ write.via = "shard" /\ ~write.chainActiveAtCommit)
    => write.endedAge < S + B

(* Not a promise the code makes: the gap between the chain and the site's
   reading, which EndsWithinFreshWindow bounds. run.sh expects it to break. *)
NothingAfterChainEnd ==
  (write.phase = "saved" /\ write.via = "shard") => write.chainActiveAtCommit

(* An agent holding an active shard in the fleet acts as that shard, never
   as its person's Key. *)
PairedOnlyWithoutShard ==
  (write.phase \in {"checked", "saved"} /\ write.via = "paired") => ~write.anyShardAtCheck
=============================================================================
