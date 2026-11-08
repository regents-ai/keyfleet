// Words for the pairing chart: what the person and the agent can see.
const paired = (v) => v.row.episode !== 0;
const codeWaiting = (v) => Object.values(v.code).includes("issued");

export const title = "An agent's pairing and one write";

export const state = (v) => {
  const w = v.write;
  if (w.phase === "refused") return "Refused";
  if (w.phase === "committed" || w.phase === "answered")
    return w.landed ? "Saved" : "Saved after unpair";
  if (w.phase === "checked") return paired(v) ? "Cleared to save" : "Cleared, then unpaired";
  if (w.phase === "admitted") return paired(v) ? "Being checked" : "Unpaired while checked";
  if (paired(v)) return v.receipt === "valid" ? "Paired" : "Paired, signed out";
  return codeWaiting(v) ? "Code waiting" : "Not paired";
};

export const group = (v) => {
  const s = state(v);
  if (s === "Not paired" || s === "Code waiting") return "Not paired yet";
  if (s.startsWith("Paired")) return "Paired";
  if (s === "Refused") return "Refused";
  if (s.startsWith("Saved")) return "Saved";
  return "Write on its way";
};

export const colors = {
  "Not paired yet": "blue",
  Paired: "teal",
  "Write on its way": "yellow",
  Saved: "tan",
  Refused: "pink",
};

const why = (v) => {
  if (!paired(v)) return " [not paired]";
  if (v.receipt !== "valid") return " [signed out]";
  if (v.wallet === "smart_eth") return " [smart wallet on Ethereum]";
  return "";
};

export const step = (action, from, to) => {
  switch (action) {
    case "PersonMakesCode": return "the person makes a pairing code";
    case "CodeRunsOut": return "the code runs out";
    case "AgentPairs": return "the agent pairs with the code";
    // An unpair while a new code waits repeats the plain unpair arrow.
    case "PersonUnpairs":
      return to.write.phase === "not_sent" && codeWaiting(to) ? null : "the person unpairs the agent";
    case "SignInRunsOut": return "the agent's sign-in runs out";
    case "AgentSignsInAgain": return "the agent signs in again";
    case "AgentSends": return "the agent sends a write" + (to.write.phase === "refused" ? why(from) : "");
    case "Recheck": return to.write.phase === "refused" ? "the second check finds no pairing" : "the second check finds the same pairing";
    case "Commit": return "the write is saved";
    case "Answer": return "the answer leaves";
    case "Done": return null;
    default: return action;
  }
};
