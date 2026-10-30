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

  `pairing_id` and `privy_user_id` identify the current server-resolved
  delegation episode. World ID is optional. Pairing admits protected work;
  Key and shard ownership still decide the product permissions.

  `owner?` is true for an agent that opened its own account
  (`Keyfleet.Accounts.AgentAccount`): it acts for that account as its owner,
  `pairing` names the account, and there is no pairing, so `pairing_id` is nil.

  `connection` is set when the agent is a connected app's own identity, such
  as Claude's, acting at `/mcp` with the token its person approved: what
  `RegentOAuth.verify/3` answered for that token. Its `verification_method`
  is then `:connected_app`, its wallet the one the sign-in server holds for it
  (`Keyfleet.Agents.HostedAddress`), and `credential_ref` names the token. The
  same app may then also run its identity tools (`Keyfleet.Agents.Connection`).
  """
  @enforce_keys [:wallet_address, :chain_id, :verification_method, :audience]
  @derive {Inspect, except: [:human_id, :connection]}
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
    :pairing_id,
    :privy_user_id,
    :human_account_id,
    :connection,
    role: :agent,
    owner?: false,
    pairing: :none
  ]

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          chain_id: 1 | 8453,
          verification_method: :eoa_recovery | :erc1271 | :erc6492 | :connected_app,
          audience: String.t(),
          credential_ref: String.t() | nil,
          receipt_expires_at: DateTime.t() | nil,
          registry_url: String.t() | nil,
          human_id: String.t() | nil,
          same_person_agent_count: pos_integer() | nil,
          owner?: boolean(),
          pairing: Keyfleet.Actors.Human.t() | :none | :person_not_here
        }

  def authenticated?(%__MODULE__{
        wallet_address: wallet,
        chain_id: chain_id,
        verification_method: method,
        audience: "keyfleet"
      })
      when is_binary(wallet) and
             ((method == :eoa_recovery and chain_id in [1, 8453]) or
                (method in [:erc1271, :erc6492, :connected_app] and chain_id == 8453)),
      do: Regex.match?(~r/\A0x[0-9a-f]{40}\z/, wallet)

  def authenticated?(_), do: false

  @doc """
  Refresh account wallets without replacing the original pairing episode, or,
  for an agent that owns its account, while the wallet still owns that account.
  """
  def refresh(%__MODULE__{owner?: true, human_account_id: account} = actor)
      when is_integer(account) do
    with true <- authenticated?(actor),
         {:ok, %__MODULE__{owner?: true, human_account_id: ^account} = current} <-
           Keyfleet.Agents.with_pairing(actor) do
      {:ok, current}
    else
      _ -> {:error, :not_paired}
    end
  end

  def refresh(%__MODULE__{pairing_id: id, privy_user_id: owner} = actor)
      when is_binary(id) and is_binary(owner) do
    with true <- authenticated?(actor),
         {:ok, %__MODULE__{pairing_id: ^id, privy_user_id: ^owner} = current} <-
           Keyfleet.Agents.with_pairing(actor) do
      {:ok, current}
    else
      _ -> {:error, :not_paired}
    end
  end

  def refresh(_), do: {:error, :not_paired}

  def valid?(%__MODULE__{owner?: true, human_account_id: account} = actor)
      when is_integer(account) do
    authenticated?(actor) and
      case Keyfleet.Accounts.AgentAccount.owned(actor.wallet_address) do
        {:ok, %{id: ^account}} -> true
        _ -> false
      end
  end

  def valid?(%__MODULE__{pairing_id: id, privy_user_id: owner} = actor)
      when is_binary(id) and is_binary(owner) do
    authenticated?(actor) and
      case RegentAgents.Authority.resolve(Keyfleet.Repo, actor.wallet_address) do
        {:ok, %{id: ^id, privy_user_id: ^owner}} -> true
        _ -> false
      end
  end

  def valid?(_), do: false
end
