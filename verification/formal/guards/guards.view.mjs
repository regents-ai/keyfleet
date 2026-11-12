// Words for the guard chart: the checks one agent request passes, in order.
const restrictionChecked = [
  "workspace_edit",
  "workspace_fork",
  "workspace_pin",
  "notebook_write",
  "code_push",
  "project_delete",
];

const saved = {
  poll_vote: "Poll vote counted",
  workspace_pin: "Pin saved",
  project_delete: "Project deleted",
  dm_send: "Message sent",
};

export const title = "What a paired agent's request passes";

export const state = (v) => {
  switch (v.phase) {
    case "sent": return "Sent";
    case "signed_in": return "Signed in";
    case "paired": return "Paired";
    case "stands": return "Acts as the Key";
    case "fresh": return "Reading current";
    case "unrestricted": return "Edits open";
    case "allowed": return saved[v.action] ?? "Saved";
    case "refused": return "Refused";
    case "built": return "Wallet step built";
    case "handed_over": return "Handed to the wallet";
    case "blocked": return "Blocked";
    case "landed": return "Landed on chain";
    case "reverted": return "Reverted";
  }
};

export const group = (v) => {
  if (v.phase === "refused") return "Refused";
  if (v.phase === "allowed") return "Let through";
  if (["built", "handed_over", "blocked"].includes(v.phase)) return "Wallet step";
  if (["landed", "reverted"].includes(v.phase)) return "On chain";
  return "Checks";
};

export const colors = {
  Checks: "blue",
  "Let through": "teal",
  Refused: "pink",
  "Wallet step": "yellow",
  "On chain": "tan",
};

export const step = (action, from, to) => {
  const refused = to.phase === "refused";
  switch (action) {
    case "CheckSignIn":
      return refused ? "the sign-in fails" : "the agent signs in";
    case "CheckPairing":
      if (refused) return "no pairing";
      return to.phase === "built" ? "its pairing is found [wallet step]" : "its pairing is found";
    case "CheckStanding":
      return refused ? "it acts as no Key" : "it acts as the Key";
    case "CheckFresh":
      return refused ? "the chain reading is late" : "the chain reading is current";
    case "CheckRestriction":
      if (refused) return "the Key's edits are restricted";
      return restrictionChecked.includes(from.action)
        ? "the Key's edits are open"
        : "no restriction check [polls, messages]";
    case "CheckRule":
      if (refused && to.reason === "agent_voting_off") return "the Key's agent voting is off";
      return refused ? "the action's own rule says no" : "the action's own rule allows it";
    case "ReadHead":
      if (refused) return "the chain doesn't answer which Keys reached it";
      return to.phase === "handed_over"
        ? "the chain says it may act for the Key"
        : "the chain says it may not act for the Key";
    case "ContractRuns":
      return to.phase === "landed" ? "the contract takes it" : "the contract refuses it";
    default:
      return null;
  }
};
