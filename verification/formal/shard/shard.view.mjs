// Words for the shard chart. S and B match ShardLife-chart.cfg.
const S = 0;
const B = 1;

const fresh = (v) => v.now - v.observedAt <= S && v.behindAt < B;
const chainRight = (v) =>
  v.chainShard.status === "issued" && v.chainShard.expires > v.now && v.chainShard.epoch === v.chainEpoch.k1;
const siteRight = (v) =>
  v.recShard.status === "issued" && v.recShard.expires > v.now && v.recShard.epoch === v.recEpoch[v.recShard.key];

export const title = "A shard's life, as the chain and Keyfleet see it";

export const state = (v) => {
  if (v.chainShard.status === "none") return "No shard";
  if (v.chainShard.expires <= v.now) return "Ran out";
  if (v.recShard.status === "none") return "Given, not read yet";
  if (siteRight(v) && chainRight(v)) return fresh(v) ? "Active" : "Active, reading late";
  if (siteRight(v)) return fresh(v) ? "Ended on chain, still counted" : "Ended on chain, reading late";
  return v.recShard.status === "ended" ? "Ended" : "Key moved";
};

export const group = (v) => {
  if (!(siteRight(v) && fresh(v))) return "Gives nothing";
  return chainRight(v) ? "Gives rights" : "Still counted";
};

export const colors = { "Gives rights": "teal", "Still counted": "orange", "Gives nothing": "tan" };

export const step = (action, from, to) => {
  switch (action) {
    case "OwnerIssuesShard": return "the Key's owner gives the shard";
    case "ShardEnds": return "the owner or the agent ends it";
    case "KeyMoves": return "the Key changes hands";
    case "Tick":
      if (to.chainShard.expires <= to.now && from.chainShard.expires > from.now) return "its time runs out";
      return "Keyfleet's last reading gets old";
    case "ReaderReads":
      if (state(from) === "Given, not read yet" && state(to) !== "Active")
        return "Keyfleet reads the chain [it ended meanwhile]";
      return "Keyfleet reads the chain";
    default: return null;
  }
};
