defmodule Keyfleet.Actors.Agent do
  @moduledoc """
  Product principal constructed by trusted code after SIWA wallet verification.

  This struct is not proof by itself and must never be deserialized from client
  input. The one place it is rebuilt is a picture upload, from the upload
  ticket this site signed for it after verifying the agent's signed request
  (`KeyfleetWeb.AgentAvatarController`). Its authority covers the wallet's
  profile and building the transactions its own wallet sends; the contracts
  decide what those may do.

  `credential_ref` names the signed request's credential, `sha256:` over its
  receipt and key id, so an audit record can cite it without holding it, and
  `receipt_expires_at` is when that receipt, the agent's sign-in, runs out.

  `chain_id` is the chain the agent signed in on, Ethereum (1) or Base (8453),
  and `verification_method` how SIWA proved the wallet. A plain wallet's
  signature (`:eoa_recovery`) proves its key, which is the same on every chain.
  A smart wallet's (`:erc1271`, `:erc6492`) proves it only on the chain it was
  checked on, and Keyfleet's Keys are on Base, so a smart wallet counts only
  when it signed in on Base.

  `registry_url`, `human_id` and `same_person_agent_count` are what the SIWA
  service said about the agent with this request: its page in the agent
  registry, and the World ID person behind it with how many agents that person
  stands behind (`RegentAgents.HumanBacking`), each nil when there is none. The
  agent's profile saves them. The person's number is never shown or logged.

  `pairing` says whether the agent may also write as the person it is paired
  with (`Keyfleet.Agents.pairing/1`): that person's account here, as a
  `Keyfleet.Actors.Human`, when the agent is paired with them on regents.sh and
  backed by a person verified with World ID; otherwise what it is missing,
  `:none` (not paired), `:not_backed` or `:person_not_here` (the person has no
  account here). It never signs with the person's wallets: what it writes as
  them is marked as its own.
  """
  @enforce_keys [:wallet_address, :chain_id, :verification_method, :audience]
  @derive {Inspect, except: [:human_id]}
  defstruct [
    :wallet_address,
    :chain_id,
    :verification_method,
    :audience,
    :credential_ref,
    :receipt_expires_at,
    :registry_url,
    :human_id,
    :same_person_agent_count,
    pairing: :none
  ]

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          chain_id: 1 | 8453,
          verification_method: :eoa_recovery | :erc1271 | :erc6492,
          audience: String.t(),
          credential_ref: String.t() | nil,
          receipt_expires_at: DateTime.t() | nil,
          registry_url: String.t() | nil,
          human_id: String.t() | nil,
          same_person_agent_count: pos_integer() | nil,
          pairing: Keyfleet.Actors.Human.t() | :none | :not_backed | :person_not_here
        }

  def valid?(%__MODULE__{
        wallet_address: wallet,
        chain_id: chain_id,
        verification_method: method,
        audience: "keyfleet"
      })
      when is_binary(wallet) and
             ((method == :eoa_recovery and chain_id in [1, 8453]) or
                (method in [:erc1271, :erc6492] and chain_id == 8453)),
      do: Regex.match?(~r/\A0x[0-9a-f]{40}\z/, wallet)

  def valid?(_), do: false
end
